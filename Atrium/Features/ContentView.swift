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
        MainAppView()
            .modelContainer(appState.sessionController.audioStore.container)
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
    @State private var pendingDeletion: Meeting?

    private var filteredMeetings: [Meeting] {
        if searchText.isEmpty { return meetings }
        return meetings.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    /// Sessions bucketed by recency so long archives stay scannable.
    private var groupedMeetings: [(title: String, meetings: [Meeting])] {
        let calendar = Calendar.current
        var today: [Meeting] = []
        var week: [Meeting] = []
        var earlier: [Meeting] = []

        for meeting in filteredMeetings {
            if calendar.isDateInToday(meeting.createdAt) {
                today.append(meeting)
            } else if let days = calendar.dateComponents([.day], from: meeting.createdAt, to: .now).day, days < 7 {
                week.append(meeting)
            } else {
                earlier.append(meeting)
            }
        }

        return [("Today", today), ("Previous 7 Days", week), ("Earlier", earlier)]
            .filter { !$0.1.isEmpty }
    }

    private func requestDelete(_ meeting: Meeting) {
        if Preferences.shared.confirmBeforeDelete {
            pendingDeletion = meeting
        } else {
            performDelete(meeting)
        }
    }

    private func performDelete(_ meeting: Meeting) {
        if selectedMeetingID == meeting.id { selectedMeetingID = nil }
        AudioStore.shared.delete(meeting: meeting)
    }

    private var selectedMeeting: Meeting? {
        guard let id = selectedMeetingID else { return nil }
        return meetings.first { $0.id == id }
    }
    
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Recording status bar
                if appState.isRecording {
                    HStack(spacing: 8) {
                        Rectangle().fill(Color.red).frame(width: 6, height: 6)
                        Text("Recording")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.red)
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
                        Text("Transcribing \(Int(appState.sessionController.transcriptionProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(white: 0.05))
                    
                    Rectangle().fill(Color(white: 0.15)).frame(height: 1)
                }
                
                // System audio unavailable — actionable, since the fix is a
                // permission toggle the user has to make in System Settings.
                if appState.sessionController.systemAudioUnavailable {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("System audio isn't being captured")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") {
                            PermissionService.openScreenRecordingSettings()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.08))

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
                    ContentUnavailableView {
                        Label(searchText.isEmpty ? "No Recordings" : "No Results",
                              systemImage: searchText.isEmpty ? "waveform.badge.mic" : "magnifyingglass")
                    } description: {
                        Text(searchText.isEmpty
                             ? "Press ⌘R or use the menu bar icon to record your first meeting."
                             : "No recordings match “\(searchText)”.")
                    }
                } else {
                    List(selection: $selectedMeetingID) {
                        ForEach(groupedMeetings, id: \.title) { group in
                            Section {
                                ForEach(group.meetings) { meeting in
                                    SessionRow(meeting: meeting)
                                        .tag(meeting.id)
                                        .listRowBackground(
                                            selectedMeetingID == meeting.id
                                            ? Color(white: 0.12)
                                            : Color.clear
                                        )
                                        .contextMenu {
                                            Button("Reveal in Finder") {
                                                NSWorkspace.shared.activateFileViewerSelecting(
                                                    [Preferences.shared.sessionsDirectory
                                                        .appendingPathComponent(meeting.id.uuidString)]
                                                )
                                            }
                                            Divider()
                                            Button("Delete…", role: .destructive) {
                                                requestDelete(meeting)
                                            }
                                        }
                                }
                            } header: {
                                Text(group.title)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.black)
                }
            }
            .searchable(text: $searchText, prompt: "Search recordings")
            .navigationTitle("Recordings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if appState.isRecording {
                            appState.sessionController.stopRecording()
                        } else {
                            Task { await appState.sessionController.startRecording() }
                        }
                    } label: {
                        Label(appState.isRecording ? "Stop" : "Record",
                              systemImage: appState.isRecording ? "stop.fill" : "record.circle")
                    }
                    .help(appState.isRecording ? "Stop recording (⇧⌘R)" : "Start recording (⌘R)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        if let meeting = selectedMeeting { requestDelete(meeting) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selectedMeeting == nil)
                    .help("Delete the selected recording (⌫)")
                }
            }
            .onDeleteCommand {
                if let meeting = selectedMeeting { requestDelete(meeting) }
            }
            .confirmationDialog(
                pendingDeletion.map { "Delete “\($0.title)”?" } ?? "Delete recording?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let meeting = pendingDeletion { performDelete(meeting) }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("The audio and transcript will be permanently removed from this Mac.")
            }
        } detail: {
            if let id = selectedMeetingID,
               let meeting = meetings.first(where: { $0.id == id }) {
                MeetingDetailView(meeting: meeting)
            } else {
                ContentUnavailableView(
                    "No Recording Selected",
                    systemImage: "waveform",
                    description: Text("Choose a recording from the list to read its transcript and play the audio.")
                )
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
            guard !AtriumApp.isRunningTests else { return }
            appState.sessionController.recoverIncompleteSessions()
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(meeting.createdAt, style: .time)
                    if meeting.duration > 0 {
                        Text("·")
                        Text(formatDuration(meeting.duration))
                    }
                    if meeting.speakers.count > 1 {
                        Text("·")
                        Text("^[\(meeting.speakers.count) speaker](inflect: true)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            StateIndicator(state: meeting.state)
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - State Indicator

struct StateIndicator: View {
    let state: MeetingState

    var body: some View {
        // "Ready" is the normal resting state; badging every row with it is
        // noise, so only surface states that need attention.
        if state != .ready {
            Text(label)
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(tint.opacity(0.15), in: Capsule())
                .foregroundStyle(tint)
        }
    }

    private var label: String {
        switch state {
        case .recording: return "Recording"
        case .processing: return "Transcribing"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    private var tint: Color {
        switch state {
        case .recording: return .red
        case .processing: return .orange
        case .ready: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Meeting Detail

struct MeetingDetailView: View {
    // SwiftData's @Model conforms to Observable, not ObservableObject, so
    // @ObservedObject does not apply. Observation is automatic; no wrapper
    // is needed since nothing here binds to $meeting.
    let meeting: Meeting
    @EnvironmentObject var appState: AppState
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
                                    isActive: playerVM.currentTime >= segment.start
                                              && playerVM.currentTime < segment.end,
                                    onTap: {
                                        playerVM.seek(to: segment.start)
                                    }
                                )
                                .id(segment.id)
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
                        ContentUnavailableView {
                            Label("Transcription Failed", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text("The recorded audio is still on disk. You can try transcribing it again.")
                        } actions: {
                            Button("Retry Transcription") {
                                Task { await appState.sessionController.retryTranscription(for: meeting) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(appState.sessionController.isTranscribing)
                        }
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
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                
                                Button(action: { playerVM.togglePlayback() }) {
                                    Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.title2)
                                        .foregroundStyle(.black)
                                        .frame(width: 52, height: 52)
                                        .background(.white, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .keyboardShortcut(.space, modifiers: [])
                                
                                Button(action: { playerVM.seek(to: min(playerVM.duration, playerVM.currentTime + 30)) }) {
                                    Image(systemName: "goforward.30")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
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
    var isActive: Bool = false
    let onTap: () -> Void

    @State private var isHovering = false

    private var speaker: Speaker? {
        speakers.first { $0.id == segment.speakerId }
    }

    private var speakerLabel: String { speaker?.label ?? "Unknown" }
    private var isYou: Bool { speaker?.isLocalUser ?? false }

    /// Distinct colours so the two sides of a conversation are separable at a
    /// glance without reading the labels.
    private var speakerTint: Color { isYou ? .cyan : .orange }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 14) {
                Rectangle()
                    .fill(speakerTint.opacity(isActive ? 0.9 : 0.35))
                    .frame(width: 2)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(speakerLabel)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(speakerTint)
                        Text(formatTime(segment.start))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }

                    Text(segment.text)
                        .font(.body)
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? speakerTint.opacity(0.10)
                                   : (isHovering ? Color.white.opacity(0.04) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Jump to \(formatTime(segment.start))")
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
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
