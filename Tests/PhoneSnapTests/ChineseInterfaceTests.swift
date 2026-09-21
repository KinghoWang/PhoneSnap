import XCTest
@testable import PhoneSnap

final class ChineseInterfaceTests: XCTestCase {
    func testScreenshotModeTitlesAreChinese() {
        XCTAssertEqual(ThumbnailMode.latestOnly.title, "仅显示最新一张截图")
        XCTAssertEqual(ThumbnailMode.recentStrip.title, "保留最近截图栏")
    }

    func testWirelessStatusTitlesAreChinese() {
        XCTAssertEqual(WirelessReceiver.State.stopped.menuTitle, "无线接收：已停止")
        XCTAssertEqual(WirelessReceiver.State.starting.menuTitle, "无线接收：正在启动")
        XCTAssertEqual(WirelessReceiver.State.ready.menuTitle, "无线接收：已就绪")
        XCTAssertEqual(WirelessReceiver.State.failed("测试").menuTitle, "无线接收：不可用 — 测试")
    }
}
