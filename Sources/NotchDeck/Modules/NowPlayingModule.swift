import SwiftUI
import AppKit
import Observation

/// Serial AppleScript runner. Never launches the target app (callers check it's running first).
enum AppleScriptRunner {
    private static let queue = DispatchQueue(label: "notchdeck.applescript", qos: .userInitiated)

    static func run(_ source: String, completion: @escaping @Sendable (String?, Data?) -> Void) {
        queue.async {
            var err: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
            let str = err == nil ? result?.stringValue : nil
            let data = err == nil ? result?.data : nil
            DispatchQueue.main.async { completion(str, data) }
        }
    }

    static func fire(_ source: String) { run(source) { _, _ in } }
}

/// Splits a byte stream into newline-delimited lines; used from a single file-handle callback queue.
final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    func append(_ chunk: Data) -> [Data] {
        data.append(chunk)
        var lines: [Data] = []
        while let nl = data.firstIndex(of: 0x0A) {
            lines.append(data.subdata(in: data.startIndex..<nl))
            data.removeSubrange(data.startIndex...nl)
        }
        return lines
    }
}

/// Carries a parsed JSON dictionary across a queue hop.
struct JSONBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ v: [String: Any]) { value = v }
}

@MainActor
@Observable
final class NowPlayingModule: NotchModule {
    enum Source: String {
        case music, spotify
        /// Any other player (browsers, iPad apps, anything else), read from system Now Playing.
        case system
        var bundleID: String {
            switch self {
            case .music: return "com.apple.Music"
            case .spotify: return "com.spotify.client"
            case .system: return "system"
            }
        }
        var displayName: String {
            switch self {
            case .music: return "Music"
            case .spotify: return "Spotify"
            case .system: return "Now Playing"
            }
        }
    }
    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: Double   // seconds
    }

    let id = "nowplaying"
    let title = "Now Playing"
    let icon = "music.note"
    let priority = 100

    var track: Track?
    var isPlaying = false
    var artwork: NSImage?
    var source: Source?
    private(set) var basePosition: Double = 0
    private(set) var baseDate = Date()

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var observersDist: [NSObjectProtocol] = []
    @ObservationIgnored private var artworkToken = 0
    @ObservationIgnored private var systemProc: Process?
    @ObservationIgnored private var feedWanted = false
    @ObservationIgnored private var feedRestarts = 0
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    var isCompactActive: Bool { track != nil && (isPlaying) }

    func position(at date: Date) -> Double {
        guard let t = track else { return 0 }
        let p = isPlaying ? basePosition + date.timeIntervalSince(baseDate) : basePosition
        return min(max(p, 0), max(t.duration, 0.01))
    }

    // MARK: Lifecycle

    func start(state: NotchState) {
        let dnc = DistributedNotificationCenter.default()
        observersDist.append(dnc.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo
            MainActor.assumeIsolated { self?.handle(.music, info: info) }
        })
        observersDist.append(dnc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo
            MainActor.assumeIsolated { self?.handle(.spotify, info: info) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let bid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let s = self.source, s.bundleID == bid else { return }
                self.clear()
            }
        })
        bootstrap()
        startSystemFeed()
    }

    func stop() {
        stopSystemFeed()
        for o in observersDist { DistributedNotificationCenter.default().removeObserver(o) }
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []; observersDist = []
        clear()
    }

    private func clear() {
        track = nil; isPlaying = false; artwork = nil; source = nil
    }

    private func isRunning(_ s: Source) -> Bool {
        // Controls for the system source go through a separate one-shot helper, so they work even
        // while the streaming feed is restarting.
        if s == .system { return helperPaths() != nil }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: s.bundleID).isEmpty
    }

    // MARK: System Now Playing feed (non-AppleScript players: browsers, other apps)

    /// Reads macOS's system Now Playing through a tiny helper dylib loaded by /usr/bin/perl, which
    /// is still allowed to use the private MediaRemote framework. Event-driven, no polling.
    private func helperPaths() -> (script: String, lib: String)? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let script = res.appendingPathComponent("np/run.pl").path
        let lib = res.appendingPathComponent("np/libnp.dylib").path
        let fm = FileManager.default
        return fm.fileExists(atPath: script) && fm.fileExists(atPath: lib) ? (script, lib) : nil
    }

    private func startSystemFeed() {
        guard systemProc == nil, let p = helperPaths() else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [p.script, p.lib, "np_stream"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            for line in buffer.append(data) {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                let box = JSONBox(obj)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleSystem(box.value) } }
            }
        }
        // If the helper dies (sleep/wake, media daemon restart, crash), bring it back after a short pause.
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.systemProc === p, self.feedWanted else { return }
                    self.systemProc = nil
                    let delay = min(30, 2 * Double(self.feedRestarts + 1))
                    self.feedRestarts += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        MainActor.assumeIsolated { if self?.feedWanted == true { self?.startSystemFeed() } }
                    }
                }
            }
        }
        feedWanted = true
        do { try proc.run(); systemProc = proc } catch { systemProc = nil }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.feedWanted else { return }
                    // Restart fresh after wake; MediaRemote registrations can go stale across sleep.
                    self.feedRestarts = 0
                    let old = self.systemProc
                    self.systemProc = nil
                    old?.terminate()
                    self.startSystemFeed()
                }
            }
        }
    }

    private func stopSystemFeed() {
        feedWanted = false
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); wakeObserver = nil }
        if let p = systemProc, p.isRunning { p.terminate() }
        systemProc = nil
    }

    private func handleSystem(_ o: [String: Any]) {
        feedRestarts = 0
        let pid = (o["pid"] as? NSNumber)?.int32Value ?? 0
        let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        // Music and desktop Spotify are handled by their richer AppleScript paths.
        if bid == Source.music.bundleID || bid == Source.spotify.bundleID { return }
        guard (o["hasInfo"] as? Bool) ?? false, let title = o["title"] as? String, !title.isEmpty else {
            if source == .system { clear() }
            return
        }
        let playing = (o["playing"] as? NSNumber)?.boolValue ?? false
        let rate = (o["rate"] as? NSNumber)?.doubleValue ?? (playing ? 1 : 0)
        let elapsed = (o["elapsed"] as? NSNumber)?.doubleValue ?? 0
        let stamp = (o["timestamp"] as? NSNumber)?.doubleValue
        var pos = elapsed
        if playing, let stamp { pos += max(0, Date().timeIntervalSince1970 - stamp) * max(rate, 1) }
        let t = Track(title: title, artist: o["artist"] as? String ?? "",
                      album: o["album"] as? String ?? "",
                      duration: (o["duration"] as? NSNumber)?.doubleValue ?? 0)
        let trackChanged = track != t || source != .system
        apply(source: .system, playing: playing, track: t, position: pos)
        if trackChanged { artworkToken += 1; artwork = nil }
        if let b64 = o["art"] as? String, let d = Data(base64Encoded: b64), let img = NSImage(data: d) {
            artwork = img
        }
    }

    private func sendSystem(_ command: Int) {
        guard let p = helperPaths() else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [p.script, p.lib, "np_command"]
        var env = ProcessInfo.processInfo.environment
        env["NP_CMD"] = String(command)
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    /// One-time state query at launch for players that are already running.
    private func bootstrap() {
        for s in [Source.music, .spotify] where isRunning(s) {
            let script = """
            tell application id "\(s.bundleID)"
                if player state is playing or player state is paused then
                    set st to (player state as string)
                    return st & "\\t" & (name of current track) & "\\t" & (artist of current track) & "\\t" & (album of current track) & "\\t" & (duration of current track as string) & "\\t" & (player position as string)
                end if
            end tell
            """
            AppleScriptRunner.run(script) { [weak self] str, _ in
                MainActor.assumeIsolated {
                    guard let self, let str else { return }
                    let f = str.components(separatedBy: "\t")
                    guard f.count >= 6 else { return }
                    var dur = Double(f[4].replacingOccurrences(of: ",", with: ".")) ?? 0
                    if s == .spotify { dur /= 1000 }
                    let pos = Double(f[5].replacingOccurrences(of: ",", with: ".")) ?? 0
                    self.apply(source: s, playing: f[0].lowercased().contains("play"),
                               track: Track(title: f[1], artist: f[2], album: f[3], duration: dur),
                               position: pos)
                }
            }
        }
    }

    // MARK: Events

    private func handle(_ s: Source, info: [AnyHashable: Any]?) {
        guard let info else { return }
        let stateStr = (info["Player State"] as? String) ?? ""
        if stateStr == "Stopped" {
            if source == s { clear() }
            return
        }
        let name = info["Name"] as? String ?? ""
        guard !name.isEmpty else { return }
        let durMs = (info[s == .music ? "Total Time" : "Duration"] as? NSNumber)?.doubleValue ?? 0
        let t = Track(title: name, artist: info["Artist"] as? String ?? "",
                      album: info["Album"] as? String ?? "", duration: durMs / 1000)
        let pos = (info["Playback Position"] as? NSNumber)?.doubleValue
        apply(source: s, playing: stateStr == "Playing", track: t, position: pos)
        if pos == nil { refreshPosition(s) }
    }

    private func apply(source s: Source, playing: Bool, track t: Track, position: Double?) {
        // Spotify is the preferred player: once it owns the slot, Music events don't take it over
        // until Spotify stops or quits (both clear `source`).
        // The same goes for a system-sourced Spotify (e.g. the iPad app) holding the slot.
        if s == .music, source == .spotify, isRunning(.spotify) { return }
        if s == .music, source == .system { return }
        let changed = (track != t) || source != s
        source = s
        track = t
        isPlaying = playing
        if let position { basePosition = position; baseDate = Date() }
        else if changed { basePosition = 0; baseDate = Date() }
        if changed && s != .system { loadArtwork(s) }
    }

    private func refreshPosition(_ s: Source) {
        guard isRunning(s) else { return }
        AppleScriptRunner.run("tell application id \"\(s.bundleID)\" to return (player position as string)") { [weak self] str, _ in
            MainActor.assumeIsolated {
                guard let self, self.source == s, let str,
                      let v = Double(str.replacingOccurrences(of: ",", with: ".")) else { return }
                self.basePosition = v; self.baseDate = Date()
            }
        }
    }

    private func loadArtwork(_ s: Source) {
        artworkToken += 1
        let token = artworkToken
        artwork = nil
        guard isRunning(s) else { return }
        switch s {
        case .system:
            break   // artwork arrives with the system feed
        case .music:
            let script = """
            tell application id "com.apple.Music"
                if (count of artworks of current track) > 0 then return data of artwork 1 of current track
            end tell
            """
            AppleScriptRunner.run(script) { [weak self] _, data in
                MainActor.assumeIsolated {
                    guard let self, token == self.artworkToken, let data, let img = NSImage(data: data) else { return }
                    self.artwork = img
                }
            }
        case .spotify:
            AppleScriptRunner.run("tell application id \"com.spotify.client\" to return artwork url of current track") { [weak self] str, _ in
                guard let str, let url = URL(string: str) else { return }
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data, let img = NSImage(data: data) else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, token == self.artworkToken else { return }
                            self.artwork = img
                        }
                    }
                }.resume()
            }
        }
    }

    // MARK: Controls

    func togglePlayPause() {
        guard let s = source, isRunning(s) else { return }
        basePosition = position(at: Date()); baseDate = Date()
        isPlaying.toggle()
        if s == .system { sendSystem(2); return }
        AppleScriptRunner.fire("tell application id \"\(s.bundleID)\" to playpause")
    }

    func next() {
        guard let s = source, isRunning(s) else { return }
        if s == .system { sendSystem(4); return }
        AppleScriptRunner.fire("tell application id \"\(s.bundleID)\" to next track")
    }

    func previous() {
        guard let s = source, isRunning(s) else { return }
        if s == .system { sendSystem(5); return }
        AppleScriptRunner.fire("tell application id \"\(s.bundleID)\" to previous track")
    }

    func seek(to seconds: Double) {
        guard let s = source, isRunning(s), s != .system else { return }
        basePosition = seconds; baseDate = Date()
        AppleScriptRunner.fire("tell application id \"\(s.bundleID)\" to set player position to \(seconds)")
    }

    // MARK: Views

    func compactLeading() -> AnyView {
        AnyView(ArtworkView(image: artwork, size: 22, radius: 5)
            .modifier(MatchedArt()))
    }

    func compactTrailing() -> AnyView {
        // Moving bars in the closed ("idle") notch; the timeline is paused whenever nothing is playing.
        AnyView(WaveformView(playing: isPlaying, bars: 4, height: 16, barWidth: 2.5, spacing: 2))
    }

    func expandedView() -> AnyView { AnyView(NowPlayingView(module: self)) }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [.gray.opacity(0.5), .gray.opacity(0.2)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct NowPlayingView: View {
    let module: NowPlayingModule

    var body: some View {
        if let t = module.track {
            HStack(spacing: 18) {
                ArtworkView(image: module.artwork, size: 112, radius: 14)
                    .modifier(MatchedArt())
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Text(t.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        WaveformView(playing: module.isPlaying).frame(width: 26, height: 18)
                    }
                    Spacer(minLength: 4)
                    Scrubber(module: module, duration: t.duration)
                    HStack(spacing: 28) {
                        Spacer()
                        ControlButton(symbol: "backward.fill", size: 17) { module.previous() }
                        ControlButton(symbol: module.isPlaying ? "pause.fill" : "play.fill", size: 24) { module.togglePlayPause() }
                        ControlButton(symbol: "forward.fill", size: 17) { module.next() }
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
            .frame(height: 112)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note.list").font(.system(size: 26)).foregroundStyle(.white.opacity(0.4))
                Text("Nothing playing").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                Text("Play something in Music or Spotify").font(.system(size: 11)).foregroundStyle(.white.opacity(0.3))
            }
            .frame(maxWidth: .infinity, minHeight: 100)
        }
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 30)
        }
        .buttonStyle(PressStyle())
    }
}

/// Scrubber redraws via TimelineView, which only exists while the notch is open.
struct Scrubber: View {
    let module: NowPlayingModule
    let duration: Double
    @StateObject private var dragBox = Local<Double?>(nil)
    private var dragValue: Double? { get { dragBox.value } nonmutating set { dragBox.value = newValue } }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !module.isPlaying && dragValue == nil)) { ctx in
            let pos = dragValue ?? module.position(at: ctx.date)
            VStack(spacing: 3) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(Color.white)
                            .frame(width: g.size.width * (duration > 0 ? pos / duration : 0))
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in dragValue = min(max(v.location.x / g.size.width, 0), 1) * duration }
                        .onEnded { v in
                            let s = min(max(v.location.x / g.size.width, 0), 1) * duration
                            module.seek(to: s); dragValue = nil
                        })
                }
                .frame(height: 12)
                HStack {
                    Text(fmt(pos)); Spacer(); Text("-" + fmt(max(duration - pos, 0)))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func fmt(_ s: Double) -> String {
        let i = Int(s.rounded()); return String(format: "%d:%02d", i / 60, i % 60)
    }
}

/// Animated bars; the timeline only runs while playing and while this view is on screen (notch open).
struct WaveformView: View {
    let playing: Bool
    var bars = 4
    var height: CGFloat = 18
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2.5

    /// Deterministic pseudo-random 0...1 per (bar, step).
    private static func noise(_ i: Int, _ step: Int) -> Double {
        let x = sin(Double(i) * 127.1 + Double(step) * 311.7) * 43758.5453
        return x - floor(x)
    }

    /// Smooth, beat-like bar level: random targets ~7 times a second, eased between, plus a gentle sway.
    private static func level(_ i: Int, _ t: Double) -> Double {
        let rate = 7.0
        let p = t * rate, step = Int(floor(p)), f = p - floor(p)
        let e = f * f * (3 - 2 * f)
        let r = noise(i, step) * (1 - e) + noise(i, step + 1) * e
        let sway = 0.08 * sin(t * (1.6 + Double(i) * 0.7))
        return min(max(0.18 + 0.82 * r + sway, 0.18), 1)
    }

    var body: some View {
        // Paused (no timer at all) unless a track is actually playing.
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<bars, id: \.self) { i in
                    let h = playing ? Self.level(i, t) : 0.25
                    Capsule().fill(Color.white.opacity(0.85))
                        .frame(width: barWidth, height: height * h)
                }
            }
            .frame(height: height)
        }
    }
}
