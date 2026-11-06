import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("check_public", Path(__file__).resolve().parents[1] / "check-public.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class PublicationCheckTests(unittest.TestCase):
    def test_detects_private_networks_but_allows_loopback_and_documentation(self):
        for octets in [(10, 1, 2, 3), (172, 20, 1, 2), (192, 168, 1, 2), (100, 96, 1, 2)]:
            address = ".".join(map(str, octets)).encode()
            self.assertEqual(len(check.text_findings(address)), 1)
        for address in [b"127.0.0.1", b"192.0.2.1", b"localhost", b"100.64.0.0/10"]:
            self.assertEqual(check.text_findings(address), [])

    def test_detects_tokens_and_key_headers_without_returning_values(self):
        values = [
            "gh" + "p_" + "A" * 36,
            "github_" + "pat_" + "A" * 60,
            "AK" + "IA" + "A" * 16,
            "xox" + "b-" + "a" * 30,
            "sk" + "-proj-" + "A" * 40,
            "-----BEGIN " + "PRIVATE KEY-----",
        ]
        for value in values:
            result = check.text_findings(value.encode())
            self.assertEqual(len(result), 1)
            self.assertNotIn(value, repr(result))

    def test_detects_home_paths_and_reports_line_numbers(self):
        content = "safe\n" + "/Users" + "/example/project\n"
        self.assertEqual(check.text_findings(content.encode()), [(2, "personal home path")])

    def test_binary_content_is_not_treated_as_text(self):
        self.assertEqual(check.text_findings(b"\0\xff\x01"), [])

    def test_rejects_local_configuration_and_private_signing_files(self):
        for name in ["Config/LocalSigning.xcconfig", ".env.local", "identity.p12", "private.pem"]:
            self.assertTrue(check.path_findings(name))
        for name in [".env.example", "Config/Signing.xcconfig", "README.md"]:
            self.assertEqual(check.path_findings(name), [])


if __name__ == "__main__":
    unittest.main()
