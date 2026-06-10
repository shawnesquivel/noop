import StrandDesign
import SwiftUI

/// Connect — link external toolkits (Google Calendar, Strava, Gmail, …)
/// through Composio so NOOP's strap data can be joined with the rest of your
/// life: meetings vs heart rate, workouts vs strain, deploy days vs RHR.
///
/// Bring-your-own key, like Coach: nothing talks to the network until the
/// user pastes their Composio API key, and the only host contacted is
/// backend.composio.dev. OAuth itself happens in the user's own browser.
struct ComposioView: View {
    @StateObject private var store = ComposioStore.shared
    @State private var keyDraft = ""
    @State private var events: [(title: String, when: String, attendees: Int)] = []
    @State private var activities: [(name: String, sport: String, km: Double)] = []
    @State private var previewError: String?

    var body: some View {
        ScreenScaffold(
            title: "Connect",
            subtitle: "Link your calendar, workouts and tools through Composio — so strap data can meet the rest of your life."
        ) {
            if !store.hasKey {
                keyCard
            } else {
                toolkitGrid
                previews
                footerCard
            }
            if let err = store.lastError {
                errorBanner(err)
            }
        }
        .task {
            await store.refresh()
            await loadPreviews()
        }
    }

    // MARK: key entry

    private var keyCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(StrandPalette.accent)
                    Text("Bring your own Composio key")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text("Like Coach, this feature is off until you add a key. Create a free account at composio.dev, copy an API key from Settings, and paste it here. It is stored in the macOS Keychain — never on disk in the clear. The only host this screen talks to is backend.composio.dev; account sign-in happens in your own browser.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    SecureField("COMPOSIO_API_KEY", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 380)
                    Button("Save") {
                        store.saveKey(keyDraft)
                        keyDraft = ""
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Link("Get a key", destination: URL(string: "https://app.composio.dev/settings/api-keys")!)
                        .font(StrandFont.subhead)
                }
            }
        }
    }

    // MARK: toolkit grid

    private var toolkitGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)],
                  alignment: .leading, spacing: 14) {
            ForEach(ComposioToolkit.featured) { toolkit in
                toolkitCard(toolkit)
            }
        }
    }

    private func toolkitCard(_ toolkit: ComposioToolkit) -> some View {
        let connected = store.activeConnection(for: toolkit.slug) != nil
        let busy = store.busySlug == toolkit.slug
        return StrandCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: toolkit.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(connected ? StrandPalette.statusPositive : StrandPalette.accent)
                        .frame(width: 24)
                    Text(toolkit.name)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    if connected {
                        StatePill("Connected", tone: .positive)
                    } else if busy {
                        StatePill(store.pollingSlug == toolkit.slug ? "Finish in browser…" : "Opening…",
                                  tone: .accent, pulsing: true)
                    }
                }
                Text(toolkit.blurb)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !connected {
                    Button {
                        Task {
                            await store.connect(toolkit)
                            await loadPreviews()
                        }
                    } label: {
                        Label("Connect", systemImage: "link")
                            .font(StrandFont.subhead)
                    }
                    .disabled(store.busySlug != nil)
                }
            }
        }
    }

    // MARK: previews

    @ViewBuilder private var previews: some View {
        if store.activeConnection(for: "googlecalendar") != nil && !events.isEmpty {
            StrandCard(padding: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Upcoming meetings", symbol: "calendar")
                    ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                        HStack(spacing: 8) {
                            Text(e.when)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .frame(width: 130, alignment: .leading)
                            Text(e.title)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            if e.attendees > 0 {
                                Text("\(e.attendees) attendees")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                    }
                    Text("Next: join these against your heart rate to find which meetings — and which attendees — spike your BPM.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        if store.activeConnection(for: "strava") != nil && !activities.isEmpty {
            StrandCard(padding: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Recent activities", symbol: "figure.run")
                    ForEach(Array(activities.enumerated()), id: \.offset) { _, a in
                        HStack(spacing: 8) {
                            Text(a.sport)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .frame(width: 130, alignment: .leading)
                            Text(a.name)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            if a.km > 0 {
                                Text(String(format: "%.1f km", a.km))
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                    }
                }
            }
        }
        if let previewError {
            errorBanner(previewError)
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(StrandPalette.accent)
            Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private var footerCard: some View {
        StrandCard(padding: 16) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(StrandPalette.textTertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Key stored in Keychain · user id \(store.userId)")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text("OAuth tokens live with Composio, not in NOOP. Strap data never leaves this Mac.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                Button("Refresh") { Task { await store.refresh(); await loadPreviews() } }
                    .font(StrandFont.footnote)
                Button("Remove key", role: .destructive) { store.clearKey() }
                    .font(StrandFont.footnote)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        StrandCard(padding: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(StrandPalette.statusWarning)
                Text(message)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func loadPreviews() async {
        previewError = nil
        if store.activeConnection(for: "googlecalendar") != nil {
            do { events = try await store.upcomingEvents() }
            catch { previewError = error.localizedDescription }
        }
        if store.activeConnection(for: "strava") != nil {
            do { activities = try await store.recentActivities() }
            catch { previewError = error.localizedDescription }
        }
    }
}
