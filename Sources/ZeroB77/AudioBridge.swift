import CoreAudio
import Foundation

/// Full-duplex bridge: 6ch in (virtual device) -> ffmpeg AC-3/SPDIF -> stereo pair out.
/// Mirrors the Python prototype's buffering: prefill frames before starting,
/// drop whole frames past prefill+3, count drops/underruns.
final class AudioBridge: @unchecked Sendable {
    static let sampleRate = 48000.0
    /// One AC-3 frame in IEC 61937 = 1536 stereo s16 samples.
    static let frameBytes = 1536 * 4

    let inDevice: AudioDeviceID
    let outDevice: AudioDeviceID
    /// 1-based first output channel (uses it and the next).
    let firstChannel: Int
    let bitrate: Int
    var prefill: Int { didSet { prefill = max(1, min(8, prefill)) } }

    var maxBuf: Int { prefill + 3 }

    private let lock = NSLock()
    private var _buf: [Data] = []          // complete IEC frames from ffmpeg
    private var _cur: Data?                // frame currently being consumed
    private var _pos = 0
    private var _playing = false
    private var _drops = 0
    private var _underruns = 0
    private var _inPeak: Float = 0 // max |sample| on input since last stats read

    private let inCond = NSCondition()
    private var _inQueue: [Data] = []      // raw 6ch s16le chunks for ffmpeg stdin

    private var _running = false
    private var encoder: EncoderProcess?
    private var staticEnc: StaticEncoder?
    private var staticMode = false
    private var pending = Data() // sub-unit input remainder (static path)
    /// "static" or "subprocess" once started — shown in the run summary.
    private(set) var engineName = "?"
    private var inProcID: AudioDeviceIOProcID?
    private var outProcID: AudioDeviceIOProcID?
    private var inFormat = AudioStreamBasicDescription()
    private var outFormat = AudioStreamBasicDescription()
    private var outChannels = 2
    private var warnedFormat = false

    struct Stats {
        let fill: Int
        let maxBuf: Int
        let drops: Int
        let underruns: Int
        let playing: Bool
        /// 0…1 input peak over the last window (stuck at 0 = silence — check mic permission).
        let inPeak: Float
    }

    var stats: Stats {
        lock.lock()
        let s = Stats(fill: _buf.count, maxBuf: maxBuf, drops: _drops,
                      underruns: _underruns, playing: _playing, inPeak: _inPeak)
        _inPeak = 0
        lock.unlock()
        return s
    }

    var isAlive: Bool {
        lock.lock(); let r = _running; lock.unlock()
        guard r else { return false }
        if staticMode { return staticEnc != nil }
        guard let e = encoder else { return false }
        return e.isAlive
    }

    var lastEncoderError: String { encoder?.stderrLast ?? "" }

    init(inDevice: AudioDeviceID, outDevice: AudioDeviceID,
         firstChannel: Int, bitrate: Int, prefill: Int) {
        self.inDevice = inDevice
        self.outDevice = outDevice
        self.firstChannel = firstChannel
        self.bitrate = bitrate
        self.prefill = max(1, min(8, prefill))
    }

    // MARK: - control

    func start() throws {
        // Engine choice: static in-process encode by default (no pipes, no
        // child); subprocess fallback on failure or ZB77_SUBPROCESS=1.
        let forceSubprocess = ProcessInfo.processInfo.environment["ZB77_SUBPROCESS"] != nil
        if !forceSubprocess, let se = try? StaticEncoder(bitrate: bitrate) {
            staticEnc = se
            staticMode = true
            engineName = "static"
        } else {
            if !forceSubprocess {
                NSLog("0B77: static encoder unavailable, falling back to ffmpeg child")
            }
            let enc = EncoderProcess(bitrate: bitrate)
            try enc.start()
            encoder = enc
            staticMode = false
            engineName = "subprocess"
        }
        lock.lock()
        _running = true
        _buf.removeAll(); _cur = nil; _pos = 0; _playing = false
        _drops = 0; _underruns = 0; _inPeak = 0
        lock.unlock()
        inCond.lock(); _inQueue.removeAll(); inCond.unlock()
        pending.removeAll()

        inFormat = Self.streamFormat(of: inDevice, scope: kAudioDevicePropertyScopeInput)
        outFormat = Self.streamFormat(of: outDevice, scope: kAudioDevicePropertyScopeOutput)
        outChannels = max(2, Int(outFormat.mChannelsPerFrame))

        // Warn when devices aren't at 48 kHz (user fixes in Audio MIDI Setup, same as before).
        let inRate = DeviceManager.nominalSampleRate(inDevice)
        let outRate = DeviceManager.nominalSampleRate(outDevice)
        if inRate != 0, abs(inRate - Self.sampleRate) > 1 {
            NSLog("0B77: input device at %.0f Hz, want 48000 (set in Audio MIDI Setup)", inRate)
        }
        if outRate != 0, abs(outRate - Self.sampleRate) > 1 {
            NSLog("0B77: output device at %.0f Hz, want 48000 (set in Audio MIDI Setup)", outRate)
        }

        // Pump threads (static path encodes inline; subprocess path pipes).
        if staticMode {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.staticWriterLoop() }
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.writerLoop() }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.readerLoop() }
        }

        // Input proc: convert device frames -> interleaved 6ch s16le -> queue for ffmpeg.
        // NOTE: outIOProcID comes first in this API.
        var inID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(
            &inID, inDevice, DispatchQueue.global(qos: .userInitiated),
            { [weak self] _, inData, _, _, _ in
                self?.handleInput(inData)
            })
        guard status == noErr, let inID else {
            stop()
            throw NSError(domain: "0B77", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not attach to input device (OSStatus \(status))"])
        }
        inProcID = inID

        // Output proc: consume IEC frames -> device channels.
        var outID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(
            &outID, outDevice, DispatchQueue.global(qos: .userInitiated),
            { [weak self] _, _, _, outData, _ in
                self?.handleOutput(outData)
            })
        guard status == noErr, let outID else {
            stop()
            throw NSError(domain: "0B77", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not attach to output device (OSStatus \(status))"])
        }
        outProcID = outID

        status = AudioDeviceStart(inDevice, inProcID)
        guard status == noErr else {
            stop()
            throw NSError(domain: "0B77", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Could not start input device (OSStatus \(status))"])
        }
        status = AudioDeviceStart(outDevice, outProcID)
        if status != noErr {
            stop()
            throw NSError(domain: "0B77", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Could not start output device (OSStatus \(status)). Is the sample rate 48 kHz?"])
        }
    }

    func stop() {
        lock.lock(); _running = false; lock.unlock()
        inCond.lock(); inCond.broadcast(); inCond.unlock()
        if let inProcID {
            AudioDeviceStop(inDevice, inProcID)
            AudioDeviceDestroyIOProcID(inDevice, inProcID)
            self.inProcID = nil
        }
        if let outProcID {
            AudioDeviceStop(outDevice, outProcID)
            AudioDeviceDestroyIOProcID(outDevice, outProcID)
            self.outProcID = nil
        }
        encoder?.stop()
        encoder = nil
        staticEnc?.close()
        staticEnc = nil
    }

    // MARK: - pump threads (mirror _writer / _reader in ac3bridge.py)

    private func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _running
    }

    private func writerLoop() {
        while isRunning() {
            inCond.lock()
            while _inQueue.isEmpty, isRunningUnsafeForCond() {
                inCond.wait(until: Date(timeIntervalSinceNow: 0.2))
            }
            let data: Data? = _inQueue.isEmpty ? nil : _inQueue.removeFirst()
            inCond.unlock()
            guard let data, let stdinHandle = encoder?.stdinHandle else { continue }
            do { try stdinHandle.write(contentsOf: data) } catch { break }
        }
    }

    /// Static path: slice input into 1536-frame units, encode inline, queue
    /// complete IEC frames. No pipes, no reader thread.
    private func staticWriterLoop() {
        while isRunning() {
            inCond.lock()
            while _inQueue.isEmpty, isRunningUnsafeForCond() {
                inCond.wait(until: Date(timeIntervalSinceNow: 0.2))
            }
            let data: Data? = _inQueue.isEmpty ? nil : _inQueue.removeFirst()
            inCond.unlock()
            guard let data, let se = staticEnc else { continue }
            pending.append(data)
            while pending.count >= StaticEncoder.pcmBytes {
                let unit = pending.prefix(StaticEncoder.pcmBytes)
                pending.removeFirst(StaticEncoder.pcmBytes)
                do {
                    if let frame = try se.encode(Data(unit)) {
                        lock.lock()
                        _buf.append(frame)
                        while _buf.count > maxBuf {
                            _buf.removeFirst()
                            _drops += 1
                        }
                        lock.unlock()
                    }
                } catch {
                    NSLog("0B77: static encode failed: %@", error.localizedDescription as NSString)
                    return
                }
            }
        }
    }

    /// Called with inCond already locked.
    private func isRunningUnsafeForCond() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _running
    }

    private func readerLoop() {
        while isRunning() {
            guard let stdoutHandle = encoder?.stdoutHandle else { break }
            let data = stdoutHandle.readData(ofLength: Self.frameBytes)
            if data.count < Self.frameBytes { break }  // ffmpeg exited
            lock.lock()
            _buf.append(data)
            while _buf.count > maxBuf {
                _buf.removeFirst()
                _drops += 1
            }
            lock.unlock()
        }
    }

    // MARK: - IOProcs

    private func handleInput(_ ablPtr: UnsafePointer<AudioBufferList>) {
        let s16 = convertInputToS16LE(ablPtr)
        guard !s16.isEmpty else { return }
        // Input peak meter (also doubles as a capture-health signal).
        var peak: Float = 0
        s16.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            let s = p.bindMemory(to: Int16.self)
            for i in 0..<s.count {
                let a = abs(Float(Int(s[i]))) / 32768.0
                if a > peak { peak = a }
            }
        }
        lock.lock()
        if peak > _inPeak { _inPeak = peak }
        lock.unlock()
        inCond.lock()
        _inQueue.append(s16)
        if _inQueue.count > 200 { _inQueue.removeFirst() }  // ffmpeg stalled
        inCond.signal()
        inCond.unlock()
    }

    private func handleOutput(_ ablPtr: UnsafeMutablePointer<AudioBufferList>) {
        // How many output frames? Derive from first buffer.
        let list = UnsafeMutableRawPointer(ablPtr).assumingMemoryBound(to: AudioBufferList.self)
        let nBufs = Int(list.pointee.mNumberBuffers)
        guard nBufs > 0 else { return }
        let bufs = UnsafeMutableRawPointer(ablPtr)
            .advanced(by: MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!)
            .assumingMemoryBound(to: AudioBuffer.self)

        let fmt = outFormat
        let bytesPerSample = max(1, Int(fmt.mBitsPerChannel) / 8)
        let firstSize = Int(bufs[0].mDataByteSize)
        let frames: Int
        if fmt.mFormatFlags & kLinearPCMFormatFlagIsNonInterleaved != 0 {
            frames = firstSize / bytesPerSample
        } else {
            let chans = max(1, Int(fmt.mChannelsPerFrame))
            frames = firstSize / (bytesPerSample * chans)
        }
        guard frames > 0 else { return }

        // Pull `frames` stereo s16 samples from the frame queue (zero-fill on underrun).
        let need = frames * 4
        var out = Data()
        out.reserveCapacity(need)
        lock.lock()
        if !_playing, _buf.count >= prefill { _playing = true }
        while _playing, out.count < need {
            if _cur == nil || _pos >= (_cur?.count ?? 0) {
                if !_buf.isEmpty {
                    _cur = _buf.removeFirst(); _pos = 0
                } else {
                    _playing = false; _cur = nil; _underruns += 1
                    break
                }
            }
            if let cur = _cur {
                let n = min(need - out.count, cur.count - _pos)
                out.append(cur[_pos..<_pos + n])
                _pos += n
            }
        }
        lock.unlock()
        if out.count < need { out.append(Data(count: need - out.count)) }

        writeStereoS16ToDevice(out, frames: frames, bufs: bufs, nBufs: nBufs, format: fmt)
    }

    // MARK: - format helpers

    private static func streamFormat(of device: AudioDeviceID,
                                     scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &fmt)
        if status != noErr {
            // Sane default: 48 kHz float32 non-interleaved stereo.
            fmt = AudioStreamBasicDescription(
                mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked
                    | kLinearPCMFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        }
        return fmt
    }

    /// Device frames -> interleaved 6ch s16le for ffmpeg stdin.
    private func convertInputToS16LE(_ ablPtr: UnsafePointer<AudioBufferList>) -> Data {
        let fmt = inFormat
        let isFloat = fmt.mFormatFlags & kLinearPCMFormatFlagIsFloat != 0
            || fmt.mFormatID == kAudioFormatLinearPCM && fmt.mBitsPerChannel == 32
            && fmt.mFormatFlags & kLinearPCMFormatFlagIsSignedInteger == 0
        let isNonInterleaved = fmt.mFormatFlags & kLinearPCMFormatFlagIsNonInterleaved != 0
        let list = UnsafeRawPointer(ablPtr).assumingMemoryBound(to: AudioBufferList.self)
        let nBufs = Int(list.pointee.mNumberBuffers)
        let bufs = UnsafeRawPointer(ablPtr)
            .advanced(by: MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!)
            .assumingMemoryBound(to: AudioBuffer.self)
        guard nBufs > 0, let firstData = bufs[0].mData else { return Data() }
        let bytesPerSample = max(1, Int(fmt.mBitsPerChannel) / 8)
        let frames: Int
        if isNonInterleaved {
            frames = Int(bufs[0].mDataByteSize) / bytesPerSample
        } else {
            let chans = max(1, Int(fmt.mChannelsPerFrame))
            frames = Int(bufs[0].mDataByteSize) / (bytesPerSample * chans)
        }
        guard frames > 0 else { return Data() }

        var out = Data(count: frames * 6 * 2)
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            let s = dst.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<frames {
                for ch in 0..<6 {
                    var v: Int16 = 0
                    if isNonInterleaved {
                        if ch < nBufs, let d = bufs[ch].mData {
                            v = sampleAsS16(from: d, frame: i, bytesPerSample: bytesPerSample, isFloat: isFloat)
                        }
                    } else {
                        let chans = max(6, Int(fmt.mChannelsPerFrame))
                        v = sampleAsS16(from: firstData, frame: i * chans + ch,
                                        bytesPerSample: bytesPerSample, isFloat: isFloat)
                    }
                    s[i * 6 + ch] = v.littleEndian
                }
            }
        }
        return out
    }

    private func sampleAsS16(from base: UnsafeMutableRawPointer, frame: Int,
                             bytesPerSample: Int, isFloat: Bool) -> Int16 {
        let p = base.advanced(by: frame * bytesPerSample)
        if isFloat, bytesPerSample == 4 {
            let f = p.load(as: Float.self)
            return Int16(max(-1, min(1, f)) * 32767)
        } else if bytesPerSample == 2 {
            return Int16(littleEndian: p.load(as: Int16.self))
        } else if bytesPerSample == 4 {
            return Int16((Int32(littleEndian: p.load(as: Int32.self))) >> 16)
        }
        return 0
    }

    /// Stereo s16 IEC frames -> device buffers; target channels col/col+1, rest silence.
    private func writeStereoS16ToDevice(_ stereo: Data, frames: Int,
                                       bufs: UnsafeMutablePointer<AudioBuffer>,
                                       nBufs: Int, format fmt: AudioStreamBasicDescription) {
        let col = max(0, firstChannel - 1)
        let isFloat = fmt.mFormatFlags & kLinearPCMFormatFlagIsFloat != 0
            || (fmt.mBitsPerChannel == 32 && fmt.mFormatFlags & kLinearPCMFormatFlagIsSignedInteger == 0)
        let isNonInterleaved = fmt.mFormatFlags & kLinearPCMFormatFlagIsNonInterleaved != 0
        let bytesPerSample = max(1, Int(fmt.mBitsPerChannel) / 8)

        stereo.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            let s = src.bindMemory(to: Int16.self).baseAddress!
            if isNonInterleaved {
                // One buffer per channel (typical HAL float32). Silence all, then fill col/col+1.
                for b in 0..<nBufs {
                    guard let d = bufs[b].mData else { continue }
                    memset(d, 0, Int(bufs[b].mDataByteSize))
                }
                for i in 0..<frames {
                    let l = Int16(littleEndian: s[i * 2])
                    let r = Int16(littleEndian: s[i * 2 + 1])
                    if col < nBufs, let d = bufs[col].mData {
                        writeS16AsDeviceSample(l, to: d, frame: i,
                                               bytesPerSample: bytesPerSample, isFloat: isFloat)
                    }
                    if col + 1 < nBufs, let d = bufs[col + 1].mData {
                        writeS16AsDeviceSample(r, to: d, frame: i,
                                               bytesPerSample: bytesPerSample, isFloat: isFloat)
                    }
                }
            } else {
                // Interleaved: Nch frame, zero all, place pair at col/col+1.
                let chans = max(2, Int(fmt.mChannelsPerFrame))
                guard let d = bufs[0].mData else { return }
                memset(d, 0, Int(bufs[0].mDataByteSize))
                for i in 0..<frames {
                    let l = Int16(littleEndian: s[i * 2])
                    let r = Int16(littleEndian: s[i * 2 + 1])
                    writeS16AsDeviceSample(l, to: d, frame: i * chans + col,
                                           bytesPerSample: bytesPerSample, isFloat: isFloat)
                    if col + 1 < chans {
                        writeS16AsDeviceSample(r, to: d, frame: i * chans + col + 1,
                                               bytesPerSample: bytesPerSample, isFloat: isFloat)
                    }
                }
            }
        }
        if !warnedFormat, !isFloat, bytesPerSample != 2 {
            warnedFormat = true
            NSLog("0B77: output format %u-bit (float=%d); bit-exact SPDIF wants s16 — check Audio MIDI Setup",
                  fmt.mBitsPerChannel, isFloat)
        }
    }

    private func writeS16AsDeviceSample(_ v: Int16, to base: UnsafeMutableRawPointer,
                                        frame: Int, bytesPerSample: Int, isFloat: Bool) {
        let p = base.advanced(by: frame * bytesPerSample)
        if isFloat, bytesPerSample == 4 {
            p.storeBytes(of: Float(v) / 32768.0, as: Float.self)
        } else if bytesPerSample == 2 {
            p.storeBytes(of: v.littleEndian, as: Int16.self)
        } else if bytesPerSample == 4 {
            p.storeBytes(of: (Int32(v) << 16).littleEndian, as: Int32.self)
        }
    }
}
