#!/usr/bin/env python3
"""Print a stable fingerprint of a directory tree, for before/after diffs.

Usage: config-dir-fingerprint.py DIR [--ignore NAME]...

Prints one line per entry under DIR:
"<kind> <mode> <relative path> <sha256 or link target>", sorted, or "(none)"
when DIR is missing or holds nothing tracked. --ignore skips a top-level
entry and everything under it.

Symlinks are fingerprinted by what they reach, not just where they point:
a linked file's contents are hashed and a linked directory is walked
(each real directory once, so cycles terminate). A test that writes
through a symlink into the real config therefore still changes the
fingerprint. An unreadable entry is an error, not a silent skip.
"""

import argparse
import hashlib
import os
import stat
import sys


def hash_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fingerprint(root, ignored):
    lines = []
    visited = set()

    def walk(directory, relative_dir):
        real = os.path.realpath(directory)
        if real in visited:
            return
        visited.add(real)
        with os.scandir(directory) as entries:
            names = sorted(entry.name for entry in entries)
        for name in names:
            if relative_dir == "" and name in ignored:
                continue
            relative = name if relative_dir == "" else relative_dir + "/" + name
            path = os.path.join(directory, name)
            info = os.lstat(path)
            mode = "%o" % stat.S_IMODE(info.st_mode)
            if stat.S_ISLNK(info.st_mode):
                target = os.readlink(path)
                lines.append("link %s %s -> %s" % (mode, relative, target))
                if os.path.isfile(path):
                    lines.append("linkfile %s %s %s" % (mode, relative, hash_file(path)))
                elif os.path.isdir(path):
                    walk(path, relative)
            elif stat.S_ISDIR(info.st_mode):
                lines.append("dir %s %s" % (mode, relative))
                walk(path, relative)
            elif stat.S_ISREG(info.st_mode):
                lines.append("file %s %s %s" % (mode, relative, hash_file(path)))
            else:
                lines.append("other %s %s" % (mode, relative))

    if os.path.isdir(root):
        walk(root, "")
    return sorted(lines) or ["(none)"]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("directory")
    parser.add_argument("--ignore", action="append", default=[])
    arguments = parser.parse_args()
    for line in fingerprint(os.path.abspath(arguments.directory), set(arguments.ignore)):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
