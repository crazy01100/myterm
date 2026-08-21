import SwiftUI

struct ConnectionAuditLogView: View {
    @EnvironmentObject private var store: ConnectionAuditStore
    @State private var searchText = ""
    @State private var filter: ConnectionAuditFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = store.lastError {
                errorBanner(error)
            }
            if filteredRecords.isEmpty {
                emptyState
            } else {
                recordList
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Logs")
                    .font(.title2.bold())
                Text("\(store.records.count) 筆互動式 SSH 連線記錄 · 保留 30 天")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("搜尋主機、帳號、位址或裝置", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            Picker("結果", selection: $filter) {
                ForEach(ConnectionAuditFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 145)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var recordList: some View {
        GeometryReader { proxy in
            let layout = ConnectionAuditColumnLayout(containerWidth: proxy.size.width)

            VStack(spacing: 0) {
                HStack(spacing: layout.spacing) {
                    Text("時間")
                        .frame(width: layout.timeWidth, alignment: .leading)
                    Text("主機與連線")
                        .frame(width: layout.hostWidth, alignment: .leading)
                    Text("來源裝置")
                        .frame(width: layout.deviceWidth, alignment: .leading)
                    Text("結果")
                        .frame(width: layout.resultWidth, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.035))

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredRecords) { record in
                            ConnectionAuditRow(record: record, layout: layout)
                            Divider().padding(.leading, 24)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                searchText.isEmpty && filter == .all ? "尚無連線記錄" : "找不到符合的記錄",
                systemImage: "clock.arrow.circlepath"
            )
        } description: {
            Text(
                searchText.isEmpty && filter == .all
                    ? "從這個版本開始，由主機庫開啟的互動式 SSH 連線會記錄於此；不會保存命令或終端輸出。"
                    : "請調整搜尋文字或結果篩選。"
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.08))
    }

    private var filteredRecords: [ConnectionAuditRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.records.filter { record in
            filter.matches(record.status) && (query.isEmpty || searchableText(for: record)
                .localizedCaseInsensitiveContains(query))
        }
    }

    private func searchableText(for record: ConnectionAuditRecord) -> String {
        "\(record.hostName) \(record.username) \(record.hostname) \(record.port) \(record.sourceDeviceName ?? "")"
    }
}

private struct ConnectionAuditRow: View {
    let record: ConnectionAuditRecord
    let layout: ConnectionAuditColumnLayout

    var body: some View {
        Group {
            if record.status.isOngoing {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    content(now: context.date)
                }
            } else {
                content(now: record.endedAt ?? record.startedAt)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private func content(now: Date) -> some View {
        HStack(spacing: layout.spacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.startedAt.formatted(
                    .dateTime.year().month(.abbreviated).day()
                        .locale(Locale(identifier: "zh_Hant_TW"))
                ))
                .font(.body.weight(.medium))
                Text(timeRange)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(durationText(now: now))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .frame(width: layout.timeWidth, alignment: .leading)

            HStack(spacing: 12) {
                platformBadge
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.hostName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text("SSH · \(record.username)@\(record.hostname):\(record.port)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            .frame(width: layout.hostWidth, alignment: .leading)

            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer")
                    .frame(width: 18)
                Text(record.sourceDeviceName ?? "舊版未記錄")
                    .lineLimit(1)
            }
            .font(.callout.weight(.medium))
            .frame(width: layout.deviceWidth, alignment: .leading)
            .help(record.sourceDeviceName ?? "舊版未記錄")

            VStack(alignment: .leading, spacing: 4) {
                Label(statusTitle, systemImage: statusIcon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(statusColor)
                if let detail = resultDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(width: layout.resultWidth, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .contentShape(.rect)
    }

    @ViewBuilder
    private var platformBadge: some View {
        if let platform = record.platform {
            HostPlatformBadge(platform: platform, size: 42)
        } else {
            Image(systemName: "network")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 42, height: 42)
                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 9))
        }
    }

    private var timeRange: String {
        let start = shortTime(record.startedAt)
        if record.status.isOngoing { return "\(start)－現在" }
        guard let endedAt = record.endedAt else { return "\(start)－—" }
        return "\(start)－\(shortTime(endedAt))"
    }

    private func shortTime(_ date: Date) -> String {
        date.formatted(
            .dateTime.hour().minute().second()
                .locale(Locale(identifier: "zh_Hant_TW"))
        )
    }

    private func durationText(now: Date) -> String {
        guard record.status != .interrupted else { return "持續時間 —" }
        let end = record.endedAt ?? now
        let seconds = max(Int(end.timeIntervalSince(record.startedAt)), 0)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 { return String(format: "持續 %d:%02d:%02d", hours, minutes, remainingSeconds) }
        return String(format: "持續 %d:%02d", minutes, remainingSeconds)
    }

    private var statusTitle: String {
        switch record.status {
        case .connecting: "連線中"
        case .connected: "已連線"
        case .completed: "已完成"
        case .failed: "連線失敗"
        case .cancelled: "已取消"
        case .interrupted: "未完整結束"
        }
    }

    private var statusIcon: String {
        switch record.status {
        case .connecting: "ellipsis.circle.fill"
        case .connected: "circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "minus.circle.fill"
        case .interrupted: "exclamationmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch record.status {
        case .connecting: .orange
        case .connected, .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        case .interrupted: .orange
        }
    }

    private var resultDetail: String? {
        switch record.status {
        case .failed: record.failureTitle ?? "SSH 連線未完成"
        case .interrupted: "前次 App 未正常收尾"
        case .connected: "工作階段進行中"
        default: nil
        }
    }

    private var accessibilityDescription: String {
        "\(record.hostName)，SSH \(record.username) at \(record.hostname) port \(record.port)，來源裝置 \(record.sourceDeviceName ?? "未知")，\(statusTitle)，開始時間 \(record.startedAt.formatted())"
    }
}

private struct ConnectionAuditColumnLayout {
    let timeWidth: CGFloat
    let hostWidth: CGFloat
    let deviceWidth: CGFloat
    let resultWidth: CGFloat
    let spacing: CGFloat = 14

    init(containerWidth: CGFloat) {
        let horizontalPadding: CGFloat = 48
        let totalSpacing = spacing * 3
        let availableWidth = max(containerWidth - horizontalPadding - totalSpacing, 0)
        let minimumTotalWidth: CGFloat = 750
        let maximumTotalWidth: CGFloat = 1_370
        let progress = min(max(
            (availableWidth - minimumTotalWidth) / (maximumTotalWidth - minimumTotalWidth),
            0
        ), 1)
        let compression = min(max(availableWidth / minimumTotalWidth, 0.72), 1)

        func width(minimum: CGFloat, maximum: CGFloat) -> CGFloat {
            let responsiveWidth = minimum + ((maximum - minimum) * progress)
            return progress == 0 ? minimum * compression : responsiveWidth
        }

        timeWidth = width(minimum: 180, maximum: 210)
        hostWidth = width(minimum: 230, maximum: 520)
        deviceWidth = width(minimum: 200, maximum: 460)
        resultWidth = width(minimum: 140, maximum: 180)
    }
}

private enum ConnectionAuditFilter: String, CaseIterable, Identifiable {
    case all
    case completed
    case failed
    case ongoing

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "全部結果"
        case .completed: "成功／已完成"
        case .failed: "失敗／取消"
        case .ongoing: "進行中"
        }
    }

    func matches(_ status: ConnectionAuditStatus) -> Bool {
        switch self {
        case .all: true
        case .completed: status == .completed
        case .failed: status == .failed || status == .cancelled || status == .interrupted
        case .ongoing: status.isOngoing
        }
    }
}
