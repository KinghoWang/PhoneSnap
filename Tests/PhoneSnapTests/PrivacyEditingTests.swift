import AppKit
import XCTest
import Vision
@testable import PhoneSnap

final class PrivacyEditingTests: XCTestCase {
    @MainActor func testCaptureModesUseSeparateArgumentsWithoutShell() {
        let output = URL(fileURLWithPath: "/tmp/example with spaces.png")
        XCTAssertEqual(MacCapture.arguments(for: .region, destination: output), ["-x", "-i", "-s", "-t", "png", output.path])
        XCTAssertTrue(MacCapture.arguments(for: .window, destination: output).contains("-w"))
        XCTAssertFalse(MacCapture.arguments(for: .screen, destination: output).contains("-i"))
        XCTAssertTrue(MacCapture.arguments(for: .screen, destination: output).contains("-m"))
    }

    @MainActor func testCanvasAcceptsArrowAndManualMaskGestures() throws {
        _ = NSApplication.shared
        let document = GrabbitDocument(image: try makeSyntheticImage())
        let editor = EditorWindowController(document: document)
        let root = try XCTUnwrap(editor.window?.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let overlay = try XCTUnwrap(descendants(root).compactMap { $0 as? AnnotationOverlay }.first)
        let window = try XCTUnwrap(editor.window)
        func drag() throws {
            let start = overlay.convert(CGPoint(x: 40, y: 60), to: nil)
            let end = overlay.convert(CGPoint(x: 220, y: 160), to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: end, modifierFlags: [], timestamp: 0.1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: end, modifierFlags: [], timestamp: 0.2, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            overlay.mouseDown(with: down)
            overlay.mouseDragged(with: moved)
            overlay.mouseUp(with: up)
        }
        overlay.activeTool = .arrow
        try drag()
        XCTAssertEqual(document.arrows.count, 1)
        document.removeArrow(id: try XCTUnwrap(document.arrows.first).id)
        overlay.activeTool = .shape
        overlay.currentFillColor = .black
        overlay.currentBorderWeight = 0
        try drag()
        XCTAssertEqual(document.shapes.count, 1)
        XCTAssertEqual(document.shapes.first?.fillColor, .black)
        XCTAssertNotNil(editor.renderedImage())
        document.removeWindowController(editor)
    }

    @MainActor private func makeSyntheticImage() throws -> NSImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.black]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black]
        ("合成测试图片 · 非真实个人资料" as NSString).draw(at: CGPoint(x: 42, y: 920), withAttributes: title)
        let lines = ["姓名：测试用户", "地址：测试市示例路123号", "Phone: 13800000000", "Email: demo@example.invalid", "API_KEY: example-not-a-real-key", "普通内容：本次会议讨论截图编辑功能。"]
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: CGPoint(x: 140, y: 785 - index * 95), withAttributes: body)
        }
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: CGRect(x: 35, y: 770, width: 80, height: 80)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: CGRect(x: 52, y: 790, width: 45, height: 45)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: NSSize(width: 800, height: 1000))
    }

    @MainActor func testSyntheticVisionAndEditorLayout() throws {
        _ = NSApplication.shared
        let image = try makeSyntheticImage()
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let start = Date()
        let regions = try PrivacyDetector.detect(in: cgImage)
        print("Synthetic local Vision duration: \(Date().timeIntervalSince(start)) seconds; candidates: \(regions.count)")
        XCTAssertTrue(regions.contains { $0.kind == .email })
        XCTAssertTrue(regions.contains { $0.kind == .phone })
        XCTAssertTrue(regions.contains { $0.kind == .name })
        XCTAssertTrue(regions.contains { $0.kind == .address })
        XCTAssertTrue(regions.contains { $0.kind == .secret })
        let document = GrabbitDocument(image: image)
        let editor = EditorWindowController(document: document)
        document.addPrivacyRegions(regions.map(\.rect))
        let root = try XCTUnwrap(editor.window?.contentView)
        root.layoutSubtreeIfNeeded()
        editor.showWindow(nil)
        editor.window?.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(document.currentImage.size, NSSize(width: 800, height: 1000))
        if let folder = ProcessInfo.processInfo.environment["PHONESNAP_QA_DIR"] {
            let destination = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent("editor-synthetic-ui.png"))
            let exported = try XCTUnwrap(editor.renderedImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            try XCTUnwrap(NSBitmapImageRep(cgImage: exported).representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent("synthetic-redacted.png"))
            try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent("synthetic-original.png"))
            if ProcessInfo.processInfo.environment["PHONESNAP_QA_WINDOW"] == "1", let window = editor.window {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber), destination.appendingPathComponent("editor-window.png").path]
                try capture.run()
                capture.waitUntilExit()
                XCTAssertEqual(capture.terminationStatus, 0)
            }
        }
        document.removeWindowController(editor)
        editor.window?.orderOut(nil)
    }

    @MainActor func testCropFlattensMasksAndUndoRestoresDocument() throws {
        _ = NSApplication.shared
        let image = try makeSyntheticImage()
        let document = GrabbitDocument(image: image)
        let editor = EditorWindowController(document: document)
        document.undoManager?.groupsByEvent = false
        document.addPrivacyRegions([CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.3)])
        document.undoManager?.beginUndoGrouping()
        editor.crop(to: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        document.undoManager?.endUndoGrouping()
        XCTAssertEqual(document.currentImage.size.height, 500)
        XCTAssertTrue(document.shapes.isEmpty)
        let exported = try XCTUnwrap(editor.renderedImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let masked = try XCTUnwrap(NSBitmapImageRep(cgImage: exported).colorAt(x: 400, y: 200)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(masked.redComponent, 0.02)
        document.undoManager?.undo()
        XCTAssertEqual(document.currentImage.size.height, 1000)
        XCTAssertEqual(document.shapes.count, 1)
        document.removeWindowController(editor)
    }

    @MainActor func testTwoEditorsKeepIndependentImagesAndUndo() throws {
        _ = NSApplication.shared
        let first = GrabbitDocument(image: try makeSyntheticImage())
        let second = GrabbitDocument(image: try makeSyntheticImage())
        let firstEditor = EditorWindowController(document: first)
        let secondEditor = EditorWindowController(document: second)
        first.addPrivacyRegions([CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)])
        XCTAssertTrue(second.shapes.isEmpty)
        XCTAssertFalse(first.undoManager === second.undoManager)
        first.removeWindowController(firstEditor)
        second.removeWindowController(secondEditor)
    }

    func testSensitiveTextCategories() {
        XCTAssertTrue(PrivacyDetector.kinds(in: "邮箱: demo@example.invalid").contains(.email))
        XCTAssertTrue(PrivacyDetector.kinds(in: "联系电话 13800000000").contains(.phone))
        XCTAssertTrue(PrivacyDetector.kinds(in: "姓名：测试用户").contains(.name))
        XCTAssertTrue(PrivacyDetector.kinds(in: "地址：测试市示例路123号").contains(.address))
        XCTAssertTrue(PrivacyDetector.kinds(in: "API_KEY = example-not-a-real-key").contains(.secret))
        XCTAssertTrue(PrivacyDetector.kinds(in: "APL_KEY = example-not-a-real-key").contains(.secret))
        XCTAssertTrue(PrivacyDetector.kinds(in: "身份证：110101199001010000").contains(.identity))
        XCTAssertTrue(PrivacyDetector.kinds(in: "银行卡：0000 0000 0000 0000").contains(.account))
        XCTAssertTrue(PrivacyDetector.kinds(in: "截图编辑工具，今天开会讨论产品").isEmpty)
    }

    func testAvatarHeuristicUsesPixelAspectNotNormalizedAspect() {
        let imageSize = CGSize(width: 1000, height: 2000)
        XCTAssertTrue(PrivacyDetector.isAvatarCandidate(CGRect(x: 0.02, y: 0.5, width: 0.08, height: 0.04), imageSize: imageSize))
        XCTAssertFalse(PrivacyDetector.isAvatarCandidate(CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4), imageSize: imageSize))
    }

    @MainActor func testRedactionIsOpaqueInExportAndUndoKeepsOriginal() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: NSSize(width: 100, height: 100))
        let document = GrabbitDocument(image: image)
        document.borderEnabled = false
        document.shadowEnabled = false
        document.addPrivacyRegions([CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)])
        let flattened = try XCTUnwrap(document.flattenedForSharing()?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let pixel = try XCTUnwrap(NSBitmapImageRep(cgImage: flattened).colorAt(x: 50, y: 50)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(pixel.redComponent, 0.02)
        XCTAssertEqual(pixel.alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(flattened.width, 100)
        document.undoManager?.undo()
        XCTAssertTrue(document.shapes.isEmpty)
        let original = try XCTUnwrap(document.currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertGreaterThan(try XCTUnwrap(NSBitmapImageRep(cgImage: original).colorAt(x: 50, y: 50)?.usingColorSpace(.deviceRGB)).redComponent, 0.98)
    }
}
