import os
import subprocess
import tempfile
import unittest

SYNC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "sync-dev.sh"))


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class SyncDevTests(unittest.TestCase):
    """ship.sh must see CI's release commits before choosing a version (2.3.0 was chosen twice without this)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        self.origin = os.path.join(root, "origin.git")
        git(root, "init", "-q", "--bare", "-b", "dev", self.origin)
        self.local = self.clone("local")
        self.write(self.local, "Info.plist", "2.2.0\n")
        git(self.local, "add", "-A")
        git(self.local, "commit", "-qm", "feat: sidebar")
        git(self.local, "push", "-q", "origin", "dev")
        self.ci = self.clone("ci")

    def tearDown(self):
        self.tmp.cleanup()

    def clone(self, name):
        path = os.path.join(self.tmp.name, name)
        git(self.tmp.name, "clone", "-q", self.origin, path)
        git(path, "checkout", "-q", "-B", "dev")
        git(path, "config", "user.email", "t@example.com")
        git(path, "config", "user.name", "t")
        return path

    def write(self, repo, name, text):
        with open(os.path.join(repo, name), "w") as f:
            f.write(text)

    def ci_release(self, version):
        git(self.ci, "pull", "-q", "origin", "dev")
        self.write(self.ci, "Info.plist", version + "\n")
        git(self.ci, "commit", "-qam", f"chore(release): {version}")
        git(self.ci, "push", "-q", "origin", "dev")

    def sync(self):
        return subprocess.run(["/bin/zsh", SYNC], cwd=self.local, capture_output=True, text=True)

    def test_fast_forwards_to_ci_release_and_keeps_local_work(self):
        self.ci_release("2.3.0")
        self.write(self.local, "Feature.swift", "new\n")
        r = self.sync()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(os.path.join(self.local, "Info.plist")) as f:
            self.assertEqual(f.read(), "2.3.0\n")
        self.assertTrue(os.path.exists(os.path.join(self.local, "Feature.swift")))

    def test_up_to_date_is_silent(self):
        r = self.sync()
        self.assertEqual((r.returncode, r.stdout), (0, ""))

    def test_diverged_dev_stops(self):
        self.ci_release("2.3.0")
        self.write(self.local, "Other.swift", "x\n")
        git(self.local, "add", "-A")
        git(self.local, "commit", "-qm", "feat: unpushed")
        r = self.sync()
        self.assertEqual(r.returncode, 1)
        self.assertIn("diverged", r.stdout)

    def test_local_change_to_the_same_file_stops(self):
        self.ci_release("2.3.0")
        self.write(self.local, "Info.plist", "2.2.1\n")
        r = self.sync()
        self.assertEqual(r.returncode, 1)
        self.assertIn("Commit or stash", r.stdout)
        with open(os.path.join(self.local, "Info.plist")) as f:
            self.assertEqual(f.read(), "2.2.1\n", "the local change is untouched")


if __name__ == "__main__":
    unittest.main()
