import json
from pathlib import Path
import plistlib
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PublicLayoutTests(unittest.TestCase):
    def test_standalone_ios_has_no_private_container(self) -> None:
        sources = list((ROOT / "ios" / "PhoneSnap").rglob("*.swift"))
        self.assertTrue(sources)
        content = "\n".join(source.read_text() for source in sources)
        for private_symbol in ("ContentView()", "HealthKit", "LocalSecrets"):
            self.assertFalse(private_symbol in content, f"Unexpected private symbol: {private_symbol}")
        self.assertIn("@main", content)
        self.assertIn("PhoneSnapRootView()", content)

    def test_ios_uses_shared_transport_sources(self) -> None:
        project = (ROOT / "ios" / "PhoneSnap.xcodeproj" / "project.pbxproj").read_text()
        for source in (ROOT / "Sources" / "NearbyTransport").glob("*.swift"):
            if source.name != "RelayReceiptStore.swift":
                self.assertIn(source.name, project)
        self.assertNotIn("DEVELOPMENT_TEAM =", project)
        self.assertNotIn("/Users/", project)

    def test_ios_permission_declarations(self) -> None:
        with (ROOT / "ios" / "PhoneSnap" / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
        self.assertIn("_phonesnap._tcp", info["NSBonjourServices"])
        self.assertTrue(info["NSLocalNetworkUsageDescription"])
        self.assertNotIn("NSAppTransportSecurity", info)
        self.assertNotIn("NSHealthShareUsageDescription", info)

    def test_relay_is_user_configured(self) -> None:
        controller = (ROOT / "Sources" / "PhoneSnap" / "RelaySetupController.swift").read_text()
        self.assertFalse('.generate(baseURL: "https://' in controller, "Hard-coded relay endpoint")
        self.assertIn("accessoryView", controller)
        self.assertIn("endpoint.stringValue", controller)

    def test_icon_is_valid_asset_catalog(self) -> None:
        directory = ROOT / "ios" / "PhoneSnap" / "Assets.xcassets" / "AppIcon.appiconset"
        manifest = json.loads((directory / "Contents.json").read_text())
        for image in manifest["images"]:
            if "filename" in image:
                self.assertTrue((directory / image["filename"]).is_file())


if __name__ == "__main__":
    unittest.main()
