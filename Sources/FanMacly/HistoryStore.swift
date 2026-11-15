import Foundation
import FanMaclyCore

struct HistorySample: Identifiable, Sendable {
    let date: Date
    let cpu: Double?
    let gpu: Double?
    let fans: [Double?]
    let targets: [Double?]
    let cpuWatts: Double?
    let gpuWatts: Double?
    var id: Date { date }
}

/// Fixed-size in-memory history (default: one hour at 2 s).
struct HistoryStore {
    private(set) var samples: [HistorySample] = []
    let capacity: Int
    init(capacity: Int = 1800) { self.capacity = capacity }

    mutating func append(_ sample: HistorySample) {
        samples.append(sample)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }
    func window(_ duration: TimeInterval, now: Date = Date()) -> [HistorySample] {
        let start = now.addingTimeInterval(-duration)
        guard let index = samples.firstIndex(where: { $0.date >= start }) else { return [] }
        return Array(samples[index...])
    }
    func fanSeries(_ fan: Int, duration: TimeInterval) -> [Double] {
        window(duration).compactMap { $0.fans.indices.contains(fan) ? $0.fans[fan] : nil }
    }
}
