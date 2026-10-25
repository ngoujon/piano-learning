import SwiftUI

/// Switches between listening with the microphone and reading the keys of a USB keyboard (⌘U).
struct InputModePicker: View {
    @ObservedObject private var midi = MIDIInputService.shared

    var body: some View {
        HStack(spacing: 6) {
            Picker("Détection", selection: Binding(get: { midi.mode }, set: { midi.mode = $0 })) {
                ForEach(MIDIInputService.InputMode.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Détection des notes : au micro (son du piano) ou par le câble USB (touches du clavier). Raccourci ⌘U.")
            if midi.usesKeyboard && !midi.isKeyboardConnected {
                Label("Aucun clavier USB", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
                    .help("Branchez le piano en USB et allumez-le, ou passez en mode Micro.")
            }
            Button("Changer de détection") { midi.toggleMode() }
                .keyboardShortcut("u", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }
}
