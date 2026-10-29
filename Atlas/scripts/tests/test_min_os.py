import os
import plistlib
import re
import unittest

ATLAS = os.path.join(os.path.dirname(__file__), "..", "..")
CI = os.path.join(ATLAS, "..", ".github", "workflows", "ci.yml")


def read(path):
    with open(path) as f:
        return f.read()


class MinimumMacOSTests(unittest.TestCase):
    """Atlas runs from macOS 12: the package, the app's Info.plist and the release build must agree, and CI checks it."""

    def test_package_plist_and_build_target_macos_12(self):
        self.assertIn(".macOS(.v12)", read(os.path.join(ATLAS, "Package.swift")))
        with open(os.path.join(ATLAS, "Resources", "Info.plist"), "rb") as f:
            self.assertEqual(plistlib.load(f)["LSMinimumSystemVersion"], "12.0")
        self.assertIn('MIN=12.0', read(os.path.join(ATLAS, "scripts", "build-app.sh")))

    def test_full_check_verifies_the_built_app(self):
        check = read(os.path.join(ATLAS, "scripts", "check.sh"))
        self.assertIn("./scripts/min-os.sh $APP", check)
        self.assertIn("./scripts/selftest.sh $APP", check)

    def test_ci_runs_the_app_on_macos_12_before_releasing(self):
        ci = read(CI)
        job = re.search(r"\n  macos12:\n(.*?)\n  release:", ci, re.S).group(1)
        self.assertIn("vars.MACOS12_RUNNER", job)
        # The scripts it runs must be checked out (a one-line sparse-checkout list left them out).
        self.assertNotIn("sparse-checkout", job)
        self.assertIn("min-os.sh", job)
        self.assertIn("selftest.sh", job)
        self.assertIn("needs: [check, macos12]", ci)
        self.assertIn("needs.macos12.result == 'success'", ci)

    def test_min_os_rejects_newer_frameworks(self):
        script = read(os.path.join(ATLAS, "scripts", "min-os.sh"))
        for lib in ("Charts.framework", "libswift_StringProcessing.dylib"):
            self.assertIn(lib, script)


if __name__ == "__main__":
    unittest.main()
