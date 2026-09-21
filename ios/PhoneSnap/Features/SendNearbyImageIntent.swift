import AppIntents
import Foundation
import UniformTypeIdentifiers

enum PhoneSnapIntentError: LocalizedError {
    case notPaired, busy
    var errorDescription: String? {
        switch self {
        case .notPaired: return "请先打开 PhoneSnap，导入 Mac 配对文件。"
        case .busy: return "上一张图片还在发送，请稍后重试。"
        }
    }
}

struct SendNearbyImageIntent: AppIntent {
    static var title: LocalizedStringResource = "发送图片到附近 Mac"
    static var description = IntentDescription("通过 PhoneSnap 附近加密连接发送截图或图片，等待 Mac 确认保存。")
    static var supportedModes: IntentModes = .background

    @Parameter(title: "图片", supportedContentTypes: [.image])
    var image: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("将\(\.$image)发送到附近 Mac")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PhoneSnapModel.shared.send(image.data, origin: .shortcut)
        return .result()
    }
}
