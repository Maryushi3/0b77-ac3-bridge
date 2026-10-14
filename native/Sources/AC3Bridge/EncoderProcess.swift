import Foundation

/// ffmpeg sidecar: bundled Contents/MacOS/ffmpeg first, then PATH / Homebrew.
enum FFmpegLocator {
    static func find() -> String? {
        // 1. Bundled next to our executable (AC3Bridge.app/Contents/MacOS/ffmpeg)
        let bundled = Bundle.main.bundlePath + "/Contents/MacOS/ffmpeg"
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        // Also handle swift-build dev layout (native/.build/.../ffmpeg copied by bundle.sh)
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let p = dir + "/ffmpeg"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        // 2. PATH lookup
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["ffmpeg"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let out, !out.isEmpty { return out }
            }
        } catch { /* fall through */ }
        return nil
    }
}

/// Owns the `ffmpeg … -f spdif pipe:1` child: raw 6ch in on stdin, IEC61937 out on stdout.
final class EncoderProcess: @unchecked Sendable {
    let bitrate: Int
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var _stderrLast = ""

    var stderrLast: String {
        lock.lock(); defer { lock.unlock() }
        return _stderrLast
    }

    init(bitrate: Int) {
        self.bitrate = bitrate
    }

    func start() throws {
        guard let ff = FFmpegLocator.find() else {
            throw NSError(domain: "AC3Bridge", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                              "ffmpeg not found. Install via: brew install ffmpeg"])
        }
        process.executableURL = URL(fileURLWithPath: ff)
        process.arguments = ["-hide_banner", "-loglevel", "error",
                             "-f", "s16le", "-ar", "48000", "-ac", "6", "-i", "pipe:0",
                             "-c:a", "ac3", "-b:a", "\(bitrate)k", "-ar", "48000",
                             "-flush_packets", "1", "-f", "spdif", "pipe:1"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Drain stderr on a background thread so the child never blocks.
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let self else { return }
            if let line = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty
            {
                self.lock.lock()
                self._stderrLast = line
                self.lock.unlock()
            }
        }
        try process.run()
    }

    var isAlive: Bool { process.isRunning }

    var stdinHandle: FileHandle { stdinPipe.fileHandleForWriting }
    var stdoutHandle: FileHandle { stdoutPipe.fileHandleForReading }

    func stop() {
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinHandle.close()
        if process.isRunning {
            process.terminate()
            // Give it a beat, then escalate like the Python version did.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                if self?.process.isRunning == true {
                    self?.process.interrupt()
                }
            }
        }
    }
}
