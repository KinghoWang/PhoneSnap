import AppKit

struct RecentScreenshotSelection {
    private(set) var selected: Set<URL> = []
    private var anchor: URL?
    private var marqueeBase: Set<URL> = []

    mutating func click(_ url: URL, ordered: [URL], modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchor, let start = ordered.firstIndex(of: anchor), let end = ordered.firstIndex(of: url) {
            let range = Set(ordered[min(start, end)...max(start, end)])
            selected = modifiers.contains(.command) ? selected.union(range) : range
        } else if modifiers.contains(.command) {
            if !selected.insert(url).inserted { selected.remove(url) }
            anchor = url
        } else {
            selected = [url]
            anchor = url
        }
    }

    mutating func retain(_ available: Set<URL>) {
        selected.formIntersection(available)
        marqueeBase.formIntersection(available)
        if let anchor, !available.contains(anchor) { self.anchor = nil }
    }

    mutating func selectAll(_ urls: [URL]) { selected = Set(urls) }

    func copyTarget(in ordered: [URL]) -> URL? {
        if selected.isEmpty { return ordered.first }
        guard selected.count == 1 else { return nil }
        return ordered.first { selected.contains($0) }
    }

    mutating func beginMarquee(additive: Bool) {
        marqueeBase = additive ? selected : []
        selected = marqueeBase
    }

    mutating func marquee(from start: CGPoint, to end: CGPoint, frames: [URL: CGRect]) {
        let rect = Self.rectangle(from: start, to: end)
        selected = marqueeBase.union(frames.compactMap { rect.intersects($0.value) ? $0.key : nil })
    }

    static func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
    }
}

enum RecentScreenshotDeletion {
    static func perform(_ urls: [URL], trash: (URL) throws -> Void) -> (removed: [URL], failed: [URL]) {
        var seen: Set<URL> = []
        var removed: [URL] = []
        var failed: [URL] = []
        for url in urls where seen.insert(url).inserted {
            do { try trash(url); removed.append(url) }
            catch { failed.append(url) }
        }
        return (removed, failed)
    }
}

@MainActor
final class RecentScreenshotSelectionView: NSView {
    var onBegin: ((NSEvent.ModifierFlags) -> Void)?
    var onMarquee: ((CGPoint, CGPoint) -> Void)?
    var onDelete: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var onCopy: (() -> Void)?
    private var start: CGPoint?
    private let marqueeLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        marqueeLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        marqueeLayer.strokeColor = NSColor.controlAccentColor.cgColor
        marqueeLayer.lineWidth = 1
        marqueeLayer.zPosition = 100
        layer?.addSublayer(marqueeLayer)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSStackView ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        start = convert(event.locationInWindow, from: nil)
        onBegin?(event.modifierFlags)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        autoscroll(with: event)
        let end = convert(event.locationInWindow, from: nil)
        marqueeLayer.path = CGPath(rect: RecentScreenshotSelection.rectangle(from: start, to: end), transform: nil)
        onMarquee?(start, end)
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
        marqueeLayer.path = nil
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            if !event.isARepeat { onCopy?() }
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?(); return }
        if event.keyCode == 53 { onBegin?([]); marqueeLayer.path = nil; start = nil; return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
            onSelectAll?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class RecentScreenshotsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
