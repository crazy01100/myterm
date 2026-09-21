import Combine
import Foundation

enum AutomaticSyncTrigger: String, Codable, Sendable {
    // `retry` remains decodable for older local journals; no code emits it now.
    case launch, foreground, periodic, localChange, logsOpened, manual, confirmedRecentOverwrite, retry, wake, availability
}

enum SyncRoundContext {
    @TaskLocal static var id: UUID?
}

enum SyncAttemptOutcome: Equatable, Sendable {
    case completed, disabled, cancelled
    case waiting(String), retryable(String), failed(String)

    var message: String {
        switch self {
        case .completed: "同步完成"
        case .disabled: "未啟用"
        case .cancelled: "同步已取消"
        case .waiting(let value), .retryable(let value), .failed(let value): value
        }
    }

    static func failure(_ error: Error) -> Self {
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            if ns.code == NSURLErrorCancelled { return .cancelled }
            return .retryable("網路暫時無法完成同步，將自動重試。")
        }
        // Raw localized errors can contain account identifiers or file paths.
        if ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain {
            return .failed("本機同步資料無法讀寫，請檢查儲存空間與檔案權限。")
        }
        return .failed("同步未完成，請檢查帳號與同步設定；診斷記錄已保留錯誤代碼。")
    }
}

/// Owns scheduling, not encryption or merge policy. Injected operations also allow
/// deterministic tests of the same scheduler used by the App, without cloud access.
@MainActor
final class AutomaticSyncCoordinator: ObservableObject {
    struct Context: Equatable {
        let scope: String // in-memory only; never included in diagnostic events
        let enabled: Bool
    }
    struct Timing {
        var periodic: TimeInterval = 300
        var debounce: TimeInterval = 1.2
        var stale: TimeInterval = 60
        var deadline: TimeInterval = 120
    }
    typealias Operation = (AutomaticSyncTrigger) async -> SyncAttemptOutcome

    @Published private(set) var message = "尚未同步"
    @Published private(set) var lastSuccessfulSyncAt: Date?
    @Published private(set) var metadataOutcome: SyncAttemptOutcome?
    @Published private(set) var snippetsOutcome: SyncAttemptOutcome?
    @Published private(set) var logsOutcome: SyncAttemptOutcome?
    @Published private(set) var isRunning = false
    @Published private(set) var isEnabled = false

    private var context: (() -> Context)?
    private var prepare: (() -> Void)?
    private var metadata: Operation?
    private var logs: Operation?
    private var snippets: Operation = { _ in .disabled }
    private var task: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var sessionRecoveryTask: Task<Void, Never>?
    private var canRecoverSession: (() -> Bool)?
    private var recoverSession: (() async -> Void)?
    private var deadlineTask: Task<Void, Never>?
    private var pending: AutomaticSyncTrigger?
    private var deferAutomaticChanges = false
    private var active = false
    private var generation = 0
    private var currentContext: Context?
    private var restoredScope: String?
    private let defaults: UserDefaults
    private let timing: Timing
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private let journal: SyncDiagnosticsJournal

    init(defaults: UserDefaults = .standard, timing: Timing = Timing(), now: @escaping () -> Date = Date.init,
         journal: SyncDiagnosticsJournal? = nil,
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.defaults = defaults
        self.timing = timing
        self.now = now
        self.sleep = sleep
        self.journal = journal ?? .shared
    }

    func configure(context: @escaping () -> Context, prepare: @escaping () -> Void,
                   canRecoverSession: @escaping () -> Bool = { false },
                   recoverSession: @escaping () async -> Void = {},
                   metadata: @escaping Operation, logs: @escaping Operation, snippets: @escaping Operation = { _ in .disabled }) {
        guard self.context == nil else { return }
        self.context = context
        self.prepare = prepare
        self.canRecoverSession = canRecoverSession
        self.recoverSession = recoverSession
        self.metadata = metadata
        self.logs = logs
        self.snippets = snippets
        journal.record(.lifecycle, .preparing)
    }

    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        periodicTask?.cancel()
        periodicTask = nil
        if active {
            request(.foreground)
            periodicTask = Task { [weak self, sleep, timing] in
                while !Task.isCancelled {
                    do { try await sleep(timing.periodic) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.request(.periodic)
                }
            }
        }
    }

    func request(_ trigger: AutomaticSyncTrigger) {
        guard let context, let metadata, let logs else { return }
        prepare?()
        let snapshot = context()
        if currentContext != snapshot {
            generation += 1
            currentContext = snapshot
            task?.cancel()
            pending = nil
            metadataOutcome = nil
            logsOutcome = nil
            snippetsOutcome = nil
            deferAutomaticChanges = false
        }
        isEnabled = snapshot.enabled
        if restoredScope != snapshot.scope {
            restoredScope = snapshot.scope
            lastSuccessfulSyncAt = defaults.object(forKey: "cloudSync.round.lastSuccess.v1." + snapshot.scope) as? Date
        }
        guard snapshot.enabled else {
            message = sessionRecoveryTask != nil ? "正在恢復登入…"
                : (canRecoverSession?() == true ? "等待登入恢復，將於下一次同步時再試" : "自動同步已關閉")
            journal.record(.coordinator, .disabled, trigger: trigger)
            // Startup already attempts restoration once. State-change callbacks must
            // never immediately retry that same failure; use the existing next tick.
            if Self.isRecoveryTrigger(trigger), canRecoverSession?() == true {
                recoverSessionOnThisPass()
            }
            return
        }
        if trigger == .logsOpened, let lastSuccessfulSyncAt,
           now().timeIntervalSince(lastSuccessfulSyncAt) < timing.stale { return }
        if deferAutomaticChanges && !Self.isRecoveryTrigger(trigger) { return }
        journal.record(.coordinator, .requested, trigger: trigger)
        guard task == nil else {
            // A confirmation is explicit authority for only the next pass; never downgrade it.
            if pending != .confirmedRecentOverwrite { pending = trigger }
            journal.record(.coordinator, .queued, trigger: trigger)
            return
        }
        let thisGeneration = generation
        let roundID = UUID()
        isRunning = true
        message = trigger == .localChange ? "已排入同步" : "正在同步…"
        task = Task { [weak self, sleep, timing] in
            guard let self else { return }
            if trigger == .localChange {
                do { try await sleep(timing.debounce) } catch {
                    self.finishCancelled(contextChanged: thisGeneration != self.generation)
                    return
                }
            }
            guard !Task.isCancelled, thisGeneration == self.generation else {
                self.finishCancelled(contextChanged: thisGeneration != self.generation)
                return
            }
            self.journal.record(.coordinator, .started, trigger: trigger, roundID: roundID)
            let (metadataResult, logsResult, snippetsResult) = await SyncRoundContext.$id.withValue(roundID) {
                async let first = metadata(trigger)
                async let second = logs(trigger)
                async let third = self.snippets(trigger)
                return await (first, second, third)
            }
            // Wait for all operations to release their resources even after cancellation.
            guard !Task.isCancelled, thisGeneration == self.generation, context() == snapshot else {
                self.finishCancelled(contextChanged: thisGeneration != self.generation)
                return
            }
            self.metadataOutcome = metadataResult
            self.logsOutcome = logsResult
            self.snippetsOutcome = snippetsResult
            let allCompleted = metadataResult == .completed && logsResult == .completed && (snippetsResult == .completed || snippetsResult == .disabled)
            self.deferAutomaticChanges = !allCompleted
            if allCompleted {
                let date = self.now()
                self.lastSuccessfulSyncAt = date
                self.defaults.set(date, forKey: "cloudSync.round.lastSuccess.v1." + snapshot.scope)
                self.message = "同步完成"
                self.journal.record(.coordinator, .completed, roundID: roundID)
            } else {
                self.message = "同步尚未全部完成"
                self.journal.record(.coordinator, .incomplete, roundID: roundID)
            }
            self.task = nil
            self.deadlineTask?.cancel()
            self.deadlineTask = nil
            self.isRunning = false
            if let pending = self.pending {
                self.pending = nil
                if allCompleted || Self.isRecoveryTrigger(pending) {
                    self.request(pending)
                }
            }
        }
        deadlineTask = Task { [weak self, sleep, timing] in
            do { try await sleep(timing.deadline) } catch { return }
            guard !Task.isCancelled, let self, self.generation == thisGeneration, self.task != nil else { return }
            self.message = "同步逾時，等待下一次同步"
            self.journal.record(.coordinator, .timedOut, roundID: roundID)
            self.task?.cancel()
        }
    }

    func showDeclinedConfirmation() {
        metadataOutcome = .waiting("已選擇不更新；主機或密碼變更尚未同步。")
        message = "同步尚未全部完成"
    }

    private func finishCancelled(contextChanged: Bool) {
        deadlineTask?.cancel()
        deadlineTask = nil
        task = nil
        isRunning = false
        deferAutomaticChanges = !contextChanged
        message = isEnabled ? "同步已取消，等待下一次同步" : "自動同步已關閉"
        journal.record(.coordinator, .cancelled)
        if let pending {
            self.pending = nil
            if contextChanged || Self.isRecoveryTrigger(pending) { request(pending) }
        }
    }

    private static func isRecoveryTrigger(_ trigger: AutomaticSyncTrigger) -> Bool {
        switch trigger {
        case .periodic, .foreground, .wake, .manual, .confirmedRecentOverwrite: return true
        default: return false
        }
    }

    private func recoverSessionOnThisPass() {
        guard sessionRecoveryTask == nil, let recoverSession else { return }
        message = "正在恢復登入…"
        sessionRecoveryTask = Task { [weak self] in
            await recoverSession()
            guard let self else { return }
            self.sessionRecoveryTask = nil
            self.prepare?()
            if self.task == nil { self.request(.availability) }
        }
    }
}
