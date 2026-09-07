import Foundation
import AVFoundation
import os

final class AudioRingBuffer {
    private let capacity: Int
    private var buffer: [Float]
    private var head: Int = 0 // Write index
    private var tail: Int = 0 // Read index
    private var lock = os_unfair_lock_s()
    private var droppedFrames: Int = 0
    
    init(capacityFrames: Int, channels: Int) {
        self.capacity = capacityFrames * channels
        self.buffer = Array(repeating: 0.0, count: capacity)
    }
    
    func write(data: UnsafePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        // Simple ring buffer write
        for i in 0..<count {
            buffer[(head + i) % capacity] = data[i]
        }
        head += count
        // If we overflow the unread data, advance tail. This discards the
        // oldest unread audio, so record it — a silent drop here means a gap
        // in the recording that nothing else would ever surface.
        if head - tail > capacity {
            droppedFrames += (head - tail) - capacity
            tail = head - capacity
        }
    }
    
    /// Frames discarded because the consumer could not keep up. Non-zero means
    /// the recording has gaps.
    var totalDroppedFrames: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return droppedFrames
    }

    /// Unread frames currently buffered.
    var availableFrames: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return head - tail
    }

    func read(count: Int) -> [Float]? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        let available = head - tail
        guard available >= count else { return nil }
        
        var result = Array(repeating: Float(0.0), count: count)
        for i in 0..<count {
            result[i] = buffer[(tail + i) % capacity]
        }
        tail += count
        return result
    }
}
