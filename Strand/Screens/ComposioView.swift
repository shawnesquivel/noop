import StrandDesign
import SwiftUI
import WhoopStore

/// Connect — your day as a stress heat map.
///
/// Hero: today's Google Calendar events (via Composio) laid out on a vertical
/// timeline next to a heat strip colored by a stress score computed from the
/// strap's heart rate (local `hrSample` data, baseline-relative). Hovering the
/// strip shows the stress level at that moment. Below: toolkit connections.
///
/// Bring-your-own Composio key (Keychain), browser-based OAuth, and the only
/// host contacted is backend.composio.dev. Strap data never leaves the Mac.
struct ComposioView: View {
    @EnvironmentObject var repo: Repository
    @StateObject private var store = ComposioStore.shared
    @State private var keyDraft = ""
    @State private var events: [DayEvent] = []
    @State private var stress: [StressPoint] = []   // minute-resolution, today
    @State private var usingDemoEvents = false
    @State private var usingDemoStress = false

    var body: some View {
        ScreenScaffold(
            title: "Connect",
            subtitle: "Today's calendar against your heart rate — where does the stress actually come from?"
        ) {
            if !store.hasKey {
                keyCard
            }
            dayCard
            if store.hasKey {
                toolkitGrid
                footerCard
            }
            if let err = store.lastError {
                errorBanner(err)
            }
        }
        .task {
            await store.refresh()
            await loadDay()
        }
    }

    // MARK: - data

    private func loadDay() async {
        // Events: real calendar when connected, otherwise a sample day so the
        // screen demonstrates itself before anything is linked.
        if store.hasKey, store.activeConnection(for: "googlecalendar") != nil,
           let real = try? await store.todayEvents(), !real.isEmpty {
            events = real
            usingDemoEvents = false
        } else {
            events = Self.sampleDay()
            usingDemoEvents = true
        }

        // Stress: strap HR vs a daily baseline. Falls back to a deterministic
        // demo curve (meetings run hot) when the local DB has no HR yet.
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date())
        let buckets = await repo.hrBuckets(
            from: Int(dayStart.timeIntervalSince1970),
            to: Int(Date().timeIntervalSince1970),
            bucketSeconds: 600
        )
        if buckets.count >= 6 {
            stress = Self.stressFromHR(buckets)
            usingDemoStress = false
        } else {
            stress = Self.demoStress(events: events, dayStart: dayStart)
            usingDemoStress = true
        }
    }

    /// Baseline-relative 0–100 score: 25th percentile of the day's bpm is "calm",
    /// the spread above it maps linearly onto the scale.
    static func stressFromHR(_ buckets: [HRBucket]) -> [StressPoint] {
        let bpms = buckets.map(\.bpm).sorted()
        let baseline = bpms[bpms.count / 4]
        let top = max(bpms.last ?? baseline + 30, baseline + 25)
        return buckets.map { b in
            let score = (b.bpm - baseline) / (top - baseline) * 100
            return StressPoint(time: Date(timeIntervalSince1970: TimeInterval(b.ts)),
                               score: min(100, max(0, score)))
        }
    }

    /// Demo curve: gentle wander, +stress inside meetings (more attendees, hotter).
    static func demoStress(events: [DayEvent], dayStart: Date) -> [StressPoint] {
        var points: [StressPoint] = []
        var t = dayStart.addingTimeInterval(7 * 3600)
        let end = dayStart.addingTimeInterval(18 * 3600)
        var wander = 25.0
        var seed: UInt64 = 0x5EED
        while t <= end {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(seed >> 33 % 1000) / 1000.0 - 0.5
            wander = min(55, max(12, wander + noise * 9))
            var score = wander
            for e in events where e.start <= t && t < e.end {
                let heat = 30.0 + Double(min(e.attendees.count, 6)) * 8.0
                let into = t.timeIntervalSince(e.start) / max(e.end.timeIntervalSince(e.start), 60)
                score += heat * (0.6 + 0.4 * into)   // meetings get worse as they go
            }
            points.append(StressPoint(time: t, score: min(100, score)))
            t = t.addingTimeInterval(600)
        }
        return points
    }

    static func sampleDay() -> [DayEvent] {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        func at(_ h: Double, _ dur: Double) -> (Date, Date) {
            let s = day.addingTimeInterval(h * 3600)
            return (s, s.addingTimeInterval(dur * 3600))
        }
        let specs: [(String, Double, Double, Int)] = [
            ("Focus time", 8, 3, 0),
            ("Julian × Karri 1:1", 11, 1, 2),
            ("Lunch", 12, 1, 0),
            ("Performance review", 13, 1, 3),
            ("Create Q2 Roadmap", 14, 1.5, 1),
        ]
        return specs.map { (title, h, dur, n) in
            let (s, e) = at(h, dur)
            return DayEvent(id: title, title: title, start: s, end: e,
                            attendees: (0..<n).map { "person\($0)@work.com" })
        }
    }

    // MARK: - day card (the mock)

    private var dayCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("Today")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(Date(), format: .dateTime.weekday(.wide).day().month())
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                    if usingDemoEvents {
                        StatePill("Sample day — connect Google Calendar", tone: .warning)
                    }
                    if usingDemoStress {
                        StatePill("Demo stress — pair strap for real HR", tone: .neutral)
                    }
                }
                DayTimeline(events: events, stress: stress)
                    .frame(maxWidth: 560)
                    .frame(height: 460)
            }
        }
    }

    // MARK: - key entry

    private var keyCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill").foregroundStyle(StrandPalette.accent)
                    Text("Bring your own Composio key")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text("Off until you add a key, like Coach. Create a free account at composio.dev, copy an API key, paste it here. Stored in the macOS Keychain. The only host contacted is backend.composio.dev; sign-in happens in your own browser.")
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
                        Task { await loadDay() }
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Link("Get a key", destination: URL(string: "https://app.composio.dev/settings/api-keys")!)
                        .font(StrandFont.subhead)
                }
            }
        }
    }

    // MARK: - toolkits

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
                            await loadDay()
                        }
                    } label: {
                        Label("Connect", systemImage: "link").font(StrandFont.subhead)
                    }
                    .disabled(store.busySlug != nil)
                }
            }
        }
    }

    private var footerCard: some View {
        StrandCard(padding: 16) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield").foregroundStyle(StrandPalette.textTertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Key stored in Keychain · user id \(store.userId)")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text("OAuth tokens live with Composio, not in NOOP. Strap data never leaves this Mac.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                Button("Refresh") { Task { await store.refresh(); await loadDay() } }
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
}

// MARK: - StressPoint

struct StressPoint: Equatable {
    let time: Date
    let score: Double   // 0–100
}

// MARK: - DayTimeline (events column + stress heat strip + hover tooltip)

private struct DayTimeline: View {
    let events: [DayEvent]
    let stress: [StressPoint]

    @State private var hoverY: CGFloat? = nil

    private var dayStart: Date {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())
        let firstEvent = events.map(\.start).min() ?? base.addingTimeInterval(8 * 3600)
        let candidate = min(firstEvent, base.addingTimeInterval(8 * 3600))
        // floor to the hour
        let h = cal.component(.hour, from: candidate)
        return cal.date(bySettingHour: h, minute: 0, second: 0, of: candidate) ?? candidate
    }

    private var dayEnd: Date {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())
        let lastEvent = events.map(\.end).max() ?? base.addingTimeInterval(17 * 3600)
        let candidate = max(lastEvent, base.addingTimeInterval(17 * 3600))
        let h = cal.component(.hour, from: candidate)
        return cal.date(bySettingHour: min(h + 1, 23), minute: 0, second: 0, of: candidate) ?? candidate
    }

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let span = dayEnd.timeIntervalSince(dayStart)
            func y(_ date: Date) -> CGFloat {
                CGFloat(date.timeIntervalSince(dayStart) / span) * height
            }

            HStack(alignment: .top, spacing: 14) {
                // events column
                ZStack(alignment: .topLeading) {
                    Color.clear
                    ForEach(events) { e in
                        eventCard(e)
                            .frame(height: max(y(e.end) - y(e.start) - 4, 34))
                            .offset(y: y(e.start))
                    }
                }
                .frame(maxWidth: .infinity)

                // heat strip
                heatStrip(height: height)
                    .frame(width: 16)
            }
            .overlay(alignment: .topLeading) {
                if let hy = hoverY {
                    tooltip(forY: hy, height: height)
                        .offset(x: geo.size.width - 230, y: max(0, min(hy - 22, height - 50)))
                }
            }
        }
    }

    private func eventCard(_ e: DayEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(e.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
            Text("\(e.start, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())–\(e.end, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())")
                .font(.system(size: 11))
                .foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1)
        )
    }

    // MARK: heat strip

    private func heatStrip(height: CGFloat) -> some View {
        let stops = gradientStops()
        return Capsule(style: .continuous)
            .fill(LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom))
            .overlay(Capsule().strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverY = p.y
                case .ended: hoverY = nil
                }
            }
    }

    private func gradientStops() -> [Gradient.Stop] {
        guard !stress.isEmpty else {
            return [.init(color: .green.opacity(0.45), location: 0),
                    .init(color: .green.opacity(0.45), location: 1)]
        }
        let span = dayEnd.timeIntervalSince(dayStart)
        return stress
            .filter { $0.time >= dayStart && $0.time <= dayEnd }
            .map { p in
                let loc = p.time.timeIntervalSince(dayStart) / span
                return Gradient.Stop(color: Self.heatColor(p.score), location: loc)
            }
    }

    static func heatColor(_ score: Double) -> Color {
        // green → yellow → orange → red, soft like the mock
        switch score {
        case ..<25:  return Color(red: 0.62, green: 0.80, blue: 0.55)
        case ..<50:  return Color(red: 0.90, green: 0.85, blue: 0.50)
        case ..<75:  return Color(red: 0.95, green: 0.70, blue: 0.40)
        default:     return Color(red: 0.93, green: 0.45, blue: 0.35)
        }
    }

    // MARK: tooltip

    private func stressAt(y: CGFloat, height: CGFloat) -> Double? {
        guard !stress.isEmpty else { return nil }
        let span = dayEnd.timeIntervalSince(dayStart)
        let t = dayStart.addingTimeInterval(span * Double(y / height))
        return stress.min(by: {
            abs($0.time.timeIntervalSince(t)) < abs($1.time.timeIntervalSince(t))
        })?.score
    }

    private func tooltip(forY y: CGFloat, height: CGFloat) -> some View {
        let score = stressAt(y: y, height: height) ?? 0
        let level = Int(score.rounded())
        let (label, tone): (String, Color) =
            score >= 70 ? ("High stress detected", DayTimeline.heatColor(90))
            : score >= 40 ? ("Elevated", DayTimeline.heatColor(60))
            : ("Calm", DayTimeline.heatColor(10))
        return HStack(spacing: 0) {
            Rectangle().fill(tone).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stress level: \(level)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize()
        .allowsHitTesting(false)
    }
}
