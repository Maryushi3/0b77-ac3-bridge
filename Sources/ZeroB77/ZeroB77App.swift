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
    /// About popup visibility (kept here: @State macros are flaky under CLT SwiftPM).
    @Published var showAbout = false
    /// Newer GitHub release tag (e.g. "0.1.1"); nil when up to date / offline.
    @Published var updateVersion: String?
    @Published var updateURL: String?
    /// Transient result of a manual update check ("Up to Date" / cleared).
    @Published var updateNote: String?

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
        // Route system audio into the bridge input; restored on stop/quit/failure.
        let previousDefault = DeviceManager.defaultOutputDevice()
        if previousDefault != inID {
            do {
                try DeviceManager.setDefaultOutputDevice(inID)
            } catch {
                lastError = t.couldNotStart(error.localizedDescription)
                return
            }
            savedDefaultOutputID = previousDefault
        } else {
            savedDefaultOutputID = nil
        }
        let b = AudioBridge(inDevice: inID, outDevice: outID,
                            firstChannel: settings.firstChannel,
                            bitrate: settings.bitrate, prefill: settings.prefill)
        do {
            try b.start()
        } catch {
            restoreDefaultOutput()
            lastError = t.couldNotStart(error.localizedDescription)
            return
        }
        bridge = b
        isRunning = true
        menuImage = MenuIcon.image(streaming: true)
        runSummary = t.runSummary(inName: inDev.name, outName: outDev.name,
                                  ch: settings.firstChannel, bitrate: settings.bitrate)
            + " (\(b.engineName))"
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
        restoreDefaultOutput()
    }

    /// Give the system output back (best-effort; never fails a stop).
    private func restoreDefaultOutput() {
        if let saved = savedDefaultOutputID {
            try? DeviceManager.setDefaultOutputDevice(saved)
            savedDefaultOutputID = nil
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("0B77 \(controller.appVersion)").font(.headline)
                    Text(t.appSubtitle).font(.caption).foregroundStyle(.secondary)
                }
            }

            statusSection(t)

            Divider()

            Form {
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

            Picker(t.firstChannelLabel, selection: $settings.firstChannel) {
                ForEach(channelRange, id: \.self) { ch in
                    Text(t.channelPair(ch)).tag(ch)
                }
            }
            .pickerStyle(.menu)
            .disabled(controller.isRunning)
            .onChange(of: controller.selectedOutputID) { _, _ in
                clampChannel(settings: settings)
            }

            Picker(t.bitrateLabel, selection: $settings.bitrate) {
                ForEach([384, 448, 576, 640], id: \.self) { b in
                    Text(t.bitrateUnit(b)).tag(b)
                }
            }
            .disabled(controller.isRunning)

            Picker(t.bufferLabel, selection: $settings.prefill) {
                ForEach(1...8, id: \.self) { n in
                    Text(t.bufferRow(n)).tag(n)
                }
            }
            .onChange(of: settings.prefill) { _, n in controller.applyPrefill(n) }
            }

            HStack {
                Button(controller.isRunning ? t.stop
                       : controller.speakerConfirmPending ? t.confirmSpeakers : t.start) {
                    controller.toggle(settings: settings)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Button(t.refresh) {
                    controller.refreshDevices()
                    controller.restoreSelection(settings: settings)
                }
                .disabled(controller.isRunning)
            }

            HStack {
                Button(t.checkUpdates) {
                    Task { await controller.checkForUpdates(manual: true) }
                }
                Button(t.about) { controller.showAbout = true }
                    .popover(isPresented: $controller.showAbout) {
                        AboutView()
                            .environmentObject(settings)
                            .environmentObject(controller)
                    }
            }
            .buttonStyle(.link)
            if let v = controller.updateVersion {
                HStack {
                    Label(t.updateAvailable(v), systemImage: "arrow.down.circle")
                        .font(.callout)
                    Button(t.download) {
                        if let u = controller.updateURL, let url = URL(string: u) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }
            } else if let note = controller.updateNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Picker(t.languageLabel, selection: $settings.language) {
                    Text(t.languageSystem).tag("system")
                    Text("English").tag("en")
                    Text("Polski").tag("pl")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button(t.quit) { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .keyboardShortcut("q", modifiers: [.command])
            }
        }
        .padding(12)
        .onAppear {
            controller.uiPolish = settings.usePolish
            controller.restoreSelection(settings: settings)
            clampChannel(settings: settings)
        }
        .onChange(of: settings.language) { _, _ in controller.uiPolish = settings.usePolish }
    }

    // Symbol-led status: default label colors, red reserved for errors.
    @ViewBuilder
    private func statusSection(_ t: T) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if controller.isRunning, !controller.runSummary.isEmpty {
                Label(controller.runSummary, systemImage: "waveform")
                    .font(.callout)
            } else {
                Label(controller.statusLine, systemImage: "stop.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !controller.isRunning {
                ForEach(controller.preflightWarnings(), id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if controller.isRunning {
                Text(controller.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let err = controller.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var channelRange: Range<Int> {
        let outs = controller.outputDevices.first(
            where: { $0.id == controller.selectedOutputID })?.outputChannels ?? 20
        return 1..<(min(64, max(2, outs)))
    }

    /// Keep the saved pair valid when the output device changes.
    private func clampChannel(settings: BridgeSettings) {
        if !channelRange.contains(settings.firstChannel) {
            settings.firstChannel = channelRange.lowerBound
        }
    }

    private func deviceBinding(devices _: [AudioDeviceInfo],
                               selection: Binding<AudioDeviceID?>) -> Binding<AudioDeviceID?> {
        selection
    }
}

struct AboutView: View {
    @EnvironmentObject var settings: BridgeSettings
    @EnvironmentObject var controller: BridgeController

    var body: some View {
        let t = T(pl: settings.usePolish)
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("0B77").font(.headline)
            Text(t.version(controller.appVersion)).font(.caption)
            Text(t.appSubtitle).font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(t.madeBy).font(.caption)
            Button(t.repoLabel) {
                if let url = URL(string: t.repoURL) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
            Text(t.built(controller.buildDate)).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 260)
    }
}
