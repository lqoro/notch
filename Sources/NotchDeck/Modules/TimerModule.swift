import SwiftUI
import AppKit
import Observation

@MainActor
@Observable
final class TimerModule: NotchModule {
    let id = "timer"
    let title = "Timer"
    let icon = "timer"
    let priority = 60

    var total: TimeInterval = 5 * 60
    private(set) var endDate: Date?
    private(set) var pausedRemaining: TimeInterval?
    @ObservationIgnored private var fireTimer: Timer?
    @ObservationIgnored private weak var state: NotchState?

    var isRunning: Bool { endDate != nil }
    var isCompactActive: Bool { isRunning }

    func remaining(at date: Date) -> TimeInterval {
        if let e = endDate { return max(e.timeIntervalSince(date), 0) }
        return pausedRemaining ?? total
    }

    func start(state: NotchState) { self.state = state }
    func stop() { reset() }

    func setDuration(_ seconds: TimeInterval) { reset(); total = seconds }

    func startOrResume() {
        let rem = pausedRemaining ?? total
        guard rem > 0 else { return }
        endDate = Date().addingTimeInterval(rem)
        pausedRemaining = nil
        // One-shot timer that exists only while a countdown is running.
        fireTimer?.invalidate()
        fireTimer = Timer.scheduledTimer(withTimeInterval: rem, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    func pause() {
        guard let e = endDate else { return }
        pausedRemaining = max(e.timeIntervalSinceNow, 0)
        endDate = nil
        fireTimer?.invalidate(); fireTimer = nil
    }

    func reset() {
        fireTimer?.invalidate(); fireTimer = nil
        endDate = nil; pausedRemaining = nil
    }

    private func finish() {
        reset()
        NSSound(named: "Glass")?.play()
        state?.showTransient(Transient(icon: "timer", label: "Timer done", value: nil, tint: .orange), duration: 3)
    }

    func compactLeading() -> AnyView {
        AnyView(Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange))
    }

    func expandedView() -> AnyView { AnyView(TimerView(module: self)) }
}

struct TimerView: View {
    let module: TimerModule
    private let presets: [(String, TimeInterval)] = [("1m", 60), ("5m", 300), ("10m", 600), ("25m", 1500), ("45m", 2700)]

    var body: some View {
        HStack(spacing: 28) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let rem = module.remaining(at: ctx.date)
                let frac = module.total > 0 ? rem / module.total : 0
                ZStack {
                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 7)
                    Circle().trim(from: 0, to: frac)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(format(rem)).font(.system(size: 22, weight: .semibold).monospacedDigit())
                }
                .frame(width: 112, height: 112)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.0) { p in
                        Button(p.0) { module.setDuration(p.1) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .tint(abs(module.total - p.1) < 1 ? .orange : nil)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        module.isRunning ? module.pause() : module.startOrResume()
                    } label: {
                        Label(module.isRunning ? "Pause" : "Start", systemImage: module.isRunning ? "pause.fill" : "play.fill")
                            .frame(width: 70)
                    }.buttonStyle(.borderedProminent).tint(.orange)
                    Button("Reset") { module.reset() }.buttonStyle(.bordered)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up)); return String(format: "%d:%02d", s / 60, s % 60)
    }
}
