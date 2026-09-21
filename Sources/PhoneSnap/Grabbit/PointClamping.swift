import AppKit

extension CGPoint {
    func clamped(to rect: CGRect) -> CGPoint {
        CGPoint(x: max(rect.minX, min(rect.maxX, x)), y: max(rect.minY, min(rect.maxY, y)))
    }
}
