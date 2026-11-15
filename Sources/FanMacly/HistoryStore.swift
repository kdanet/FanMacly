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

/// Fixed-size in-memory history: one hour at the fastest (1 s) sampling rate.
struct HistoryStore {
    private(set) var samples: [HistorySample] = []
    let capacity: Int
    init(capacity: Int = 3600) { self.capacity = capacity }

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

/// One plotted value. Points of one line share `series` and `segment`;
/// a new segment starts after a gap, so the chart does not draw across it.
struct ChartPoint: Identifiable, Equatable {
    let series: String
    let segment: Int
    let date: Date
    let value: Double
    var line: String { "\(series)#\(segment)" }
    var id: String { "\(line)-\(date.timeIntervalSinceReferenceDate)" }
}

enum ChartData {
    /// At most `buckets` averaged points per series across `domain`. Swift Charts
    /// redraws every point on each update, and an hour at 1 s is 3 600 per line.
    /// Samples further apart than `gap` (sleep, stale counters) split the line.
    static func points(_ samples: [HistorySample], series: [(String, (HistorySample) -> Double?)],
                       domain: ClosedRange<Date>, buckets: Int = 240, gap: TimeInterval = 8) -> [ChartPoint] {
        let lower = domain.lowerBound.timeIntervalSinceReferenceDate
        let width = max(1, domain.upperBound.timeIntervalSince(domain.lowerBound) / Double(max(1, buckets)))
        var result: [ChartPoint] = []
        for (name, value) in series {
            var segment = 0, bucket = Int.min, count = 0.0, sumValue = 0.0, sumTime = 0.0
            var last: TimeInterval?
            func flush() {
                guard count > 0 else { return }
                result.append(ChartPoint(series: name, segment: segment, date: Date(timeIntervalSinceReferenceDate: sumTime / count), value: sumValue / count))
                count = 0; sumValue = 0; sumTime = 0
            }
            for sample in samples {
                guard let reading = value(sample), reading.isFinite else { continue }
                let time = sample.date.timeIntervalSinceReferenceDate
                guard time >= lower else { continue }
                let index = Int((time - lower) / width)
                if let last, time - last > gap { flush(); segment += 1; bucket = index }
                if index != bucket { flush(); bucket = index }
                count += 1; sumValue += reading; sumTime += time
                last = time
            }
            flush()
        }
        return result
    }

    /// A round axis step (1, 2, 2.5 or 5 × 10ⁿ) giving at most `maxTicks` intervals, never below `minimum`.
    static func axisStep(span: Double, minimum: Double, maxTicks: Int = 6) -> Double {
        guard span.isFinite, span > 0 else { return minimum }
        let raw = span / Double(maxTicks)
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? 10 * magnitude
        return max(minimum, step)
    }
}
