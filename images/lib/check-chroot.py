#!/usr/bin/env python3
"""Check the installer's paths inside a chroot tarball without extracting it."""

import posixpath
import sys
import tarfile


def resolve(members, path, links=0):
    """Resolve tar links with absolute symlinks relative to the guest root."""
    path = posixpath.normpath(path)
    if path != "release" and not path.startswith("release/"):
        raise ValueError("path escapes release/: " + path)
    if links > 40:
        raise ValueError("too many links resolving " + path)
    parts = path.split("/")
    for index in range(len(parts)):
        prefix = "/".join(parts[:index + 1])
        member = members.get(prefix)
        if member is None:
            raise ValueError("missing " + prefix)
        if member.issym() or member.islnk():
            target = member.linkname
            if member.issym():
                if target.startswith("/"):
                    target = "release/" + target.lstrip("/")
                else:
                    target = posixpath.join(posixpath.dirname(prefix), target)
            return resolve(members, posixpath.join(target, *parts[index + 1:]), links + 1)
        if index < len(parts) - 1 and not member.isdir():
            raise ValueError("not a directory: " + prefix)
    return member


def check(path):
    with tarfile.open(path, "r:gz") as archive:
        members = {posixpath.normpath(m.name): m for m in archive}
    if not members or any(name != "release" and not name.startswith("release/")
                          for name in members):
        raise ValueError("tarball must be rooted at release/")
    if not resolve(members, "release/usr/bin").isdir():
        raise ValueError("release/usr/bin is not a directory")
    # Trixie records bin -> usr/bin and sh -> dash, not bin/bash and bin/sh.
    for shell in ("release/bin/bash", "release/bin/sh"):
        member = resolve(members, shell)
        if not member.isfile() or not member.mode & 0o111:
            raise ValueError(shell + " is not an executable file")
        print(shell + " resolves to " + member.name)
    print("chroot layout OK (%d entries)" % len(members))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: check-chroot.py <chroot.tar.gz>")
    try:
        check(sys.argv[1])
    except (OSError, tarfile.TarError, ValueError) as error:
        sys.exit("check-chroot.py: " + str(error))
