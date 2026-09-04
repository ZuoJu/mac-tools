import CoreGraphics

/// A fixed cursor anchor enforced by the hardware event tap, including while the app
/// is in the background. No global cursor disassociation survives a crash or shutdown.
public final class CursorLock {
    public var isLocked: Bool { anchor != nil }
    private var anchor: CGPoint?
    private let position: () -> CGPoint?
    private let warp: (CGPoint) -> Bool
    public init(position: @escaping () -> CGPoint? = { CGEvent(source: nil)?.location },
                warp: @escaping (CGPoint) -> Bool = { CGWarpMouseCursorPosition($0) == .success }) {
        self.position = position
        self.warp = warp
    }
    @discardableResult
    public func setLocked(_ locked: Bool) -> Bool {
        guard locked != isLocked else { return true }
        if locked {
            guard let point = position(), point.x.isFinite, point.y.isFinite else { return false }
            anchor = point
        } else {
            anchor = nil
        }
        return true
    }
    @discardableResult
    public func holdPosition() -> Bool {
        guard let anchor else { return true }
        return warp(anchor)
    }
}
