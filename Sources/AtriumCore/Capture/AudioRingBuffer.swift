import Foundation
import os

/// Fixed-size FIFO of Float samples between an audio thread and the writer.
///
/// Counts are in samples, not frames. Every track Atrium writes is mono, so
/// the two are the same, but the type does not assume it.
public final class AudioRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private var storage: [Float]
    private var head = 0 // total samples ever written
    private var tail = 0 // total samples ever read
    private var lock = os_unfair_lock_s()
    private var dropped = 0

    public init(capacitySamples: Int) {
        capacity = capacitySamples
        storage = Array(repeating: 0, count: capacitySamples)
    }

    public func write(_ data: UnsafePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        for i in 0..<count {
            storage[(head + i) % capacity] = data[i]
        }
        head += count
        // Overflow discards the oldest unread audio. Count it: a silent drop
        // here is a gap in the recording that nothing else would surface.
        if head - tail > capacity {
            dropped += (head - tail) - capacity
            tail = head - capacity
        }
    }

    public func writeSilence(count: Int) {
        let zeros = [Float](repeating: 0, count: min(count, 4096))
        var remaining = count
        zeros.withUnsafeBufferPointer { pointer in
            while remaining > 0 {
                let chunk = min(remaining, zeros.count)
                write(pointer.baseAddress!, count: chunk)
                remaining -= chunk
            }
        }
    }

    /// Samples discarded because the consumer could not keep up.
    public var droppedSamples: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return dropped
    }

    public var availableSamples: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return head - tail
    }

    /// Reads up to `maxCount` samples; returns nil when empty.
    public func read(maxCount: Int) -> [Float]? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let count = min(maxCount, head - tail)
        guard count > 0 else { return nil }
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            result[i] = storage[(tail + i) % capacity]
        }
        tail += count
        return result
    }
}

