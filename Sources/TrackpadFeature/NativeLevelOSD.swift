import AppKit
import TrackpadBridge

public enum NativeLevelOSD {
    @discardableResult
    public static func show(side: EdgeGesture.Side, value: Double, fadeMilliseconds: UInt32 = 1200) -> Bool {
        guard value.isFinite else { return false }
        let fraction = min(1, max(0, value))
        let display = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let id = (display?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
        let image: Int64 = side == .brightness ? 1 : (fraction > 0 ? 3 : 4)
        return MTShowSystemOSD(image, id, UInt32((fraction * 100).rounded()), fadeMilliseconds) != 0
    }
}
