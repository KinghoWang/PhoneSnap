import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class BuildSigningTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "scripts").mkdir()
        shutil.copyfile(Path(__file__).with_name("build-app.sh"), self.root / "scripts/build-app.sh")
        for name in [".build/release/PhoneSnap", "Resources/PhoneSnap.icns", "LICENSE", "ThirdParty/Grabbit-LICENSE"]:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture")
        tools = self.root / "tools"
        tools.mkdir()
        for name in ["swift", "codesign"]:
            path = tools / name
            path.write_text('#!/bin/bash\nprintf "%s\\n" "' + name + ' $*" >> "$COMMAND_LOG"\n'
                            'if [[ "$1" == "--force" && "${FAIL_SIGN:-0}" == 1 ]]; then exit 42; fi\n')
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                        PHONESNAP_VERSION="0.2.0", COMMAND_LOG=str(self.root / "commands"))
        for name in ["PHONESNAP_SIGN_IDENTITY", "PHONESNAP_ALLOW_ADHOC", "PHONESNAP_APP_PATH", "FAIL_SIGN"]:
            self.env.pop(name, None)

    def run_build(self, **settings):
        return subprocess.run(["bash", "scripts/build-app.sh"], cwd=self.root,
                              env=dict(self.env, **settings), capture_output=True, text=True)

    def commands(self):
        path = self.root / "commands"
        return path.read_text() if path.exists() else ""

    def test_missing_identity_stops_before_build(self):
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PHONESNAP_SIGN_IDENTITY", result.stdout + result.stderr)
        self.assertEqual(self.commands(), "")

    def test_explicit_adhoc_requires_opt_in(self):
        self.assertNotEqual(self.run_build(PHONESNAP_SIGN_IDENTITY="-").returncode, 0)
        self.assertEqual(self.commands(), "")

    def test_fixed_identity_is_passed_without_fallback(self):
        identity = "A" * 40
        result = self.run_build(PHONESNAP_SIGN_IDENTITY=identity)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"--sign {identity} --identifier dev.phonesnap.PhoneSnap", self.commands())
        self.assertNotIn("--sign - ", self.commands())

    def test_failed_certificate_does_not_retry_adhoc(self):
        result = self.run_build(PHONESNAP_SIGN_IDENTITY="A" * 40, FAIL_SIGN="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("--sign - ", self.commands())

    def test_existing_bundle_is_preserved(self):
        bundle = self.root / "PhoneSnap.app"
        bundle.mkdir()
        (bundle / "keep").write_text("old signed app")
        self.assertNotEqual(self.run_build(PHONESNAP_SIGN_IDENTITY="A" * 40).returncode, 0)
        self.assertEqual((bundle / "keep").read_text(), "old signed app")
        self.assertEqual(self.commands(), "")

    def test_opt_in_adhoc_and_separate_output(self):
        result = self.run_build(PHONESNAP_ALLOW_ADHOC="1", PHONESNAP_APP_PATH="staging/PhoneSnap.app")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "staging/PhoneSnap.app/Contents/Info.plist").exists())
        self.assertIn("--sign - ", self.commands())


if __name__ == "__main__":
    unittest.main()
