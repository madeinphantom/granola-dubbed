import Foundation
import AVFoundation
import CoreAudio

final class ClockAligner {
    private var sessionStartHostTime: UInt64?
    
    private var timebaseInfo: mach_timebase_info_data_t = mach_timebase_info_data_t()
    
    init() {
        mach_timebase_info(&timebaseInfo)
    }
    
    func getSessionTime(hostTime: UInt64) -> TimeInterval {
        if sessionStartHostTime == nil {
            sessionStartHostTime = hostTime
        }
        
        guard let start = sessionStartHostTime else { return 0 }
        
        let elapsed = hostTime > start ? hostTime - start : 0
        let elapsedNanos = (elapsed * UInt64(timebaseInfo.numer)) / UInt64(timebaseInfo.denom)
        
        return TimeInterval(elapsedNanos) / 1_000_000_000.0
    }
    
    func reset() {
        sessionStartHostTime = nil
    }
}
