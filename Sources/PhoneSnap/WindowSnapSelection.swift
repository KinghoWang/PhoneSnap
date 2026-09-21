import AppKit

struct WindowSnapSelection {
    let bounds: CGRect
    let windows: [CGRect]
    var rect = CGRect.zero
    var committed = false
    private var anchor: CGPoint?
    private var initial = CGRect.zero
    private var moved = false
    private var edges: [CGRectEdge] = []

    init(bounds: CGRect, windows: [CGRect]) {
        self.bounds = bounds
        self.windows = windows
    }

    static func appKitRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    @MainActor static func visibleWindows() -> [CGRect] {
        guard let primary = NSScreen.screens.first,
              let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let owner = entry[kCGWindowOwnerPID as String] as? Int, owner != Int(ProcessInfo.processInfo.processIdentifier),
                  let alpha = entry[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dictionary), frame.width >= 3, frame.height >= 3 else { return nil }
            return appKitRect(frame, primaryTop: primary.frame.maxY)
        }
    }

    mutating func hover(at point: CGPoint) {
        guard !committed, anchor == nil else { return }
        guard bounds.contains(point) else { rect = .zero; return }
        rect = windows.first { $0.contains(point) }?.intersection(bounds) ?? .zero
    }

    mutating func begin(at point: CGPoint) {
        edges = []
        if committed, rect.insetBy(dx: -6, dy: -6).contains(point) {
            if abs(point.x - rect.minX) <= 6 { edges.append(.minXEdge) }
            else if abs(point.x - rect.maxX) <= 6 { edges.append(.maxXEdge) }
            if abs(point.y - rect.minY) <= 6 { edges.append(.minYEdge) }
            else if abs(point.y - rect.maxY) <= 6 { edges.append(.maxYEdge) }
        }
        if edges.isEmpty {
            committed = false
            hover(at: point)
        }
        initial = rect
        anchor = point
        moved = false
    }

    mutating func drag(to point: CGPoint) {
        guard let anchor else { return }
        if hypot(point.x - anchor.x, point.y - anchor.y) >= 3 { moved = true }
        guard moved else { return }
        if edges.isEmpty {
            rect = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                          width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)).intersection(bounds)
        } else {
            let start = CGPoint(x: edges.contains(.minXEdge) ? point.x : initial.minX,
                                y: edges.contains(.minYEdge) ? point.y : initial.minY)
            let end = CGPoint(x: edges.contains(.maxXEdge) ? point.x : initial.maxX,
                              y: edges.contains(.maxYEdge) ? point.y : initial.maxY)
            rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
        }
    }

    mutating func end(at point: CGPoint) {
        guard anchor != nil else { return }
        drag(to: point)
        anchor = nil
        committed = !rect.isNull && rect.width >= 3 && rect.height >= 3
        edges = []
    }

    @discardableResult mutating func reset() -> Bool {
        let hadSelection = committed || anchor != nil
        committed = false
        anchor = nil
        rect = .zero
        edges = []
        return hadSelection
    }
}
