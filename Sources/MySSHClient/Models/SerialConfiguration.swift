import Foundation

enum SerialParity: String, CaseIterable, Identifiable {
    case none, odd, even
    var id: Self { self }
    var title: String {
        switch self { case .none: "無"; case .odd: "奇數"; case .even: "偶數" }
    }
}

enum SerialFlowControl: String, CaseIterable, Identifiable {
    case none, rtsCts, xonXoff
    var id: Self { self }
    var title: String {
        switch self { case .none: "無"; case .rtsCts: "RTS/CTS"; case .xonXoff: "XON/XOFF" }
    }
}

enum SerialConfigurationError: LocalizedError {
    case invalidDevice
    case unsupportedBaudRate
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidDevice: "請選擇有效的本機 Serial Port。"
        case .unsupportedBaudRate: "不支援這個 Baud rate。"
        case .configurationFailed(let message): "無法設定 Serial Port：\(message)"
        }
    }
}

struct SerialConfiguration: Equatable {
    static let supportedBaudRates = [300, 1_200, 2_400, 4_800, 9_600, 19_200, 38_400, 57_600, 115_200, 230_400]

    var devicePath = ""
    var baudRate = 9_600
    var dataBits = 8
    var stopBits = 1
    var parity: SerialParity = .none
    var flowControl: SerialFlowControl = .none

    func validated(requireExistingDevice: Bool = true) throws -> SerialConfiguration {
        var result = self
        result.devicePath = devicePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSafePrefix = result.devicePath.hasPrefix("/dev/cu.") || result.devicePath.hasPrefix("/dev/tty.")
        guard hasSafePrefix,
              !result.devicePath.contains("\n"),
              !result.devicePath.contains("\0") else { throw SerialConfigurationError.invalidDevice }
        if requireExistingDevice {
            let attributes = try? FileManager.default.attributesOfItem(atPath: result.devicePath)
            guard attributes?[.type] as? FileAttributeType == .typeCharacterSpecial else {
                throw SerialConfigurationError.invalidDevice
            }
        }
        guard Self.supportedBaudRates.contains(result.baudRate) else {
            throw SerialConfigurationError.unsupportedBaudRate
        }
        guard (5...8).contains(result.dataBits), (1...2).contains(result.stopBits) else {
            throw SerialConfigurationError.invalidDevice
        }
        return result
    }

    var sttyArguments: [String] {
        var arguments = ["-f", devicePath, String(baudRate), "cs\(dataBits)"]
        arguments.append(stopBits == 2 ? "cstopb" : "-cstopb")
        switch parity {
        case .none: arguments += ["-parenb"]
        case .odd: arguments += ["parenb", "parodd"]
        case .even: arguments += ["parenb", "-parodd"]
        }
        switch flowControl {
        case .none: arguments += ["-ixon", "-ixoff", "-crtscts"]
        case .rtsCts: arguments += ["-ixon", "-ixoff", "crtscts"]
        case .xonXoff: arguments += ["ixon", "ixoff", "-crtscts"]
        }
        return arguments
    }

    var screenMode: String {
        let softwareFlow = flowControl == .xonXoff ? "ixon,ixoff" : "-ixon,-ixoff"
        return "\(baudRate),cs\(dataBits),\(softwareFlow),-istrip"
    }

    func prepareDevice() throws {
        let configuration = try validated()
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/stty")
        process.arguments = configuration.sttyArguments
        process.standardError = standardError
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SerialConfigurationError.configurationFailed(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SerialConfigurationError.configurationFailed(message?.isEmpty == false ? message! : "stty 結束碼 \(process.terminationStatus)")
        }
    }
}

enum SerialPortCatalog {
    static func availablePorts() -> [String] {
        let directory = URL(fileURLWithPath: "/dev", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let calloutPorts = names.filter { $0.hasPrefix("cu.") }.map { "/dev/\($0)" }
        if !calloutPorts.isEmpty { return calloutPorts.sorted() }
        return names.filter { $0.hasPrefix("tty.") }.map { "/dev/\($0)" }.sorted()
    }
}
