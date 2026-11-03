from pathlib import Path
import plistlib
import tempfile
import unittest

from validate_privacy_manifests import validate_bundle


class PrivacyManifestTests(unittest.TestCase):
    def test_tracking_requires_domains_and_domains_require_tracking(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "PrivacyInfo.xcprivacy"
            for tracking, domains in [(True, []), (False, ["ads.example.com"])]:
                with self.subTest(tracking=tracking, domains=domains):
                    path.write_bytes(plistlib.dumps({"NSPrivacyTracking": tracking, "NSPrivacyTrackingDomains": domains}))
                    with self.assertRaisesRegex(ValueError, "ITMS-91064"):
                        validate_bundle(Path(folder))

    def test_optional_sdk_keys_are_valid_and_manifests_are_not_modified(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            sdk = root / "SDK.bundle"
            sdk.mkdir()
            (sdk / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({"NSPrivacyAccessedAPITypes": []}))
            app = root / "PrivacyInfo.xcprivacy"
            data = plistlib.dumps({"NSPrivacyTracking": True, "NSPrivacyTrackingDomains": ["ads.example.com"]})
            app.write_bytes(data)
            self.assertEqual(len(validate_bundle(root)), 2)
            self.assertEqual(app.read_bytes(), data)

    def test_domain_values_must_be_hostnames_and_tracking_must_be_boolean(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "PrivacyInfo.xcprivacy"
            for tracking, domains in [("true", ["ads.example.com"]), (True, ["https://ads.example.com/path"]), (True, "ads.example.com")]:
                with self.subTest(tracking=tracking, domains=domains):
                    path.write_bytes(plistlib.dumps({"NSPrivacyTracking": tracking, "NSPrivacyTrackingDomains": domains}))
                    with self.assertRaises(ValueError):
                        validate_bundle(path)


if __name__ == "__main__":
    unittest.main()
