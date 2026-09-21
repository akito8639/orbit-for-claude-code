import Foundation

// MARK: - Anthropic OAuth API

enum ClaudeAPI {
    static let userAgent = "claude-cli/2.1.42 (external, cli)"
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    enum APIError: Error, LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            switch self { case .http(let c, let m): return "HTTP \(c): \(m)" }
        }
    }

    private static func request(_ url: String, token: String) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        return req
    }

    private static func getJSON(_ url: String, token: String) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: request(url, token: token))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(code) else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw APIError.http(code, msg)
        }
        return json
    }

    struct UsageResult {
        var windows: [UsageWindow]
        var extra: ExtraUsage?
        var raw: String
        var breakdown: [UsageSnapshot.BreakdownRow]?
    }

    static func fetchUsage(token: String) async throws -> UsageResult {
        let json = try await getJSON("https://api.anthropic.com/api/oauth/usage", token: token)
        let rawData = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let raw = String(decoding: rawData, as: UTF8.self)
        var windows: [UsageWindow] = []
        var extra: ExtraUsage?
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        func date(_ v: Any?) -> Date? { (v as? String).flatMap { iso.date(from: $0) ?? iso2.date(from: $0) } }

        // Preferred source: the `limits` array (carries severity, is_active and per-model scopes such as Fable).
        var coveredKinds = Set<UsageWindowKind>()
        for lim in json["limits"] as? [[String: Any]] ?? [] {
            guard let kindStr = lim["kind"] as? String, let pct = lim["percent"] as? Double else { continue }
            let severity = lim["severity"] as? String
            let active = lim["is_active"] as? Bool
            switch kindStr {
            case "session":
                windows.append(UsageWindow(id: "five_hour", kind: .fiveHour, utilization: pct, resetsAt: date(lim["resets_at"]), severity: severity, isActive: active))
                coveredKinds.insert(.fiveHour)
            case "weekly_all":
                windows.append(UsageWindow(id: "seven_day", kind: .sevenDay, utilization: pct, resetsAt: date(lim["resets_at"]), severity: severity, isActive: active))
                coveredKinds.insert(.sevenDay)
            case "weekly_scoped":
                let scope = lim["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let name = (model?["display_name"] as? String) ?? (model?["id"] as? String) ?? (scope?["surface"] as? String) ?? "scoped"
                windows.append(UsageWindow(id: "weekly_scoped:\(name)", kind: .weeklyScoped, utilization: pct, resetsAt: date(lim["resets_at"]), scopeName: name, severity: severity, isActive: active))
            default:
                windows.append(UsageWindow(id: "limit:\(kindStr)", kind: .other, utilization: pct, resetsAt: date(lim["resets_at"]), scopeName: nil, severity: severity, isActive: active))
            }
        }

        var breakdown: [UsageSnapshot.BreakdownRow]?
        if let bd = json["seven_day_breakdown"] as? [String: Any], let rows = bd["rows"] as? [[String: Any]] {
            breakdown = rows.compactMap { r in
                guard let k = r["key"] as? String, let p = r["percent"] as? Double else { return nil }
                return UsageSnapshot.BreakdownRow(key: k, displayName: r["display_name"] as? String ?? k, percent: p)
            }
        }

        for (key, value) in json {
            guard let obj = value as? [String: Any] else { continue }
            if key == "limits" || key == "seven_day_breakdown" || key == "spend" { continue }
            if let k = UsageWindowKind(rawValue: key), coveredKinds.contains(k) { continue }
            if key == "extra_usage" {
                extra = ExtraUsage(isEnabled: obj["is_enabled"] as? Bool ?? false,
                                   monthlyLimit: obj["monthly_limit"] as? Double,
                                   usedCredits: obj["used_credits"] as? Double,
                                   utilization: obj["utilization"] as? Double)
                continue
            }
            guard let util = obj["utilization"] as? Double else { continue }
            var resets: Date?
            if let s = obj["resets_at"] as? String { resets = iso.date(from: s) ?? iso2.date(from: s) }
            windows.append(UsageWindow(id: key, kind: UsageWindowKind(rawValue: key) ?? .other, utilization: util, resetsAt: resets))
        }
        // Stable order: 5h, week, then the rest alphabetically.
        let order: [UsageWindowKind: Int] = [.fiveHour: 0, .sevenDay: 1, .weeklyScoped: 2, .sevenDayOpus: 3, .sevenDaySonnet: 4]
        windows.sort { (order[$0.kind] ?? 9, $0.id) < (order[$1.kind] ?? 9, $1.id) }
        return UsageResult(windows: windows, extra: extra, raw: raw, breakdown: breakdown)
    }

    static func fetchProfile(token: String) async throws -> AccountProfile {
        let json = try await getJSON("https://api.anthropic.com/api/oauth/profile", token: token)
        let acc = json["account"] as? [String: Any] ?? [:]
        let org = json["organization"] as? [String: Any] ?? [:]
        return AccountProfile(email: acc["email"] as? String ?? acc["email_address"] as? String,
                              displayName: acc["display_name"] as? String ?? acc["full_name"] as? String,
                              organizationName: org["name"] as? String,
                              subscriptionType: nil, rateLimitTier: org["rate_limit_tier"] as? String)
    }
}

// MARK: - status.claude.com (Statuspage v2)

enum StatusAPI {
    static func fetch() async throws -> ServiceStatus {
        var req = URLRequest(url: URL(string: "https://status.claude.com/api/v2/summary.json")!)
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let st = json["status"] as? [String: Any] ?? [:]
        let comps = json["components"] as? [[String: Any]] ?? []
        let cc = comps.first { ($0["name"] as? String)?.localizedCaseInsensitiveContains("claude code") == true }
        let all = comps.compactMap { c -> ServiceStatus.StatusComponent? in
            guard let n = c["name"] as? String, let st = c["status"] as? String, c["group"] as? Bool != true else { return nil }
            return ServiceStatus.StatusComponent(name: n, status: st)
        }
        let incidents = (json["incidents"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let updated = ((json["page"] as? [String: Any])?["updated_at"] as? String).flatMap { iso.date(from: $0) }
        return ServiceStatus(indicator: st["indicator"] as? String ?? "none",
                             description: st["description"] as? String ?? "Unknown",
                             claudeCodeStatus: cc?["status"] as? String,
                             unresolvedIncidents: incidents, updatedAt: updated, components: all)
    }
}

