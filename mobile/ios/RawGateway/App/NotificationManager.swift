import Foundation
import UserNotifications
import Combine

/// Centralized manager for local mobile notifications across Keepsake.
/// Delivers immediate user alerts for new decisions, battery level / charging events,
/// and connection state changes.
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    @Published var isAuthorized = false

    private let center = UNUserNotificationCenter.current()
    private let seenDecisionsKey = "notified_decision_ids_v1"
    private var seenDecisionIDs: Set<String> = []

    // State trackers to prevent duplicate or spammy battery notifications
    private var lastNotifiedChargingState: Bool? = nil
    private var lastNotifiedLowBatteryTimestamp: TimeInterval = 0
    private var lastNotifiedFullChargeTimestamp: TimeInterval = 0

    private override init() {
        super.init()
        center.delegate = self
        loadSeenDecisions()
        checkAuthorization()
    }

    // MARK: - Authorization

    func checkAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.isAuthorized = settings.authorizationStatus == .authorized
            }
        }
    }

    func requestPermissions() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
            }
        }
    }

    // MARK: - Foreground Presentation Delegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner and play sound even when the app is active in foreground
        completionHandler([.banner, .sound])
    }

    // MARK: - Decision Notifications

    private func loadSeenDecisions() {
        if let saved = UserDefaults.standard.stringArray(forKey: seenDecisionsKey) {
            seenDecisionIDs = Set(saved)
        }
    }

    private func saveSeenDecisions() {
        UserDefaults.standard.set(Array(seenDecisionIDs), forKey: seenDecisionsKey)
    }

    /// Seeds existing decision IDs without triggering notifications (called on first launch)
    func seedExistingDecisions(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        var modified = false
        for id in ids {
            if !seenDecisionIDs.contains(id) {
                seenDecisionIDs.insert(id)
                modified = true
            }
        }
        if modified {
            saveSeenDecisions()
        }
    }

    func notifyDecision(id: String, text: String, category: String? = nil, settings: Settings) {
        guard settings.notificationsEnabled && settings.decisionNotifications else { return }
        guard !seenDecisionIDs.contains(id) else { return }

        seenDecisionIDs.insert(id)
        saveSeenDecisions()

        let content = UNMutableNotificationContent()
        content.title = "🎯 Decision Tracked"
        if let cat = category, !cat.isEmpty && cat.lowercased() != "all" {
            content.subtitle = cat.capitalized
        }
        content.body = text
        content.sound = .default
        content.userInfo = ["decision_id": id]

        let request = UNNotificationRequest(
            identifier: "decision-\(id)",
            content: content,
            trigger: nil // Deliver immediately
        )

        center.add(request) { error in
            if let error = error {
                print("[NotificationManager] Error delivering decision notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Battery Notifications

    func handleBatteryStateUpdate(
        percent: Int?,
        millivolts: Int?,
        isCharging: Bool?,
        settings: Settings
    ) {
        guard settings.notificationsEnabled && settings.batteryNotifications else { return }
        guard let percent = percent else { return }
        let now = ProcessInfo.processInfo.systemUptime

        // 1. Charging state transitions
        if let charging = isCharging {
            if lastNotifiedChargingState != charging {
                lastNotifiedChargingState = charging
                if charging {
                    // Charger just plugged in
                    postNotification(
                        id: "battery-charging-\(Int(now))",
                        title: "⚡️ Pendant Charging",
                        body: "Keepsake is connected to power (currently \(percent)%)."
                    )
                }
            }
        }

        // 2. Fully charged alert (>= 95% while charging or just finished)
        if (isCharging == true || (lastNotifiedChargingState == true && isCharging == false)) && percent >= 95 {
            if now - lastNotifiedFullChargeTimestamp > 3600 { // At most once per hour
                lastNotifiedFullChargeTimestamp = now
                postNotification(
                    id: "battery-full-\(Int(now))",
                    title: "🔋 Pendant Fully Charged",
                    body: "Pendant battery reached \(percent)% and is ready to wear."
                )
            }
        }

        // 3. Low battery alert (<= 20% and not currently charging)
        if isCharging != true && percent <= 20 {
            if now - lastNotifiedLowBatteryTimestamp > 1800 { // At most once per 30 minutes
                lastNotifiedLowBatteryTimestamp = now
                let mvText = millivolts.map { String(format: " (%.2f V)", Double($0) / 1000.0) } ?? ""
                postNotification(
                    id: "battery-low-\(Int(now))",
                    title: percent <= 10 ? "🪫 Pendant Battery Critical" : "🪫 Pendant Battery Low",
                    body: "Pendant battery is at \(percent)%\(mvText). Please connect to charger."
                )
            }
        }
    }

    // MARK: - Connection Notifications

    func notifyConnectionLost(deviceName: String, settings: Settings) {
        guard settings.notificationsEnabled && settings.connectionNotifications else { return }
        postNotification(
            id: "conn-lost-\(Int(ProcessInfo.processInfo.systemUptime))",
            title: "⚠️ Pendant Disconnected",
            body: "\(deviceName) lost connection. Audio capture is paused."
        )
    }

    func notifyConnectionRestored(deviceName: String, settings: Settings) {
        guard settings.notificationsEnabled && settings.connectionNotifications else { return }
        postNotification(
            id: "conn-restored-\(Int(ProcessInfo.processInfo.systemUptime))",
            title: "✅ Pendant Connected",
            body: "\(deviceName) is connected and ready."
        )
    }

    // MARK: - Private Helpers

    private func postNotification(id: String, title: String, body: String, subtitle: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle = subtitle {
            content.subtitle = subtitle
        }
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request) { error in
            if let error = error {
                print("[NotificationManager] Error posting notification '\(title)': \(error.localizedDescription)")
            }
        }
    }
}
