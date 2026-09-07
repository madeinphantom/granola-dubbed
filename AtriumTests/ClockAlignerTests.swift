import XCTest
@testable import Atrium

final class ClockAlignerTests: XCTestCase {
    func testClockAligner() {
        let aligner = ClockAligner()
        
        let startHost = mach_absolute_time()
        let time1 = aligner.getSessionTime(hostTime: startHost)
        XCTAssertEqual(time1, 0, "First call should set zero")
        
        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)
        let nanosPerTick = Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
        
        let futureHost = startHost + UInt64(1_000_000_000 / nanosPerTick)
        
        let time2 = aligner.getSessionTime(hostTime: futureHost)
        XCTAssertTrue(time2 > 0.99 && time2 < 1.01, "Should be approximately 1 second")
    }
    
    func testClockAlignerReset() {
        let aligner = ClockAligner()
        _ = aligner.getSessionTime(hostTime: 1000)
        
        aligner.reset()
        let time2 = aligner.getSessionTime(hostTime: 5000)
        XCTAssertEqual(time2, 0, "Reset should zero out the base host time")
    }

    func testClockGoingBackwardsClampsToZero() {
        // Host time can appear to move backwards across device restarts; never emit negative session time.
        XCTAssertEqual(ClockAligner().getSessionTime(hostTime: 500), 0)
    }
}
