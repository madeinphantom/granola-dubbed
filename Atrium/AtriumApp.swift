import SwiftUI
import AppKit

@main
struct AtriumApp: App {
    @StateObject private var appState = AppState()
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var updater = UpdaterService.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.sessionController)
                .preferredColorScheme(.dark)
                .background(Color.black)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear(perform: applyActivationPolicy)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            // Sits directly under "About Atrium", where macOS users expect it.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            CommandGroup(after: .newItem) {
                Button("Start Recording") {
                    Task { await appState.sessionController.startRecording() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.isRecording)

                Button("Stop Recording") {
                    appState.sessionController.stopRecording()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!appState.isRecording)
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }

        MenuBarExtra("Atrium", systemImage: appState.isRecording ? "record.circle.fill" : "waveform") {
            MenuBarView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
        .menuBarExtraStyle(.window)
    }

    /// `LSUIElement` is fixed at build time, so honour the menu-bar-only
    /// preference at runtime instead.
    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(prefs.menuBarOnly ? .accessory : .regular)
    }
}
