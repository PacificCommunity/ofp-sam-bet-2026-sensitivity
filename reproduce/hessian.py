#!/usr/bin/env python3
"""Check or restore original saved Hessian files; never run a model."""

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request


MAX_MANIFEST = 2 * 1024 * 1024
MAX_ARCHIVE = 512 * 1024 * 1024
MAX_MEMBER = 512 * 1024 * 1024
MAX_EXPANDED = 1024 * 1024 * 1024
CHUNK = 1024 * 1024
SHA = re.compile(r"[0-9a-f]{64}\Z")
CASE = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}\Z")
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW


class HessianError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise HessianError(message)


def identity(st):
    return (st.st_dev, st.st_ino, st.st_mode, st.st_size,
            st.st_mtime_ns, st.st_ctime_ns)


def member_path(value):
    require(isinstance(value, str) and 0 < len(value) <= 240,
            "invalid member path")
    parts = value.split("/")
    require(len(parts) <= 8 and str(PurePosixPath(value)) == value and
            not value.startswith("/") and all(
                re.fullmatch(r"[A-Za-z0-9._-]{1,128}", p) and
                p not in (".", "..") for p in parts),
            "member path must be a canonical safe relative path")
    return parts


def keys(value, required, optional=()):
    require(isinstance(value, dict) and set(required) <= value.keys() and
            value.keys() <= set(required) | set(optional),
            "missing or unknown manifest field")


def bounded_integer(value, maximum):
    require(type(value) is int and 0 <= value <= maximum,
            "invalid or excessive byte count")


def text_field(value, maximum=128):
    require(isinstance(value, str) and 0 < len(value) <= maximum and
            not any(ord(c) < 32 or ord(c) == 127 for c in value),
            "invalid metadata text")


def no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


class PinnedParents:
    """Open each existing ancestor without following links; retain identities."""

    def __init__(self, absolute):
        require(isinstance(absolute, str) and absolute.startswith("/") and
                str(Path(absolute)) == absolute and ".." not in absolute.split("/"),
                "path must be absolute and canonical")
        self.path = Path(absolute)
        self.fds = [os.open("/", DIR_FLAGS)]
        self.names = []
        try:
            for name in self.path.parts[1:-1]:
                self.fds.append(os.open(name, DIR_FLAGS, dir_fd=self.fds[-1]))
                self.names.append(name)
            self.check()
        except BaseException:
            self.close()
            raise

    @property
    def fd(self):
        return self.fds[-1]

    def check(self):
        for i, name in enumerate(self.names):
            found = os.stat(name, dir_fd=self.fds[i], follow_symlinks=False)
            opened = os.fstat(self.fds[i + 1])
            require(stat.S_ISDIR(found.st_mode) and
                    (found.st_dev, found.st_ino) == (opened.st_dev, opened.st_ino),
                    "parent directory changed")

    def close(self):
        for fd in self.fds:
            os.close(fd)
        self.fds = []


def read_manifest(path):
    path = Path(os.path.abspath(path))
    parents = PinnedParents(str(path))
    try:
        fd = os.open(path.name, FILE_FLAGS, dir_fd=parents.fd)
        with os.fdopen(fd, "rb") as handle:
            before = os.fstat(handle.fileno())
            require(stat.S_ISREG(before.st_mode) and before.st_size <= MAX_MANIFEST,
                    "manifest must be a bounded regular file")
            raw = handle.read(MAX_MANIFEST + 1)
            require(len(raw) <= MAX_MANIFEST and identity(before) ==
                    identity(os.fstat(handle.fileno())), "manifest changed")
            require(identity(before) == identity(os.stat(path.name, dir_fd=parents.fd,
                    follow_symlinks=False)), "manifest path changed")
        parents.check()
    finally:
        parents.close()
    data = json.loads(raw, object_pairs_hook=no_duplicate_keys)
    keys(data, ("schema_version", "classification", "repository", "cases"))
    require(type(data["schema_version"]) is int and data["schema_version"] == 1,
            "unsupported manifest schema")
    require(data["classification"] == "PUBLIC", "manifest must be PUBLIC")
    repository = data["repository"]
    require(isinstance(repository, str) and re.fullmatch(
        r"PacificCommunity/ofp-sam-bet-2026-[a-z][a-z0-9-]*", repository),
        "invalid BET repository")
    cases = data["cases"]
    require(isinstance(cases, dict) and 1 <= len(cases) <= 512,
            "manifest must contain 1 to 512 cases")
    for case, entry in cases.items():
        require(isinstance(case, str) and CASE.fullmatch(case), "invalid case ID")
        require(isinstance(entry, dict), "invalid case entry")
        kind = entry.get("kind", "matrix")
        require(kind in ("matrix", "native_parts"), "invalid Hessian kind")
        common = ("model_id", "pdh_status", "final_par_sha256", "archive", "members")
        if kind == "matrix":
            keys(entry, common + ("hessian_sha256",),
                 ("kind", "report_id", "report_label", "hessian_header"))
        else:
            keys(entry, common + ("kind", "hessian_parts"), ("report_id", "report_label"))
        text_field(entry["model_id"])
        text_field(entry["pdh_status"], 32)
        for field in ("report_id", "report_label"):
            if field in entry:
                text_field(entry[field])
        if "hessian_header" in entry:
            header = entry["hessian_header"]
            keys(header, ("bytes_hex", "n_parameter"), ("row_bounds",))
            require(isinstance(header["bytes_hex"], str) and
                    re.fullmatch(r"(?:[0-9a-f]{2}){1,64}", header["bytes_hex"]),
                    "invalid original Hessian header bytes")
            bounded_integer(header["n_parameter"], 100000)
            require(header["n_parameter"] > 0, "invalid original Hessian dimensions")
            if "row_bounds" in header:
                require(isinstance(header["row_bounds"], list) and
                        len(header["row_bounds"]) == 2, "invalid original Hessian dimensions")
                for value in header["row_bounds"]:
                    bounded_integer(value, 100000)
        archive = entry["archive"]
        require(isinstance(archive, dict) and
                ("url" in archive) != ("relative_path" in archive),
                "archive requires exactly one fixed source")
        source = "url" if "url" in archive else "relative_path"
        keys(archive, (source, "bytes", "sha256"))
        bounded_integer(archive["bytes"], MAX_ARCHIVE)
        require(archive["bytes"] > 0 and isinstance(archive["sha256"], str) and
                SHA.fullmatch(archive["sha256"]), "invalid archive pin")
        if source == "url":
            prefix = "https://github.com/" + repository + "/releases/download/"
            url = archive["url"]
            require(isinstance(url, str) and url.startswith(prefix) and
                    re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.tar\.gz",
                                 url[len(prefix):]), "invalid fixed release URL")
            member_path(url[len(prefix):])
        else:
            member_path(archive["relative_path"])
            require(archive["relative_path"].endswith(".tar.gz"),
                    "archive must be .tar.gz")
        members = entry["members"]
        require(isinstance(members, dict) and 2 <= len(members) <= 64 and
                "final.par" in members,
                "manifest requires final.par and Hessian files, at most 64 files")
        require((kind == "matrix" and "bet.hes" in members) or
                (kind == "native_parts" and "bet.hes" not in members),
                "matrix requires root bet.hes; native_parts must preserve nested part paths")
        paths = set()
        total = 0
        for name, pin in members.items():
            parts = member_path(name)
            folded = name.casefold()
            require(folded not in paths and not any(
                folded.startswith(old + "/") or old.startswith(folded + "/")
                for old in paths), "member paths collide")
            paths.add(folded)
            keys(pin, ("bytes", "sha256"))
            bounded_integer(pin["bytes"], MAX_MEMBER)
            require(isinstance(pin["sha256"], str) and SHA.fullmatch(pin["sha256"]),
                    "invalid member SHA256")
            total += pin["bytes"]
        require(total <= MAX_EXPANDED, "excessive total member bytes")
        scientific_pins = [("final_par_sha256", "final.par")]
        if kind == "matrix":
            scientific_pins.append(("hessian_sha256", "bet.hes"))
        for field, name in scientific_pins:
            require(entry[field] == members[name]["sha256"],
                    "scientific source pin disagrees with member pin")
        if kind == "native_parts":
            validate_part_manifest(entry)
    return path, data


def validate_part_manifest(entry):
    parts = entry["hessian_parts"]
    require(isinstance(parts, list) and 1 <= len(parts) <= 63,
            "native_parts requires a finite nonempty part list")
    next_row = 1
    n_parameter = None
    seen = set()
    for part in parts:
        keys(part, ("path", "n_parameter", "row_bounds", "bytes_hex", "sha256"))
        path = part["path"]
        components = member_path(path)
        require(len(components) >= 2 and components[-1] == "bet.hes" and
                path in entry["members"] and path not in seen,
                "missing, duplicate or invalid original Hessian part path")
        seen.add(path)
        n = part["n_parameter"]
        bounded_integer(n, 100000)
        require(n > 0, "invalid Hessian part dimension")
        if n_parameter is None:
            n_parameter = n
        require(n == n_parameter, "Hessian part dimensions differ")
        bounds = part["row_bounds"]
        require(isinstance(bounds, list) and len(bounds) == 2, "invalid part row bounds")
        for value in bounds:
            bounded_integer(value, n)
        start, end = bounds
        require(start == next_row and start <= end, "part rows must be ordered and cover 1..n")
        next_row = end + 1
        header = part["bytes_hex"]
        require(isinstance(header, str) and re.fullmatch(r"[0-9a-f]{24}", header) and
                struct.unpack("<iii", bytes.fromhex(header)) == (n, start, end),
                "original native part header disagrees with its row bounds")
        member = entry["members"][path]
        require(part["sha256"] == member["sha256"] and
                member["bytes"] == 12 + 8 * n * (end - start + 1),
                "native part source SHA256 or byte layout differs")
    require(next_row == n_parameter + 1, "incomplete native Hessian row coverage")
    require(seen == {name for name in entry["members"]
                     if PurePosixPath(name).name == "bet.hes"},
            "unlisted native Hessian part member")


class ReleaseRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urllib.parse.urlsplit(newurl)
        require(parsed.scheme == "https" and parsed.hostname in (
            "github.com", "release-assets.githubusercontent.com",
            "objects.githubusercontent.com") and parsed.port in (None, 443) and
            parsed.username is None and parsed.password is None and
            not parsed.fragment, "unexpected archive redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def copy_archive(entry, manifest, override, destination):
    archive = entry["archive"]
    parents = None
    source = None
    before = None
    try:
        if override is not None or "relative_path" in archive:
            path = Path(override) if override is not None else manifest.parent / archive["relative_path"]
            parents = PinnedParents(str(path))
            fd = os.open(path.name, FILE_FLAGS, dir_fd=parents.fd)
            source = os.fdopen(fd, "rb")
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and before.st_size == archive["bytes"],
                    "archive is not the pinned regular file")
        else:
            opener = urllib.request.build_opener(ReleaseRedirect())
            source = opener.open(urllib.request.Request(archive["url"], headers={
                "User-Agent": "BET2026-saved-hessian", "Accept-Encoding": "identity"}),
                timeout=30)
        digest = hashlib.sha256()
        count = 0
        deadline = time.monotonic() + 600
        with open(destination, "xb") as target:
            while True:
                require(time.monotonic() <= deadline, "archive transfer timed out")
                block = source.read(min(CHUNK, archive["bytes"] - count + 1))
                if not block:
                    break
                count += len(block)
                require(count <= archive["bytes"], "archive exceeds pinned bytes")
                target.write(block)
                digest.update(block)
        require(count == archive["bytes"] and digest.hexdigest() == archive["sha256"],
                "archive bytes or SHA256 differ")
        if parents is not None:
            require(identity(before) == identity(os.fstat(source.fileno())),
                    "source archive changed")
            require(identity(before) == identity(os.stat(path.name, dir_fd=parents.fd,
                    follow_symlinks=False)), "source archive path changed")
            parents.check()
    finally:
        if source is not None:
            source.close()
        if parents is not None:
            parents.close()


class NewTree:
    """Files are exclusive; each opened directory remains tied to its path."""

    def __init__(self, root_fd):
        self.fds = {(): root_fd}

    def check(self):
        for parts, fd in self.fds.items():
            if parts:
                st = os.stat(parts[-1], dir_fd=self.fds[parts[:-1]],
                             follow_symlinks=False)
                pinned = os.fstat(fd)
                require(stat.S_ISDIR(st.st_mode) and (st.st_dev, st.st_ino) ==
                        (pinned.st_dev, pinned.st_ino), "member directory changed")

    def open_new(self, name):
        parts = member_path(name)
        for i in range(1, len(parts)):
            key = tuple(parts[:i])
            if key not in self.fds:
                parent = self.fds[key[:-1]]
                os.mkdir(parts[i - 1], 0o700, dir_fd=parent)
                self.fds[key] = open_reserved_directory(parts[i - 1], parent)
        self.check()
        return os.fdopen(os.open(parts[-1], os.O_WRONLY | os.O_CREAT |
                                os.O_EXCL | os.O_NOFOLLOW, 0o600,
                                dir_fd=self.fds[tuple(parts[:-1])]), "wb")

    def check_files(self, members):
        self.check()
        expected = {parts: set() for parts in self.fds}
        for parts in self.fds:
            if parts:
                expected[parts[:-1]].add(parts[-1])
        for name, pin in members.items():
            parts = tuple(member_path(name))
            expected[parts[:-1]].add(parts[-1])
            fd = os.open(parts[-1], FILE_FLAGS, dir_fd=self.fds[parts[:-1]])
            with os.fdopen(fd, "rb") as handle:
                before = os.fstat(handle.fileno())
                require(stat.S_ISREG(before.st_mode) and before.st_size == pin["bytes"],
                        "output member changed")
                digest = hashlib.sha256()
                for block in iter(lambda: handle.read(CHUNK), b""):
                    digest.update(block)
                require(digest.hexdigest() == pin["sha256"] and identity(before) ==
                        identity(os.fstat(handle.fileno())), "output SHA256 differs")
                current = os.stat(parts[-1], dir_fd=self.fds[parts[:-1]],
                                  follow_symlinks=False)
                require(stat.S_ISREG(current.st_mode) and identity(current) == identity(before),
                        "output member path changed")
        require(all(set(os.listdir(fd)) == expected[parts]
                    for parts, fd in self.fds.items()), "unexpected output entry")
        self.check()

    def close(self):
        for fd in self.fds.values():
            os.close(fd)
        self.fds = {}


def open_reserved_directory(name, parent):
    before = os.stat(name, dir_fd=parent, follow_symlinks=False)
    require(stat.S_ISDIR(before.st_mode) and before.st_uid == os.getuid(),
            "reserved directory changed")
    fd = os.open(name, DIR_FLAGS, dir_fd=parent)
    try:
        require((before.st_dev, before.st_ino) ==
                (os.fstat(fd).st_dev, os.fstat(fd).st_ino) and not os.listdir(fd),
                "reserved directory changed or is not empty")
        return fd
    except BaseException:
        os.close(fd)
        raise


def validate_tar(archive, entry, scratch):
    members = entry["members"]
    seen = set()
    expanded = 0
    limit = sum(pin["bytes"] for pin in members.values()) + 1024 * 1024
    tree = NewTree(os.open(scratch, DIR_FLAGS))
    try:
        with gzip.open(archive, "rb") as stream:
            while True:
                header = stream.read(512)
                expanded += len(header)
                require(len(header) == 512 and expanded <= limit,
                        "truncated or excessive tar header")
                if header == bytes(512):
                    require(stream.read(512) == bytes(512), "missing tar end blocks")
                    expanded += 512
                    for block in iter(lambda: stream.read(CHUNK), b""):
                        expanded += len(block)
                        require(expanded <= limit and
                                not any(block), "extra or excessive tar trailer")
                    break
                info = tarfile.TarInfo.frombuf(header, "utf-8", "strict")
                member_path(info.name)
                require(info.type in (tarfile.REGTYPE, tarfile.AREGTYPE) and
                        not info.linkname, "tar contains a link or non-regular member")
                require(info.name in members and info.name not in seen,
                        "unexpected or duplicate tar member")
                pin = members[info.name]
                require(info.size == pin["bytes"], "tar member size differs")
                seen.add(info.name)
                digest = hashlib.sha256()
                remaining = info.size
                with tree.open_new(info.name) as handle:
                    while remaining:
                        block = stream.read(min(CHUNK, remaining))
                        require(block, "truncated tar member")
                        expanded += len(block)
                        handle.write(block)
                        digest.update(block)
                        remaining -= len(block)
                require(digest.hexdigest() == pin["sha256"], "tar member SHA256 differs")
                padding = (-info.size) % 512
                require(stream.read(padding) == bytes(padding), "invalid tar padding")
                expanded += padding
                require(expanded <= limit, "excessive expanded tar")
        require(seen == members.keys(), "missing tar member")
        tree.check_files(members)
        prefixes = {part["path"]: part["bytes_hex"]
                    for part in entry.get("hessian_parts", [])}
        if "hessian_header" in entry:
            prefixes["bet.hes"] = entry["hessian_header"]["bytes_hex"]
        for name, header_hex in prefixes.items():
            parts = tuple(member_path(name))
            original_header = bytes.fromhex(header_hex)
            fd = os.open(parts[-1], FILE_FLAGS, dir_fd=tree.fds[parts[:-1]])
            with os.fdopen(fd, "rb") as handle:
                before = os.fstat(handle.fileno())
                require(handle.read(len(original_header)) == original_header,
                        "original Hessian header bytes differ")
                require(identity(before) == identity(os.fstat(handle.fileno())) and
                        identity(before) == identity(os.stat(parts[-1],
                        dir_fd=tree.fds[parts[:-1]], follow_symlinks=False)),
                        "Hessian member path changed during header verification")
    finally:
        tree.close()


def output_parents(out, manifest):
    parents = PinnedParents(out)
    try:
        require(parents.path.name not in ("", ".", ".."), "invalid output name")
        roots = (manifest.parent.parent, Path(__file__).absolute().parent.parent)
        require(not any(parents.path == root or parents.path in root.parents or
                        root in parents.path.parents for root in roots),
                "OUT must be outside the repository and its ancestors")
        try:
            os.stat(parents.path.name, dir_fd=parents.fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise HessianError("OUT already exists; choose a new directory")
        return parents
    except BaseException:
        parents.close()
        raise


def restore(entry, manifest, out, archive=None):
    parents = output_parents(out, manifest)
    reserved = False
    tree = None
    try:
        with tempfile.TemporaryDirectory(prefix="bet-hessian-") as scratch:
            scratch = Path(scratch)
            packed = scratch / "archive.tar.gz"
            extracted = scratch / "members"
            extracted.mkdir(mode=0o700)
            copy_archive(entry, manifest, archive, packed)
            validate_tar(packed, entry, extracted)
            parents.check()
            os.mkdir(parents.path.name, 0o700, dir_fd=parents.fd)
            reserved = True
            tree = NewTree(open_reserved_directory(parents.path.name, parents.fd))
            pinned = os.fstat(tree.fds[()])

            def output_check():
                parents.check()
                current = os.stat(parents.path.name, dir_fd=parents.fd,
                                  follow_symlinks=False)
                require(stat.S_ISDIR(current.st_mode) and (current.st_dev, current.st_ino) ==
                        (pinned.st_dev, pinned.st_ino), "OUT directory changed")
                tree.check()

            for name, pin in entry["members"].items():
                output_check()
                digest = hashlib.sha256()
                count = 0
                source_parents = PinnedParents(str(extracted.resolve() / name))
                try:
                    fd = os.open(Path(name).name, FILE_FLAGS, dir_fd=source_parents.fd)
                    with os.fdopen(fd, "rb") as source, tree.open_new(name) as target:
                        before = os.fstat(source.fileno())
                        require(stat.S_ISREG(before.st_mode) and before.st_size == pin["bytes"],
                                "validated member changed")
                        for block in iter(lambda: source.read(CHUNK), b""):
                            count += len(block)
                            require(count <= pin["bytes"], "validated member changed")
                            target.write(block)
                            digest.update(block)
                        require(identity(before) == identity(os.fstat(source.fileno())),
                                "validated member changed")
                        source_parents.check()
                        target.flush()
                        os.fsync(target.fileno())
                finally:
                    source_parents.close()
                require(count == pin["bytes"] and digest.hexdigest() == pin["sha256"],
                        "validated member changed")
            output_check()
            tree.check_files(entry["members"])
            output_check()
            os.fsync(tree.fds[()])
            return (pinned.st_dev, pinned.st_ino)
    except BaseException as exc:
        if reserved:
            raise HessianError("restore failed; no reserved output was removed: " +
                               out + " (" + str(exc) + ")") from exc
        raise
    finally:
        if tree is not None:
            tree.close()
        parents.close()


def select_case(data, selector):
    if selector in data["cases"]:
        return selector
    matches = [key for key, entry in data["cases"].items()
               if entry["model_id"] == selector]
    require(len(matches) == 1, "choose a case or unique model ID listed in hessians.json")
    return matches[0]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=Path(__file__).parent / "hessians.json")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--case")
    parser.add_argument("--out")
    parser.add_argument("--archive", help="absolute local exact archive for offline use")
    args = parser.parse_args(argv)
    try:
        manifest, data = read_manifest(args.manifest)
        if args.verify and not args.case and not args.archive and not args.out:
            print("Manifest verified: " + str(len(data["cases"])) + " cases")
            return 0
        args.case = select_case(data, args.case)
        entry = data["cases"][args.case]
        if args.verify:
            require(args.archive is not None and args.out is None,
                    "archive verification requires CASE and a local archive, no OUT")
            with tempfile.TemporaryDirectory(prefix="bet-hessian-check-") as scratch:
                scratch = Path(scratch)
                packed = scratch / "archive.tar.gz"
                extracted = scratch / "members"
                extracted.mkdir(mode=0o700)
                copy_archive(entry, manifest, args.archive, packed)
                validate_tar(packed, entry, extracted)
            print("Archive verified: " + args.case)
        else:
            require(args.out is not None, "OUT must be a new absolute directory")
            restore(entry, manifest, args.out, args.archive)
            print("Restored " + args.case + " to " + args.out)
        return 0
    except (HessianError, OSError, ValueError, tarfile.TarError, EOFError) as exc:
        print("Hessian: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
