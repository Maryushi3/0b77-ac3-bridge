import CZeroB77
import Foundation

/// In-process AC-3/SPDIF encoder (static libavcodec + spdif muxer).
/// Same bytes as the old ffmpeg-child pipeline (proven by the golden test).
final class StaticEncoder: @unchecked Sendable {
    static let pcmBytes = Int(ZB77_PCM_BYTES)     // 18432
    static let spdifBytes = Int(ZB77_SPDIF_BYTES) // 6144

    private var handle: OpaquePointer?
    private let lock = NSLock()

    init(bitrate: Int) throws {
        var err = [CChar](repeating: 0, count: 256)
        guard let h = zb77_open(Int32(bitrate), &err, err.count) else {
            throw NSError(domain: "0B77", code: 10,
                          userInfo: [NSLocalizedDescriptionKey:
                              "Static encoder failed: \(String(cString: err))"])
        }
        handle = h
    }

    /// Feed exactly one input unit. Returns a complete IEC frame, or nil while
    /// the encoder is still warming up on the first unit.
    func encode(_ pcm: Data) throws -> Data? {
        precondition(pcm.count == Self.pcmBytes)
        return try locked { h in
            var out = [UInt8](repeating: 0, count: Self.spdifBytes)
            let r = pcm.withUnsafeBytes { p -> Int32 in
                let pcmPtr = p.bindMemory(to: Int16.self).baseAddress!
                return out.withUnsafeMutableBufferPointer { o in
                    zb77_encode(h, pcmPtr, o.baseAddress!)
                }
            }
            if r == Int32(Self.spdifBytes) { return Data(out) }
            if r == 0 { return nil }
            throw NSError(domain: "0B77", code: 11,
                          userInfo: [NSLocalizedDescriptionKey:
                              "Static encoder error: \(r)"])
        }
    }

    func close() {
        locked { h in
            zb77_close(h)
            handle = nil
        }
    }

    private func locked<T>(_ f: (OpaquePointer) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        guard let handle else {
            fatalError("StaticEncoder used after close")
        }
        return try f(handle)
    }
}
