import Foundation

/// Persisted settings (replaces ~/.ac3bridge.json with UserDefaults).
final class BridgeSettings: ObservableObject {
    @Published var inDeviceName: String {
        didSet { defaults.set(inDeviceName, forKey: "inDeviceName") }
    }
    @Published var outDeviceName: String {
        didSet { defaults.set(outDeviceName, forKey: "outDeviceName") }
    }
    @Published var firstChannel: Int {
        didSet { defaults.set(firstChannel, forKey: "firstChannel") }
    }
    @Published var bitrate: Int {
        didSet { defaults.set(bitrate, forKey: "bitrate") }
    }
    @Published var prefill: Int {
        didSet { defaults.set(prefill, forKey: "prefill") }
    }

    private let defaults = UserDefaults.standard

    init() {
        inDeviceName = defaults.string(forKey: "inDeviceName") ?? ""
        outDeviceName = defaults.string(forKey: "outDeviceName") ?? ""
        let ch = defaults.integer(forKey: "firstChannel")
        firstChannel = ch == 0 ? 9 : ch
        let br = defaults.integer(forKey: "bitrate")
        bitrate = br == 0 ? 640 : br
        let pf = defaults.integer(forKey: "prefill")
        prefill = pf == 0 ? 1 : pf
    }
}
