import SwiftUI
import AppKit

struct RecPillView: View {
    @State private var timeElapsed: TimeInterval = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
            Text(timeString(from: timeElapsed))
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.92))
        .border(Color(white: 0.25), width: 1)
        .onReceive(timer) { _ in
            timeElapsed += 1
        }
    }
    
    private func timeString(from time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

@MainActor
final class RecPillWindowManager {
    static let shared = RecPillWindowManager()
    private var window: NSPanel?
    
    func show() {
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 110, height: 34),
                styleMask: [.nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "RecPill"
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isMovableByWindowBackground = true
            
            let hostingView = NSHostingView(rootView: RecPillView())
            panel.contentView = hostingView
            window = panel
        }
        
        // Position top-right
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let x = screenRect.maxX - 130
            let y = screenRect.maxY - 50
            window?.setFrameOrigin(CGPoint(x: x, y: y))
        }
        
        window?.orderFront(nil)
    }
    
    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}
