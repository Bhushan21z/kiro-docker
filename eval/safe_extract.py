#!/usr/bin/env python3
"""Extract a zip without trusting it.

Every archive the evaluator opens is built from candidate-controlled content
(their working tree) or admin-uploaded content (the rubric zip). Either can
carry a path that escapes the destination, a symlink that redirects a later
write, or a header that lies about its size. Python's zipfile.extractall
sanitises some of this; this script refuses rather than rewrites, so a hostile
archive fails the run loudly instead of landing a renamed file somewhere.

Exit status: 0 extracted, 3 rejected (message on stderr), 2 usage error.
"""
import argparse
import os
import stat
import sys
import zipfile

CHUNK = 1024 * 1024


class Rejected(Exception):
    pass


def unsafe_reason(name):
    if not name:
        return "entry has an empty path"
    if "\x00" in name:
        return "entry contains a NUL byte"
    if "\\" in name:
        return "entry contains a backslash"
    if name.startswith("/"):
        return "entry has an absolute path"
    if len(name) >= 2 and name[1] == ":":
        return "entry has a drive letter"
    parts = name.rstrip("/").split("/")
    if ".." in parts:
        return "entry contains a '..' segment"
    if any(p == "" for p in parts):
        return "entry contains an empty path segment"
    return None


def is_symlink(info):
    return stat.S_ISLNK(info.external_attr >> 16)


def extract(zip_path, dest, max_entries, max_file_bytes, max_total_bytes, max_ratio):
    dest = os.path.realpath(dest)
    os.makedirs(dest, exist_ok=True)
    try:
        zf = zipfile.ZipFile(zip_path)
    except (zipfile.BadZipFile, OSError) as err:
        raise Rejected(f"not a readable zip: {err}")

    with zf:
        infos = zf.infolist()
        if len(infos) > max_entries:
            raise Rejected(f"{len(infos)} entries exceeds limit {max_entries}")

        seen = set()
        declared = 0
        compressed = 0
        for info in infos:
            reason = unsafe_reason(info.filename)
            if reason:
                raise Rejected(f"{reason}: {info.filename!r}")
            if is_symlink(info):
                raise Rejected(f"symlink entry: {info.filename!r}")
            key = info.filename.rstrip("/")
            if key in seen:
                raise Rejected(f"duplicate entry: {info.filename!r}")
            seen.add(key)
            declared += info.file_size
            compressed += info.compress_size
        if declared > max_total_bytes:
            raise Rejected(f"declared size {declared} exceeds limit {max_total_bytes}")
        if compressed and declared / compressed > max_ratio:
            raise Rejected(f"compression ratio {declared // compressed}:1 exceeds {max_ratio}:1")

        # Headers are only a first filter: the byte count below is what is
        # enforced, so an entry that lies about its size still stops at the cap.
        written = 0
        for info in infos:
            target = os.path.realpath(os.path.join(dest, info.filename))
            if target != dest and not target.startswith(dest + os.sep):
                raise Rejected(f"entry resolves outside destination: {info.filename!r}")
            if info.is_dir():
                os.makedirs(target, mode=0o755, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), mode=0o755, exist_ok=True)
            if os.path.lexists(target):
                raise Rejected(f"entry collides with an existing path: {info.filename!r}")
            entry_bytes = 0
            # O_EXCL + O_NOFOLLOW: never write through a pre-existing file or link.
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644)
            with os.fdopen(fd, "wb") as out, zf.open(info) as src:
                while True:
                    chunk = src.read(CHUNK)
                    if not chunk:
                        break
                    entry_bytes += len(chunk)
                    written += len(chunk)
                    if entry_bytes > max_file_bytes:
                        raise Rejected(f"{info.filename!r} exceeds per-file limit {max_file_bytes}")
                    if written > max_total_bytes:
                        raise Rejected(f"archive exceeds total limit {max_total_bytes}")
                    out.write(chunk)
    return len(infos), written


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("zip_path")
    p.add_argument("dest")
    p.add_argument("--max-entries", type=int, default=int(os.environ.get("EVAL_MAX_ENTRIES", "100000")))
    p.add_argument("--max-file-bytes", type=int, default=int(os.environ.get("EVAL_MAX_FILE_BYTES", str(256 * 1024 * 1024))))
    p.add_argument("--max-total-bytes", type=int, default=int(os.environ.get("EVAL_MAX_TOTAL_BYTES", str(2 * 1024 * 1024 * 1024))))
    p.add_argument("--max-ratio", type=float, default=float(os.environ.get("EVAL_MAX_RATIO", "300")))
    args = p.parse_args(argv)
    try:
        count, size = extract(args.zip_path, args.dest, args.max_entries, args.max_file_bytes,
                              args.max_total_bytes, args.max_ratio)
    except Rejected as err:
        print(f"safe_extract: rejected {os.path.basename(args.zip_path)}: {err}", file=sys.stderr)
        return 3
    print(f"safe_extract: {os.path.basename(args.zip_path)}: {count} entries, {size} bytes", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
