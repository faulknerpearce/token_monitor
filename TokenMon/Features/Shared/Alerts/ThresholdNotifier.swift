import Combine
import Foundation
import os
import UserNotifications

/// One usage-threshold crossing to deliver.
struct ThresholdAlert: Equatable {
    var provider: MonitorProvider
    var usedPercent: Double
    var threshold: Double
}

/// Fires one local notification per usage-threshold crossing, tracked
/// separately for each provider and account.
@MainActor
final class ThresholdNotifier: ObservableObject {
    private let logger = Logger(category: "Alerts")
    private let defaults: UserDefaults
    /// Delivery seam (tests record calls); defaults to a local notification.
    private let deliver: (ThresholdAlert) -> Void

    init(defaults: UserDefaults = .standard, deliver: ((ThresholdAlert) -> Void)? = nil) {
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

    /// Records a threshold crossing for `provider` and `account` and delivers
    /// once per threshold within a billing period. `resetsAt` names the period:
    /// when it moves to a later period than the one the last alert was recorded
    /// in, the record is cleared, so the new period alerts whether or not a poll
    /// saw usage drop.
    func evaluate(
        provider: MonitorProvider = .grok,
        usedPercent: Double,
        settings: AppSettings,
        account: String?,
        resetsAt: Date? = nil
    ) {
        guard settings.thresholdEnabled else { return }
        let threshold = settings.thresholdPercent
        // Persisted and scoped to provider and account, so an alert the user
        // already saw stays suppressed across relaunches and account switches
        // while usage remains above the threshold.
        let key = Self.notifiedKey(provider: provider, account: account)
        let periodKey = Self.notifiedPeriodKey(provider: provider, account: account)
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
        deliver(ThresholdAlert(provider: provider, usedPercent: usedPercent, threshold: threshold))
    }

    /// Defaults key of the last notified threshold. Grok's keys carry no
    /// provider segment.
    static func notifiedKey(provider: MonitorProvider = .grok, account: String?) -> String {
        "thresholdNotified.\(scope(provider: provider, account: account))"
    }

    static func notifiedPeriodKey(provider: MonitorProvider = .grok, account: String?) -> String {
        "thresholdNotifiedResetsAt.\(scope(provider: provider, account: account))"
    }

    private static func scope(provider: MonitorProvider, account: String?) -> String {
        let account = account ?? "default"
        return provider == .grok ? account : "\(provider.rawValue).\(account)"
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

    /// Notification text for `alert`.
    nonisolated static func body(for alert: ThresholdAlert) -> String {
        let usage = alert.provider == .grok ? "Weekly SuperGrok usage" : "\(alert.provider.displayName) usage"
        return String(format: "%@ is at %.0f%% (threshold %.0f%%).", usage, alert.usedPercent, alert.threshold)
    }

    private static func postLocalNotification(_ alert: ThresholdAlert) {
        let content = UNMutableNotificationContent()
        content.title = "TokenMon Alert"
        content.body = body(for: alert)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "\(alert.provider.rawValue)-usage-threshold-\(Int(alert.threshold))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
