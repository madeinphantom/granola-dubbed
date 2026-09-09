import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            TranscriptionSettingsView()
                .tabItem { Label("Transcription", systemImage: "waveform") }
            StorageSettingsView()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 480, height: 320)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                Toggle("Ask before deleting a recording", isOn: $prefs.confirmBeforeDelete)
            } footer: {
                Text("Deleting removes the audio and transcript from disk permanently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hide Dock icon (menu bar only)", isOn: $prefs.menuBarOnly)
            } footer: {
                Text("Takes effect after you quit and reopen Atrium.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Transcription

struct TranscriptionSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $prefs.whisperModelRaw) {
                    ForEach(WhisperModel.allCases) { model in
                        Text(model.displayName).tag(model.rawValue)
                    }
                }
                LabeledContent("Download size", value: prefs.whisperModel.approximateDownloadSize)
            } header: {
                Text("Speech recognition")
            } footer: {
                Text("Larger models are more accurate but slower. The model downloads once, on first use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Slider(value: $prefs.speakerSensitivity, in: 0.001...0.1) {
                        Text("Speaker sensitivity")
                    } minimumValueLabel: {
                        Text("Sensitive").font(.caption2)
                    } maximumValueLabel: {
                        Text("Strict").font(.caption2)
                    }
                    Text(String(format: "Energy threshold: %.3f", prefs.speakerSensitivity))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } header: {
                Text("Speaker attribution")
            } footer: {
                Text("How loud a track must be to count as someone speaking. Lower catches quiet speakers but may pick up background noise. Applies to new transcriptions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Storage

struct StorageSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var usage: String = "Calculating…"

    var body: some View {
        Form {
            Section {
                LabeledContent("Recordings use", value: usage)
                LabeledContent("Location") {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([prefs.sessionsDirectory])
                    }
                }
            } header: {
                Text("On this Mac")
            } footer: {
                Text(prefs.sessionsDirectory.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .task { refresh() }
    }

    private func refresh() {
        let bytes = prefs.totalStorageBytes()
        usage = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
