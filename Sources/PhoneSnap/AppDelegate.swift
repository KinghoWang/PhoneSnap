import AppKit
import CryptoKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL { ScreenshotEditor.shared.open(fileURL: url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ScreenshotEditor.shared.canTerminate() ? .terminateNow : .terminateCancel
    }
    private var statusItemController: StatusItemController!
    private var presenter: ThumbnailPresenter!
    private var recentPresenter: RecentScreenshotsPresenter!
    private var cameraBridge: CameraBridge!
    private var wirelessReceiver: WirelessReceiver!
    private var wirelessSetupWindow: WirelessSetupWindowController!
    private var settingsWindow: SettingsWindowController!
    private var nearbySetup: NearbySetupController!
    private var relaySetup: RelaySetupController!
    private let store = ImageStore()
    /// Assigned in `applicationDidFinishLaunching`, after the enablement
    /// migration has had a chance to observe whether a pairing already
    /// existed — `WirelessPairing.load()` provisions one as a side effect.
    private var wirelessPairing: WirelessPairing!
    private var wirelessEnabled = false
    private let wirelessPort: UInt16 = {
        ProcessInfo.processInfo.environment["PHONESNAP_WIRELESS_PORT"].flatMap(UInt16.init) ?? 8472
    }()
    /// How many recent screenshots the generated Shortcut sends per run.
    /// Baked into the Shortcut at download time — changing it requires
    /// re-downloading and re-adding the Shortcut on the iPhone.
    private let wirelessBatchCount: Int = {
        let value = ProcessInfo.processInfo.environment["PHONESNAP_BATCH_COUNT"].flatMap(Int.init) ?? 10
        return min(max(value, 1), 50)
    }()
    private var wirelessState: WirelessReceiver.State = .stopped

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Order matters: the migration inspects the stored pairing, which
        // loading one would create.
        wirelessEnabled = WirelessSettings.resolveEnabled()
        wirelessPairing = WirelessPairing.load()

        presenter = ThumbnailPresenter()
        recentPresenter = RecentScreenshotsPresenter()
        MacCapture.shared.onCaptured = { [weak self] url in self?.surface(fileURL: url, activate: true) }
        CaptureHotkey.shared.start()
        wirelessSetupWindow = WirelessSetupWindowController(infoProvider: { [weak self] in
            self?.wirelessSetupInfo() ?? WirelessSetupInfo(
                pairID: "unavailable",
                port: 0,
                receiverState: .failed("app unavailable"),
                hostName: "localhost",
                lanIP: nil
            )
        })
        settingsWindow = SettingsWindowController(
            wirelessEnabled: { [weak self] in self?.wirelessEnabled ?? false },
            onToggleWireless: { [weak self] enabled in self?.setWirelessEnabled(enabled) },
            onModeChanged: { [weak self] mode in
                Log.info("Thumbnail display set to \(mode.rawValue)")
                self?.statusItemController.refresh()
            }
        )
        nearbySetup = NearbySetupController(receive: { [weak self] data, context in
            guard let self else { return false }
            if case .accepted = self.deliverWireless(data: data, deduplicate: false, context: context) { return true }
            return false
        })
        relaySetup = RelaySetupController(receive: { [weak self] data, context in
            guard let self else { return false }
            if case .accepted = self.deliverWireless(data: data, deduplicate: false, context: context) { return true }
            return false
        })
        statusItemController = StatusItemController(
            wiredStatus: { [weak self] in
                let names = self?.cameraBridge?.connectedDeviceNames ?? []
                if names.isEmpty {
                    return "有线：未连接 iPhone（无线模式无需插线）"
                }
                return "有线：已连接 \(names.joined(separator: ", "))"
            },
            wirelessStatus: { [weak self] in
                guard let self else { return WirelessReceiver.State.stopped.menuTitle }
                guard self.wirelessEnabled else {
                    return "无线接收：已关闭"
                }
                return self.wirelessState.menuTitle
            },
            wirelessEnabled: { [weak self] in self?.wirelessEnabled ?? false },
            onToggleWireless: { [weak self] enabled in
                self?.setWirelessEnabled(enabled)
            },
            onOpenSettings: { [weak self] in self?.settingsWindow.show() },
            onRotatePairing: { [weak self] in self?.confirmRotatePairing() },
            onShowLast: { [weak self] in self?.showLastScreenshot() },
            onRevealFolder: { [weak self] in self?.store.revealInFinder() },
            onSetupWireless: { [weak self] in
                // Setting wireless up implies wanting it to run.
                self?.setWirelessEnabled(true)
                self?.wirelessSetupWindow.show()
            },
            onSetupNearby: { [weak self] in self?.nearbySetup.show() },
            onSetupRelay: { [weak self] in self?.relaySetup.show() }
        )

        wirelessReceiver = makeWirelessReceiver()

        // ImageCaptureCore watches trusted USB-connected iPhones and emits
        // new camera-roll items created after app startup.
        cameraBridge = CameraBridge { [weak self] data, name, confirmedUSB in
            guard let self else { return }
            _ = self.deliver(data: data, source: "Camera(\(name))", confirmedUSB: confirmedUSB)
        }
        cameraBridge.onDevicesChanged = { [weak self] names in
            self?.statusItemController.setConnected(!names.isEmpty)
            self?.statusItemController.refresh()
        }

        if wirelessEnabled {
            startWirelessReceiver()
        } else {
            Log.info("Wireless receiver is off; no network listener started")
        }

        Log.info("Starting wired iPhone screenshot watcher")
        cameraBridge.start()
        relaySetup.restore()
    }

    func applicationWillTerminate(_ notification: Notification) {
        nearbySetup?.stop()
        relaySetup?.stop()
        wirelessReceiver?.stop()
        cameraBridge?.stop()
    }

    // MARK: wireless lifecycle

    private func makeWirelessReceiver() -> WirelessReceiver {
        WirelessReceiver(
            port: wirelessPort,
            pairing: wirelessPairing,
            batchCount: wirelessBatchCount,
            uploadHandler: { [weak self] data in
                guard let self else { return .storageFailure }
                return self.deliverWireless(data: data)
            },
            stateHandler: { [weak self] state in
                DispatchQueue.main.async {
                    self?.wirelessState = state
                    self?.statusItemController.refresh()
                    self?.wirelessSetupWindow.refreshIfVisible()
                }
            }
        )
    }

    @MainActor
    private func startWirelessReceiver() {
        do {
            try wirelessReceiver.start()
        } catch {
            wirelessState = .failed(error.localizedDescription)
            Log.error("Wireless receiver could not start on port \(wirelessPort): \(error)")
            statusItemController.refresh()
        }
    }

    @MainActor
    private func setWirelessEnabled(_ enabled: Bool) {
        guard enabled != wirelessEnabled else { return }
        wirelessEnabled = enabled
        WirelessSettings.setEnabled(enabled)
        if enabled {
            Log.info("Wireless receiver turned on")
            startWirelessReceiver()
        } else {
            Log.info("Wireless receiver turned off")
            wirelessReceiver.stop()
            wirelessState = .stopped
        }
        statusItemController.refresh()
        wirelessSetupWindow.refreshIfVisible()
    }

    /// Rotating invalidates every Shortcut already installed on a phone, so
    /// confirm before doing it.
    @MainActor
    private func confirmRotatePairing() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "要重置 PhoneSnap 配对吗？"
        alert.informativeText = """
        将生成新的配对凭据。iPhone 上已添加的 PhoneSnap 快捷指令将失效，需扫描新二维码重新添加。

        仅在怀疑配对链接或凭据泄露时执行此操作。
        """
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        rotatePairing()
    }

    @MainActor
    private func rotatePairing() {
        wirelessReceiver.stop()
        wirelessPairing = WirelessPairing.rotate()
        wirelessReceiver = makeWirelessReceiver()
        wirelessState = .stopped
        Log.info("Rotated the wireless pairing; previously installed Shortcuts are now rejected")
        if wirelessEnabled {
            startWirelessReceiver()
        }
        statusItemController.refresh()
        wirelessSetupWindow.refreshIfVisible()
    }

    /// Prefer the last screenshot delivered this session (wired or wireless);
    /// fall back to the newest file in the save folder so the menu item works
    /// right after launch too.
    @MainActor
    private func showLastScreenshot() {
        if presenter.lastFileURL != nil {
            presenter.showLast()
            return
        }
        if let latest = store.latestFile() {
            presenter.present(fileURL: latest)
        } else {
            Log.info("Show Last Screenshot: no screenshots in \(store.folder.path)")
        }
    }

    private func wirelessSetupInfo() -> WirelessSetupInfo {
        WirelessSetupInfo(
            pairID: wirelessPairing.pairID,
            port: wirelessPort,
            receiverState: wirelessState,
            hostName: LANAddress.bonjourHostName(),
            lanIP: LANAddress.currentIPv4()
        )
    }

    /// Single surfacing path for every capture source. Which presenter is used
    /// is the user's preference, not a property of how the screenshot arrived.
    @MainActor
    private func surface(fileURL: URL, activate: Bool = false) {
        let mode = ThumbnailSettings.mode()
        Log.info("Surfacing \(fileURL.lastPathComponent) as \(mode.rawValue)")
        switch mode {
        case .latestOnly:
            presenter.present(fileURL: fileURL, activate: activate)
        case .recentStrip:
            recentPresenter.enqueue(fileURL: fileURL, activate: activate)
        }
    }

    @discardableResult
    private func deliver(data: Data, source: String, confirmedUSB: Bool) -> Bool {
        do {
            let url = try store.save(data: data, context: ScreenshotReceiveContext(source: confirmedUSB ? .cable : .cameraUnknown))
            Log.info("Delivered via \(source): \(url.lastPathComponent)")
            DispatchQueue.main.async { [weak self] in
                self?.surface(fileURL: url)
                if !ScreenshotEditor.shared.hasOpenEditors { Pasteboard.write(fileURL: url) }
            }
            return true
        } catch {
            Log.error("Save failed (\(source)): \(error)")
            return false
        }
    }

    /// Hash → saved file for wireless uploads received this session. The
    /// Shortcut re-sends the configured recent screenshot batch on every run, so
    /// duplicates skip the disk write — but still re-surface in the panel,
    /// otherwise a second run after closing the panel shows nothing.
    private var seenWirelessUploads: [String: URL] = [:]
    private let seenWirelessUploadsLock = NSLock()

    @discardableResult
    private func deliverWireless(data: Data, deduplicate: Bool = true, context: ScreenshotReceiveContext = ScreenshotReceiveContext(source: .http)) -> WirelessReceiver.UploadResult {
        let digest = deduplicate ? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() : ""
        seenWirelessUploadsLock.lock()
        let existing = seenWirelessUploads[digest]
        seenWirelessUploadsLock.unlock()
        if deduplicate, let existing {
            Log.info("Wireless upload already received this session: re-showing \(existing.lastPathComponent)")
            DispatchQueue.main.async { [weak self] in
                self?.surface(fileURL: existing)
            }
            return .accepted
        }
        do {
            let url = try store.save(data: data, context: context)
            seenWirelessUploadsLock.lock()
            if deduplicate { seenWirelessUploads[digest] = url }
            seenWirelessUploadsLock.unlock()
            Log.info("Delivered via Wireless Shortcut Batch: \(url.lastPathComponent)")
            DispatchQueue.main.async { [weak self] in
                self?.surface(fileURL: url)
                if !ScreenshotEditor.shared.hasOpenEditors { Pasteboard.write(fileURL: url) }
            }
            return .accepted
        } catch ImageStore.SaveError.noImage {
            Log.error("Save failed (Wireless Shortcut Batch): uploaded data is not an image")
            return .invalidImage
        } catch ImageStore.SaveError.imageTooLarge {
            Log.error("Save failed (Wireless Shortcut Batch): image dimensions exceed the safety limit")
            return .invalidImage
        } catch {
            Log.error("Save failed (Wireless Shortcut Batch): \(error)")
            return .storageFailure
        }
    }
}
