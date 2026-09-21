import XCTest
@testable import PhoneSnap

final class InstantShortcutTests: XCTestCase {
    func testCapturesOnceAndUploadsOnlyThatOutput() throws {
        let data = try WirelessShortcutGenerator.makeUnsigned(uploadURL: "http://example.local:8472/upload", token: "test-only", shortcutName: "截图到Mac")
        let workflow = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let actions = try XCTUnwrap(workflow["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.compactMap { $0["WFWorkflowActionIdentifier"] as? String }, ["is.workflow.actions.takescreenshot", "is.workflow.actions.downloadurl"])
        let capture = try XCTUnwrap(actions.first?["WFWorkflowActionParameters"] as? [String: Any])
        let upload = try XCTUnwrap(actions.last?["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(upload["WFHTTPMethod"] as? String, "POST")
        XCTAssertEqual(upload["WFURL"] as? String, "http://example.local:8472/upload")
        XCTAssertEqual(upload["WFHTTPBodyType"] as? String, "File")
        XCTAssertNil(upload["WFFormValues"])
        let request = try XCTUnwrap(upload["WFRequestVariable"] as? [String: Any])
        XCTAssertEqual(request["WFSerializationType"] as? String, "WFTextTokenAttachment")
        let output = try XCTUnwrap(request["Value"] as? [String: Any])
        XCTAssertEqual(output["Type"] as? String, "ActionOutput")
        XCTAssertEqual(output["OutputUUID"] as? String, capture["UUID"] as? String)
        let xml = try PropertyListSerialization.data(fromPropertyList: workflow, format: .xml, options: 0)
        let text = try XCTUnwrap(String(data: xml, encoding: .utf8))
        XCTAssertFalse(text.contains("Repeat Item"))
        XCTAssertFalse(text.contains("getlastscreenshot"))
        XCTAssertTrue(text.contains("ActionOutput"))
        let captureID = try XCTUnwrap(capture["UUID"] as? String)
        XCTAssertEqual(text.components(separatedBy: captureID).count - 1, 2)
        XCTAssertTrue(text.contains("Bearer test-only"))
        XCTAssertTrue(text.contains("image/png"))
    }
}
