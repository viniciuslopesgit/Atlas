import os
import re
import subprocess
import tempfile
import unittest

CI = os.path.join(os.path.dirname(__file__), "..", "..", "..", ".github", "workflows", "ci.yml")


class ReleaseChecksumTests(unittest.TestCase):
    """Installed updaters download only the .zip and run `shasum -c SHA256SUMS`: a .dmg listed there breaks them."""

    def checksum_line(self):
        with open(CI) as f:
            line = next(l for l in f if "> SHA256SUMS" in l)
        return re.sub(r'^\s*', "", line).strip()

    def test_sha256sums_from_ci_verifies_with_only_the_zip(self):
        with tempfile.TemporaryDirectory() as root:
            dist = os.path.join(root, "dist")
            os.makedirs(dist)
            for name, body in [("Atlas-9.9.9.zip", b"zip"), ("Atlas-9.9.9.dmg", b"dmg")]:
                with open(os.path.join(dist, name), "wb") as f:
                    f.write(body)
            line = self.checksum_line().replace('"$VERSION"', "9.9.9").replace("$VERSION", "9.9.9")
            subprocess.run(["/bin/bash", "-c", line], cwd=root, check=True)

            # What an installed updater has: the zip and SHA256SUMS, no .dmg.
            updater = os.path.join(root, "updater")
            os.makedirs(updater)
            for name in ["Atlas-9.9.9.zip", "SHA256SUMS"]:
                os.rename(os.path.join(dist, name), os.path.join(updater, name))
            check = subprocess.run(["shasum", "-a", "256", "-c", "SHA256SUMS"], cwd=updater, capture_output=True, text=True)
            self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
            self.assertTrue(os.path.exists(os.path.join(dist, "Atlas-9.9.9.dmg.sha256")), "the .dmg gets its own checksum")


if __name__ == "__main__":
    unittest.main()
