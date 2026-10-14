import AppKit
import SwiftUI

/// The Preferences window: how new notes behave, and the global "new note" shortcut. Deliberately
/// small and consistent with the app's other floating panels (Lists, MCP).
struct SettingsView: View {
    private var model: AppModel { AppModel.shared }
    private var prefs: NotePreferences { model.preferences }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            newNoteSection
            Divider()
            hotkeySection

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Done") { model.dismissSettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 380, alignment: .topLeading)
        .background(NoteBackground(color: .graphite, material: .glass))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Preferences")
                .font(.title2.weight(.semibold))
            Text(Environment.current.isDevelopment ? "Development build — data in TicDev" : "Tic")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var newNoteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New notes")
                .font(.headline)

            Toggle("Keep new notes on top of other windows", isOn: Binding(
                get: { prefs.defaultFloatOnTop },
                set: { prefs.defaultFloatOnTop = $0; model.applyNewNoteDefaults() }
            ))
            Toggle("Show new notes on every Space", isOn: Binding(
                get: { prefs.defaultShowOnAllSpaces },
                set: { prefs.defaultShowOnAllSpaces = $0; model.applyNewNoteDefaults() }
            ))

            Text("Applies to notes you create from now on. Existing notes keep their own settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.switch)
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Global shortcut")
                .font(.headline)

            HStack(spacing: 12) {
                HotkeyRecorderField(shortcut: Binding(
                    get: { prefs.hotkey },
                    set: { prefs.hotkey = $0; model.applyGlobalHotkey() }
                ))
                .frame(width: 160, height: 30)

                Button("Reset") {
                    prefs.hotkey = .default
                    model.applyGlobalHotkey()
                }
                .controlSize(.small)

                Spacer()

                Toggle("Enabled", isOn: Binding(
                    get: { prefs.hotkey != nil },
                    set: { on in
                        prefs.hotkey = on ? .default : nil
                        model.applyGlobalHotkey()
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            statusLine
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.hotkeyStatus {
        case .registered:
            Label("Shortcut is active in every app.", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .conflict:
            Label("That shortcut is already taken by another app. Choose a different one.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        case .invalid:
            Label("Shortcut off. Turn it on and press a key combination with ⌘, ⌥, or ⌃.",
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .failed:
            Label("Couldn't register the shortcut.", systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }
}

/// A click-to-record control for a single global shortcut. Clicking arms it; the next chord with a
/// supported modifier is captured. Esc cancels, Delete clears.
private struct HotkeyRecorderField: View {
    @Binding var shortcut: HotkeyShortcut?

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording.toggle()
            recording ? startMonitoring() : stopMonitoring()
        } label: {
            HStack {
                Image(systemName: "keyboard")
                    .foregroundStyle(.secondary)
                Text(recording ? "Press keys…" : (shortcut?.displayString ?? "Off"))
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(recording ? 0.10 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: recording ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .onDisappear { stopMonitoring() }
    }

    private func startMonitoring() {
        stopMonitoring()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { recording = false; stopMonitoring() }
            if event.keyCode == 53 { return nil }                       // Esc → cancel
            if event.keyCode == 51 || event.keyCode == 117 {            // Delete → clear
                shortcut = nil
                return nil
            }
            if let captured = HotkeyShortcut(event: event) {
                shortcut = captured
            }
            return nil
        }
    }

    private func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
