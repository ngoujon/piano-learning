import Foundation

/// Utilities for converting MIDI note numbers to names and frequencies.
public enum NoteName {
    public static let frenchNames = ["Do", "Do♯", "Ré", "Ré♯", "Mi", "Fa", "Fa♯", "Sol", "Sol♯", "La", "La♯", "Si"]
    public static let englishNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    /// Piano range (A0...C8).
    public static let pianoRange: ClosedRange<Int> = 21...108

    /// French note name with octave, using the convention where middle C (MIDI 60) is "Do4".
    public static func french(_ midi: Int, withOctave: Bool = true) -> String {
        let name = frenchNames[((midi % 12) + 12) % 12]
        return withOctave ? "\(name)\(midi / 12 - 1)" : name
    }

    public static func english(_ midi: Int, withOctave: Bool = true) -> String {
        let name = englishNames[((midi % 12) + 12) % 12]
        return withOctave ? "\(name)\(midi / 12 - 1)" : name
    }

    public static func frequency(_ midi: Double) -> Double {
        440.0 * pow(2.0, (midi - 69.0) / 12.0)
    }

    public static func frequency(_ midi: Int) -> Double {
        frequency(Double(midi))
    }

    /// Fractional MIDI note number for a frequency in Hz.
    public static func midi(forFrequency f: Double) -> Double {
        69.0 + 12.0 * log2(f / 440.0)
    }

    public static func isBlackKey(_ midi: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(((midi % 12) + 12) % 12)
    }
}
