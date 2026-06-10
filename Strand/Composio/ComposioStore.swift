// ComposioStore.swift
// Composio integration: connect external toolkits (Google Calendar, Strava, …)
// through Composio's managed-auth REST API so NOOP can join strap data with
// the rest of your life.
//
// Pure macOS: Foundation + URLSession + Security (Keychain) + AppKit (browser
// open). The API key is the user's own (composio.dev → Settings → API Keys)
// and is stored in the Keychain, never on disk in the clear. Network is used
// only on this screen, and only against backend.composio.dev.

import AppKit
import Foundation
import Security

// MARK: - Secure key storage (Keychain) — same pattern as AIKeyStore

enum ComposioKeyStore {
    private static let service = "com.noop.composio"
    private static let account = "api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return }
        guard let data = trimmed.data(using: .utf8) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else { return nil }
        return str
    }

    static func clear() { SecItemDelete(baseQuery as CFDictionary) }
}

// MARK: - Model

struct ComposioToolkit: Identifiable, Hashable {
    let slug: String
    let name: String
    let icon: String      // SF Symbol
    let blurb: String

    var id: String { slug }

    /// Curated set that makes sense next to a biometric stream.
    static let featured: [ComposioToolkit] = [
        .init(slug: "googlecalendar", name: "Google Calendar", icon: "calendar",
              blurb: "Join meetings + attendees against your heart rate."),
        .init(slug: "strava", name: "Strava", icon: "figure.run",
              blurb: "Match workouts to strain and recovery."),
        .init(slug: "gmail", name: "Gmail", icon: "envelope.fill",
              blurb: "Email yourself reports, or find inbox-stress patterns."),
        .init(slug: "notion", name: "Notion", icon: "doc.text.fill",
              blurb: "Push daily summaries into your workspace."),
        .init(slug: "slack", name: "Slack", icon: "bubble.left.and.bubble.right.fill",
              blurb: "Post recovery to a channel, or correlate pings with HR."),
        .init(slug: "github", name: "GitHub", icon: "chevron.left.forwardslash.chevron.right",
              blurb: "Does deploy day actually raise your resting HR?"),
        .init(slug: "linear", name: "Linear", icon: "checklist",
              blurb: "Sprint load vs strain, issue churn vs sleep."),
    ]
}

struct DayEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let attendees: [String]
}

struct ComposioConnection: Identifiable {
    let id: String
    let toolkitSlug: String
    let status: String     // ACTIVE / INITIATED / EXPIRED / FAILED

    var isActive: Bool { status.uppercased() == "ACTIVE" }
}

enum ComposioError: LocalizedError {
    case noKey
    case http(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "Add your Composio API key first (composio.dev → Settings → API Keys)."
        case .http(let code, let body):
            return "Composio API error \(code): \(body.prefix(200))"
        case .badResponse(let what):
            return "Unexpected Composio response: \(what)"
        }
    }
}

// MARK: - Store

@MainActor
final class ComposioStore: ObservableObject {
    static let shared = ComposioStore()

    @Published private(set) var hasKey: Bool
    @Published private(set) var connections: [ComposioConnection] = []
    @Published private(set) var busySlug: String? = nil
    @Published private(set) var pollingSlug: String? = nil
    @Published var lastError: String? = nil

    private let base = URL(string: "https://backend.composio.dev")!
    private static let userIdKey = "composio.userId"

    /// Stable per-install user id, so connections survive relaunches.
    let userId: String

    private init() {
        hasKey = ComposioKeyStore.read() != nil
        if let existing = UserDefaults.standard.string(forKey: Self.userIdKey) {
            userId = existing
        } else {
            let fresh = "noop-" + UUID().uuidString.lowercased()
            UserDefaults.standard.set(fresh, forKey: Self.userIdKey)
            userId = fresh
        }
    }

    func saveKey(_ key: String) {
        ComposioKeyStore.save(key)
        hasKey = ComposioKeyStore.read() != nil
        if hasKey { Task { await refresh() } }
    }

    func clearKey() {
        ComposioKeyStore.clear()
        hasKey = false
        connections = []
    }

    func activeConnection(for slug: String) -> ComposioConnection? {
        connections.first { $0.toolkitSlug == slug && $0.isActive }
    }

    // MARK: networking

    private func request(_ method: String, _ path: String,
                         query: [URLQueryItem] = [],
                         body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let key = ComposioKeyStore.read() else { throw ComposioError.noKey }
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ComposioError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let dict = parsed as? [String: Any] else {
            throw ComposioError.badResponse("not a JSON object")
        }
        return dict
    }

    /// Tolerate snake_case / camelCase across API revisions.
    private static func str(_ dict: [String: Any], _ keys: String...) -> String? {
        for k in keys where dict[k] is String { return dict[k] as? String }
        return nil
    }

    // MARK: refresh connections

    func refresh() async {
        guard hasKey else { return }
        do {
            let resp = try await request("GET", "/api/v3/connected_accounts",
                                         query: [.init(name: "user_ids", value: userId)])
            let items = (resp["items"] as? [[String: Any]]) ?? []
            connections = items.compactMap { item in
                guard let id = Self.str(item, "id", "nanoid") else { return nil }
                let toolkit = (item["toolkit"] as? [String: Any]).flatMap { Self.str($0, "slug") }
                    ?? Self.str(item, "toolkit_slug", "appName") ?? "?"
                let status = Self.str(item, "status") ?? "UNKNOWN"
                return ComposioConnection(id: id, toolkitSlug: toolkit.lowercased(), status: status)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: connect flow

    /// Find an existing auth config for the toolkit or create a Composio-managed one.
    private func authConfigId(for slug: String) async throws -> String {
        let listed = try await request("GET", "/api/v3/auth_configs",
                                       query: [.init(name: "toolkit_slug", value: slug)])
        if let items = listed["items"] as? [[String: Any]],
           let first = items.first, let id = Self.str(first, "id", "nanoid") {
            return id
        }
        let created = try await request("POST", "/api/v3/auth_configs", body: [
            "toolkit": ["slug": slug],
            "auth_config": ["type": "use_composio_managed_auth"],
        ])
        if let cfg = created["auth_config"] as? [String: Any],
           let id = Self.str(cfg, "id", "nanoid") { return id }
        if let id = Self.str(created, "id", "nanoid") { return id }
        throw ComposioError.badResponse("auth config create returned no id")
    }

    /// Full connect flow: ensure auth config → create link session → open the
    /// user's browser → poll until the account goes ACTIVE (or times out).
    func connect(_ toolkit: ComposioToolkit) async {
        guard busySlug == nil else { return }
        busySlug = toolkit.slug
        lastError = nil
        defer { busySlug = nil; pollingSlug = nil }
        do {
            let authConfig = try await authConfigId(for: toolkit.slug)
            let link = try await request("POST", "/api/v3/connected_accounts/link", body: [
                "auth_config_id": authConfig,
                "user_id": userId,
            ])
            guard let redirect = Self.str(link, "redirect_url", "redirectUrl", "redirectUri"),
                  let url = URL(string: redirect) else {
                throw ComposioError.badResponse("link session returned no redirect_url")
            }
            let accountId = Self.str(link, "connected_account_id", "connectedAccountId", "id")
            NSWorkspace.shared.open(url)

            // Poll for up to 3 minutes while the user finishes OAuth in the browser.
            pollingSlug = toolkit.slug
            for _ in 0..<36 {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                if let accountId {
                    let acct = try await request("GET", "/api/v3/connected_accounts/\(accountId)")
                    if (Self.str(acct, "status") ?? "").uppercased() == "ACTIVE" { break }
                } else {
                    await refresh()
                    if activeConnection(for: toolkit.slug) != nil { break }
                }
            }
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: tool execution (previews)

    /// Execute a Composio tool for this user. Returns the `data` payload.
    func execute(_ toolSlug: String, arguments: [String: Any]) async throws -> [String: Any] {
        let resp = try await request("POST", "/api/v3/tools/execute/\(toolSlug)", body: [
            "user_id": userId,
            "arguments": arguments,
        ])
        if let ok = resp["successful"] as? Bool, !ok {
            throw ComposioError.badResponse(Self.str(resp, "error") ?? "tool reported failure")
        }
        return (resp["data"] as? [String: Any]) ?? [:]
    }

    /// Today's timed events, for the day timeline. All-day events are skipped.
    func todayEvents() async throws -> [DayEvent] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date())
        let dayEnd = dayStart.addingTimeInterval(86_400)
        let iso = ISO8601DateFormatter()
        let data = try await execute("GOOGLECALENDAR_EVENTS_LIST", arguments: [
            "calendarId": "primary",
            "timeMin": iso.string(from: dayStart),
            "timeMax": iso.string(from: dayEnd),
            "singleEvents": true,
            "orderBy": "startTime",
            "maxResults": 50,
        ])
        let items = (data["items"] as? [[String: Any]]) ?? (data["events"] as? [[String: Any]]) ?? []
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return items.compactMap { e in
            guard let startRaw = (e["start"] as? [String: Any]).flatMap({ Self.str($0, "dateTime") }),
                  let endRaw = (e["end"] as? [String: Any]).flatMap({ Self.str($0, "dateTime") }),
                  let start = parser.date(from: startRaw),
                  let end = parser.date(from: endRaw) else { return nil }
            let attendees = (e["attendees"] as? [[String: Any]])?
                .compactMap { Self.str($0, "email") } ?? []
            return DayEvent(id: Self.str(e, "id") ?? UUID().uuidString,
                            title: Self.str(e, "summary") ?? "(untitled)",
                            start: start, end: end, attendees: attendees)
        }
    }

    /// Upcoming calendar events (next 7 days, first 5).
    func upcomingEvents() async throws -> [(title: String, when: String, attendees: Int)] {
        let iso = ISO8601DateFormatter()
        let data = try await execute("GOOGLECALENDAR_EVENTS_LIST", arguments: [
            "calendarId": "primary",
            "timeMin": iso.string(from: Date()),
            "timeMax": iso.string(from: Date().addingTimeInterval(7 * 86_400)),
            "singleEvents": true,
            "orderBy": "startTime",
            "maxResults": 5,
        ])
        let items = (data["items"] as? [[String: Any]]) ?? (data["events"] as? [[String: Any]]) ?? []
        let out = DateFormatter()
        out.dateFormat = "EEE d MMM, HH:mm"
        return items.compactMap { e in
            let title = Self.str(e, "summary") ?? "(untitled)"
            let startRaw = (e["start"] as? [String: Any]).flatMap { Self.str($0, "dateTime", "date") } ?? ""
            let when: String
            if let d = ISO8601DateFormatter().date(from: startRaw) {
                when = out.string(from: d)
            } else {
                when = startRaw
            }
            let attendees = (e["attendees"] as? [[String: Any]])?.count ?? 0
            return (title, when, attendees)
        }
    }

    /// Recent Strava activities (last 5).
    func recentActivities() async throws -> [(name: String, sport: String, km: Double)] {
        let data = try await execute("STRAVA_LIST_ATHLETE_ACTIVITIES",
                                     arguments: ["per_page": 5, "page": 1])
        let items = (data["details"] as? [[String: Any]]) ?? []
        return items.map { a in
            let name = Self.str(a, "name") ?? "(activity)"
            let sport = Self.str(a, "sport_type", "type") ?? ""
            let meters = (a["distance"] as? Double) ?? 0
            return (name, sport, meters / 1000)
        }
    }
}
