import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var elapsed: TimeInterval = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("ATRIUM")
                    .font(.system(.headline, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(.white)
                Spacer()
                Rectangle()
                    .fill(appState.isRecording ? Color.red : Color(white: 0.25))
                    .frame(width: 6, height: 6)
                Text(appState.isRecording ? "LIVE" : "IDLE")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(appState.isRecording ? .red : Color(white: 0.4))
            }
            .padding(16)
            .background(Color.black)
            
            Rectangle().fill(Color(white: 0.15)).frame(height: 1)
            
            // Elapsed time during recording
            if appState.isRecording {
                HStack {
                    Text(formatElapsed(elapsed))
                        .font(.system(.title3, design: .monospaced))
                        .foregroundColor(.red)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.03))
                .onReceive(timer) { _ in
                    if appState.isRecording { elapsed += 1 }
                }
                
                Rectangle().fill(Color(white: 0.15)).frame(height: 1)
            }
            
            // Transcription progress
            if appState.sessionController.isTranscribing {
                HStack(spacing: 8) {
                    Text("PROCESSING")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(Color(white: 0.5))
                    Spacer()
                    Text("\(Int(appState.sessionController.transcriptionProgress * 100))%")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(Color(white: 0.5))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(white: 0.03))
                
                Rectangle().fill(Color(white: 0.15)).frame(height: 1)
            }
            
            // Record Button
            Button(action: {
                if appState.isRecording {
                    appState.sessionController.stopRecording()
                    elapsed = 0
                } else {
                    Task { await appState.sessionController.startRecording() }
                    elapsed = 0
                }
            }) {
                Text(appState.isRecording ? "END SESSION" : "NEW SESSION")
                    .font(.system(.subheadline, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(appState.isRecording ? Color.red.opacity(0.08) : Color.white.opacity(0.04))
                    .foregroundColor(appState.isRecording ? .red : .white)
            }
            .buttonStyle(.plain)
            
            Rectangle().fill(Color(white: 0.15)).frame(height: 1)
            
            // Open App
            Button(action: {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApplication.shared.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                    break
                }
            }) {
                HStack {
                    Text("OPEN ARCHIVE")
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
                .foregroundColor(Color(white: 0.5))
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(Color.black)
            }
            .buttonStyle(.plain)
            
            Rectangle().fill(Color(white: 0.15)).frame(height: 1)
            
            // Quit
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack {
                    Text("QUIT ATRIUM")
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    Text("⌘Q")
                        .font(.system(.caption, design: .monospaced))
                }
                .foregroundColor(Color(white: 0.35))
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(Color.black)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 280)
        .background(Color.black)
    }
    
    private func formatElapsed(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
