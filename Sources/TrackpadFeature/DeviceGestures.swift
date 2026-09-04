import Foundation

/// Finger identifiers and device timestamps are local to each trackpad.
/// Only one armed gesture owns the system controls and cursor at a time.
public struct DeviceGestures {
    private var gestures: [UInt64: EdgeGesture] = [:]
    private var blocked: Set<UInt64> = []
    private var lastActiveFrame = -Double.infinity
    public private(set) var activeDeviceID: UInt64?
    public var isArmed: Bool { activeDeviceID != nil }
    public var isControlling: Bool { activeDeviceID.flatMap { gestures[$0]?.isControlling } ?? false }
    public init() {}

    public mutating func reset() { self = DeviceGestures() }

    public mutating func cancelUntilLift() {
        blocked.formUnion(gestures.keys)
        gestures.removeAll()
        activeDeviceID = nil
    }

    @discardableResult
    public mutating func expire(at time: Double) -> Bool {
        guard isArmed, time - lastActiveFrame > 0.3 else { return false }
        cancelUntilLift()
        return true
    }

    public mutating func update(deviceID: UInt64, touches: [EdgeTouch], at timestamp: Double,
                                receivedAt: Double, width: Double, sensitivity: Double) -> EdgeGesture.Change? {
        expire(at: receivedAt)
        if touches.isEmpty {
            gestures.removeValue(forKey: deviceID)
            blocked.remove(deviceID)
            if activeDeviceID == deviceID { activeDeviceID = nil }
            return nil
        }
        guard !blocked.contains(deviceID) else { return nil }
        if let activeDeviceID, activeDeviceID != deviceID {
            // A finger already resting on another pad must lift before taking over.
            blocked.insert(deviceID)
            gestures.removeValue(forKey: deviceID)
            return nil
        }
        var gesture = gestures[deviceID] ?? EdgeGesture()
        let change = gesture.update(touches, at: timestamp, width: width, sensitivity: sensitivity)
        gestures[deviceID] = gesture
        if gesture.isArmed {
            activeDeviceID = deviceID
            lastActiveFrame = receivedAt
            for other in Array(gestures.keys) where other != deviceID {
                blocked.insert(other)
                gestures.removeValue(forKey: other)
            }
        } else if activeDeviceID == deviceID {
            activeDeviceID = nil
        }
        return change
    }
}
