import CoreMIDI
import Foundation

/// Optional USB/Bluetooth MIDI keyboard input: exact note detection when a digital piano is plugged in.
@MainActor
final class MIDIInputService: ObservableObject {
    static let shared = MIDIInputService()

    /// Connected keyboards (USB or Bluetooth), by name. Virtual ports (IAC, network sessions) are not listed.
    @Published private(set) var sources: [String] = []
    @Published private(set) var heldKeys: Set<Int> = []

    /// A keyboard sends exact notes: the microphone is then not used to check what was played.
    var isKeyboardConnected: Bool { !sources.isEmpty }

    /// (pitch, isNoteOn)
    var onNote: ((Int, Bool) -> Void)?

    private let debugLog = ProcessInfo.processInfo.environment["PIANO_DEBUG"] != nil
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()

    private init() {
        let notify = Self.makeNotifyBlock { [weak self] in
            Task { @MainActor in self?.connectAll() }
        }
        guard MIDIClientCreateWithBlock("PianoLearning" as CFString, &client, notify) == noErr else { return }
        let receive = Self.makeReceiveBlock { [weak self] notes in
            Task { @MainActor in self?.handle(notes) }
        }
        MIDIInputPortCreateWithProtocol(client, "Input" as CFString, ._1_0, &port, receive)
        connectAll()
    }

    private func connectAll() {
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            MIDIPortConnectSource(port, src, nil)
            guard !Self.isVirtual(src) else { continue }
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name) == noErr, let n = name?.takeRetainedValue() {
                names.append(n as String)
            }
        }
        sources = names
    }

    /// Sources created by software (IAC bus, network session, other apps) rather than a plugged-in keyboard.
    private static func isVirtual(_ src: MIDIEndpointRef) -> Bool {
        var offline: Int32 = 0
        if MIDIObjectGetIntegerProperty(src, kMIDIPropertyOffline, &offline) == noErr, offline != 0 { return true }
        var entity = MIDIEntityRef()
        var device = MIDIDeviceRef()
        guard MIDIEndpointGetEntity(src, &entity) == noErr, MIDIEntityGetDevice(entity, &device) == noErr else { return true }
        var driver: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(device, kMIDIPropertyDriverOwner, &driver) == noErr,
              let owner = driver?.takeRetainedValue() as String? else { return false }
        return owner.contains("IAC") || owner.contains("RTP") || owner.contains("NetworkMIDI")
    }

    /// Plays what the keyboard sends on the Mac's speakers (the USB cable carries notes, not sound).
    private var playsThroughMac: Bool {
        UserDefaults.standard.object(forKey: "midiPlayback") as? Bool ?? true
    }

    private func handle(_ events: [Event]) {
        let sound = SoundEngine.shared
        for event in events {
            switch event {
            case .note(let pitch, let velocity):
                let on = velocity > 0
                if debugLog { FileHandle.standardError.write("midi note=\(pitch) velocity=\(velocity)\n".data(using: .utf8)!) }
                if on { heldKeys.insert(pitch) } else { heldKeys.remove(pitch) }
                if playsThroughMac {
                    if on { sound.keyboardNoteOn(pitch, velocity: velocity) } else { sound.keyboardNoteOff(pitch) }
                }
                onNote?(pitch, on)
            case .sustain(let value):
                if playsThroughMac { sound.keyboardSustain(value) }
            }
        }
    }

    /// Note on/off (velocity 0 = released) or sustain pedal position.
    enum Event: Sendable {
        case note(Int, velocity: Int)
        case sustain(Int)
    }

    // Blocks are built outside the main actor: CoreMIDI calls them on its own thread.
    nonisolated private static func makeNotifyBlock(_ changed: @escaping @Sendable () -> Void) -> MIDINotifyBlock {
        return { _ in changed() }
    }

    nonisolated private static func makeReceiveBlock(_ handler: @escaping @Sendable ([Event]) -> Void) -> MIDIReceiveBlock {
        return { eventList, _ in
            let events = decode(eventList)
            if !events.isEmpty { handler(events) }
        }
    }

    nonisolated private static func decode(_ list: UnsafePointer<MIDIEventList>) -> [Event] {
        var result: [Event] = []
        withUnsafePointer(to: list.pointee.packet) { first in
            var packet = first
            for _ in 0..<list.pointee.numPackets {
                let words = Mirror(reflecting: packet.pointee.words).children.compactMap { $0.value as? UInt32 }
                for w in words.prefix(Int(packet.pointee.wordCount)) {
                    // MIDI 1.0 channel voice message in a Universal MIDI Packet (type 2).
                    guard w >> 28 == 0x2 else { continue }
                    let status = (w >> 16) & 0xF0
                    let data1 = Int((w >> 8) & 0x7F)
                    let data2 = Int(w & 0x7F)
                    if status == 0x90 { result.append(.note(data1, velocity: data2)) }
                    else if status == 0x80 { result.append(.note(data1, velocity: 0)) }
                    else if status == 0xB0 && data1 == 64 { result.append(.sustain(data2)) }
                }
                packet = UnsafePointer(MIDIEventPacketNext(packet))
            }
        }
        return result
    }
}
