#!/usr/bin/env python3
"""Print a stable fingerprint of a directory tree, for before/after diffs.

Usage: config-dir-fingerprint.py DIR [--ignore NAME]...

Prints one line per entry under DIR:
"<kind> <mode> <relative path> <sha256 or link target>", sorted, or "(none)"
when DIR is missing or holds nothing tracked. --ignore skips a top-level
entry and everything under it.

Symlinks are fingerprinted by what they reach, not just where they point:
a linked file's contents are hashed, and a linked directory whose target
stays inside DIR (and outside every ignored entry) is walked, each real
directory once so cycles terminate. A test that writes through a symlink
into the real config therefore still changes the fingerprint, while a
link out of the tree cannot pull an unbounded foreign tree into it. An
unreadable entry prints an "error" line instead of aborting the diff.
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
    root_real = os.path.realpath(root)
    ignored_real = [os.path.realpath(os.path.join(root, name)) for name in ignored]

    def inside(real):
        if real != root_real and not real.startswith(root_real + os.sep):
            return False
        return all(real != skip and not real.startswith(skip + os.sep) for skip in ignored_real)

    def walk(directory, relative_dir):
        real = os.path.realpath(directory)
        if real in visited:
            return
        visited.add(real)
        try:
            with os.scandir(directory) as entries:
                names = sorted(entry.name for entry in entries)
        except OSError as error:
            lines.append("error %s %s" % (relative_dir or ".", error.errno))
            return
        for name in names:
            if relative_dir == "" and name in ignored:
                continue
            relative = name if relative_dir == "" else relative_dir + "/" + name
            path = os.path.join(directory, name)
            try:
                info = os.lstat(path)
            except OSError as error:
                lines.append("error %s %s" % (relative, error.errno))
                continue
            mode = "%o" % stat.S_IMODE(info.st_mode)
            try:
                if stat.S_ISLNK(info.st_mode):
                    lines.append("link %s %s -> %s" % (mode, relative, os.readlink(path)))
                    if os.path.isfile(path):
                        target_mode = "%o" % stat.S_IMODE(os.stat(path).st_mode)
                        lines.append("linkfile %s %s %s" % (target_mode, relative, hash_file(path)))
                    elif os.path.isdir(path) and inside(os.path.realpath(path)):
                        walk(path, relative)
                elif stat.S_ISDIR(info.st_mode):
                    lines.append("dir %s %s" % (mode, relative))
                    walk(path, relative)
                elif stat.S_ISREG(info.st_mode):
                    lines.append("file %s %s %s" % (mode, relative, hash_file(path)))
                else:
                    lines.append("other %s %s" % (mode, relative))
            except OSError as error:
                lines.append("error %s %s" % (relative, error.errno))

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
