import Foundation

/// All user-visible strings, English + Polish. `pl == true` → Polish.
/// Kept in code (not .strings files) so the SwiftPM build needs no Xcode catalog.
/// Casing rule: lowercase first letter unless it's a complete sentence
/// (imperatives like "Odśwież urządzenia" count as sentences).
struct T {
    let pl: Bool
    init(pl: Bool) { self.pl = pl }

    // App chrome
    var appName: String { "0B77" }
    var appSubtitle: String { pl ? "mostek AC-3" : "AC-3 bridge" }
    var languageLabel: String { pl ? "język" : "language" }
    var languageSystem: String { pl ? "systemowy" : "system" }

    // Device pickers
    var inputLabel: String { pl ? "wejście (6 kan.)" : "input (6ch)" }
    var outputLabel: String { pl ? "wyjście" : "output" }
    func channelsIn(_ n: Int) -> String { pl ? "\(n) wej." : "\(n) in" }
    func channelsOut(_ n: Int) -> String { pl ? "\(n) wyj." : "\(n) out" }

    // Settings
    func firstChannel(_ ch: Int) -> String {
        pl ? "pierwszy kanał wyjścia: \(ch) (używa \(ch)–\(ch + 1))"
            : "first output channel: \(ch) (uses \(ch)–\(ch + 1))"
    }
    var bitrateLabel: String { pl ? "przepływność AC-3" : "AC-3 bitrate" }
    func bitrateUnit(_ b: Int) -> String { pl ? "\(b) kb/s" : "\(b) kbps" }
    func buffer(_ n: Int) -> String {
        pl ? "bufor: \(n) (~\(n * 32) ms)" : "buffer: \(n) (~\(n * 32) ms)"
    }

    // Buttons
    var start: String { "start" }
    var stop: String { "stop" }
    var confirmSpeakers: String { pl ? "Potwierdź: start na 1–2" : "Confirm: start on 1–2" }
    var refresh: String { pl ? "Odśwież urządzenia" : "Refresh devices" }
    var quit: String { pl ? "zakończ" : "quit" }

    // Status
    var stopped: String { pl ? "zatrzymano" : "stopped" }
    var streaming: String { pl ? "transmisja" : "streaming" }
    var buffering: String { pl ? "buforowanie" : "buffering" }
    func running(_ mode: String, fill: Int, max: Int, drops: Int, underruns: Int, peak: String, e2e: String) -> String {
        pl ? "działa (\(mode)) | bufor \(fill)/\(max) ramek | odrzucone \(drops) | underruny \(underruns) | \(peak) | \(e2e)"
            : "Running (\(mode)) | buffer \(fill)/\(max) frames | dropped \(drops) | underruns \(underruns) | \(peak) | \(e2e)"
    }
    var inputSilent: String { pl ? "wej. cisza" : "in silent" }
    func inputPeak(_ db: Int) -> String { pl ? "szczyt wej. \(db) dBFS" : "in peak \(db) dBFS" }
    func runSummary(inName: String, outName: String, ch: Int, bitrate: Int) -> String {
        pl ? "\(inName) → \(outName), kan. \(ch)–\(ch + 1) @ \(bitrate) kb/s"
            : "\(inName) → \(outName) ch \(ch)–\(ch + 1) @ \(bitrate) kbps"
    }

    // Updates (check only — installs stay manual, see MAINTAINING)
    func updateAvailable(_ v: String) -> String {
        pl ? "dostępna aktualizacja: \(v)" : "update available: \(v)"
    }
    var download: String { pl ? "pobierz" : "download" }

    // Preflight
    var ffmpegMissing: String { pl ? "Nie znaleziono ffmpeg — odpal: brew install ffmpeg"
        : "ffmpeg not found — run: brew install ffmpeg" }
    func inputRate(_ hz: Double) -> String {
        pl ? String(format: "wejście: %.0f Hz — ustaw 48 kHz w Konfiguratorze MIDI Audio", hz)
            : String(format: "input at %.0f Hz — set 48 kHz in Audio MIDI Setup", hz)
    }
    func outputRate(_ hz: Double) -> String {
        pl ? String(format: "wyjście: %.0f Hz — ustaw 48 kHz w Konfiguratorze MIDI Audio", hz)
            : String(format: "output at %.0f Hz — set 48 kHz in Audio MIDI Setup", hz)
    }

    // Errors
    var micDenied: String {
        pl ? "Brak zgody na mikrofon — włącz 0B77 w: Ustawienia systemowe > Prywatność i bezpieczeństwo > Mikrofon. (macOS wymaga jej do przechwytywania dźwięku, także z BlackHole.)"
            : "Microphone permission denied — enable 0B77 in System Settings > Privacy & Security > Microphone. (macOS requires it for any audio capture, including BlackHole.)"
    }
    var pickDevices: String { pl ? "Wybierz urządzenia wejściowe i wyjściowe." : "Pick input and output devices." }
    var sameDevice: String { pl ? "Wejście i wyjście nie mogą być tym samym urządzeniem."
        : "Input and output can't be the same device." }
    var deviceGone: String { pl ? "Wybrane urządzenie zniknęło. Odśwież listę."
        : "Selected device disappeared. Hit Refresh." }
    func onlyChannels(_ n: Int) -> String {
        pl ? "Urządzenie wyjściowe ma tylko \(n) kanałów."
            : "Output device only has \(n) channels."
    }
    var speakerConfirm: String {
        pl ? "Kanały 1–2 to głośniki — zakodowany AC-3 to hałas o pełnej skali. Naciśnij start ponownie, aby potwierdzić."
            : "Channels 1–2 feed your speakers — encoded AC-3 there is full-scale noise. Press start again to confirm."
    }
    func couldNotStart(_ e: String) -> String { pl ? "Nie można uruchomić:\n\(e)" : "Could not start:\n\(e)" }
    var ffmpegExited: String { pl ? "ffmpeg zakończył działanie" : "ffmpeg exited" }
    var stoppedDeviceChanged: String {
        pl ? "Zatrzymano: zmieniono urządzenie audio (przepięcie lub zmiana częstotliwości)"
            : "Stopped: audio device changed (replug or sample-rate flip)"
    }
    var deviceChangedHelp: String {
        pl ? "Urządzenie audio uległo zmianie — mostek zatrzymany dla ochrony wyjść. Odśwież, sprawdź kanały i wystartuj ponownie."
            : "Audio device changed — bridge stopped to protect the outputs. Hit Refresh, verify channels, Start again."
    }
}
