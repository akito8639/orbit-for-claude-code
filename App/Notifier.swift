import Foundation
import UserNotifications
import AppKit

/// Local notifications: limit thresholds, sessions waiting for you, Claude incidents.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// window id → what the last limit notification said ("<period>|<percent>"). Persisted so a relaunch does not repeat it.
    /// The period is resets_at rounded to the minute: the API adds microsecond jitter to it on every response.
    private var notifiedLimits: [String: String] = AppSettings.defaults.dictionary(forKey: Notifier.notifiedLimitsKey) as? [String: String] ?? [:] {
        didSet { AppSettings.defaults.set(notifiedLimits, forKey: Self.notifiedLimitsKey) }
    }
    private static let notifiedLimitsKey = "notified_limits"
    private var waitingSessions: Set<String> = []            // session ids already announced as waiting
    private var incidentAnnounced = false
    private var authorized = false

    func prepare() {
        UNUserNotificationCenter.current().delegate = self
        let opts = AppSettings.snapshot()
        guard opts[.notifyLimits] || opts[.notifyWaiting] || opts[.notifyIncidents] else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            Task { @MainActor in self.authorized = ok }
        }
    }

    /// Compare the new snapshot with the previous one and post what changed.
    func evaluate(old: UsageSnapshot?, new: UsageSnapshot, options: DisplayOptions) {
        if options[.notifyLimits] {
            let threshold = Double(AppSettings.notifyThreshold)
            for w in options.visibleWindows(new) where w.isLimit {
                let period = w.resetsAt.map { Int($0.timeIntervalSinceReferenceDate / 60) } ?? -1
                let state = "\(period)|\(Fmt.percent(w.utilization))"
                if w.utilization >= threshold {
                    // Post only when the notification would differ from the last one (percent moved or a new period).
                    guard notifiedLimits[w.id] != state else { continue }
                    notifiedLimits[w.id] = state
                    post(id: "limit-\(w.id)",
                         title: L("%@ at %@", w.title, Fmt.percent(w.utilization)),
                         body: L("Resets %@", Fmt.resetLabel(w.resetsAt)),
                         userInfo: ["kind": "limit"])
                } else if notifiedLimits[w.id] != nil {
                    notifiedLimits[w.id] = nil   // back below the threshold (new period): announce the next crossing
                }
            }
        }
        if options[.notifyWaiting] {
            let waitingNow = Set(new.sessions.filter { $0.activity == .needsInput || $0.activity == .permission }.map(\.id))
            for s in new.sessions where waitingNow.contains(s.id) && !waitingSessions.contains(s.id) {
                let reason = s.activity == .permission ? L("permission prompt") : L("input needed")
                post(id: "waiting-\(s.id)",
                     title: s.displayName(options),
                     body: L("Claude Code is waiting for you (%@)", reason),
                     userInfo: ["kind": "session", "id": s.id])
            }
            waitingSessions = waitingNow
        }
        if options[.notifyIncidents], let st = new.serviceStatus {
            if !st.isHealthy, !incidentAnnounced {
                incidentAnnounced = true
                post(id: "incident",
                     title: L("Claude status") + ": " + st.description,
                     body: st.unresolvedIncidents.first ?? (st.claudeCodeStatus.map { "Claude Code · " + $0.replacingOccurrences(of: "_", with: " ") } ?? ""),
                     userInfo: ["kind": "incident"])
            } else if st.isHealthy, incidentAnnounced {
                incidentAnnounced = false
                post(id: "incident-resolved", title: L("Claude status"), body: L("All systems operational"), userInfo: ["kind": "incident"])
            }
        }
    }

    private func post(id: String, title: String, body: String, userInfo: [String: String]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // Show banners even while the app is "active" (it is a menu bar app).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let kind = info["kind"] as? String
        let id = info["id"] as? String
        await MainActor.run {
            switch kind {
            case "session":
                if let id { AppDelegate.handle(URL(string: "orbit://session/\(id)")!) }
            case "limit":
                NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
            case "incident":
                NSWorkspace.shared.open(URL(string: "https://status.claude.com")!)
            default:
                break
            }
        }
    }
}
