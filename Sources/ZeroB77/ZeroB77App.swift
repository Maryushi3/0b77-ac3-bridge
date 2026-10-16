import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation

/// Menu-bar-only entry: manual NSApplication run, no SwiftUI scene (a Scene
/// would spawn a window on launch — exactly what we don't want).
@main
enum ZeroB77App {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

// MARK: - controller

@MainActor
final class BridgeController: ObservableObject {
    @Published var isRunning = false
    @Published var statusLine = "Stopped"
    @Published var lastError: String?
    @Published var inputDevices: [AudioDeviceInfo] = []
    @Published var outputDevices: [AudioDeviceInfo] = []
    @Published var selectedInputID: AudioDeviceID?
    @Published var selectedOutputID: AudioDeviceID?
    /// Two-step arm: starting on ch 1-2 (speakers) needs a second press.
    @Published var speakerConfirmPending = false
    /// Frozen at Start for the running summary line.
    @Published var runSummary = ""
    /// Mirrors BridgeSettings.usePolish (synced by the menu); drives all controller strings.
    @Published var uiPolish = false
    /// Newer GitHub release tag (e.g. "0.1.1"); nil when up to date / offline.
    @Published var updateVersion: String?
    @Published var updateURL: String?
    /// Transient result of a manual update check ("Up to Date" / cleared).
    @Published var updateNote: String?
    /// Error sink for modal alerts (no popover to show them in).
    var onError: ((String) -> Void)?

    /// From the bundle (stamped by bundle.sh) — shown in header and About.
    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }
    var buildDate: String {
        Bundle.main.object(forInfoDictionaryKey: "ZeroB77BuildDate") as? String ?? "–"
    }

    private var bridge: AudioBridge?
    private var timer: Timer?
    // Previous system default output, restored on stop (nil = already Ours).
    private var savedDefaultOutputID: AudioDeviceID?
    // Watchdog: device set + sample rates captured at Start; tick() stops on change.
    private var watchInID: AudioDeviceID?
    private var watchOutID: AudioDeviceID?
    private var watchInRate: Double = 0
    private var watchOutRate: Double = 0

    init() {
        refreshDevices()
        // Clean shutdown: stop HAL IOProcs + ffmpeg child before the app exits,
        // otherwise the child keeps running and the device stays claimed.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await checkForUpdates() }
    }

    /// One-shot update check against GitHub releases. Silent on failure
    /// (offline, no releases yet) — installs stay manual regardless.
    /// Manual checks report "up to date" instead of staying silent.
    func checkForUpdates(manual: Bool = false) async {
        updateNote = nil
        struct Release: Decodable { var tag_name: String; var html_url: String }
        guard let url = URL(string: "https://api.github.com/repos/Maryushi3/0b77-ac3-bridge/releases/latest"),
              let current = Bundle.main.object(
                  forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let rel = try JSONDecoder().decode(Release.self, from: data)
            let latest = rel.tag_name.hasPrefix("v")
                ? String(rel.tag_name.dropFirst()) : rel.tag_name
            if Self.newer(latest, than: current) {
                updateVersion = latest
                updateURL = rel.html_url
            } else if manual {
                updateVersion = nil
                updateURL = nil
                updateNote = T(pl: uiPolish).upToDate
            }
        } catch { /* stay silent */ }
    }

    private static func newer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            Array((s.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]).prefix(3))
        }
        return parts(b).lexicographicallyPrecedes(parts(a))
    }

    /// Preflight warnings for the current selection (ffmpeg, sample rates).
    /// Never blocks Start — the 18i20 is shared, so we warn instead of forcing.
    func preflightWarnings() -> [String] {
        let t = T(pl: uiPolish)
        var w: [String] = []
        if FFmpegLocator.find() == nil {
            w.append(t.ffmpegMissing)
        }
        if let inID = selectedInputID {
            let r = DeviceManager.nominalSampleRate(inID)
            if r != 0, abs(r - AudioBridge.sampleRate) > 1 {
                w.append(t.inputRate(r))
            }
        }
        if let outID = selectedOutputID {
            let r = DeviceManager.nominalSampleRate(outID)
            if r != 0, abs(r - AudioBridge.sampleRate) > 1 {
                w.append(t.outputRate(r))
            }
        }
        return w
    }

    func refreshDevices() {
        inputDevices = DeviceManager.inputCandidates()
        outputDevices = DeviceManager.outputCandidates()
        NSLog("0B77: devices: %lu in-candidates, %lu out-candidates, running=%d",
              inputDevices.count, outputDevices.count, isRunning ? 1 : 0)
    }

    func restoreSelection(settings: BridgeSettings) {
        if let m = inputDevices.first(where: { $0.name == settings.inDeviceName }) {
            selectedInputID = m.id
        } else if let m = inputDevices.first(where: { $0.name.localizedCaseInsensitiveContains("blackhole") }) {
            selectedInputID = m.id
        } else {
            selectedInputID = inputDevices.first?.id
        }
        if let m = outputDevices.first(where: { $0.name == settings.outDeviceName }) {
            selectedOutputID = m.id
        } else if let m = outputDevices.first(where: { $0.name.localizedCaseInsensitiveContains("scarlett") }) {
            selectedOutputID = m.id
        } else {
            selectedOutputID = outputDevices.first?.id
        }
    }

    func toggle(settings: BridgeSettings) {
        if bridge != nil {
            stop()
            return
        }
        Task { await startFlow(settings: settings) }
    }

    /// Mic permission (needed even for virtual inputs like BlackHole) is async — hence the split.
    private func startFlow(settings: BridgeSettings) async {
        let t = T(pl: uiPolish)
        lastError = nil
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            fail(t.micDenied)
            return
        }
        guard let inID = selectedInputID, let outID = selectedOutputID else {
            fail(t.pickDevices)
            return
        }
        // Safeguard: same device for in+out would loop the encoded blast back into the encoder.
        if inID == outID {
            fail(t.sameDevice)
            return
        }
        guard let inDev = inputDevices.first(where: { $0.id == inID }),
              let outDev = outputDevices.first(where: { $0.id == outID })
        else {
            fail(t.deviceGone)
            return
        }
        if settings.firstChannel + 1 > outDev.outputChannels {
            fail(t.onlyChannels(outDev.outputChannels))
            return
        }
        if settings.firstInChannel + 5 > inDev.inputChannels {
            fail(t.onlyInputChannels(inDev.inputChannels))
            return
        }
        // Safeguard: 1-2 are the speakers on a shared device (e.g. 18i20) —
        // encoded AC-3 there is full-scale noise. Require a second press.
        if settings.firstChannel <= 2, !speakerConfirmPending {
            speakerConfirmPending = true
            lastError = t.speakerConfirm
            return
        }
        speakerConfirmPending = false
        // Route system audio into the bridge input; restored on stop/quit/failure.
        let previousDefault = DeviceManager.defaultOutputDevice()
        if previousDefault != inID {
            do {
                try DeviceManager.setDefaultOutputDevice(inID)
            } catch {
                fail(t.couldNotStart(error.localizedDescription))
                return
            }
            savedDefaultOutputID = previousDefault
        } else {
            savedDefaultOutputID = nil
        }
        let b = AudioBridge(inDevice: inID, outDevice: outID,
                            firstChannel: settings.firstChannel,
                            firstInChannel: settings.firstInChannel,
                            bitrate: settings.bitrate, prefill: settings.prefill)
        do {
            try b.start()
        } catch {
            restoreDefaultOutput()
            fail(t.couldNotStart(error.localizedDescription))
            return
        }
        bridge = b
        isRunning = true
        runSummary = t.runSummary(inName: inDev.name, inCh: settings.firstInChannel,
                                  outName: outDev.name, ch: settings.firstChannel)
        watchInID = inID
        watchOutID = outID
        watchInRate = DeviceManager.nominalSampleRate(inID)
        watchOutRate = DeviceManager.nominalSampleRate(outID)
        settings.inDeviceName = inDev.name
        settings.outDeviceName = outDev.name
    }

    /// Hard failure: record + surface modally (menus have no error surface).
    private func fail(_ msg: String) {
        lastError = msg
        speakerConfirmPending = false
        onError?(msg)
    }

    func stop() {
        bridge?.stop()
        bridge = nil
        isRunning = false
        statusLine = T(pl: uiPolish).stopped
        runSummary = ""
        speakerConfirmPending = false
        watchInID = nil
        watchOutID = nil
        restoreDefaultOutput()
    }

    /// Give the system output back (best-effort; never fails a stop).
    private func restoreDefaultOutput() {
        if let saved = savedDefaultOutputID {
            try? DeviceManager.setDefaultOutputDevice(saved)
            savedDefaultOutputID = nil
        }
    }

    /// First channels of 6-channel banks (hard 5.1): 1–6, 2–7, … never past
    /// the device's last channel. Tiny devices fall back to pairs.
    static func setRange(channels: Int) -> Range<Int> {
        if channels >= 6 { return 1..<(min(60, channels - 4)) }
        return 1..<(min(64, max(2, channels)))
    }

    /// First channels of stereo pairs (SPDIF out).
    static func pairRange(channels: Int) -> Range<Int> {
        1..<(min(64, max(2, channels)))
    }

    /// Keep both saved channel selections valid for the current devices.
    func clampChannels(settings: BridgeSettings) {
        let outs = outputDevices.first(where: { $0.id == selectedOutputID })?.outputChannels ?? 20
        let prange = Self.pairRange(channels: outs)
        if !prange.contains(settings.firstChannel) {
            settings.firstChannel = prange.lowerBound
        }
        let ins = inputDevices.first(where: { $0.id == selectedInputID })?.inputChannels ?? 6
        let srange = Self.setRange(channels: ins)
        if !srange.contains(settings.firstInChannel) {
            settings.firstInChannel = srange.lowerBound
        }
    }

    func applyPrefill(_ n: Int) {
        bridge?.prefill = n
    }

    private func tick() {
        guard let b = bridge else { return }
        let t = T(pl: uiPolish)
        if !b.isAlive {
            let msg = b.lastEncoderError.isEmpty ? t.ffmpegExited : b.lastEncoderError
            stop()
            statusLine = "\(t.stopped): \(msg)"
            fail(msg)
            return
        }
        // Watchdog: replug or sample-rate flip under a shared device must never
        // keep streaming onto a re-routed layout — stop instead.
        if let wIn = watchInID, let wOut = watchOutID {
            let stillThere = Set(DeviceManager.allDevices().map(\.id))
            let ratesChanged = DeviceManager.nominalSampleRate(wIn) != watchInRate
                || DeviceManager.nominalSampleRate(wOut) != watchOutRate
            if !stillThere.contains(wIn) || !stillThere.contains(wOut) || ratesChanged {
                stop()
                statusLine = t.stoppedDeviceChanged
                fail(t.deviceChangedHelp)
                refreshDevices()
                return
            }
        }
        let s = b.stats
        let mode = s.playing ? t.streaming : t.buffering
        let peak: String
        if s.inPeak <= 0.0001 {
            peak = t.inputSilent
        } else {
            peak = t.inputPeak(Int((20 * log10(s.inPeak)).rounded()))
        }
        statusLine = t.running(mode, fill: s.fill, max: s.maxBuf, drops: s.drops, underruns: s.underruns, peak: peak)
    }
}
