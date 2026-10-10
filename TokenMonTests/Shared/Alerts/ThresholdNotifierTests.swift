@testable import TokenMon
import XCTest

/// Pure decision logic for threshold alerts: fire once per crossing,
/// re-arm after a 5+ point drop below the notified threshold.
final class ThresholdNotifierTests: XCTestCase {
    func testFiresWhenCrossingThreshold() {
        XCTAssertTrue(ThresholdNotifier.shouldNotify(usedPercent: 85, threshold: 80, lastNotifiedThreshold: nil))
    }

    func testDoesNotFireBelowThreshold() {
        XCTAssertFalse(ThresholdNotifier.shouldNotify(usedPercent: 79.9, threshold: 80, lastNotifiedThreshold: nil))
        XCTAssertFalse(ThresholdNotifier.shouldNotify(usedPercent: 80, threshold: 81, lastNotifiedThreshold: nil))
    }

    func testDoesNotRefireAtSameThreshold() {
        // Already notified at 80: staying above 80 does not refire at 80.
        XCTAssertFalse(ThresholdNotifier.shouldNotify(usedPercent: 90, threshold: 80, lastNotifiedThreshold: 80))
        // A raised threshold (90) above the last notified value (80) still fires.
        XCTAssertTrue(ThresholdNotifier.shouldNotify(usedPercent: 95, threshold: 90, lastNotifiedThreshold: 80))
    }

    func testReArmsAfterFivePointDrop() {
        // While a notification at/above the threshold is recorded, stay quiet.
        XCTAssertFalse(ThresholdNotifier.shouldNotify(usedPercent: 78, threshold: 75, lastNotifiedThreshold: 81))
        // evaluate() clears the record once usage drops 5+ points below the
        // notified threshold (81 - 5 = 76; 75 < 76). With state cleared,
        // a fresh crossing fires again.
        XCTAssertTrue(ThresholdNotifier.shouldNotify(usedPercent: 75, threshold: 75, lastNotifiedThreshold: nil))
    }

    func testExactBoundaryCountsAsCrossing() {
        XCTAssertTrue(ThresholdNotifier.shouldNotify(usedPercent: 80, threshold: 80, lastNotifiedThreshold: nil))
    }

    // MARK: - Stateful evaluate (injected delivery, persisted hysteresis)

    private final class Recorder {
        var calls: [Double] = []
    }

    @MainActor
    private func makeSettings(_ defaults: UserDefaults, threshold: Double) -> AppSettings {
        let settings = AppSettings(defaults: defaults)
        settings.thresholdEnabled = true
        settings.thresholdPercent = threshold
        return settings
    }

    @MainActor
    func testEvaluateFiresOnceAndDoesNotRefireWhileAbove() {
        let suite = "ThresholdNotifierTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = makeSettings(defaults, threshold: 80)
        let recorder = Recorder()
        let notifier = ThresholdNotifier(defaults: defaults) { alert in recorder.calls.append(alert.usedPercent) }

        notifier.evaluate(usedPercent: 85, settings: settings, account: "a@b.com")
        XCTAssertEqual(recorder.calls, [85])
        notifier.evaluate(usedPercent: 90, settings: settings, account: "a@b.com")
        XCTAssertEqual(recorder.calls, [85])
    }

    /// The notified threshold is persisted, so a relaunch (new instance, same
    /// store) does not re-fire while still above it.
    @MainActor
    func testEvaluatePersistsAcrossInstances() {
        let suite = "ThresholdNotifierTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = makeSettings(defaults, threshold: 80)

        let first = Recorder()
        ThresholdNotifier(defaults: defaults) { alert in first.calls.append(alert.usedPercent) }
            .evaluate(usedPercent: 85, settings: settings, account: "a@b.com")
        XCTAssertEqual(first.calls, [85])

        let second = Recorder()
        ThresholdNotifier(defaults: defaults) { alert in second.calls.append(alert.usedPercent) }
            .evaluate(usedPercent: 88, settings: settings, account: "a@b.com")
        XCTAssertTrue(second.calls.isEmpty)
    }

    /// Hysteresis is per account: a different account is not suppressed by the
    /// first account's last-notified value.
    @MainActor
    func testEvaluateIsAccountScoped() {
        let suite = "ThresholdNotifierTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = makeSettings(defaults, threshold: 80)
        let recorder = Recorder()
        let notifier = ThresholdNotifier(defaults: defaults) { alert in recorder.calls.append(alert.usedPercent) }

        notifier.evaluate(usedPercent: 85, settings: settings, account: "a@b.com")
        notifier.evaluate(usedPercent: 85, settings: settings, account: "c@d.com")
        XCTAssertEqual(recorder.calls.count, 2)
    }

    /// Each provider keeps its own record, so one provider's alert leaves
    /// another's armed; Grok keeps its unprefixed keys.
    @MainActor
    func testEvaluateIsProviderScoped() {
        let suite = "ThresholdNotifierTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = makeSettings(defaults, threshold: 80)
        var alerts: [ThresholdAlert] = []
        let notifier = ThresholdNotifier(defaults: defaults) { alerts.append($0) }

        notifier.evaluate(provider: .grok, usedPercent: 85, settings: settings, account: "a@b.com")
        notifier.evaluate(provider: .claude, usedPercent: 90, settings: settings, account: "a@b.com")
        notifier.evaluate(provider: .claude, usedPercent: 92, settings: settings, account: "a@b.com")

        XCTAssertEqual(alerts.map(\.provider), [.grok, .claude])
        XCTAssertNotNil(defaults.object(forKey: "thresholdNotified.a@b.com"))
        XCTAssertNotNil(defaults.object(forKey: "thresholdNotified.claude.a@b.com"))
    }

    func testNotificationBodyNamesTheProvider() {
        XCTAssertEqual(
            ThresholdNotifier.body(for: ThresholdAlert(provider: .grok, usedPercent: 85.4, threshold: 80)),
            "Weekly SuperGrok usage is at 85% (threshold 80%)."
        )
        XCTAssertEqual(
            ThresholdNotifier.body(for: ThresholdAlert(provider: .cursor, usedPercent: 91, threshold: 90)),
            "Cursor usage is at 91% (threshold 90%)."
        )
    }

    @MainActor
    func testEvaluateReArmsAfterFivePointDrop() {
        let suite = "ThresholdNotifierTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = makeSettings(defaults, threshold: 75)
        let recorder = Recorder()
        let notifier = ThresholdNotifier(defaults: defaults) { alert in recorder.calls.append(alert.usedPercent) }

        notifier.evaluate(usedPercent: 81, settings: settings, account: nil)
        XCTAssertEqual(recorder.calls.count, 1)
        // The record stores the threshold (75); re-arm needs a 5-point drop below
        // it (75 - 5 = 70), so 69 clears and 76 fires again.
        notifier.evaluate(usedPercent: 74, settings: settings, account: nil)
        XCTAssertEqual(recorder.calls.count, 1)
        notifier.evaluate(usedPercent: 69, settings: settings, account: nil)
        notifier.evaluate(usedPercent: 76, settings: settings, account: nil)
        XCTAssertEqual(recorder.calls.count, 2)
    }

    @MainActor
    func testEvaluateNoOpWhenDisabled() {
        let suite = "ThresholdNotifierTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = makeSettings(defaults, threshold: 80)
        settings.thresholdEnabled = false
        let recorder = Recorder()
        ThresholdNotifier(defaults: defaults) { alert in recorder.calls.append(alert.usedPercent) }
            .evaluate(usedPercent: 99, settings: settings, account: nil)
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    /// A new billing period re-arms the alert even when no poll saw usage drop
    /// below the threshold across the reset.
    @MainActor
    func testEvaluateReArmsForNewBillingPeriod() throws {
        let suite = "ThresholdNotifierTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = makeSettings(defaults, threshold: 80)
        let recorder = Recorder()
        let notifier = ThresholdNotifier(defaults: defaults) { alert in recorder.calls.append(alert.usedPercent) }
        let firstReset = Date(timeIntervalSince1970: 1_784_000_000)
        let nextReset = firstReset.addingTimeInterval(7 * 86_400)

        notifier.evaluate(usedPercent: 85, settings: settings, account: "a@b.com", resetsAt: firstReset)
        notifier.evaluate(usedPercent: 90, settings: settings, account: "a@b.com", resetsAt: firstReset)
        XCTAssertEqual(recorder.calls, [85])
        // A reset instant reported a few minutes later is still the same period.
        notifier.evaluate(
            usedPercent: 92,
            settings: settings,
            account: "a@b.com",
            resetsAt: firstReset.addingTimeInterval(300)
        )
        XCTAssertEqual(recorder.calls, [85])

        notifier.evaluate(usedPercent: 82, settings: settings, account: "a@b.com", resetsAt: nextReset)
        XCTAssertEqual(recorder.calls, [85, 82])
        notifier.evaluate(usedPercent: 88, settings: settings, account: "a@b.com", resetsAt: nextReset)
        XCTAssertEqual(recorder.calls, [85, 82])
    }

    /// A record written without a period adopts the first period it sees and
    /// stays quiet inside it.
    @MainActor
    func testEvaluateAdoptsPeriodForRecordWithoutOne() throws {
        let suite = "ThresholdNotifierTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = makeSettings(defaults, threshold: 80)
        let recorder = Recorder()
        let notifier = ThresholdNotifier(defaults: defaults) { alert in recorder.calls.append(alert.usedPercent) }
        let reset = Date(timeIntervalSince1970: 1_784_000_000)

        notifier.evaluate(usedPercent: 85, settings: settings, account: nil)
        notifier.evaluate(usedPercent: 86, settings: settings, account: nil, resetsAt: reset)
        XCTAssertEqual(recorder.calls, [85])
        notifier.evaluate(usedPercent: 86, settings: settings, account: nil, resetsAt: reset.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(recorder.calls, [85, 86])
    }
}
