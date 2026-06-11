import Foundation

// Reset-aware auto-switching. Runs after every refresh when enabled.
// Policy: if the active account is hot (5h >= 90 or weekly >= 99) and another
// account has meaningfully more usable headroom, switch — unless the active
// 5h window is about to reset anyway. At most one auto-switch per hour.
enum Autopilot {
    static let hotFiveHour = 90.0
    static let hotWeekly = 99.0
    static let minGain = 15.0
    static let resetGraceSeconds: TimeInterval = 20 * 60
    static let debounceSeconds: TimeInterval = 3600

    // Usable headroom right now: constrained by whichever window is tighter.
    static func score(_ u: Usage) -> Double {
        min(100 - u.fiveHourPct, 100 - u.sevenDayPct)
    }

    static func decide(active: String, usage: [String: UsageState],
                       lastSwitch: Date?, now: Date = Date()) -> (target: String, reason: String)? {
        guard case .fresh(let a)? = usage[active] else { return nil }

        let hot5 = a.fiveHourPct >= hotFiveHour
        let hotWk = a.sevenDayPct >= hotWeekly
        guard hot5 || hotWk else { return nil }

        // 5h about to reset and weekly is fine — riding it out beats flipping.
        if hot5, !hotWk, let reset = a.fiveHourReset,
           reset.timeIntervalSince(now) < resetGraceSeconds { return nil }

        if let lastSwitch, now.timeIntervalSince(lastSwitch) < debounceSeconds { return nil }

        var best: (name: String, usage: Usage)? = nil
        for (name, state) in usage where name != active {
            guard case .fresh(let u) = state else { continue }
            guard let current = best else { best = (name, u); continue }
            if score(u) > score(current.usage) + 5 {
                best = (name, u)
            } else if abs(score(u) - score(current.usage)) <= 5,
                      let candidateReset = u.sevenDayReset, let bestReset = current.usage.sevenDayReset,
                      candidateReset < bestReset {
                // Near-tie: burn the account whose weekly window refreshes sooner.
                best = (name, u)
            }
        }

        guard let (name, u) = best, score(u) - score(a) >= minGain else { return nil }

        let constraint = hotWk ? String(format: "wk %.0f%%", a.sevenDayPct)
                               : String(format: "5h %.0f%%", a.fiveHourPct)
        let reason = String(format: "%@ %@ — switched to %@ (5h %.0f%%, wk %.0f%%)",
                            active, constraint, name, u.fiveHourPct, u.sevenDayPct)
        return (name, reason)
    }
}
