"""Offline regression checks: python3 -m unittest discover -s images/tests -v."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]


def workflow_run(filename, name):
    """Read a named shell step verbatim; actionlint validates the surrounding YAML."""
    lines = (REPO / ".github/workflows" / filename).read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == "- name: " + name)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line.strip().startswith("run:"):
            if line.strip() != "run: |":
                return line.strip()[len("run: "):]
            result = []
            for line in lines[index + 1:]:
                if line.strip() and not line.startswith("          "):
                    break
                result.append(line[10:])
            return "\n".join(result)
        if line.strip().startswith("- name:"):
            break
    raise AssertionError("No shell body for " + name)


class ReleasePipelineTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.manifest = self.work / "stryker_manifest.json"
        shutil.copy2(REPO / "stryker_manifest.json", self.manifest)
        self.before = json.loads(self.manifest.read_text())
        (self.work / "app").mkdir()
        (self.work / "app/build.gradle").write_text(
            'versionCode 650\nbuildConfigField "String", "CHROOT_ID", '\
            '\'"chroot-fixture"\'\n')
        (self.work / "images").symlink_to(REPO / "images", target_is_directory=True)

    def run_command(self, args, env=None, success=True):
        clean = dict(os.environ)
        for key in ("OUT_DIR", "REPO", "MANIFEST", "CHROOT_VERSION", "CHROOT_KEY",
                    "CHROOT_MIN_VC", "VERSION_CODE", "APPLY", "DRY_RUN"):
            clean.pop(key, None)
        clean.update(env or {})
        result = subprocess.run(args, cwd=self.work, env=clean, text=True,
                                capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def make_archive(self, merged=True, root="release"):
        tree = self.work / "tree"
        (tree / "usr/bin").mkdir(parents=True)
        if merged:
            (tree / "bin").symlink_to("usr/bin")
        else:
            (tree / "bin").mkdir()
        for name in ("bash", "dash"):
            file = tree / "bin" / name
            file.write_text("#!/bin/sh\nexit 0\n")
            file.chmod(0o755)
        (tree / "bin/sh").symlink_to("dash")
        archive = self.work / "chroot.tar.gz"
        self.pack_archive(tree, archive, root)
        return tree, archive

    def pack_archive(self, tree, archive, root="release"):
        with tarfile.open(archive, "w:gz", dereference=False) as tar:
            tar.add(tree, arcname=root)

    def check_archive(self, archive, success=True):
        self.run_command(["python3", str(REPO / "images/lib/check-chroot.py"),
                          str(archive)], success=success)

    def test_merged_usr_archive(self):
        _, archive = self.make_archive()
        self.check_archive(archive)

    def test_separate_bin_archive(self):
        _, archive = self.make_archive(merged=False)
        self.check_archive(archive)

    def test_absolute_guest_symlink(self):
        tree, archive = self.make_archive()
        (tree / "usr/bin/sh").unlink()
        (tree / "usr/bin/sh").symlink_to("/usr/bin/dash")
        self.pack_archive(tree, archive)
        self.check_archive(archive)

    def test_wrong_archive_root(self):
        _, archive = self.make_archive(root="wrong")
        self.check_archive(archive, success=False)

    def test_broken_shell_link(self):
        tree, archive = self.make_archive()
        (tree / "usr/bin/dash").unlink()
        self.pack_archive(tree, archive)
        self.check_archive(archive, success=False)

    def test_shell_link_loop(self):
        tree, archive = self.make_archive()
        (tree / "usr/bin/sh").unlink()
        (tree / "usr/bin/sh").symlink_to("sh")
        self.pack_archive(tree, archive)
        self.check_archive(archive, success=False)

    def test_non_executable_shell(self):
        tree, archive = self.make_archive()
        (tree / "usr/bin/bash").chmod(0o644)
        self.pack_archive(tree, archive)
        self.check_archive(archive, success=False)

    def make_fragment(self, extra=None):
        out = self.work / "out"
        out.mkdir()
        (out / "artifacts.tsv").write_text("fixture\n")
        (out / "chroot64-debian.tar.gz").write_bytes(b"test artifact")
        env = {"OUT_DIR": str(out), "REPO": str(self.work), "SUITE": "trixie",
               "CHROOT_TAG": "chroot-650-12345-2"}
        env.update(extra or {})
        self.run_command(["bash", str(REPO / "images/publish.sh"),
                          "https://github.com/example/fork/releases/download"], env)
        return out / "publish/manifest-fragment.json"

    def test_publish_identity_and_downloaded_fragment(self):
        fragment = self.make_fragment()
        dist = self.work / "dist"
        dist.mkdir()
        shutil.copy2(fragment, dist / fragment.name)
        for step in ("Confirm the app knows about this chroot", "Propose the manifest block for it"):
            self.run_command(["bash", "-euo", "pipefail", "-c", workflow_run("chroot.yml", step)])
        core = json.loads(self.manifest.read_text())["core"]
        self.assertEqual(core["debian_v2"]["version"], "chroot-fixture")
        self.assertEqual(core["debian_v2"]["chroot64"]["url"],
                         "https://github.com/example/fork/releases/download/chroot-650-12345-2/chroot64-debian.tar.gz")
        for legacy in ("chroot64", "chroot32", "debian"):
            self.assertEqual(core[legacy], self.before["core"][legacy])

    def test_explicit_chroot_identity(self):
        fragment = self.make_fragment({"CHROOT_VERSION": "custom-tree"})
        self.assertEqual(json.loads(fragment.read_text())["core"]["debian_v2"]["version"],
                         "custom-tree")

    def app_args(self):
        apk = self.work / "Stryker.6.6.apk"
        apk.write_bytes(b"APK fixture; version is supplied by the aapt2 workflow step")
        return ["python3", str(REPO / "images/lib/update-manifest.py"), str(self.manifest),
                "--app", str(apk), "--app-url", "https://example.test/Stryker.6.6.apk"]

    def test_apk_metadata_and_checksum(self):
        args = self.app_args() + ["--app-version-code", "660", "--app-version-name", "6.6.0"]
        self.run_command(args)
        manifest = json.loads(self.manifest.read_text())
        app = manifest["app"]
        apk = self.work / "Stryker.6.6.apk"
        self.assertEqual((app["versionCode"], app["versionName"]), (660, "6.6.0"))
        self.assertEqual(app["sha256"], hashlib.sha256(apk.read_bytes()).hexdigest())
        self.assertEqual(app["size"], apk.stat().st_size)
        self.assertEqual(manifest["core"], self.before["core"])
        self.assertEqual(app["changelog"], self.before["app"]["changelog"])
        result = self.run_command(args)
        self.assertIn("already up to date", result.stdout)

    def test_missing_apk_version_does_not_write(self):
        original = self.manifest.read_bytes()
        self.run_command(self.app_args(), success=False)
        self.assertEqual(self.manifest.read_bytes(), original)

    def test_invalid_apk_versions_do_not_write(self):
        original = self.manifest.read_bytes()
        for code, name in (("0", "6.6.0"), ("-1", "6.6.0"), ("660", " ")):
            with self.subTest(code=code, name=name):
                self.run_command(self.app_args() + ["--app-version-code", code,
                                 "--app-version-name", name], success=False)
                self.assertEqual(self.manifest.read_bytes(), original)

    def test_dry_run_does_not_write(self):
        original = self.manifest.read_bytes()
        self.run_command(self.app_args() + ["--app-version-code", "660",
                         "--app-version-name", "6.6.0", "--dry-run"])
        self.assertEqual(self.manifest.read_bytes(), original)

    def test_release_urls_differ_across_rebuilds(self):
        script = workflow_run("chroot.yml", "Work out which release this build is for")
        tags = []
        for run_id, attempt, prefix in (("123", "1", ""), ("123", "2", ""),
                                         ("124", "1", ""), ("123", "1", "custom"),
                                         ("123", "2", "custom")):
            output = self.work / "github-output"
            output.write_text("")
            self.run_command(["bash", "-euo", "pipefail", "-c", script],
                             {"GITHUB_OUTPUT": str(output), "GITHUB_RUN_ID": run_id,
                              "GITHUB_RUN_ATTEMPT": attempt, "TAG_PREFIX": prefix})
            tags.append(output.read_text().strip().removeprefix("tag="))
        self.assertEqual(len(tags), len(set(tags)))
        self.assertEqual(tags[0], "chroot-650-123-1")
        self.assertEqual(tags[3], "custom-123-1")

    def test_prunes_real_firmware_fixture_without_kernel(self):
        tree = self.work / "tree"
        firmware = tree / "usr/lib/firmware"
        (firmware / "rtlwifi").mkdir(parents=True)
        for index in range(25):
            (firmware / "rtlwifi" / (str(index) + ".bin")).write_bytes(b"keep")
        source = (REPO / "images/rootfs/build.sh").read_text()
        function = next(line for line in source.splitlines() if line.startswith("chroot_only()"))
        branch = source[source.index("\nKREL=\n"):source.index('\nbash "$HERE/scrub.sh"')]
        script = function + '\nsay() { echo "$*"; }\nwarn() { echo "$*"; }\n' + branch
        for mode in ("1", "0"):
            with self.subTest(CHROOT_ONLY=mode):
                (firmware / "unneeded.bin").write_bytes(b"remove")
                self.run_command(["bash", "-euo", "pipefail", "-c", script],
                                 {"CHROOT_ONLY": mode, "TREE": str(tree),
                                  "VMOUT": str(self.work / "no-kernel"),
                                  "HERE": str(REPO / "images/rootfs")})
                self.assertFalse((firmware / "unneeded.bin").exists())
                self.assertEqual(len(list((firmware / "rtlwifi").iterdir())), 25)


if __name__ == "__main__":
    unittest.main()
