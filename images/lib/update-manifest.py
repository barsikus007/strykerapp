#!/usr/bin/env python3
"""Write a built artifact into stryker_manifest.json.

The manifest is what the app trusts: it carries the sha256 of every download,
so repointing it at a new build has to be done from the file that was actually
produced, not by hand. Two things get written:

  --core KEY --fragment F   the core[K] block from images/publish.sh
  --app FILE --app-url U --app-version-code N --app-version-name V
                           the app block, sized and hashed from FILE

The legacy core.chroot64 / core.chroot32 keys are never touched. Shipped builds
below version 6 read those two directly and cannot be redirected, so a release
that edits them is a release that cannot be rolled back.

Usage:
  update-manifest.py stryker_manifest.json --core debian_v2 \\
      --fragment out/publish/manifest-fragment.json --dry-run
"""

import argparse
import hashlib
import json
import os
import sys


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def write(path, manifest):
    text = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            if handle.read() == text:
                return False
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    return True


def apply_core(manifest, key, fragment):
    core = manifest.get("core")
    if not isinstance(core, dict):
        sys.exit("update-manifest.py: the manifest has no 'core' object")
    if key in ("chroot64", "chroot32"):
        sys.exit(
            "update-manifest.py: refusing to write core.%s -- shipped builds "
            "below version 6 read that key directly and cannot be redirected" % key
        )
    block = fragment.get("core", {}).get(key)
    if not isinstance(block, dict):
        sys.exit("update-manifest.py: the fragment has no core.%s" % key)
    if "chroot64" not in block:
        sys.exit("update-manifest.py: core.%s has no chroot64 asset" % key)
    before = core.get(key)
    core[key] = block
    return before, block


def apply_rootless(manifest, key, fragment):
    rootless = manifest.get(key)
    if not isinstance(rootless, dict):
        sys.exit("update-manifest.py: the manifest has no '%s' object" % key)
    frag_rootless = fragment.get("rootless")
    if not isinstance(frag_rootless, dict):
        sys.exit("update-manifest.py: the fragment has no 'rootless' object")
    before = dict(rootless)
    for asset_name in ("rootfs", "kernel", "initrd", "qemu", "libslirp", "uml_kernel", "uml_stub"):
        if asset_name in frag_rootless:
            rootless[asset_name] = frag_rootless[asset_name]
    if "version" in frag_rootless:
        rootless["version"] = frag_rootless["version"]
    if frag_rootless.get("kernel_release"):
        rootless["kernel_release"] = frag_rootless["kernel_release"]
    return before, rootless


def apply_app(manifest, path, url, version_code, version_name):
    block = manifest.get("app")
    if not isinstance(block, dict):
        sys.exit("update-manifest.py: the manifest has no 'app' object")
    if not url:
        sys.exit("update-manifest.py: --app needs --app-url")
    if version_code is None or version_code <= 0 or not version_name or not version_name.strip():
        sys.exit("update-manifest.py: --app needs a positive --app-version-code "
                 "and a non-empty --app-version-name from the APK")
    before = dict(block)
    block["versionCode"] = version_code
    block["versionName"] = version_name
    block["url"] = url
    block["sha256"] = sha256_of(path)
    block["size"] = os.path.getsize(path)
    return before, block


def report(label, before, after, keys):
    print("%s:" % label)
    for key in keys:
        old = before.get(key) if isinstance(before, dict) else None
        new = after.get(key) if isinstance(after, dict) else None
        mark = "  " if old == new else "- "
        print("  %s%-12s %s" % (mark, key, json.dumps(new)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest")
    parser.add_argument("--core", metavar="KEY",
                        help="core block to replace, e.g. debian_v2")
    parser.add_argument("--rootless", metavar="KEY",
                        help="rootless block to replace, e.g. rootless_v2")
    parser.add_argument("--fragment", metavar="FILE",
                        help="fragment written by images/publish.sh")
    parser.add_argument("--app", metavar="FILE",
                        help="APK to size and hash into the app block")
    parser.add_argument("--app-url", metavar="URL")
    parser.add_argument("--app-version-code", type=int, metavar="N")
    parser.add_argument("--app-version-name", metavar="VERSION")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not os.path.exists(args.manifest):
        sys.exit("update-manifest.py: no such manifest: %s" % args.manifest)

    changes = []
    manifest = None

    if args.core or args.rootless:
        if not args.fragment:
            sys.exit("update-manifest.py: --core and --rootless require --fragment")
        manifest = load(args.manifest)
        fragment = load(args.fragment)
        if args.core:
            before, after = apply_core(manifest, args.core, fragment)
            changes.append(("core.%s" % args.core, before, after, ["chroot64"]))
        if args.rootless:
            before, after = apply_rootless(manifest, args.rootless, fragment)
            keys = [k for k in ("rootfs", "kernel", "initrd", "version") if k in after]
            changes.append(("%s" % args.rootless, before, after, keys))

    if args.app:
        if manifest is None:
            manifest = load(args.manifest)
        before, after = apply_app(manifest, args.app, args.app_url,
                                  args.app_version_code, args.app_version_name)
        changes.append(("app", before, after,
                        ["versionCode", "versionName", "url", "sha256", "size"]))

    if not changes:
        sys.exit("update-manifest.py: nothing to do -- pass --core/--rootless/--fragment "
                 "or --app")

    for label, before, after, keys in changes:
        report(label, before, after, keys)

    if args.dry_run:
        print("\n(dry run, %s not written)" % args.manifest)
        return 0

    if write(args.manifest, manifest):
        print("\nwrote %s" % args.manifest)
    else:
        print("\n%s already up to date" % args.manifest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
