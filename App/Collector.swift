import Foundation
import Darwin

// MARK: - Shell helper

enum Shell {
    struct Result { var status: Int32; var stdout: String; var stderr: String }

    static func run(_ path: String, _ args: [String], stdin: String? = nil) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        if let stdin {
            let inPipe = Pipe()
            p.standardInput = inPipe
            try p.run()
            inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
            try inPipe.fileHandleForWriting.close()
        } else {
            try p.run()
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
    }
}

// MARK: - Credentials (Claude Code keychain item / credentials file)

struct OAuthCredentials {
    var service: String?          // keychain service name, nil when read from file
    var account: String?
    var fileURL: URL?
    var raw: [String: Any]        // full JSON so we can write it back unchanged
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var subscriptionType: String?
    var rateLimitTier: String?

    var isExpired: Bool { expiresAt.timeIntervalSinceNow < 60 }

    static func parse(_ raw: [String: Any]) -> OAuthCredentials? {
        guard let o = raw["claudeAiOauth"] as? [String: Any], let at = o["accessToken"] as? String else { return nil }
        let ms = (o["expiresAt"] as? Double) ?? 0
        return OAuthCredentials(service: nil, account: nil, fileURL: nil, raw: raw, accessToken: at,
                                refreshToken: o["refreshToken"] as? String,
                                expiresAt: Date(timeIntervalSince1970: ms / 1000),
                                subscriptionType: o["subscriptionType"] as? String,
                                rateLimitTier: o["rateLimitTier"] as? String)
    }
}

/// A user-supplied long-lived OAuth token (from `claude setup-token`), kept in the app's own keychain item.
enum ManualTokenStore {
    static let service = "com.akito.OrbitForClaudeCode.manual-token"
    static let account = "oauth"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func save(_ token: String) throws {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { delete(); return }
        let data = t.data(using: .utf8)!
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            let s2 = SecItemAdd(q as CFDictionary, nil)
            guard s2 == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s2)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete() { SecItemDelete(query as CFDictionary) }

    /// Wraps the manual token as credentials that never expire and cannot be refreshed.
    static func credentials() -> OAuthCredentials? {
        guard let t = load() else { return nil }
        return OAuthCredentials(service: "manual token", account: nil, fileURL: nil, raw: [:], accessToken: t,
                                refreshToken: nil, expiresAt: .distantFuture, subscriptionType: nil, rateLimitTier: nil)
    }
}

enum CredentialStore {
    static let servicePrefix = "Claude Code-credentials"

    /// Lists keychain services starting with the Claude Code prefix (attributes only — no prompt).
    static func keychainServices() -> [(service: String, account: String)] {
        guard let r = try? Shell.run("/usr/bin/security", ["dump-keychain"]) else { return [] }
        var results: [(String, String)] = []
        var svc: String?, acct: String?
        func flush() {
            if let s = svc, s.hasPrefix(servicePrefix) { results.append((s, acct ?? NSUserName())) }
            svc = nil; acct = nil
        }
        for line in r.stdout.split(separator: "\n") {
            if line.hasPrefix("keychain:") { flush(); continue }
            if let v = attr(line, "svce") { svc = v }
            if let v = attr(line, "acct") { acct = v }
        }
        flush()
        return results
    }

    private static func attr(_ line: Substring, _ name: String) -> String? {
        let key = "\"\(name)\"<blob>=\""
        guard let r = line.range(of: key) else { return nil }
        var v = String(line[r.upperBound...])
        if v.hasSuffix("\"") { v.removeLast() }
        return v
    }

    /// Returns the freshest credential found in the keychain or ~/.claude/.credentials.json.
    static func loadBest() -> OAuthCredentials? {
        var found: [OAuthCredentials] = []
        for (svc, acct) in keychainServices() {
            guard let r = try? Shell.run("/usr/bin/security", ["find-generic-password", "-s", svc, "-a", acct, "-w"]),
                  r.status == 0,
                  let data = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var c = OAuthCredentials.parse(json) else { continue }
            c.service = svc; c.account = acct
            found.append(c)
        }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var c = OAuthCredentials.parse(json) {
            c.fileURL = file
            found.append(c)
        }
        return found.max { $0.expiresAt < $1.expiresAt }
    }

    static func save(_ c: OAuthCredentials) throws {
        var raw = c.raw
        var o = raw["claudeAiOauth"] as? [String: Any] ?? [:]
        o["accessToken"] = c.accessToken
        if let rt = c.refreshToken { o["refreshToken"] = rt }
        o["expiresAt"] = Int(c.expiresAt.timeIntervalSince1970 * 1000)
        raw["claudeAiOauth"] = o
        let data = try JSONSerialization.data(withJSONObject: raw)
        let json = String(decoding: data, as: UTF8.self)
        if let svc = c.service {
            let r = try Shell.run("/usr/bin/security", ["add-generic-password", "-U", "-a", c.account ?? NSUserName(), "-s", svc, "-w", json])
            if r.status != 0 { throw NSError(domain: "Orbit", code: 2, userInfo: [NSLocalizedDescriptionKey: "keychain write failed: \(r.stderr)"]) }
        } else if let url = c.fileURL {
            try data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Token refresh (app only: it writes back to Claude Code's keychain item)

extension ClaudeAPI {
    /// Exchanges the refresh token for a new access token. Refresh tokens rotate, so the caller must persist the result.
    static func refresh(_ c: OAuthCredentials) async throws -> OAuthCredentials {
        guard let rt = c.refreshToken else { throw APIError.http(0, "no refresh token") }
        var req = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["grant_type": "refresh_token", "refresh_token": rt, "client_id": clientID])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard code == 200, let at = json["access_token"] as? String else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw APIError.http(code, msg)
        }
        var n = c
        n.accessToken = at
        if let r = json["refresh_token"] as? String { n.refreshToken = r }
        n.expiresAt = Date().addingTimeInterval(json["expires_in"] as? Double ?? 3600)
        return n
    }
}

// MARK: - Local ~/.claude scanning

enum LocalScanner {
    static let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")

    static func runningSessions(includeContext: Bool = true) -> [LocalSession] {
        let dir = claudeDir.appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [LocalSession] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = j["pid"] as? Int32 else { continue }
            guard kill(pid, 0) == 0 else { continue }   // process still alive?
            let started = (j["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            let sessionId = j["sessionId"] as? String ?? f.lastPathComponent
            let cwd = j["cwd"] as? String ?? "?"
            out.append(LocalSession(id: sessionId, pid: pid, cwd: cwd, startedAt: started,
                                    version: j["version"] as? String, entrypoint: j["entrypoint"] as? String,
                                    context: includeContext ? contextUsage(sessionId: sessionId, cwd: cwd) : nil,
                                    name: j["name"] as? String, hostSessionId: j["hostSessionId"] as? String,
                                    status: j["status"] as? String, waitingFor: j["waitingFor"] as? String,
                                    statusUpdatedAt: (j["statusUpdatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }))
        }
        return out.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    /// Cowork sessions from the desktop app: ~/Library/Application Support/Claude/local-agent-mode-sessions/<account>/<org>/local_*.json
    static func coworkSessions(limit: Int = 12) -> [CoworkSession] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [CoworkSession] = []
        for case let url as URL in en {
            guard url.pathExtension == "json", url.lastPathComponent.hasPrefix("local_"),
                  url.pathComponents.count - root.pathComponents.count == 3,   // <account>/<org>/local_x.json
                  let data = try? Data(contentsOf: url),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = j["title"] as? String else { continue }
            func date(_ k: String) -> Date? { (j[k] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
            out.append(CoworkSession(id: url.deletingPathExtension().lastPathComponent, title: title,
                                     createdAt: date("createdAt"), lastActivityAt: date("lastActivityAt"),
                                     model: j["model"] as? String, isArchived: j["isArchived"] as? Bool ?? false))
        }
        return Array(out.filter { !$0.isArchived }
            .sorted { ($0.lastActivityAt ?? $0.createdAt ?? .distantPast) > ($1.lastActivityAt ?? $1.createdAt ?? .distantPast) }
            .prefix(limit))
    }

    /// Claude Code stores transcripts at ~/.claude/projects/<cwd with non-alphanumerics replaced by "-">/<sessionId>.jsonl
    static func transcriptURL(sessionId: String, cwd: String) -> URL? {
        let projects = claudeDir.appendingPathComponent("projects")
        let encoded = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let direct = projects.appendingPathComponent(encoded).appendingPathComponent("\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        // Fallback: look through every project folder.
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for d in dirs {
            let u = d.appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// Context window of the last assistant turn: reads only the tail of the transcript.
    static func contextUsage(sessionId: String, cwd: String) -> ContextUsage? {
        guard let url = transcriptURL(sessionId: sessionId, cwd: cwd),
              let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let tailLen: UInt64 = 512 * 1024
        let start = size > tailLen ? size - tailLen : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return nil }
        let marker = Data("\"type\":\"assistant\"".utf8)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result: ContextUsage?
        var pos = data.startIndex
        while pos < data.endIndex {
            let end = data[pos...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[pos..<end]
            pos = end + 1
            guard line.range(of: marker) != nil,
                  let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let msg = j["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }
            let input = usage["input_tokens"] as? Int ?? 0
            let cr = usage["cache_read_input_tokens"] as? Int ?? 0
            let cc = usage["cache_creation_input_tokens"] as? Int ?? 0
            let out = usage["output_tokens"] as? Int ?? 0
            let model = msg["model"] as? String ?? "?"
            result = ContextUsage(input: input, cacheRead: cr, cacheCreation: cc, output: out, model: model,
                                  limit: ContextUsage.limit(for: model, used: input + cr),
                                  at: (j["timestamp"] as? String).flatMap { iso.date(from: $0) })
        }
        return result
    }

    /// Pricing per million tokens: (input, output, cacheWrite, cacheRead). Estimates only.
    static func pricing(for model: String) -> (Double, Double, Double, Double) {
        let m = model.lowercased()
        if m.contains("haiku") { return m.contains("4-5") || m.contains("4.5") ? (1, 5, 1.25, 0.1) : (0.8, 4, 1, 0.08) }
        if m.contains("sonnet") { return (3, 15, 3.75, 0.3) }
        if m.contains("opus-4-1") || m.contains("opus-4-2025") { return (15, 75, 18.75, 1.5) }
        return (5, 25, 6.25, 0.5)   // opus 4.5+/5, fable/mythos: assume opus tier
    }

    static func todayUsage() -> LocalUsageToday? {
        let projects = claudeDir.appendingPathComponent("projects")
        let startOfDay = Calendar.current.startOfDay(for: .now)
        guard let en = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        var seen = Set<String>()
        var input = 0, output = 0, cw = 0, cr = 0, msgs = 0
        var cost = 0.0
        var byModel: [String: Int] = [:]
        for case let url as URL in en {
            guard url.pathExtension == "jsonl",
                  let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  mod >= startOfDay,
                  let data = try? Data(contentsOf: url) else { continue }
            let marker = Data("\"type\":\"assistant\"".utf8)
            var start = data.startIndex
            while start < data.endIndex {
                let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
                let line = data[start..<end]
                start = end + 1
                guard line.range(of: marker) != nil,
                      let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let msg = j["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { continue }
                if let ts = j["timestamp"] as? String, let d = iso.date(from: ts) ?? iso2.date(from: ts), d < startOfDay { continue }
                let key = (msg["id"] as? String ?? "") + ":" + (j["requestId"] as? String ?? UUID().uuidString)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                let i = usage["input_tokens"] as? Int ?? 0
                let o = usage["output_tokens"] as? Int ?? 0
                let c1 = usage["cache_creation_input_tokens"] as? Int ?? 0
                let c2 = usage["cache_read_input_tokens"] as? Int ?? 0
                input += i; output += o; cw += c1; cr += c2; msgs += 1
                let model = msg["model"] as? String ?? "unknown"
                byModel[model, default: 0] += i + o + c1 + c2
                let p = pricing(for: model)
                cost += (Double(i) * p.0 + Double(o) * p.1 + Double(c1) * p.2 + Double(c2) * p.3) / 1_000_000
            }
        }
        return LocalUsageToday(inputTokens: input, outputTokens: output, cacheCreationTokens: cw, cacheReadTokens: cr,
                               messages: msgs, estimatedCostUSD: cost, byModel: byModel)
    }
}

// MARK: - Collector: builds a snapshot from every enabled source

enum Collector {
    struct Report {
        var snapshot: UsageSnapshot
        var credentials: OAuthCredentials?
    }

    static func collect(options: DisplayOptions, forceTokenRefresh: Bool = false) async -> Report {
        var snap = UsageSnapshot(fetchedAt: .now, windows: [], extraUsage: nil, profile: nil, serviceStatus: nil,
                                 sessions: [], today: nil, tokenState: .missing, errorMessage: nil)
        var errors: [String] = []

        // Independent sources in parallel
        async let status: ServiceStatus? = options[.showServiceStatus] ? (try? await StatusAPI.fetch()) : nil
        let sessionsTask = Task.detached(priority: .utility) { options[.showSessions] ? LocalScanner.runningSessions() : [] }
        let todayTask = Task.detached(priority: .utility) { options[.showTodayUsage] ? LocalScanner.todayUsage() : nil }
        let credsTask = Task.detached(priority: .utility) { CredentialStore.loadBest() }
        let coworkTask = Task.detached(priority: .utility) { options[.showCowork] ? LocalScanner.coworkSessions() : [] }

        let detected = await credsTask.value
        var creds = ManualTokenStore.credentials() ?? detected
        if var c = creds {
            snap.tokenState = c.isExpired ? .expired : .ok
            if c.isExpired && c.refreshToken != nil && (options[.autoRefreshToken] || forceTokenRefresh) {
                do {
                    c = try await ClaudeAPI.refresh(c)
                    try CredentialStore.save(c)
                    creds = c
                    snap.tokenState = .refreshed
                } catch {
                    errors.append("token refresh failed: \(error.localizedDescription)")
                }
            }
            if snap.tokenState != .expired {
                do {
                    let u = try await ClaudeAPI.fetchUsage(token: c.accessToken)
                    snap.windows = u.windows
                    snap.extraUsage = u.extra
                    snap.rawUsageJSON = u.raw
                    snap.breakdown = u.breakdown
                } catch {
                    var handled = false
                    // A manual token that is rejected (wrong scope / invalid) is dropped and we fall back to Claude Code's own token.
                    if c.service == "manual token", let d = detected, !d.isExpired,
                       case ClaudeAPI.APIError.http(let code, _) = error, code == 401 || code == 403 {
                        ManualTokenStore.delete()
                        errors.append("manual token rejected (HTTP \(code)) — removed, using Claude Code keychain token")
                        c = d; creds = d
                        if let u = try? await ClaudeAPI.fetchUsage(token: d.accessToken) {
                            snap.windows = u.windows
                            snap.extraUsage = u.extra
                            snap.rawUsageJSON = u.raw
                            snap.breakdown = u.breakdown
                            handled = true
                        }
                    }
                    if !handled {
                        if case ClaudeAPI.APIError.http(429, _) = error {
                            errors.append("usage: rate limited by Anthropic — will retry in \(options.refreshMinutes) min")
                        } else {
                            errors.append("usage: \(error.localizedDescription)")
                        }
                        if case ClaudeAPI.APIError.http(401, _) = error { snap.tokenState = .expired }
                        if case ClaudeAPI.APIError.http(403, _) = error, c.service == "manual token" {
                            errors.append("manual token lacks user:profile scope (claude setup-token tokens cannot be used)")
                        }
                    }
                }
                if options[.showProfile] {
                    var p = (try? await ClaudeAPI.fetchProfile(token: c.accessToken)) ?? AccountProfile()
                    p.subscriptionType = c.subscriptionType
                    if p.rateLimitTier == nil { p.rateLimitTier = c.rateLimitTier }
                    snap.profile = p
                }
            } else {
                errors.append("token expired — run `claude` once, or enable auto refresh")
                snap.profile = AccountProfile(subscriptionType: c.subscriptionType, rateLimitTier: c.rateLimitTier)
            }
        } else {
            errors.append("no Claude Code credentials found (run `claude login`)")
        }

        if let c = creds, snap.tokenState != .expired {
            do { try SharedToken.save(accessToken: c.accessToken, expiresAt: c.expiresAt) }
            catch { NSLog("Orbit: shared token save failed: %@", error.localizedDescription) }
        } else {
            SharedToken.delete()
        }
        snap.serviceStatus = await status
        snap.sessions = await sessionsTask.value
        snap.today = await todayTask.value
        snap.coworkSessions = await coworkTask.value
        snap.errorMessage = errors.isEmpty ? nil : errors.joined(separator: " · ")
        snap.fetchedAt = .now
        return Report(snapshot: snap, credentials: creds)
    }
}
