import XCTest
@testable import FanMacly

final class ChartDataTests: XCTestCase {
    private func sample(_ t: TimeInterval, cpu: Double?) -> HistorySample {
        HistorySample(date: Date(timeIntervalSinceReferenceDate: t), cpu: cpu, gpu: nil, fans: [], targets: [], cpuWatts: nil, gpuWatts: nil)
    }
    private let domain = Date(timeIntervalSinceReferenceDate: 0)...Date(timeIntervalSinceReferenceDate: 3600)

    func testAnHourIsAveragedIntoBuckets() {
        let samples = (0..<3600).map { sample(TimeInterval($0), cpu: Double($0 % 2 == 0 ? 60 : 70)) }
        let points = ChartData.points(samples, series: [("CPU", { $0.cpu })], domain: domain, buckets: 240)
        XCTAssertEqual(points.count, 240)
        XCTAssertTrue(points.allSatisfy { abs($0.value - 65) < 0.7 }, "each point is the mean of its 15 samples")
        XCTAssertEqual(Set(points.map(\.segment)), [0])
    }

    func testGapStartsANewSegment() {
        // Missing readings for a minute (stale counter, sleep) must not be bridged by a line.
        let samples = (0..<60).map { sample(TimeInterval($0), cpu: 50) }
            + (60..<120).map { sample(TimeInterval($0), cpu: nil) }
            + (120..<180).map { sample(TimeInterval($0), cpu: 52) }
        let points = ChartData.points(samples, series: [("CPU", { $0.cpu })], domain: domain)
        XCTAssertEqual(Set(points.map(\.segment)), [0, 1])
        XCTAssertTrue(points.filter { $0.segment == 0 }.allSatisfy { $0.value == 50 })
        XCTAssertTrue(points.filter { $0.segment == 1 }.allSatisfy { $0.value == 52 })
    }

    func testAxisStepKeepsGridlinesFew() {
        XCTAssertEqual(ChartData.axisStep(span: 4000, minimum: 5), 1000)
        XCTAssertEqual(ChartData.axisStep(span: 5800, minimum: 1000), 1000, "fans near maximum keep 1 000 rpm gridlines")
        XCTAssertEqual(ChartData.axisStep(span: 90, minimum: 10), 20)
        XCTAssertEqual(ChartData.axisStep(span: 40, minimum: 10), 10)
        XCTAssertEqual(ChartData.axisStep(span: 12, minimum: 5), 5)
        XCTAssertEqual(ChartData.axisStep(span: 5000, minimum: 1000), 1000)
    }
}
