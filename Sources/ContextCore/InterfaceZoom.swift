import Foundation
import Observation

/// App-wide interface scale for dense high-resolution displays, such as a 24-inch 4K monitor.
/// Views read `scale` while rendering, so Observation redraws them when it changes; 1 keeps system sizes.
@MainActor @Observable public final class InterfaceZoom {
    public static let shared = InterfaceZoom()
    public static let preferenceKey = "interfaceZoom"
    public static let steps: [Double] = [0.9, 1, 1.1, 1.25, 1.4, 1.6, 1.8, 2]

    public private(set) var scale: Double
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        scale = Self.clamped(defaults.double(forKey: Self.preferenceKey))
    }

    public var canZoomIn: Bool { scale < Self.steps[Self.steps.count - 1] }
    public var canZoomOut: Bool { scale > Self.steps[0] }
    public var isActualSize: Bool { scale == 1 }
    public var percent: Int { Int((scale * 100).rounded()) }

    /// A point length scaled for AppKit fonts and SwiftUI metrics.
    public func scaled(_ value: CGFloat) -> CGFloat { scale == 1 ? value : (value * scale).rounded() }

    public func zoomIn() { set(Self.steps.first { $0 > scale + 0.001 } ?? scale) }
    public func zoomOut() { set(Self.steps.last { $0 < scale - 0.001 } ?? scale) }
    public func reset() { set(1) }

    public func set(_ value: Double) {
        let value = Self.clamped(value)
        guard value != scale else { return }
        scale = value
        defaults.set(value, forKey: Self.preferenceKey)
    }

    /// A missing or invalid preference means actual size; others stay within the offered range.
    static func clamped(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        return min(max(value, steps[0]), steps[steps.count - 1])
    }
}
