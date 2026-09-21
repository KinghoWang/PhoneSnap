import Foundation

enum WirelessShortcutGenerator {
    enum GenerateError: LocalizedError {
        case templateEncodingFailed
        case plistConversionFailed(Error)
        case signingLaunchFailed(Error)
        case signingFailed(exitCode: Int32, stderr: String)
        case signingTimedOut
        case readBackFailed(Error)

        var errorDescription: String? {
            switch self {
            case .templateEncodingFailed:
                return "无法编码快捷指令模板。"
            case .plistConversionFailed(let error):
                return "无法生成快捷指令文件：\(error.localizedDescription)"
            case .signingLaunchFailed(let error):
                return "无法运行系统快捷指令工具：\(error.localizedDescription)"
            case .signingFailed(let exitCode, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty {
                    return "快捷指令签名失败，退出码：\(exitCode)。"
                }
                return "快捷指令签名失败，退出码 \(exitCode)：\(detail)"
            case .signingTimedOut:
                return "快捷指令签名超过 \(Int(signingTimeout)) 秒。请先打开一次 Mac 的“快捷指令”App，再重试。"
            case .readBackFailed(let error):
                return "无法读取已签名的快捷指令：\(error.localizedDescription)"
            }
        }
    }

    /// Signed bytes are stable for a given upload URL + token, so cache them:
    /// the download route is reachable without the bearer token (the pair ID
    /// is the capability), and repeated requests must not each spawn a
    /// signing subprocess.
    private static let signedCache = SignedShortcutCache(limit: 8)
    private static let signingTimeout: TimeInterval = 30

    static func makeSigned(uploadURL: String,
                           token: String,
                           batchCount: Int = 10,
                           shortcutName: String = "PhoneSnap") throws -> Data {
        let batchCount = min(max(batchCount, 1), 50)
        let cacheKey = "\(uploadURL)\n\(token)\n\(batchCount)\n\(shortcutName)"
        if let cached = signedCache.value(for: cacheKey) { return cached }

        let unsignedData = try makeUnsigned(uploadURL: uploadURL, token: token, shortcutName: shortcutName)
        let signed = try sign(unsignedData)
        signedCache.insert(signed, for: cacheKey)
        return signed
    }

    static func makeUnsigned(uploadURL: String, token: String, shortcutName: String) throws -> Data {
        let screenshotUUID = UUID().uuidString
        let uploadUUID = UUID().uuidString
        let xml = template
            .replacingOccurrences(of: "$$SHORTCUT_NAME$$", with: xmlEscape(shortcutName))
            .replacingOccurrences(of: "$$UPLOAD_URL$$", with: xmlEscape(uploadURL))
            .replacingOccurrences(of: "$$TOKEN$$", with: xmlEscape("Bearer \(token)"))
            .replacingOccurrences(of: "$$SCREENSHOT_UUID$$", with: screenshotUUID)
            .replacingOccurrences(of: "$$UPLOAD_UUID$$", with: uploadUUID)

        guard let xmlData = xml.data(using: .utf8) else {
            throw GenerateError.templateEncodingFailed
        }

        let plistObject: Any
        do {
            plistObject = try PropertyListSerialization.propertyList(from: xmlData, options: [], format: nil)
        } catch {
            throw GenerateError.plistConversionFailed(error)
        }

        do {
            return try PropertyListSerialization.data(
                fromPropertyList: plistObject,
                format: .binary,
                options: 0
            )
        } catch {
            throw GenerateError.plistConversionFailed(error)
        }
    }

    private static func sign(_ unsignedData: Data) throws -> Data {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let runID = UUID().uuidString
        let unsignedURL = tempDir.appendingPathComponent("PhoneSnap-unsigned-\(runID).shortcut")
        let signedURL = tempDir.appendingPathComponent("PhoneSnap-signed-\(runID).shortcut")
        defer {
            try? FileManager.default.removeItem(at: unsignedURL)
            try? FileManager.default.removeItem(at: signedURL)
        }

        try unsignedData.write(to: unsignedURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = [
            "sign",
            "--mode", "anyone",
            "--input", unsignedURL.path,
            "--output", signedURL.path
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw GenerateError.signingLaunchFailed(error)
        }

        // Drain stderr while the process runs. Reading it only after exit can
        // deadlock: a child that fills the pipe buffer blocks on write and
        // never exits.
        let stderrDrain = PipeDrain(fileHandle: stderrPipe.fileHandleForReading)
        stderrDrain.start()

        if exited.wait(timeout: .now() + signingTimeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            throw GenerateError.signingTimedOut
        }
        let stderrData = stderrDrain.wait(timeout: .now() + 2)

        if process.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8) ?? "<binary stderr>"
            throw GenerateError.signingFailed(exitCode: process.terminationStatus, stderr: stderr)
        }

        let signed: Data
        do {
            signed = try Data(contentsOf: signedURL)
        } catch {
            throw GenerateError.readBackFailed(error)
        }

        return signed
    }

    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static let template = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>WFWorkflowClientVersion</key>
        <string>2607.0.6</string>
        <key>WFWorkflowMinimumClientVersion</key>
        <integer>900</integer>
        <key>WFWorkflowName</key>
        <string>$$SHORTCUT_NAME$$</string>
        <key>WFWorkflowIcon</key>
        <dict>
            <key>WFWorkflowIconStartColor</key>
            <integer>463140863</integer>
            <key>WFWorkflowIconGlyphNumber</key>
            <integer>59511</integer>
        </dict>
        <key>WFWorkflowInputContentItemClasses</key>
        <array>
            <string>WFAppStoreAppContentItem</string>
            <string>WFArticleContentItem</string>
            <string>WFContactContentItem</string>
            <string>WFDateContentItem</string>
            <string>WFEmailAddressContentItem</string>
            <string>WFGenericFileContentItem</string>
            <string>WFImageContentItem</string>
            <string>WFiTunesProductContentItem</string>
            <string>WFLocationContentItem</string>
            <string>WFDictionaryContentItem</string>
            <string>WFMKMapItemContentItem</string>
            <string>WFNumberContentItem</string>
            <string>WFPDFContentItem</string>
            <string>WFPhoneNumberContentItem</string>
            <string>WFRichTextContentItem</string>
            <string>WFSafariWebPageContentItem</string>
            <string>WFStringContentItem</string>
            <string>WFURLContentItem</string>
        </array>
        <key>WFWorkflowTypes</key>
        <array>
            <string>NCWidget</string>
            <string>WatchKit</string>
        </array>
        <key>WFWorkflowImportQuestions</key>
        <array/>
        <key>WFWorkflowActions</key>
        <array>
            <dict>
                <key>WFWorkflowActionIdentifier</key>
                <string>is.workflow.actions.takescreenshot</string>
                <key>WFWorkflowActionParameters</key>
                <dict>
                    <key>UUID</key>
                    <string>$$SCREENSHOT_UUID$$</string>
                </dict>
            </dict>
            <dict>
                <key>WFWorkflowActionIdentifier</key>
                <string>is.workflow.actions.downloadurl</string>
                <key>WFWorkflowActionParameters</key>
                <dict>
                    <key>ShowHeaders</key>
                    <true/>
                    <key>UUID</key>
                    <string>$$UPLOAD_UUID$$</string>
                    <key>WFRequestVariable</key>
                    <dict>
                        <key>Value</key>
                        <dict>
                            <key>Type</key>
                            <string>ActionOutput</string>
                            <key>OutputUUID</key>
                            <string>$$SCREENSHOT_UUID$$</string>
                            <key>OutputName</key>
                            <string>Screenshot</string>
                        </dict>
                        <key>WFSerializationType</key>
                        <string>WFTextTokenAttachment</string>
                    </dict>
                    <key>WFHTTPBodyType</key>
                    <string>File</string>
                    <key>WFHTTPHeaders</key>
                    <dict>
                        <key>Value</key>
                        <dict>
                            <key>WFDictionaryFieldValueItems</key>
                            <array>
                                <dict>
                                    <key>WFItemType</key>
                                    <integer>0</integer>
                                    <key>WFKey</key>
                                    <dict>
                                        <key>Value</key>
                                        <dict>
                                            <key>string</key>
                                            <string>Authorization</string>
                                        </dict>
                                        <key>WFSerializationType</key>
                                        <string>WFTextTokenString</string>
                                    </dict>
                                    <key>WFValue</key>
                                    <dict>
                                        <key>Value</key>
                                        <dict>
                                            <key>string</key>
                                            <string>$$TOKEN$$</string>
                                        </dict>
                                        <key>WFSerializationType</key>
                                        <string>WFTextTokenString</string>
                                    </dict>
                                </dict>
                                <dict>
                                    <key>WFItemType</key>
                                    <integer>0</integer>
                                    <key>WFKey</key>
                                    <dict>
                                        <key>Value</key>
                                        <dict><key>string</key><string>Content-Type</string></dict>
                                        <key>WFSerializationType</key><string>WFTextTokenString</string>
                                    </dict>
                                    <key>WFValue</key>
                                    <dict>
                                        <key>Value</key>
                                        <dict><key>string</key><string>image/png</string></dict>
                                        <key>WFSerializationType</key><string>WFTextTokenString</string>
                                    </dict>
                                </dict>
                            </array>
                        </dict>
                        <key>WFSerializationType</key>
                        <string>WFDictionaryFieldValue</string>
                    </dict>
                    <key>WFHTTPMethod</key>
                    <string>POST</string>
                    <key>WFURL</key>
                    <string>$$UPLOAD_URL$$</string>
                </dict>
            </dict>
        </array>
    </dict>
    </plist>
    """
}

private final class SignedShortcutCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func value(for key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func insert(_ data: Data, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if storage.count >= limit {
            storage.removeAll()
        }
        storage[key] = data
    }
}

private final class PipeDrain: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let lock = NSLock()
    private let drained = DispatchSemaphore(value: 0)
    private var data = Data()

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let output = (try? fileHandle.readToEnd()) ?? Data()
            lock.lock()
            data = output
            lock.unlock()
            drained.signal()
        }
    }

    func wait(timeout: DispatchTime) -> Data {
        _ = drained.wait(timeout: timeout)
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
