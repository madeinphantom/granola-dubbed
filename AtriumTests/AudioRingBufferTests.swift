import XCTest
@testable import Atrium

final class AudioRingBufferTests: XCTestCase {
    func testRingBufferWriteRead() {
        let buffer = AudioRingBuffer(capacityFrames: 10, channels: 1)
        let input: [Float] = [1.0, 2.0, 3.0]
        
        buffer.write(data: input, count: 3)
        let output = buffer.read(count: 3)
        
        XCTAssertEqual(output, input)
        XCTAssertNil(buffer.read(count: 1))
    }
    
    func testRingBufferOverflow() {
        let buffer = AudioRingBuffer(capacityFrames: 4, channels: 1)
        let input: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0]
        
        buffer.write(data: input, count: 5)
        // Should overflow. Size is 4, we wrote 5.
        // It keeps the latest 4 elements: [2.0, 3.0, 4.0, 5.0]
        
        let output = buffer.read(count: 4)
        XCTAssertEqual(output, [2.0, 3.0, 4.0, 5.0])
    }
    
    func testRingBufferUnderflow() {
        let buffer = AudioRingBuffer(capacityFrames: 10, channels: 1)
        buffer.write(data: [1.0, 2.0], count: 2)
        
        // Try reading more than written
        XCTAssertNil(buffer.read(count: 5))
        
        // Reading exactly what's there
        let output = buffer.read(count: 2)
        XCTAssertEqual(output, [1.0, 2.0])
    }
}
