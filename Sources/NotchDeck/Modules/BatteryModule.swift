import SwiftUI
import IOKit.ps
import Observation

@MainActor
@Observable
final class BatteryModule: NotchModule {
    let id = "battery"
    let title = "Battery"
    let icon = "battery.75percent"
    let priority = 30

    private(set) var percent: Int = 0
    private(set) var isCharging = false
    private(set) var onAC = false
    private(set) var hasBattery = false
    private(set) var minutesRemaining: Int?

    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private weak var state: NotchState?
    @ObservationIgnored private var lastAC: Bool?

    func start(state: NotchState) {
        self.state = state
        refresh(announce: false)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        // Event-driven: IOKit invokes this only when power-source state changes.
        if let s = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let m = Unmanaged<BatteryModule>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { m.refresh(announce: true) }
        }, ctx)?.takeRetainedValue() {
            source = s
            CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode)
        }
    }

    func stop() {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode) }
        source = nil
    }

    func onEvent(_ event: NotchEvent) { if event == .opened { refresh(announce: false) } }

    func refresh(announce: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            hasBattery = true
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            percent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            isCharging = d[kIOPSIsChargingKey] as? Bool ?? false
            onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let t = (isCharging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int
            minutesRemaining = (t ?? -1) > 0 ? t : nil
        }
        if announce, hasBattery, let last = lastAC, last != onAC {
            state?.showTransient(Transient(icon: onAC ? "bolt.fill" : "battery.75percent",
                                           label: "\(percent)%", value: Double(percent) / 100,
                                           tint: onAC ? .green : .white))
        }
        lastAC = onAC
    }

    func expandedView() -> AnyView { AnyView(BatteryView(module: self)) }
}

struct BatteryView: View {
    let module: BatteryModule
    var body: some View {
        if !module.hasBattery {
            Text("No battery detected").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
        } else {
            HStack(spacing: 26) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 8)
                    Circle().trim(from: 0, to: Double(module.percent) / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(module.percent)%").font(.system(size: 24, weight: .semibold).monospacedDigit())
                        if module.isCharging { Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(.green) }
                    }
                }
                .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 6) {
                    Text(module.isCharging ? "Charging" : (module.onAC ? "Plugged in" : "On battery"))
                        .font(.system(size: 16, weight: .semibold))
                    if let m = module.minutesRemaining {
                        Text("\(m / 60)h \(m % 60)m \(module.isCharging ? "until full" : "remaining")")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    } else if module.onAC && !module.isCharging {
                        Text("Fully charged").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer()
            }
        }
    }
    private var color: Color { module.percent <= 20 && !module.isCharging ? .red : (module.isCharging ? .green : .white) }
}
