import CoreMIDI
import Foundation

/// Optional USB/Bluetooth MIDI keyboard input: exact note detection when a digital piano is plugged in.
@MainActor
final class MIDIInputService: ObservableObject {
    static let shared = MIDIInputService()

    @Published private(set) var sources: [String] = []
    @Published private(set) var heldKeys: Set<Int> = []

    /// (pitch, isNoteOn)
    var onNote: ((Int, Bool) -> Void)?

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
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name) == noErr, let n = name?.takeRetainedValue() {
                names.append(n as String)
            }
        }
        sources = names
    }

    private func handle(_ notes: [(Int, Bool)]) {
        for (pitch, on) in notes {
            if on { heldKeys.insert(pitch) } else { heldKeys.remove(pitch) }
            onNote?(pitch, on)
        }
    }

    // Blocks are built outside the main actor: CoreMIDI calls them on its own thread.
    nonisolated private static func makeNotifyBlock(_ changed: @escaping @Sendable () -> Void) -> MIDINotifyBlock {
        return { _ in changed() }
    }

    nonisolated private static func makeReceiveBlock(_ handler: @escaping @Sendable ([(Int, Bool)]) -> Void) -> MIDIReceiveBlock {
        return { eventList, _ in
            let notes = decode(eventList)
            if !notes.isEmpty { handler(notes) }
        }
    }

    nonisolated private static func decode(_ list: UnsafePointer<MIDIEventList>) -> [(Int, Bool)] {
        var result: [(Int, Bool)] = []
        withUnsafePointer(to: list.pointee.packet) { first in
            var packet = first
            for _ in 0..<list.pointee.numPackets {
                let words = Mirror(reflecting: packet.pointee.words).children.compactMap { $0.value as? UInt32 }
                for w in words.prefix(Int(packet.pointee.wordCount)) {
                    // MIDI 1.0 channel voice message in a Universal MIDI Packet (type 2).
                    guard w >> 28 == 0x2 else { continue }
                    let status = (w >> 16) & 0xF0
                    let note = Int((w >> 8) & 0x7F)
                    let velocity = w & 0x7F
                    if status == 0x90 && velocity > 0 { result.append((note, true)) }
                    else if status == 0x80 || (status == 0x90 && velocity == 0) { result.append((note, false)) }
                }
                packet = UnsafePointer(MIDIEventPacketNext(packet))
            }
        }
        return result
    }
}
