#!/usr/bin/env python3
"""Print a stable fingerprint of a directory tree, for before/after diffs.

Usage: config-dir-fingerprint.py DIR [--ignore NAME]...

Prints one line per entry under DIR:
"<kind> <mode> <relative path> <sha256 or link target>", sorted, or "(none)"
when DIR is missing or holds nothing tracked. --ignore skips a top-level
entry and everything under it.
"""

import argparse
import hashlib
import os
import stat
import sys


def entry_line(root, relative):
    path = os.path.join(root, relative)
    info = os.lstat(path)
    mode = "%o" % stat.S_IMODE(info.st_mode)
    if stat.S_ISLNK(info.st_mode):
        return "link %s %s -> %s" % (mode, relative, os.readlink(path))
    if stat.S_ISDIR(info.st_mode):
        return "dir %s %s" % (mode, relative)
    if stat.S_ISREG(info.st_mode):
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(65536), b""):
                digest.update(chunk)
        return "file %s %s %s" % (mode, relative, digest.hexdigest())
    return "other %s %s" % (mode, relative)


def fingerprint(root, ignored):
    lines = []
    for current, directories, files in os.walk(root):
        relative_dir = os.path.relpath(current, root)
        if relative_dir == ".":
            directories[:] = [name for name in directories if name not in ignored]
            files = [name for name in files if name not in ignored]
        for name in directories + files:
            relative = os.path.normpath(os.path.join(relative_dir, name))
            lines.append(entry_line(root, relative))
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
