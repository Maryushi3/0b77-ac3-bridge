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
    /// 1-based first INPUT channel (captures this + next 5 = the 5.1 bank).
    @Published var firstInChannel: Int {
        didSet { defaults.set(firstInChannel, forKey: "firstInChannel") }
    }
    @Published var bitrate: Int {
        didSet { defaults.set(bitrate, forKey: "bitrate") }
    }
    @Published var prefill: Int {
        didSet { defaults.set(prefill, forKey: "prefill") }
    }
    /// "system" | "en" | "pl"
    @Published var language: String {
        didSet { defaults.set(language, forKey: "language") }
    }

    private let defaults = UserDefaults.standard

    init() {
        inDeviceName = defaults.string(forKey: "inDeviceName") ?? ""
        outDeviceName = defaults.string(forKey: "outDeviceName") ?? ""
        let ch = defaults.integer(forKey: "firstChannel")
        firstChannel = ch == 0 ? 9 : ch
        let ich = defaults.integer(forKey: "firstInChannel")
        firstInChannel = ich == 0 ? 1 : ich
        let br = defaults.integer(forKey: "bitrate")
        bitrate = br == 0 ? 640 : br
        let pf = defaults.integer(forKey: "prefill")
        prefill = pf == 0 ? 1 : pf
        language = defaults.string(forKey: "language") ?? "system"
    }

    var usePolish: Bool {
        switch language {
        case "pl": return true
        case "en": return false
        default:
            if #available(macOS 13, *) {
                return Locale.current.language.languageCode?.identifier == "pl"
            } else {
                return Locale.current.languageCode == "pl"
            }
        }
    }
}
