import Foundation

struct Usage: Codable {
    var fiveHourPct: Double
    var fiveHourReset: Date?
    var sevenDayPct: Double
    var sevenDayReset: Date?
    var fetchedAt: Date
}

enum UsageState {
    case fresh(Usage)
    case stale(Usage, String)      // last good numbers + why the live fetch failed
    case unavailable(String)
}

extension UsageState {
    var usage: Usage? {
        switch self {
        case .fresh(let u), .stale(let u, _): return u
        case .unavailable: return nil
        }
    }
}

enum UsageAPI {
    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }

    private static func get(_ urlString: String, token: String) -> (data: Data?, status: Int, error: String?) {
        guard let url = URL(string: urlString) else { return (nil, 0, "bad url") }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 10
        var result: (Data?, Int, String?) = (nil, 0, "timed out")
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            result = (data, (resp as? HTTPURLResponse)?.statusCode ?? 0, err?.localizedDescription)
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 15)
        return result
    }

    static func fetchUsage(token: String) -> (usage: Usage?, error: String) {
        let (data, status, error) = get("https://api.anthropic.com/api/oauth/usage", token: token)
        if status == 401 { return (nil, "token expired") }
        if let error, data == nil { return (nil, error) }
        guard status == 200, let data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["seven_day"] != nil
        else { return (nil, status == 0 ? "offline" : "HTTP \(status)") }

        func window(_ key: String) -> (Double, Date?) {
            guard let w = json[key] as? [String: Any] else { return (0, nil) }
            let pct = (w["utilization"] as? NSNumber)?.doubleValue ?? 0
            return (pct, parseDate(w["resets_at"] as? String))
        }
        let five = window("five_hour")
        let seven = window("seven_day")
        return (Usage(fiveHourPct: five.0, fiveHourReset: five.1,
                      sevenDayPct: seven.0, sevenDayReset: seven.1, fetchedAt: Date()), "")
    }

    static func fetchEmail(token: String) -> String? {
        let (data, status, _) = get("https://api.anthropic.com/api/oauth/profile", token: token)
        guard status == 200, let data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        if let account = json["account"] as? [String: Any], let email = account["email"] as? String { return email }
        return json["email"] as? String
    }
}

// Last-good usage per account survives restarts and expired tokens.
enum UsageCache {
    private static func key(_ name: String) -> String { "usage-cache-\(name)" }

    static func save(_ name: String, _ usage: Usage) {
        if let data = try? JSONEncoder().encode(usage) {
            UserDefaults.standard.set(data, forKey: key(name))
        }
    }

    static func load(_ name: String) -> Usage? {
        guard let data = UserDefaults.standard.data(forKey: key(name)) else { return nil }
        return try? JSONDecoder().decode(Usage.self, from: data)
    }
}
