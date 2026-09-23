import Combine
import Foundation
import os
import UserNotifications

@MainActor
final class ThresholdNotifier: ObservableObject {
    private let logger = Logger(category: "Alerts")
    private let defaults: UserDefaults
    /// Delivery seam (tests record calls); defaults to a local notification.
    private let deliver: (Double, Double) -> Void

    init(defaults: UserDefaults = .standard, deliver: ((Double, Double) -> Void)? = nil) {
        self.defaults = defaults
        self.deliver = deliver ?? Self.postLocalNotification
    }

    func requestAuthorizationIfNeeded() {
        Task { @MainActor [weak self] in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                if !granted {
                    self?.logger.info("User denied notification permission")
                }
            } catch {
                self?.logger.error("Notification auth failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func evaluate(usedPercent: Double, settings: AppSettings, account: String?) {
        guard settings.thresholdEnabled else { return }
        let threshold = settings.thresholdPercent
        // Persisted, account-scoped so a relaunch (or account switch) does not
        // re-fire an alert the user already saw while still above the threshold.
        let key = Self.notifiedKey(account: account)
        let last = defaults.object(forKey: key) as? Double
        guard usedPercent >= threshold else {
            if let last, usedPercent < last - 5 {
                defaults.removeObject(forKey: key)
            }
            return
        }
        guard Self.shouldNotify(
            usedPercent: usedPercent,
            threshold: threshold,
            lastNotifiedThreshold: last
        ) else { return }
        defaults.set(threshold, forKey: key)
        deliver(usedPercent, threshold)
    }

    static func notifiedKey(account: String?) -> String {
        "thresholdNotified.\(account ?? "default")"
    }

    /// Fires once per threshold crossing; re-arms only after usage drops 5+ points
    /// below the notified threshold.
    nonisolated static func shouldNotify(
        usedPercent: Double,
        threshold: Double,
        lastNotifiedThreshold: Double?
    ) -> Bool {
        guard usedPercent >= threshold else { return false }
        if let last = lastNotifiedThreshold, last >= threshold { return false }
        return true
    }

    private static func postLocalNotification(usedPercent: Double, threshold: Double) {
        let content = UNMutableNotificationContent()
        content.title = "TokenMon Alert"
        content.body = String(
            format: "Weekly SuperGrok usage is at %.0f%% (threshold %.0f%%).",
            usedPercent,
            threshold
        )
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "grok-usage-threshold-\(Int(threshold))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
