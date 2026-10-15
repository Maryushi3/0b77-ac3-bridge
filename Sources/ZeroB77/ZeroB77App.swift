import AppKit
import AVFoundation
import CoreAudio
import SwiftUI

@main
struct ZeroB77App: App {
    @StateObject private var settings = BridgeSettings()
    @StateObject private var controller = BridgeController()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(settings)
                .environmentObject(controller)
                .frame(width: 380)
        } label: {
            Label { Text("0B77") } icon: { Image(nsImage: controller.menuImage) }
        }
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
    /// Mirrors BridgeSettings.usePolish (synced by the view); drives all controller strings.
    @Published var uiPolish = false
    /// Menu-bar grid state; the icon itself shows idle vs streaming.
    @Published var menuImage: NSImage = MenuIcon.image(streaming: false)
    /// Newer GitHub release tag (e.g. "0.1.1"); nil when up to date / offline.
    @Published var updateVersion: String?
    @Published var updateURL: String?

    private var bridge: AudioBridge?
    private var timer: Timer?
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
    private func checkForUpdates() async {
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
            lastError = t.micDenied
            speakerConfirmPending = false
            return
        }
        guard let inID = selectedInputID, let outID = selectedOutputID else {
            lastError = t.pickDevices
            return
        }
        // Safeguard: same device for in+out would loop the encoded blast back into the encoder.
        if inID == outID {
            lastError = t.sameDevice
            speakerConfirmPending = false
            return
        }
        guard let inDev = inputDevices.first(where: { $0.id == inID }),
              let outDev = outputDevices.first(where: { $0.id == outID })
        else {
            lastError = t.deviceGone
            speakerConfirmPending = false
            return
        }
        if settings.firstChannel + 1 > outDev.outputChannels {
            lastError = t.onlyChannels(outDev.outputChannels)
            speakerConfirmPending = false
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
        let b = AudioBridge(inDevice: inID, outDevice: outID,
                            firstChannel: settings.firstChannel,
                            bitrate: settings.bitrate, prefill: settings.prefill)
        do {
            try b.start()
        } catch {
            lastError = t.couldNotStart(error.localizedDescription)
            return
        }
        bridge = b
        isRunning = true
        menuImage = MenuIcon.image(streaming: true)
        runSummary = t.runSummary(inName: inDev.name, outName: outDev.name,
                                  ch: settings.firstChannel, bitrate: settings.bitrate)
        watchInID = inID
        watchOutID = outID
        watchInRate = DeviceManager.nominalSampleRate(inID)
        watchOutRate = DeviceManager.nominalSampleRate(outID)
        settings.inDeviceName = inDev.name
        settings.outDeviceName = outDev.name
    }

    func stop() {
        bridge?.stop()
        bridge = nil
        isRunning = false
        menuImage = MenuIcon.image(streaming: false)
        statusLine = T(pl: uiPolish).stopped
        runSummary = ""
        speakerConfirmPending = false
        watchInID = nil
        watchOutID = nil
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
            lastError = msg
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
                lastError = t.deviceChangedHelp
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

// MARK: - popover UI (parity with the Tk window)

struct PopoverView: View {
    @EnvironmentObject var settings: BridgeSettings
    @EnvironmentObject var controller: BridgeController

    var body: some View {
        let t = T(pl: settings.usePolish)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t.appName).font(.headline)
                Text(t.appSubtitle).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker(t.languageLabel, selection: $settings.language) {
                    Text(t.languageSystem).tag("system")
                    Text("English").tag("en")
                    Text("Polski").tag("pl")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            if controller.isRunning, !controller.runSummary.isEmpty {
                Text(controller.runSummary)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(2)
            }
            let warnings = controller.preflightWarnings()
            if !controller.isRunning, !warnings.isEmpty {
                ForEach(warnings, id: \.self) { w in
                    Text("⚠ \(w)").font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            if let v = controller.updateVersion {
                HStack {
                    Text(t.updateAvailable(v)).font(.caption).foregroundStyle(.blue)
                    Button(t.download) {
                        if let u = controller.updateURL, let url = URL(string: u) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }
            }

            Picker(t.inputLabel, selection: deviceBinding(
                devices: controller.inputDevices,
                selection: $controller.selectedInputID)) {
                ForEach(controller.inputDevices) { d in
                    Text("\(d.name) (\(t.channelsIn(d.inputChannels)))").tag(Optional(d.id))
                }
            }
            .pickerStyle(.menu)
            .disabled(controller.isRunning)

            Picker(t.outputLabel, selection: deviceBinding(
                devices: controller.outputDevices,
                selection: $controller.selectedOutputID)) {
                ForEach(controller.outputDevices) { d in
                    Text("\(d.name) (\(t.channelsOut(d.outputChannels)))").tag(Optional(d.id))
                }
            }
            .pickerStyle(.menu)
            .disabled(controller.isRunning)

            HStack {
                Stepper(t.firstChannel(settings.firstChannel),
                        value: $settings.firstChannel, in: 1...63)
            }
            .disabled(controller.isRunning)

            HStack {
                Picker(t.bitrateLabel, selection: $settings.bitrate) {
                    ForEach([384, 448, 576, 640], id: \.self) { b in
                        Text(t.bitrateUnit(b)).tag(b)
                    }
                }
                .pickerStyle(.menu)
                .disabled(controller.isRunning)
                Stepper(t.buffer(settings.prefill),
                        value: $settings.prefill, in: 1...8)
                    .onChange(of: settings.prefill) { _, n in controller.applyPrefill(n) }
            }

            HStack {
                Button(controller.isRunning ? t.stop
                       : controller.speakerConfirmPending ? t.confirmSpeakers : t.start) {
                    controller.toggle(settings: settings)
                }
                    .keyboardShortcut(.defaultAction)
                Button(t.refresh) {
                    controller.refreshDevices()
                    controller.restoreSelection(settings: settings)
                }
                .disabled(controller.isRunning)
            }

            Text(controller.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if let err = controller.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(4)
            }
            Button(t.quit) { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
        }
        .padding(12)
        .onAppear {
            controller.uiPolish = settings.usePolish
            controller.restoreSelection(settings: settings)
        }
        .onChange(of: settings.language) { _, _ in controller.uiPolish = settings.usePolish }
    }

    private func deviceBinding(devices _: [AudioDeviceInfo],
                               selection: Binding<AudioDeviceID?>) -> Binding<AudioDeviceID?> {
        selection
    }
}
