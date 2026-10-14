import CoreAudio
import SwiftUI

@main
struct AC3BridgeApp: App {
    @StateObject private var settings = BridgeSettings()
    @StateObject private var controller = BridgeController()

    var body: some Scene {
        MenuBarExtra("AC-3 Bridge", systemImage: "cable.connector.horizontal") {
            PopoverView()
                .environmentObject(settings)
                .environmentObject(controller)
                .frame(width: 380)
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

    private var bridge: AudioBridge?
    private var timer: Timer?

    init() {
        refreshDevices()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
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
        lastError = nil
        guard let inID = selectedInputID, let outID = selectedOutputID else {
            lastError = "Pick input and output devices."
            return
        }
        guard let inDev = inputDevices.first(where: { $0.id == inID }),
              let outDev = outputDevices.first(where: { $0.id == outID })
        else {
            lastError = "Selected device disappeared. Hit Refresh."
            return
        }
        if settings.firstChannel + 1 > outDev.outputChannels {
            lastError = "Output device only has \(outDev.outputChannels) channels."
            return
        }
        let b = AudioBridge(inDevice: inID, outDevice: outID,
                            firstChannel: settings.firstChannel,
                            bitrate: settings.bitrate, prefill: settings.prefill)
        do {
            try b.start()
        } catch {
            lastError = "Could not start:\n\(error.localizedDescription)"
            return
        }
        bridge = b
        isRunning = true
        settings.inDeviceName = inDev.name
        settings.outDeviceName = outDev.name
    }

    func stop() {
        bridge?.stop()
        bridge = nil
        isRunning = false
        statusLine = "Stopped"
    }

    func applyPrefill(_ n: Int) {
        bridge?.prefill = n
    }

    private func tick() {
        guard let b = bridge else { return }
        if !b.isAlive {
            let msg = b.lastEncoderError.isEmpty ? "ffmpeg exited" : b.lastEncoderError
            stop()
            statusLine = "Stopped: \(msg)"
            lastError = msg
            return
        }
        let s = b.stats
        statusLine = "Running (\(s.playing ? "streaming" : "buffering")) | buffer \(s.fill)/\(s.maxBuf) frames | dropped \(s.drops) | underruns \(s.underruns)"
    }
}

// MARK: - popover UI (parity with the Tk window)

struct PopoverView: View {
    @EnvironmentObject var settings: BridgeSettings
    @EnvironmentObject var controller: BridgeController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AC-3 Bridge").font(.headline)

            Picker("Input (6ch)", selection: deviceBinding(
                devices: controller.inputDevices,
                selection: $controller.selectedInputID)) {
                ForEach(controller.inputDevices) { d in
                    Text("\(d.name) (\(d.inputChannels) in)").tag(Optional(d.id))
                }
            }
            .pickerStyle(.menu)

            Picker("Output", selection: deviceBinding(
                devices: controller.outputDevices,
                selection: $controller.selectedOutputID)) {
                ForEach(controller.outputDevices) { d in
                    Text("\(d.name) (\(d.outputChannels) out)").tag(Optional(d.id))
                }
            }
            .pickerStyle(.menu)

            HStack {
                Stepper("First output channel: \(settings.firstChannel) (uses \(settings.firstChannel)–\(settings.firstChannel + 1))",
                        value: $settings.firstChannel, in: 1...63)
            }

            HStack {
                Picker("AC-3 bitrate", selection: $settings.bitrate) {
                    ForEach([384, 448, 576, 640], id: \.self) { b in
                        Text("\(b) kbps").tag(b)
                    }
                }
                .pickerStyle(.menu)
                Stepper("Buffer: \(settings.prefill) (~\(settings.prefill * 32) ms)",
                        value: $settings.prefill, in: 1...8)
                    .onChange(of: settings.prefill) { _, n in controller.applyPrefill(n) }
            }

            HStack {
                Button(controller.isRunning ? "Stop" : "Start") { controller.toggle(settings: settings) }
                    .keyboardShortcut(.defaultAction)
                Button("Refresh devices") {
                    controller.refreshDevices()
                    controller.restoreSelection(settings: settings)
                }
            }

            Text(controller.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if let err = controller.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(4)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
        }
        .padding(12)
        .onAppear { controller.restoreSelection(settings: settings) }
    }

    private func deviceBinding(devices _: [AudioDeviceInfo],
                               selection: Binding<AudioDeviceID?>) -> Binding<AudioDeviceID?> {
        selection
    }
}
