import AppKit
import XCTest
@testable import PhoneSnap

final class RedactionStyleTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor func testRenderedMosaicAndOCRUseSameEditedPixels() throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for column in 0..<200 {
            context.setFillColor(column.isMultiple(of: 2) ? NSColor.white.cgColor : NSColor.black.cgColor)
            context.fill(CGRect(x: column, y: 0, width: 1, height: 200))
        }
        let original = try XCTUnwrap(context.makeImage())
        let document = GrabbitDocument(image: NSImage(cgImage: original, size: NSSize(width: 200, height: 200)))
        document.addPrivacyRegions([CGRect(x: 0, y: 0, width: 1, height: 1)], pixelated: true)
        let editor = EditorWindowController(document: document)
        let rendered = try XCTUnwrap(editor.renderedImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let snapshot = try XCTUnwrap(editor.makeOCRSnapshot(region: nil))
        func png(_ image: CGImage) throws -> Data {
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        }
        XCTAssertNotEqual(try png(original), try png(rendered))
        XCTAssertEqual(try png(rendered), try png(snapshot))
        document.changeRedaction(id: try XCTUnwrap(document.blurRegions.first?.id), pixelated: false, color: .red, intensity: 80)
        let solid = NSBitmapImageRep(cgImage: try XCTUnwrap(editor.makeOCRSnapshot(region: nil)))
        let center = try XCTUnwrap(solid.colorAt(x: 100, y: 100)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(center.redComponent, 1, accuracy: 0.02)
        XCTAssertEqual(center.greenComponent, 0, accuracy: 0.02)
        document.removeWindowController(editor)
    }

    @MainActor func testToolbarExposesStyleAndIntensity() throws {
        _ = NSApplication.shared
        let document = GrabbitDocument(image: NSImage(size: NSSize(width: 200, height: 200)))
        let editor = EditorWindowController(document: document)
        let root = try XCTUnwrap(editor.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let controls = descendants(root)
        let style = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first)
        let slider = try XCTUnwrap(controls.compactMap { $0 as? NSSlider }.first)
        let color = try XCTUnwrap(controls.compactMap { $0 as? NSColorWell }.first)
        XCTAssertEqual(style.itemTitles, ["纯色", "马赛克"])
        XCTAssertFalse(slider.isEnabled)
        style.selectItem(at: 1)
        style.sendAction(try XCTUnwrap(style.action), to: style.target)
        XCTAssertTrue(slider.isEnabled)
        XCTAssertFalse(color.isEnabled)
        XCTAssertGreaterThan(slider.frame.width, 0)
        document.removeWindowController(editor)
    }

    @MainActor func testStylesAndConversionPreserveGeometryAndUndo() throws {
        let document = GrabbitDocument(image: NSImage(size: NSSize(width: 200, height: 200)))
        document.undoManager?.groupsByEvent = false
        let region = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)
        document.addPrivacyRegions([region], pixelated: true, color: .red, intensity: 70)
        let mask = try XCTUnwrap(document.blurRegions.first)
        XCTAssertEqual(mask.style, .pixelate)
        XCTAssertEqual(mask.intensity, 70)
        document.changeRedaction(id: mask.id, pixelated: false, color: NSColor.red.withAlphaComponent(0.2), intensity: 90)
        let solid = try XCTUnwrap(document.shapes.first)
        XCTAssertEqual(solid.id, mask.id)
        XCTAssertEqual(solid.rect, region)
        XCTAssertEqual(solid.zOrder, mask.zOrder)
        XCTAssertEqual(solid.fillColor.alphaComponent, 1)
        XCTAssertTrue(document.blurRegions.isEmpty)
        document.undoManager?.undo()
        XCTAssertTrue(document.shapes.isEmpty)
        XCTAssertEqual(document.blurRegions.first?.id, mask.id)
        document.undoManager?.redo()
        XCTAssertEqual(document.shapes.first?.id, mask.id)
    }

    @MainActor func testDefaultPrivacyRemainsOpaqueBlack() throws {
        let document = GrabbitDocument(image: NSImage(size: NSSize(width: 200, height: 200)))
        document.addPrivacyRegions([CGRect(x: 0, y: 0, width: 1, height: 1)])
        XCTAssertTrue(document.blurRegions.isEmpty)
        XCTAssertEqual(try XCTUnwrap(document.shapes.first).fillColor, .black)
    }
}
