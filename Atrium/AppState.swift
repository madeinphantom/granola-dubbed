import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var hasGivenConsent: Bool {
        didSet { UserDefaults.standard.set(hasGivenConsent, forKey: "hasGivenConsent") }
    }
    @Published var isRecording: Bool = false
    let sessionController = SessionController()
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        self.hasGivenConsent = UserDefaults.standard.bool(forKey: "hasGivenConsent")
        
        // Mirror sessionController's recording state so MenuBarExtra reacts
        sessionController.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.isRecording = value
            }
            .store(in: &cancellables)
    }
}
