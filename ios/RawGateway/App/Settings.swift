import Foundation
import Security
import Combine

enum DeliveryMode: String, CaseIterable, Identifiable {
    case live
    case checkpoint
    case archiveOnly
    var id: String { rawValue }
}

final class Settings: ObservableObject {
    @Published var endpoint: String { didSet { defaults.set(endpoint, forKey: "endpoint") } }
    @Published var checkpoint: Int { didSet { defaults.set(checkpoint, forKey: "checkpoint") } }
    @Published var wifiOnly: Bool { didSet { defaults.set(wifiOnly, forKey: "wifiOnly") } }
    @Published var deliveryMode: DeliveryMode { didSet { defaults.set(deliveryMode.rawValue, forKey: "deliveryMode") } }
    @Published var dreamAIWebhook: String { didSet { defaults.set(dreamAIWebhook, forKey: "dreamAIWebhook") } }
    @Published var uploadsEnabled: Bool { didSet { defaults.set(uploadsEnabled, forKey: "uploadsEnabled") } }
    @Published var token: String
    @Published var tokenError = ""
    @Published var webhookToken: String
    @Published var webhookTokenError = ""
    private let defaults = UserDefaults.standard
    private let service = "KeepsakeRawGateway.server-token"
    private let webhookService = "KeepsakeRawGateway.webhook-token"

    init() {
        if let saved = UserDefaults.standard.string(forKey: "deliveryMode"), let mode = DeliveryMode(rawValue: saved) {
            deliveryMode = mode
        } else if UserDefaults.standard.object(forKey: "dreamAIStreaming") != nil && !UserDefaults.standard.bool(forKey: "dreamAIStreaming") {
            deliveryMode = .archiveOnly
        } else {
            deliveryMode = .live
        }
        dreamAIWebhook = UserDefaults.standard.string(forKey: "dreamAIWebhook") ?? "https://aadeshai.xyz/omi/webhook/audio?sample_rate=16000&uid=iphone_user"
        uploadsEnabled = UserDefaults.standard.bool(forKey: "uploadsEnabled")
        endpoint = UserDefaults.standard.string(forKey: "endpoint") ?? ""
        checkpoint = UserDefaults.standard.object(forKey: "checkpoint") as? Int ?? 30
        wifiOnly = UserDefaults.standard.bool(forKey: "wifiOnly")

        // Load upload bearer token from Keychain
        token = Self.loadKeychain(service: "KeepsakeRawGateway.server-token", account: "upload") ?? ""
        tokenError = ""

        // Load webhook auth token from Keychain (or use default simple secret)
        if let saved = Self.loadKeychain(service: "KeepsakeRawGateway.webhook-token", account: "webhook"), !saved.isEmpty {
            webhookToken = saved
        } else {
            webhookToken = "keepsake-secret-2026"
            saveWebhookToken()
        }
        webhookTokenError = ""
    }

    func saveToken() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "upload"]
        let attrs: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil)
        }
        tokenError = status == errSecSuccess ? "" : "Could not save token (Keychain \(status))."
    }

    func saveWebhookToken() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: webhookService, kSecAttrAccount as String: "webhook"]
        let attrs: [String: Any] = [kSecValueData as String: Data(webhookToken.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil)
        }
        webhookTokenError = status == errSecSuccess ? "" : "Could not save webhook token (Keychain \(status))."
    }

    /// Build the webhook URL with auth token appended as a query param.
    var webhookURL: URL? {
        var urlString = dreamAIWebhook.trimmingCharacters(in: .whitespacesAndNewlines)
        if !webhookToken.isEmpty {
            let separator = urlString.contains("?") ? "&" : "?"
            urlString += "\(separator)token=\(webhookToken)"
        }
        return URL(string: urlString)
    }

    var uploadURL: URL? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }

    var checkpointURL: URL? {
        guard let webhook = URL(string: dreamAIWebhook.trimmingCharacters(in: .whitespacesAndNewlines)),
              webhook.scheme?.lowercased() == "https", webhook.host != nil else { return nil }
        var parts = URLComponents()
        parts.scheme = webhook.scheme
        parts.host = webhook.host
        parts.port = webhook.port
        parts.path = "/omi/webhook/checkpoint"
        return parts.url
    }

    // MARK: - Keychain Helpers

    private static func loadKeychain(service: String, account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
