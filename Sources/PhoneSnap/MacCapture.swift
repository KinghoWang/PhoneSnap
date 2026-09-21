import AppKit
import Carbon.HIToolbox

enum MacCaptureMode { case region, window, screen }

@MainActor
final class MacCapture {
    static let shared = MacCapture()
    private var process: Process?
    private var permissionGuide: CapturePermissionGuide?
    private var regionSession: RegionSelectionSession?
    private var regionWindowFrames: [CGRect] = []
    private var preparingRegion = false
    private var extractionResult: TextExtractionResultController?
    var onCaptured: ((URL) -> Void)?

    func finishCapture(data: Data, store: ImageStore = ImageStore()) throws {
        let saved = try store.save(data: data, context: ScreenshotReceiveContext(source: .mac))
        onCaptured?(saved)
    }

    func capture(_ mode: MacCaptureMode) {
        guard process == nil, !preparingRegion, regionSession == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            if permissionGuide == nil { permissionGuide = CapturePermissionGuide() }
            permissionGuide?.present()
            return
        }
        permissionGuide?.close()
        if mode == .region { beginRegionSelection(); return }
        let captureURL = FileManager.default.temporaryDirectory.appendingPathComponent("phonesnap-capture-\(UUID().uuidString).png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = Self.arguments(for: mode, destination: captureURL)
        capture.standardOutput = FileHandle.nullDevice
        capture.standardError = FileHandle.nullDevice
        process = capture
        NSApp.hide(nil)
        capture.terminationHandler = { [weak self] completed in
            DispatchQueue.main.async {
                self?.process = nil
                NSApp.unhideWithoutActivation()
                defer { try? FileManager.default.removeItem(at: captureURL) }
                guard completed.terminationStatus == 0, let bytes = try? Data(contentsOf: captureURL) else { return }
                do {
                    try self?.finishCapture(data: bytes)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "截图未能保存"
                    alert.informativeText = "请检查截图文件夹权限和磁盘空间。"
                    alert.runModal()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            do { try capture.run() }
            catch {
                self?.process = nil
                NSApp.unhideWithoutActivation()
                let alert = NSAlert()
                alert.messageText = "无法启动系统截图工具"
                alert.runModal()
            }
        }
    }

    private func beginRegionSelection() {
        let frames = NSScreen.screens.map(\.frame)
        guard !frames.isEmpty else { showCaptureError("无法访问显示器，请在已登录的 Mac 桌面重试。"); return }
        preparingRegion = true
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.regionWindowFrames = WindowSnapSelection.visibleWindows()
            self?.captureDisplay(frames: frames, index: 0, snapshots: [])
        }
    }

    private func captureDisplay(frames: [NSRect], index: Int, snapshots: [(NSRect, NSImage)]) {
        guard index < frames.count else {
            preparingRegion = false
            NSApp.unhideWithoutActivation()
            regionSession = RegionSelectionSession(snapshots: snapshots, windowFrames: regionWindowFrames) { [weak self] action, image, screenFrame in
                self?.regionSession?.close()
                self?.regionSession = nil
                self?.performSelectionAction(action, image: image, screenFrame: screenFrame)
            }
            regionSession?.show()
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phonesnap-selection-\(UUID().uuidString).png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-D", "\(index + 1)", "-t", "png", url.path]
        capture.standardOutput = FileHandle.nullDevice
        capture.standardError = FileHandle.nullDevice
        process = capture
        capture.terminationHandler = { [weak self] completed in
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: url) }
                guard let self else { return }
                self.process = nil
                guard completed.terminationStatus == 0, let data = try? Data(contentsOf: url),
                      let image = NSImage(data: data) else {
                    self.preparingRegion = false
                    NSApp.unhideWithoutActivation()
                    self.showCaptureError("读取屏幕失败。请确认屏幕录制权限已生效后重试。")
                    return
                }
                self.captureDisplay(frames: frames, index: index + 1, snapshots: snapshots + [(frames[index], image)])
            }
        }
        do { try capture.run() }
        catch {
            process = nil
            preparingRegion = false
            NSApp.unhideWithoutActivation()
            showCaptureError("无法启动系统截图工具。")
        }
    }

    private func performSelectionAction(_ action: RegionSelectionAction, image: NSImage?, screenFrame: NSRect?) {
        guard action != .cancel, let image else { return }
        switch action {
        case .pin: PinnedImagePresenter.shared.pin(image: image, at: screenFrame?.origin)
        case .edit: ScreenshotEditor.shared.open(image: image)
        case .ocr: extractSelectionText(image)
        case .copy, .save:
            guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let data = NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:]) else {
                showCaptureError("无法处理选区图片，请重新框选。"); return
            }
            if action == .copy {
                NSPasteboard.general.clearContents()
                if !NSPasteboard.general.setData(data, forType: .png) { showCaptureError("图片复制失败，请重试。") }
            } else {
                do { try finishCapture(data: data) }
                catch { showCaptureError("截图未能保存，请检查截图文件夹权限和磁盘空间。") }
            }
        case .cancel: break
        }
    }

    private func extractSelectionText(_ image: NSImage) {
        guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        extractionResult?.close()
        let result = TextExtractionResultController(text: "正在本机识别选区文字…",
            sourceDescription: "仅识别刚才框选的区域，在本机完成；结果可修改，可能有错字，不会自动写入剪贴板。")
        extractionResult = result
        result.onClosed = { [weak self, weak result] in
            if self?.extractionResult === result { self?.extractionResult = nil }
        }
        result.textView.isEditable = false
        result.window?.center()
        result.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak result] in
            let text = Result { try TextExtraction.recognize(in: pixels) }
            DispatchQueue.main.async {
                guard let result, self?.extractionResult === result, result.window?.isVisible == true else { return }
                result.textView.isEditable = true
                switch text {
                case .success(let value):
                    result.textView.string = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未识别到文字，请尝试更清晰的选区。" : value
                case .failure: result.textView.string = "本机文字识别失败，请稍后重试。图片未上传，剪贴板未写入。"
                }
            }
        }
    }

    private func showCaptureError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "截图未完成"
        alert.informativeText = message
        alert.runModal()
    }

    static func arguments(for mode: MacCaptureMode, destination: URL) -> [String] {
        switch mode {
        case .region: return ["-x", "-i", "-s", "-t", "png", destination.path]
        case .window: return ["-x", "-i", "-w", "-o", "-t", "png", destination.path]
        case .screen: return ["-x", "-m", "-t", "png", destination.path]
        }
    }
}

private func captureHotkeyHandler(_ call: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    var identifier = EventHotKeyID()
    guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                            MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
          identifier.signature == 0x50484E53, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
    DispatchQueue.main.async { MacCapture.shared.capture(.region) }
    return noErr
}

@MainActor
final class CaptureHotkey: NSObject, NSWindowDelegate {
    static let shared = CaptureHotkey()
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var recorder: Any?
    private var settingsWindow: NSWindow?
    private(set) var displayName = "⌘⌥2"
    private(set) var isRegistered = false

    func start() {
        guard handler == nil else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), captureHotkeyHandler, 1, &event, nil, &handler)
        let defaults = UserDefaults.standard
        let key = defaults.object(forKey: "PhoneSnapCaptureKey") as? UInt32 ?? UInt32(kVK_ANSI_2)
        let modifiers = defaults.object(forKey: "PhoneSnapCaptureModifiers") as? UInt32 ?? UInt32(cmdKey | optionKey)
        displayName = defaults.string(forKey: "PhoneSnapCaptureDisplay") ?? "⌘⌥2"
        register(key: key, modifiers: modifiers)
    }

    private func register(key: UInt32, modifiers: UInt32) {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        hotkey = nil
        let identifier = EventHotKeyID(signature: 0x50484E53, id: 1)
        isRegistered = RegisterEventHotKey(key, modifiers, identifier, GetApplicationEventTarget(), 0, &hotkey) == noErr
    }

    func configure() {
        stopRecording()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 150), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = "设置 Mac 区域截图快捷键"
        let label = NSTextField(wrappingLabelWithString: "当前：\(displayName)\(isRegistered ? "" : "（被占用或注册失败）")\n请按新组合键，必须包含 ⌘、⌥ 或 ⌃。按 Esc 取消。")
        label.frame = NSRect(x: 20, y: 25, width: 420, height: 100)
        window.contentView?.addSubview(label)
        settingsWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, window.isKeyWindow else { return event }
            if event.keyCode == 53 { self.stopRecording(); return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.intersection([.command, .option, .control]).isEmpty,
                  let character = event.charactersIgnoringModifiers, !character.isEmpty else { return nil }
            var carbon: UInt32 = 0
            var name = ""
            if flags.contains(.control) { carbon |= UInt32(controlKey); name += "⌃" }
            if flags.contains(.option) { carbon |= UInt32(optionKey); name += "⌥" }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey); name += "⇧" }
            if flags.contains(.command) { carbon |= UInt32(cmdKey); name += "⌘" }
            self.register(key: UInt32(event.keyCode), modifiers: carbon)
            guard self.isRegistered else { label.stringValue = "组合键被占用，当前未注册截图快捷键。请换一个组合键。"; return nil }
            self.displayName = name + character.uppercased()
            UserDefaults.standard.set(UInt32(event.keyCode), forKey: "PhoneSnapCaptureKey")
            UserDefaults.standard.set(carbon, forKey: "PhoneSnapCaptureModifiers")
            UserDefaults.standard.set(self.displayName, forKey: "PhoneSnapCaptureDisplay")
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        settingsWindow?.close()
        settingsWindow = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        settingsWindow = nil
    }
}
