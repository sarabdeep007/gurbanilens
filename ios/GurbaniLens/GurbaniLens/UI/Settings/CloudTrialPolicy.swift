import Foundation
import SwiftUI

/// Tiny policy helper for the Phase A.4b free-trial counter. Owns the
/// @AppStorage keys + the monthly-reset rule + the "consume one trial"
/// transition. Kept in its own file so the Settings UI and the
/// AppContainer / live-session commit paths (Phase A.4b future hookup)
/// import a single source of truth.
///
/// Behaviour summary:
///   - 50 cloud searches per calendar month (UTC). When `lastResetMonth`
///     doesn't match the current month, reset `remaining` to 50 and
///     update `lastResetMonth` — done once on Settings open and once on
///     each commit attempt.
///   - `tryConsume` returns false if the trial is exhausted. Callers
///     should bail out of the cloud query and surface the
///     "trial used up" alert.
///   - No actual paywall enforcement in v1 — premium IAP is deferred.
///     The counter exists to (a) protect Deep from accidental burn
///     during testing and (b) prep the UI for the eventual paywall.
public enum CloudTrialPolicy {

    // MARK: - @AppStorage key names

    public static let enabledKey         = "settings.cloudEnabled"
    public static let remainingKey       = "settings.cloudFreeTrialRemaining"
    public static let lastResetMonthKey  = "settings.lastTrialResetMonth"

    // MARK: - Constants

    public static let monthlyAllowance: Int = 50

    // MARK: - UserDefaults-driven plumbing (for non-View callers)

    /// "YYYY-MM" in UTC. Stable across timezones, matches what a server
    /// dashboard would compute, no DST surprises.
    public static func currentMonthKey(now: Date = Date()) -> String {
        let cal = Calendar(identifier: .gregorian)
        var utc = cal
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? cal.timeZone
        let comps = utc.dateComponents([.year, .month], from: now)
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }

    /// Roll the trial counter forward to a fresh allowance if we've
    /// crossed a month boundary since `lastResetMonth`. View-friendly
    /// variant: takes two `Binding`s so the UI re-renders.
    public static func resetIfNewMonth(
        lastResetMonth: Binding<String>,
        remaining: Binding<Int>,
        now: Date = Date()
    ) {
        let cur = currentMonthKey(now: now)
        if lastResetMonth.wrappedValue != cur {
            NSLog("[DIAG] CloudTrialPolicy month rollover \(lastResetMonth.wrappedValue) → \(cur) (remaining reset to \(monthlyAllowance))")
            lastResetMonth.wrappedValue = cur
            remaining.wrappedValue = monthlyAllowance
        }
    }

    /// Non-View variant for callers that hold UserDefaults directly
    /// (e.g. AppContainer commit hook in a future patch).
    public static func resetIfNewMonth(
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        let cur = currentMonthKey(now: now)
        let stored = defaults.string(forKey: lastResetMonthKey) ?? ""
        if stored != cur {
            NSLog("[DIAG] CloudTrialPolicy month rollover (\(stored) → \(cur)); remaining reset to \(monthlyAllowance)")
            defaults.set(cur, forKey: lastResetMonthKey)
            defaults.set(monthlyAllowance, forKey: remainingKey)
        }
    }

    /// Try to spend one trial credit. Returns the new remaining count
    /// when the spend succeeded; nil when the trial was already
    /// exhausted (caller should surface the "trial used up" modal and
    /// force-disable the cloud toggle).
    @discardableResult
    public static func tryConsume(
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> Int? {
        resetIfNewMonth(defaults: defaults, now: now)
        let cur = defaults.integer(forKey: remainingKey)
        // First-launch: integer(forKey:) returns 0 for absent keys, so
        // we need the .object(forKey:) check to distinguish "missing"
        // from "spent". When missing, treat as a full allowance.
        let effective = defaults.object(forKey: remainingKey) == nil ? monthlyAllowance : cur
        if effective <= 0 { return nil }
        let next = effective - 1
        defaults.set(next, forKey: remainingKey)
        NSLog("[DIAG] CloudTrialPolicy consumed 1 (remaining \(effective) → \(next))")
        return next
    }

    /// Disable the cloud toggle + snap the active provider back to
    /// WhisperKit. Called when the trial counter hits 0.
    public static func forceDisable(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: enabledKey)
        defaults.set(ASRProviderId.whisperKit.rawValue, forKey: "settings.asrProvider")
        NSLog("[DIAG] CloudTrialPolicy force-disabled cloud — toggle off, provider snapped to whisperKit")
    }
}
