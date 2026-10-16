import CoreAudio
import Foundation

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let inputChannels: Int
    let outputChannels: Int

    var idValue: UInt32 { id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

enum DeviceManager {
    static func allDevices() -> [AudioDeviceInfo] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { describe($0) }
    }

    static func inputCandidates() -> [AudioDeviceInfo] {
        allDevices().filter { $0.inputChannels >= 6 }
    }

    static func outputCandidates() -> [AudioDeviceInfo] {
        allDevices().filter { $0.outputChannels >= 2 }
    }

    // MARK: - private

    private static func describe(_ id: AudioDeviceID) -> AudioDeviceInfo? {
        guard let name = stringProperty(id, selector: kAudioDevicePropertyDeviceNameCFString)
            ?? stringProperty(id, selector: kAudioObjectPropertyName)
        else { return nil }
        let ins = channelCount(id, scope: kAudioDevicePropertyScopeInput)
        let outs = channelCount(id, scope: kAudioDevicePropertyScopeOutput)
        return AudioDeviceInfo(id: id, name: name, inputChannels: ins, outputChannels: outs)
    }

    private static func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfStr: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return cfStr as String
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 1)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return 0 }
        let abl = buf.bindMemory(to: AudioBufferList.self, capacity: 1).pointee
        return withUnsafePointer(to: abl) { ptr in
            let list = UnsafeRawPointer(ptr).assumingMemoryBound(to: AudioBufferList.self)
            var total = 0
            for i in 0..<Int(list.pointee.mNumberBuffers) {
                let b = UnsafeRawPointer(list)
                    .advanced(by: MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!)
                    .assumingMemoryBound(to: AudioBuffer.self)
                    .advanced(by: i).pointee
                total += Int(b.mNumberChannels)
            }
            return total
        }
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    /// System default output (what the user hears outside the bridge).
    static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
            id != 0
        else { return nil }
        return id
    }

    static func setDefaultOutputDevice(_ id: AudioDeviceID) throws {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var v = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &v)
        guard status == noErr else {
            throw NSError(domain: "0B77", code: 20,
                          userInfo: [NSLocalizedDescriptionKey:
                              "Could not switch system output (OSStatus \(status))"])
        }
    }
}
