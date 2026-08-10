import Foundation

enum CloudConfigurationError: LocalizedError, Equatable {
    case missingFile
    case unreadableFile
    case missingValue(String)
    case invalidGoogleClientID
    case invalidGoogleClientSecret
    case invalidFirebaseAPIKey
    case invalidProjectID

    var errorDescription: String? {
        switch self {
        case .missingFile:
            "尚未加入 MyTerm 雲端設定檔。純本機功能不受影響。"
        case .unreadableFile:
            "MyTerm 雲端設定檔格式不正確。"
        case .missingValue(let key):
            "MyTerm 雲端設定缺少 \(key)。"
        case .invalidGoogleClientID:
            "Google Desktop OAuth Client ID 格式不正確。"
        case .invalidGoogleClientSecret:
            "Google Desktop OAuth Client Secret 格式不正確。"
        case .invalidFirebaseAPIKey:
            "雲端同步服務的 API Key 格式不正確。"
        case .invalidProjectID:
            "雲端同步服務的專案識別格式不正確。"
        }
    }
}

struct CloudConfiguration: Equatable, Sendable {
    static let resourceName = "MyTermCloudConfig"

    let googleDesktopClientID: String
    let googleDesktopClientSecret: String
    let firebaseAPIKey: String
    let firebaseProjectID: String

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: resourceName, withExtension: "plist") else {
            throw CloudConfigurationError.missingFile
        }
        do {
            return try parse(Data(contentsOf: url))
        } catch let error as CloudConfigurationError {
            throw error
        } catch {
            throw CloudConfigurationError.unreadableFile
        }
    }

    static func parse(_ data: Data) throws -> Self {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = object as? [String: Any] else {
            throw CloudConfigurationError.unreadableFile
        }

        func required(_ key: String) throws -> String {
            guard let value = values[key] as? String else {
                throw CloudConfigurationError.missingValue(key)
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw CloudConfigurationError.missingValue(key) }
            return trimmed
        }

        let clientID = try required("GOOGLE_DESKTOP_CLIENT_ID")
        let clientSecret = try required("GOOGLE_DESKTOP_CLIENT_SECRET")
        let apiKey = try required("FIREBASE_API_KEY")
        let projectID = try required("FIREBASE_PROJECT_ID")

        guard clientID.hasSuffix(".apps.googleusercontent.com"),
              !clientID.contains("YOUR_") else {
            throw CloudConfigurationError.invalidGoogleClientID
        }
        guard clientSecret.count >= 10, !clientSecret.contains("YOUR_") else {
            throw CloudConfigurationError.invalidGoogleClientSecret
        }
        guard apiKey.hasPrefix("AIza"), !apiKey.contains("YOUR_") else {
            throw CloudConfigurationError.invalidFirebaseAPIKey
        }
        let allowedProjectCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard projectID.rangeOfCharacter(from: allowedProjectCharacters.inverted) == nil,
              !projectID.contains("YOUR_") else {
            throw CloudConfigurationError.invalidProjectID
        }

        return Self(
            googleDesktopClientID: clientID,
            googleDesktopClientSecret: clientSecret,
            firebaseAPIKey: apiKey,
            firebaseProjectID: projectID
        )
    }
}
