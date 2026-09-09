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
        var ids: [Int32]
        var side: Side
        var x: Double
        var y: Double
        var lastY: Double
        var began: Double
        var armed = false
    }
    private var contact: Contact?
    private var rejected = false
    private var landing: EdgeTouch?
    private var landingTime: Double?
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
        guard !rejected else { return nil }
        let edge = min(0.25, max(0.08, width.isFinite ? width : 0.15))
        func sideOf(_ point: EdgeTouch) -> Side? {
            guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
            return point.x <= edge ? .brightness : (point.x >= 1 - edge ? .volume : nil)
        }
        func reject() { rejected = true; contact = nil; isControlling = false }
        // Fingers naturally land in separate frames. Allow a stationary first finger
        // briefly, but never turn an ordinary one-finger swipe into a control gesture.
        if touches.count == 1, contact == nil, let first = touches.first {
            guard sideOf(first) != nil else { reject(); return nil }
            if let landing, let landingTime {
                guard first.id == landing.id, time - landingTime <= 0.25,
                      abs(first.x - landing.x) < 0.025, abs(first.y - landing.y) < 0.025 else {
                    reject(); return nil
                }
            } else { landing = first; landingTime = time }
            return nil
        }
        guard touches.count == 2, touches[0].id != touches[1].id,
              let side = sideOf(touches[0]), sideOf(touches[1]) == side else {
            reject(); return nil
        }
        if contact == nil, let landing, let landingTime {
            guard time - landingTime <= 0.25, let first = touches.first(where: { $0.id == landing.id }),
                  abs(first.x - landing.x) < 0.025, abs(first.y - landing.y) < 0.025 else {
                reject(); return nil
            }
        }
        let ids = touches.map(\.id).sorted()
        let touch = EdgeTouch(id: 0, x: (touches[0].x + touches[1].x) / 2,
                              y: (touches[0].y + touches[1].y) / 2)
        guard var current = contact else {
            contact = Contact(ids: ids, side: side, x: touch.x, y: touch.y, lastY: touch.y, began: time)
            return nil
        }
        guard current.ids == ids, current.side == side, abs(touch.x - current.x) < 0.06 else {
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
