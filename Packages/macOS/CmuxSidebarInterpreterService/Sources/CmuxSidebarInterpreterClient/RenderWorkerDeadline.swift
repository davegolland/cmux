import Foundation

/// Normalizes caller-supplied worker deadlines before they reach
/// `Task.sleep` or a GCD timer. A public initializer can receive an extreme
/// `Duration`; allowing that value through would keep a dead worker and its
/// pipes alive for an unbounded time, and converting it to `Double` could
/// overflow.
enum RenderWorkerDeadline {
    static let minimum: Duration = .milliseconds(1)
    static let maximum: Duration = .seconds(5 * 60)

    static func clamp(_ duration: Duration) -> Duration {
        if duration < minimum { return minimum }
        if duration > maximum { return maximum }
        return duration
    }

    static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = clamp(duration).components
        let seconds = Double(components.seconds)
        let attoseconds = Double(components.attoseconds) / 1e18
        let value = seconds + attoseconds
        guard value.isFinite else { return maximumTimeInterval }
        return min(maximumTimeInterval, max(minimumTimeInterval, value))
    }

    static let minimumTimeInterval: TimeInterval = 0.001
    static let maximumTimeInterval: TimeInterval = 5 * 60
}
