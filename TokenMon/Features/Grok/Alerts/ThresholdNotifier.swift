import Combine
import Foundation
import os
import UserNotifications

/// Fires one local notification per usage-threshold crossing.
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

    /// Records a threshold crossing for `account` and delivers once per threshold
    /// within a billing period. `resetsAt` names the period: when it moves to a
    /// later period than the one the last alert was recorded in, the record is
    /// cleared, so the new period alerts whether or not a poll saw usage drop.
    func evaluate(usedPercent: Double, settings: AppSettings, account: String?, resetsAt: Date? = nil) {
        guard settings.thresholdEnabled else { return }
        let threshold = settings.thresholdPercent
        // Persisted and account-scoped, so an alert the user already saw stays
        // suppressed across relaunches and account switches while usage remains
        // above the threshold.
        let key = Self.notifiedKey(account: account)
        let periodKey = Self.notifiedPeriodKey(account: account)
        var last = defaults.object(forKey: key) as? Double
        if last != nil, let resetsAt {
            let recordedReset = defaults.object(forKey: periodKey) as? Double
            if let recordedReset, Self.isLaterPeriod(resetsAt, than: recordedReset) {
                defaults.removeObject(forKey: key)
                defaults.removeObject(forKey: periodKey)
                last = nil
            } else if recordedReset == nil {
                defaults.set(resetsAt.timeIntervalSince1970, forKey: periodKey)
            }
        }
        guard usedPercent >= threshold else {
            if let last, usedPercent < last - 5 {
                defaults.removeObject(forKey: key)
                defaults.removeObject(forKey: periodKey)
            }
            return
        }
        guard Self.shouldNotify(
            usedPercent: usedPercent,
            threshold: threshold,
            lastNotifiedThreshold: last
        ) else { return }
        defaults.set(threshold, forKey: key)
        if let resetsAt {
            defaults.set(resetsAt.timeIntervalSince1970, forKey: periodKey)
        }
        deliver(usedPercent, threshold)
    }

    static func notifiedKey(account: String?) -> String {
        "thresholdNotified.\(account ?? "default")"
    }

    static func notifiedPeriodKey(account: String?) -> String {
        "thresholdNotifiedResetsAt.\(account ?? "default")"
    }

    /// True when `resetsAt` ends a later period than the recorded reset. An
    /// hour of slack absorbs small shifts in the reported reset instant.
    nonisolated static func isLaterPeriod(_ resetsAt: Date, than recordedReset: TimeInterval) -> Bool {
        resetsAt.timeIntervalSince1970 > recordedReset + 3_600
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
