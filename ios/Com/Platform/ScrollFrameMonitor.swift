import UIKit

/// Ask ProMotion for high-rate callbacks only during motion. The samples measure
/// main-run-loop delivery, not GPU-presented frames; they contain no user content.
@MainActor final class ScrollFrameMonitor: NSObject {
    private var link: CADisplayLink?
    private var first = 0.0
    private var previous = 0.0
    private var intervals: [Double] = []
    private var requested = 60
    func start() {
        guard link == nil else { return }
        intervals = []; first = 0; previous = 0
        requested = UIScreen.main.maximumFramesPerSecond
        let display = CADisplayLink(target: self, selector: #selector(tick(_:)))
        let maximum = Float(requested)
        display.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, maximum), maximum: maximum, preferred: maximum)
        display.add(to: .main, forMode: .common)
        link = display
    }
    @objc private func tick(_ display: CADisplayLink) {
        if first == 0 { first = display.timestamp }
        if previous > 0 && intervals.count < 7200 { intervals.append(display.timestamp - previous) }
        previous = display.timestamp
    }
    func stop() {
        guard let link else { return }
        link.invalidate(); self.link = nil
        guard intervals.count >= 10 else { return }
        let sorted = intervals.sorted()
        let values: [String: Any] = ["requested_hz": requested, "callbacks": intervals.count,
            "duration_s": previous - first, "callback_hz": Double(intervals.count) / intervals.reduce(0,+),
            "p95_interval_ms": sorted[Int(Double(sorted.count-1) * 0.95)] * 1000,
            "over_25ms": intervals.filter { $0 > 0.025 }.count,
            "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "measurement": "CADisplayLink callback cadence; not GPU FPS"]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        // Do file IO away from the scrolling run loop.
        let url = directory.appendingPathComponent("scroll-performance.json")
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }
}
