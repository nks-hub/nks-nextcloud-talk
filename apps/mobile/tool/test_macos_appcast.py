import unittest

from macos_appcast import release_tag


class MacOSAppcastTest(unittest.TestCase):
    def setUp(self):
        self.info = {
            "CFBundleIdentifier": "com.nkshub.nextcloudtalk",
            "CFBundleShortVersionString": "1.0.17",
            "CFBundleVersion": "83",
            "SUPublicEDKey": "test-public-key",
            "SUVerifyUpdateBeforeExtraction": True,
            "SURequireSignedFeed": True,
        }

    def test_tag_comes_from_the_packaged_app(self):
        self.assertEqual(release_tag(self.info, "test-public-key"), "v1.0.17+83")

    def test_different_app_or_signing_key_is_refused(self):
        for field in ("CFBundleIdentifier", "SUPublicEDKey"):
            with self.subTest(field=field), self.assertRaises(ValueError):
                release_tag({**self.info, field: "another-app"}, "test-public-key")

    def test_archives_without_mandatory_signature_checks_are_refused(self):
        for field in ("SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"):
            with self.subTest(field=field), self.assertRaises(ValueError):
                release_tag({**self.info, field: False}, "test-public-key")


if __name__ == "__main__":
    unittest.main()
