import SwiftUI
import AppKit
import CoreAudio
import CoreGraphics
import ApplicationServices
import Observation

// MARK: - CoreAudio volume

enum SystemVolume {
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D7663 // 'vmvc'

    static func addr(_ sel: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultDevice() -> AudioDeviceID? {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var dev = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let r = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev)
        return (r == noErr && dev != kAudioObjectUnknown) ? dev : nil
    }

    static func get() -> Float? {
        guard let dev = defaultDevice() else { return nil }
        var a = addr(virtualMainVolume)
        guard AudioObjectHasProperty(dev, &a) else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func set(_ value: Float) -> Bool {
        guard let dev = defaultDevice() else { return false }
        var a = addr(virtualMainVolume)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(dev, &a),
              AudioObjectIsPropertySettable(dev, &a, &settable) == noErr, settable.boolValue else { return false }
        var v = min(max(value, 0), 1)
        return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    static func isMuted() -> Bool? {
        guard let dev = defaultDevice() else { return nil }
        var a = addr(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(dev, &a) else { return nil }
        var m: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &m) == noErr ? (m != 0) : nil
    }

    static func setMuted(_ muted: Bool) -> Bool {
        guard let dev = defaultDevice() else { return false }
        var a = addr(kAudioDevicePropertyMute)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(dev, &a),
              AudioObjectIsPropertySettable(dev, &a, &settable) == noErr, settable.boolValue else { return false }
        var m: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m) == noErr
    }
}

// MARK: - Brightness via private DisplayServices (dlopen, fully guarded)

enum DisplayBrightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFn: GetFn? = {
        guard let h = handle, let s = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(s, to: GetFn.self)
    }()
    private static let setFn: SetFn? = {
        guard let h = handle, let s = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(s, to: SetFn.self)
    }()

    static var isAvailable: Bool { getFn != nil && setFn != nil }

    static func get(display: CGDirectDisplayID) -> Float? {
        guard let getFn else { return nil }
        var v: Float = 0
        return getFn(display, &v) == 0 ? v : nil
    }

    static func set(_ value: Float, display: CGDirectDisplayID) -> Bool {
        guard let setFn else { return false }
        return setFn(display, min(max(value, 0), 1)) == 0
    }
}

// MARK: - Module

@MainActor
@Observable
final class HUDModule: NotchModule {
    let id = "hud"
    let title = "Volume & Brightness HUD"
    let icon = "speaker.wave.2"
    let priority = 0
    var showsTab: Bool { false }

    var tapActive = false
    var hasAccessibility: Bool { AXIsProcessTrusted() }

    @ObservationIgnored private weak var state: NotchState?
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var tapSource: CFRunLoopSource?
    @ObservationIgnored private var a11yObserver: NSObjectProtocol?
    @ObservationIgnored private var volBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var devBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var listenedDevice: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    @ObservationIgnored private var lastVolume: Float = -1
    @ObservationIgnored private var lastMuted: Bool = false
    @ObservationIgnored private var primed = false

    private static let step: Float = 1.0 / 16.0

    func start(state: NotchState) {
        self.state = state
        installAudioListeners()
        installTap()
        // Accessibility trust changes are announced; retry the tap then (no polling).
        a11yObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tap == nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.installTap() }
            }
        }
    }

    func stop() {
        removeTap()
        removeAudioListeners()
        if let o = a11yObserver { DistributedNotificationCenter.default().removeObserver(o) }
        a11yObserver = nil
    }

    func expandedView() -> AnyView { AnyView(EmptyView()) }

    // MARK: Accessibility / tap

    func requestAccessibility() {
        // The system prompt only appears once per app; after a deny/reset it silently does nothing,
        // so always take the user straight to the Accessibility list as well.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func installTap() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else { tapActive = false; return }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: hudTapCallback, userInfo: refcon) else {
            tapActive = false
            return
        }
        tap = port
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tapActive = true
    }

    private func removeTap() {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let src = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil; tapSource = nil; tapActive = false
    }

    fileprivate func reenableTap() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) } }

    /// Returns true if the key was handled (event should be swallowed).
    fileprivate func handleMediaKey(code: Int, down: Bool, flags: CGEventFlags) -> Bool {
        let isKnown = [0, 1, 7, 2, 3].contains(code)
        guard isKnown else { return false }
        // Leave Option/Command variants (open System Settings etc.) to the system.
        if flags.contains(.maskAlternate) || flags.contains(.maskCommand) { return false }
        switch code {
        case 0, 1, 7:
            return handleVolume(code: code, down: down)
        default:
            return handleBrightness(up: code == 2, down: down)
        }
    }

    private func handleVolume(code: Int, down: Bool) -> Bool {
        guard let cur = SystemVolume.get() else { return false }   // device without volume control: pass through
        guard down else { return true }
        if code == 7 {
            let muted = SystemVolume.isMuted() ?? false
            guard SystemVolume.setMuted(!muted) else { return false }
        } else {
            let delta = code == 0 ? Self.step : -Self.step
            if code == 0, SystemVolume.isMuted() == true { _ = SystemVolume.setMuted(false) }
            guard SystemVolume.set(cur + delta) else { return false }
        }
        showVolume()
        return true
    }

    private func handleBrightness(up: Bool, down: Bool) -> Bool {
        guard let state, DisplayBrightness.isAvailable,
              let cur = DisplayBrightness.get(display: state.geometry.displayID) else { return false }
        guard down else { return true }
        let new = min(max(cur + (up ? Self.step : -Self.step), 0), 1)
        guard DisplayBrightness.set(new, display: state.geometry.displayID) else { return false }
        state.showTransient(Transient(icon: new < 0.01 ? "sun.min" : "sun.max.fill",
                                      label: "Brightness", value: Double(new)))
        return true
    }

    private func showVolume() {
        guard let state, let v = SystemVolume.get() else { return }
        let muted = SystemVolume.isMuted() ?? false
        lastVolume = v; lastMuted = muted
        let icon = muted || v <= 0 ? "speaker.slash.fill"
            : (v < 0.34 ? "speaker.wave.1.fill" : (v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"))
        state.showTransient(Transient(icon: icon, label: muted ? "Muted" : "Volume",
                                      value: muted ? 0 : Double(v)))
    }

    // MARK: CoreAudio listeners (show HUD for volume changes from anywhere)

    private func installAudioListeners() {
        lastVolume = SystemVolume.get() ?? -1
        lastMuted = SystemVolume.isMuted() ?? false
        primed = true
        volBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.audioChanged() } }
        }
        devBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.attachVolumeListener() } }
        }
        var a = SystemVolume.addr(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, devBlock!)
        attachVolumeListener()
    }

    private func attachVolumeListener() {
        detachVolumeListener()
        guard let dev = SystemVolume.defaultDevice(), let block = volBlock else { return }
        listenedDevice = dev
        for sel in [AudioObjectPropertySelector(0x766D7663), kAudioDevicePropertyMute] {
            var a = SystemVolume.addr(sel)
            if AudioObjectHasProperty(dev, &a) { AudioObjectAddPropertyListenerBlock(dev, &a, .main, block) }
        }
        lastVolume = SystemVolume.get() ?? -1
        lastMuted = SystemVolume.isMuted() ?? false
    }

    private func detachVolumeListener() {
        guard listenedDevice != kAudioObjectUnknown, let block = volBlock else { return }
        for sel in [AudioObjectPropertySelector(0x766D7663), kAudioDevicePropertyMute] {
            var a = SystemVolume.addr(sel)
            AudioObjectRemovePropertyListenerBlock(listenedDevice, &a, .main, block)
        }
        listenedDevice = AudioDeviceID(kAudioObjectUnknown)
    }

    private func removeAudioListeners() {
        detachVolumeListener()
        if let b = devBlock {
            var a = SystemVolume.addr(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, b)
        }
        volBlock = nil; devBlock = nil
    }

    private func audioChanged() {
        guard primed else { return }
        let v = SystemVolume.get() ?? -1
        let m = SystemVolume.isMuted() ?? false
        if abs(v - lastVolume) > 0.0005 || m != lastMuted { showVolume() }
    }
}

// C callback for the CGEventTap (runs on the main run loop).
private func hudTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let module = Unmanaged<HUDModule>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { module.reenableTap() }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let data1 = ns.data1
    let keyCode = (data1 & 0xFFFF0000) >> 16
    let keyFlags = data1 & 0x0000FFFF
    let down = ((keyFlags & 0xFF00) >> 8) == 0xA
    let flags = event.flags
    let handled = MainActor.assumeIsolated { module.handleMediaKey(code: keyCode, down: down, flags: flags) }
    return handled ? nil : Unmanaged.passUnretained(event)
}
