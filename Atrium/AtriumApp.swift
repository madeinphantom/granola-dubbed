import SwiftUI

@main
struct AtriumApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.sessionController)
                .preferredColorScheme(.dark)
                .background(Color.black)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 700)
        
        MenuBarExtra("Atrium", systemImage: appState.isRecording ? "record.circle.fill" : "waveform") {
            MenuBarView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
        .menuBarExtraStyle(.window)
    }
}
