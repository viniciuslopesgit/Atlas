import os
import subprocess
import tempfile
import unittest

SCRIPTS = os.path.join(os.path.dirname(__file__), "..")


class ResolvedPathTests(unittest.TestCase):
    """The test sandbox allows writes by real path; scripts must not hand it a symlinked one (/var, /tmp)."""

    def test_scripts_resolve_their_folders(self):
        with open(os.path.join(SCRIPTS, "test-isolated.sh")) as f:
            self.assertIn("ROOT=$(pwd -P)", f.read())
        with open(os.path.join(SCRIPTS, "stable.sh")) as f:
            self.assertIn('TMP=$(cd -P "$(mktemp -d)" && pwd -P)', f.read())

    def test_resolving_removes_the_symlink(self):
        with tempfile.TemporaryDirectory() as real:
            link = real + "-link"
            os.symlink(real, link)
            try:
                out = subprocess.run(["/bin/zsh", "-c", f'cd -P "{link}" && pwd -P'], capture_output=True, text=True)
                self.assertEqual(out.stdout.strip(), os.path.realpath(real))
            finally:
                os.remove(link)


if __name__ == "__main__":
    unittest.main()
