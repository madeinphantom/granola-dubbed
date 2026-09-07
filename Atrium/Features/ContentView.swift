import SwiftUI
import SwiftData
import AppKit

// Static formatters to avoid re-allocation on every render
private let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy.MM.dd"
    return f
}()

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        Group {
            if appState.hasGivenConsent {
                MainAppView()
                    .modelContainer(appState.sessionController.audioStore.container)
            } else {
                OnboardingView()
            }
        }
        .background(Color.black)
        .foregroundColor(.white)
    }
}

// MARK: - Main App

struct MainAppView: View {
    @EnvironmentObject var appState: AppState
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]
    @State private var selectedMeetingID: UUID?
    @State private var searchText: String = ""
    
    private var filteredMeetings: [Meeting] {
        if searchText.isEmpty { return meetings }
        return meetings.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Recording status bar
                if appState.isRecording {
                    HStack(spacing: 8) {
                        Rectangle().fill(Color.red).frame(width: 6, height: 6)
                        Text("RECORDING")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.red)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.05))
                    
                    Rectangle().fill(Color(white: 0.15)).frame(height: 1)
                }
                
                if appState.sessionController.isTranscribing {
                    HStack(spacing: 8) {
                        ProgressView(value: appState.sessionController.transcriptionProgress)
                            .tint(.white)
                        Text("\(Int(appState.sessionController.transcriptionProgress * 100))%")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(Color(white: 0.5))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(white: 0.05))
                    
                    Rectangle().fill(Color(white: 0.15)).frame(height: 1)
                }
                
                // Error banner
                if let error = appState.sessionController.lastError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundColor(Color(red: 1, green: 0.6, blue: 0.4))
                        Text(error)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(Color(red: 1, green: 0.6, blue: 0.4))
                            .lineLimit(2)
                        Spacer()
                        Button(action: { appState.sessionController.lastError = nil }) {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundColor(Color(white: 0.4))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(red: 1, green: 0.6, blue: 0.4).opacity(0.05))
                    
                    Rectangle().fill(Color(white: 0.15)).frame(height: 1)
                }
                
                if filteredMeetings.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 32))
                            .foregroundColor(Color(white: 0.15))
                        Text(searchText.isEmpty ? "NO SESSIONS" : "NO RESULTS")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(Color(white: 0.25))
                        if searchText.isEmpty {
                            Text("Start a new session from the\nmenu bar or press ⌘R")
                                .font(.system(.caption2))
                                .foregroundColor(Color(white: 0.2))
                                .multilineTextAlignment(.center)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List(selection: $selectedMeetingID) {
                        ForEach(filteredMeetings) { meeting in
                            SessionRow(meeting: meeting)
                                .tag(meeting.id)
                                .listRowBackground(
                                    selectedMeetingID == meeting.id
                                    ? Color(white: 0.1)
                                    : Color.black
                                )
                                .contextMenu {
                                    Button("Delete", role: .destructive) {
                                        if selectedMeetingID == meeting.id {
                                            selectedMeetingID = nil
                                        }
                                        AudioStore.shared.delete(meeting: meeting)
                                    }
                                }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.black)
                }
            }
            .searchable(text: $searchText, prompt: "Search meetings")
            .navigationTitle("ARCHIVE")
        } detail: {
            if let id = selectedMeetingID,
               let meeting = meetings.first(where: { $0.id == id }) {
                MeetingDetailView(meeting: meeting)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "waveform")
                        .font(.system(size: 48))
                        .foregroundColor(Color(white: 0.15))
                    Text("AWAITING SELECTION")
                        .font(.system(.headline, design: .monospaced))
                        .foregroundColor(Color(white: 0.25))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }
        }
        // Keyboard shortcuts
        .keyboardShortcut("r", modifiers: .command, action: {
            if appState.isRecording {
                appState.sessionController.stopRecording()
            } else {
                Task { await appState.sessionController.startRecording() }
            }
        })
        .onAppear {
            appState.sessionController.recoverIncompleteSessions()
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let meeting: Meeting
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    Text(dateFormatter.string(from: meeting.createdAt))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(Color(white: 0.4))
                    
                    if meeting.duration > 0 {
                        Text("//")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(Color(white: 0.2))
                        Text(formatDuration(meeting.duration))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(Color(white: 0.4))
                    }
                }
            }
            
            Spacer()
            
            StateIndicator(state: meeting.state)
        }
        .padding(.vertical, 6)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - State Indicator

struct StateIndicator: View {
    let state: MeetingState
    
    var body: some View {
        Text(state.rawValue.uppercased())
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(stateColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .border(stateColor.opacity(0.3), width: 1)
    }
    
    private var stateColor: Color {
        switch state {
        case .recording: return .red
        case .processing: return Color(white: 0.6)
        case .ready: return .green
        case .failed: return Color(red: 1, green: 0.4, blue: 0.4)
        }
    }
}

// MARK: - Meeting Detail

struct MeetingDetailView: View {
    @ObservedObject var meeting: Meeting
    @State private var notes: String = ""
    @State private var transcript: TranscriptDocument?
    @StateObject private var playerVM = AudioPlayerViewModel()
    @State private var isEditingTitle = false
    @State private var editedTitle: String = ""
    
    var body: some View {
        HSplitView {
            // Left: Notes + Transcript
            VStack(spacing: 0) {
                // Title bar
                HStack {
                    if isEditingTitle {
                        TextField("Title", text: $editedTitle, onCommit: {
                            meeting.title = editedTitle
                            try? AudioStore.shared.container.mainContext.save()
                            isEditingTitle = false
                        })
                        .font(.system(.title3, design: .monospaced))
                        .textFieldStyle(.plain)
                    } else {
                        Text(meeting.title)
                            .font(.system(.title3, design: .monospaced))
                            .fontWeight(.bold)
                            .onTapGesture(count: 2) {
                                editedTitle = meeting.title
                                isEditingTitle = true
                            }
                    }
                    
                    Spacer()
                    
                    Menu {
                        Button("Markdown") { exportAs(.markdown) }
                        Button("JSON") { exportAs(.json) }
                        Button("SRT") { exportAs(.srt) }
                        Button("Plain Text") { exportAs(.txt) }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(Color(white: 0.6))
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding(16)
                .background(Color(white: 0.03))
                
                Rectangle().fill(Color(white: 0.15)).frame(height: 1)
                
                // Notes editor
                TextEditor(text: $notes)
                    .font(.system(.body))
                    .padding(16)
                    .frame(minHeight: 120, maxHeight: 180)
                    .scrollContentBackground(.hidden)
                    .background(Color.black)
                    .onChange(of: notes) { _, newValue in
                        meeting.notesMarkdown = newValue
                        try? AudioStore.shared.container.mainContext.save()
                    }
                
                Rectangle().fill(Color(white: 0.15)).frame(height: 1)
                
                // Transcript
                ScrollView {
                    if let transcript = transcript, !transcript.segments.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(transcript.segments) { segment in
                                TranscriptRow(
                                    segment: segment,
                                    speakers: meeting.speakers,
                                    onTap: {
                                        playerVM.seek(to: segment.start)
                                    }
                                )
                            }
                        }
                        .padding(20)
                    } else if meeting.state == .processing {
                        VStack(spacing: 12) {
                            ProgressView()
                                .tint(.white)
                            Text("TRANSCRIBING")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(Color(white: 0.4))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(40)
                    } else if meeting.state == .recording {
                        Text("CAPTURE IN PROGRESS")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(Color(white: 0.3))
                            .frame(maxWidth: .infinity)
                            .padding(40)
                    } else if meeting.state == .failed {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title2)
                                .foregroundColor(Color(red: 1, green: 0.4, blue: 0.4))
                            Text("PIPELINE FAILED")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(Color(red: 1, green: 0.4, blue: 0.4))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(40)
                    } else {
                        Text("NO TRANSCRIPT DATA")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(Color(white: 0.2))
                            .frame(maxWidth: .infinity)
                            .padding(40)
                    }
                }
                .background(Color.black)
            }
            .frame(minWidth: 400)
            
            // Right: Audio Player
            VStack(spacing: 0) {
                Rectangle().fill(Color(white: 0.03)).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(
                        VStack(spacing: 32) {
                            Spacer()
                            
                            // Waveform bars (seeded from meeting ID for consistency)
                            WaveformBars(
                                progress: playerVM.duration > 0 ? playerVM.currentTime / playerVM.duration : 0,
                                isPlaying: playerVM.isPlaying,
                                seed: meeting.id
                            )
                            
                            VStack(spacing: 8) {
                                Slider(value: Binding(
                                    get: { playerVM.currentTime },
                                    set: { playerVM.seek(to: $0) }
                                ), in: 0...max(0.01, playerVM.duration))
                                .tint(.white)
                                
                                HStack {
                                    Text(formatTime(playerVM.currentTime))
                                    Spacer()
                                    Text(formatTime(playerVM.duration))
                                }
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(Color(white: 0.4))
                            }
                            
                            HStack(spacing: 24) {
                                Button(action: { playerVM.seek(to: max(0, playerVM.currentTime - 15)) }) {
                                    Image(systemName: "gobackward.15")
                                        .font(.title3)
                                        .foregroundColor(Color(white: 0.6))
                                }
                                .buttonStyle(.plain)
                                
                                Button(action: { playerVM.togglePlayback() }) {
                                    Text(playerVM.isPlaying ? "HALT" : "PLAY")
                                        .font(.system(.headline, design: .monospaced))
                                        .tracking(1)
                                        .frame(width: 100, height: 36)
                                        .border(Color.white, width: 1)
                                        .background(playerVM.isPlaying ? Color.white : Color.clear)
                                        .foregroundColor(playerVM.isPlaying ? .black : .white)
                                }
                                .buttonStyle(.plain)
                                .keyboardShortcut(.space, modifiers: [])
                                
                                Button(action: { playerVM.seek(to: min(playerVM.duration, playerVM.currentTime + 30)) }) {
                                    Image(systemName: "goforward.30")
                                        .font(.title3)
                                        .foregroundColor(Color(white: 0.6))
                                }
                                .buttonStyle(.plain)
                            }
                            
                            Spacer()
                        }
                        .padding(32)
                    )
            }
            .frame(minWidth: 240, maxWidth: 320)
            .border(Color(white: 0.15), width: 1)
        }
        .background(Color.black)
        .onAppear { loadData() }
        .onChange(of: meeting.stateRaw) { _, _ in
            // Auto-refresh transcript when state changes (e.g. processing -> ready)
            transcript = AudioStore.shared.loadTranscript(for: meeting)
        }
    }
    
    private func loadData() {
        notes = meeting.notesMarkdown
        transcript = AudioStore.shared.loadTranscript(for: meeting)
        
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let m4aURL = appSupport.appendingPathComponent("Atrium/\(meeting.audioMixRelativePath)")
        if FileManager.default.fileExists(atPath: m4aURL.path) {
            playerVM.load(url: m4aURL)
        }
    }
    
    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
    
    private func exportAs(_ format: ExportService.ExportFormat) {
        let service = ExportService()
        let output = service.export(meeting: meeting, transcript: transcript, format: format)
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(meeting.title).\(format.fileExtension)"
        
        if panel.runModal() == .OK, let url = panel.url {
            try? output.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Waveform

struct WaveformBars: View {
    let progress: Double
    let isPlaying: Bool
    let seed: UUID
    
    // Generate deterministic bar heights from the meeting UUID so they don't change on re-render
    private var barHeights: [CGFloat] {
        var heights: [CGFloat] = []
        let seedString = seed.uuidString
        for (i, char) in seedString.enumerated() {
            let ascii = CGFloat(char.asciiValue ?? 65)
            let normalized = 4 + (ascii + CGFloat(i * 7)).truncatingRemainder(dividingBy: 26)
            heights.append(normalized)
        }
        // Pad to 40 bars
        while heights.count < 40 {
            heights.append(heights[heights.count % seedString.count])
        }
        return Array(heights.prefix(40))
    }
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<40, id: \.self) { i in
                let barProgress = Double(i) / 40.0
                let isPast = barProgress <= progress
                Rectangle()
                    .fill(isPast ? Color.white : Color(white: isPlaying ? 0.2 : 0.12))
                    .frame(width: 3, height: barHeights[i])
            }
        }
        .frame(height: 40)
    }
}

// MARK: - Transcript Row

struct TranscriptRow: View {
    let segment: TranscriptSegment
    let speakers: [Speaker]
    let onTap: () -> Void
    
    private var speakerLabel: String {
        speakers.first(where: { $0.id == segment.speakerId })?.label ?? "Unknown"
    }
    
    private var isYou: Bool {
        speakers.first(where: { $0.id == segment.speakerId })?.isLocalUser ?? false
    }
    
    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(formatTime(segment.start))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(Color(white: 0.35))
                    Text(speakerLabel.uppercased())
                        .font(.system(.caption2, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(isYou ? Color.white : Color(white: 0.55))
                }
                .frame(width: 70, alignment: .leading)
                
                Text(segment.text)
                    .font(.system(.body))
                    .foregroundColor(Color(white: 0.85))
                    .lineSpacing(5)
                    .multilineTextAlignment(.leading)
                
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
    
    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var understandsConsent = false
    
    var body: some View {
        VStack(spacing: 40) {
            Text("ATRIUM")
                .font(.system(size: 48, weight: .light, design: .monospaced))
                .tracking(8)
            
            VStack(spacing: 16) {
                Text("CONSENT REQUIRED")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.red)
                
                Text("Atrium records the microphone and everything playing through this Mac. In many places you must tell the other people on the call. You are responsible for consent.")
                    .font(.system(.body))
                    .multilineTextAlignment(.center)
                    .foregroundColor(Color(white: 0.75))
                    .frame(maxWidth: 420)
            }
            
            Toggle("I understand I must notify participants.", isOn: $understandsConsent)
                .font(.system(.caption, design: .monospaced))
                .toggleStyle(.checkbox)
                .tint(.white)
            
            Button(action: {
                appState.hasGivenConsent = true
            }) {
                Text("INITIALIZE")
                    .font(.system(.headline, design: .monospaced))
                    .tracking(2)
                    .frame(width: 200, height: 50)
                    .background(understandsConsent ? Color.white : Color(white: 0.15))
                    .foregroundColor(understandsConsent ? .black : Color(white: 0.4))
            }
            .buttonStyle(.plain)
            .disabled(!understandsConsent)
        }
        .padding(60)
        .frame(width: 600, height: 500)
        .background(Color.black)
    }
}

// MARK: - View+KeyboardShortcut helper

extension View {
    func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers, action: @escaping () -> Void) -> some View {
        self.background(
            Button("", action: action)
                .keyboardShortcut(key, modifiers: modifiers)
                .hidden()
        )
    }
}
