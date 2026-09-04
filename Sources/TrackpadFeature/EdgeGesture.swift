import Foundation

public struct EdgeTouch {
    public let id: Int32
    public let x: Double
    public let y: Double
    public init(id: Int32, x: Double, y: Double) { self.id = id; self.x = x; self.y = y }
}

/// Physical coordinates: bottom-left origin, independent of natural scrolling.
public struct EdgeGesture {
    public enum Side: String { case brightness, volume }
    public struct Change {
        public let side: Side
        public let delta: Double
    }
    private struct Contact {
        var id: Int32
        var side: Side
        var x: Double
        var y: Double
        var lastY: Double
        var began: Double
        var armed = false
    }
    private var contact: Contact?
    private var rejected = false
    private var lastTimestamp: Double?
    public private(set) var isControlling = false
    public var isArmed: Bool { contact?.armed == true && !rejected }
    public init() {}
    public mutating func reset() { self = EdgeGesture() }

    public mutating func update(_ touches: [EdgeTouch], at time: Double, width: Double, sensitivity: Double) -> Change? {
        guard time.isFinite else { reset(); return nil }
        if let lastTimestamp, time < lastTimestamp || time - lastTimestamp > 0.3 { reset() }
        lastTimestamp = time
        if touches.isEmpty { reset(); return nil }
        guard touches.count == 1, let touch = touches.first,
              touch.x.isFinite, touch.y.isFinite,
              (0...1).contains(touch.x), (0...1).contains(touch.y) else {
            rejected = true; contact = nil; isControlling = false; return nil
        }
        guard !rejected else { return nil }
        let edge = min(0.25, max(0.08, width.isFinite ? width : 0.15))
        let side: Side? = touch.x <= edge ? .brightness : (touch.x >= 1 - edge ? .volume : nil)
        guard let side else { rejected = true; contact = nil; isControlling = false; return nil }
        guard var current = contact else {
            contact = Contact(id: touch.id, side: side, x: touch.x, y: touch.y, lastY: touch.y, began: time)
            return nil
        }
        guard current.id == touch.id, current.side == side, abs(touch.x - current.x) < 0.06 else {
            rejected = true; contact = nil; isControlling = false; return nil
        }
        if !current.armed {
            // Hold still briefly before sliding. Ordinary pointer movement is not a gesture.
            if time - current.began < 0.18 {
                if abs(touch.y - current.y) > 0.025 { rejected = true; contact = nil }
                return nil
            }
            current.armed = true
            current.lastY = touch.y
            contact = current
            return nil
        }
        let distance = touch.y - current.lastY
        guard abs(distance) >= 0.008 else { return nil }
        // Discontinuous frames should never cause a brightness/volume jump.
        guard abs(distance) < 0.15 else { rejected = true; contact = nil; isControlling = false; return nil }
        isControlling = true
        current.lastY = touch.y
        contact = current
        let gain = min(2, max(0.5, sensitivity.isFinite ? sensitivity : 1))
        return Change(side: side, delta: max(-0.08, min(0.08, distance * gain)))
    }
}
