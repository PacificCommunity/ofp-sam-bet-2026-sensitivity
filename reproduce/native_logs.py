#!/usr/bin/env python3
"""Verify or restore exact original native MFCL logs; never execute a model."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

import hessian as h


def document(path):
    path = Path(os.path.abspath(path))
    parents = h.PinnedParents(str(path))
    try:
        fd = os.open(path.name, h.FILE_FLAGS, dir_fd=parents.fd)
        with os.fdopen(fd, "rb") as handle:
            before = os.fstat(handle.fileno())
            h.require(stat.S_ISREG(before.st_mode) and before.st_size <= h.MAX_MANIFEST,
                      "manifest must be a bounded regular file")
            raw = handle.read(h.MAX_MANIFEST + 1)
            h.require(len(raw) <= h.MAX_MANIFEST and h.identity(before) ==
                      h.identity(os.fstat(handle.fileno())), "manifest changed")
            h.require(h.identity(before) == h.identity(os.stat(
                path.name, dir_fd=parents.fd, follow_symlinks=False)),
                "manifest path changed")
        parents.check()
    finally:
        parents.close()
    return path, raw, json.loads(raw, object_pairs_hook=h.no_duplicate_keys)


def read_manifest(path, hessians):
    path, raw, data = document(path)
    h.keys(data, ("schema_version", "classification", "kind", "repository",
                  "hessians_sha256", "archive", "members"))
    h.require(type(data["schema_version"]) is int and data["schema_version"] == 1
              and data["classification"] == "PUBLIC" and data["kind"] == "native_logs",
              "unsupported native log manifest")
    repository = data["repository"]
    h.require(repository in ("PacificCommunity/ofp-sam-bet-2026-stepwise",
                             "PacificCommunity/ofp-sam-bet-2026-sensitivity"),
              "invalid native log repository")
    h.require(isinstance(data["hessians_sha256"], str) and
              h.SHA.fullmatch(data["hessians_sha256"]), "invalid Hessian manifest pin")
    _, hessian_raw, saved = document(hessians)
    h.require(hashlib.sha256(hessian_raw).hexdigest() == data["hessians_sha256"],
              "saved Hessian manifest SHA256 differs")
    h.require(isinstance(saved, dict) and saved.get("repository") == repository and
              isinstance(saved.get("cases"), dict), "wrong saved Hessian repository")
    _, validated_saved = h.read_manifest(hessians)
    h.require(saved == validated_saved, "saved Hessian manifest changed")

    archive = data["archive"]
    h.require(isinstance(archive, dict) and
              ("url" in archive) != ("relative_path" in archive),
              "archive requires exactly one fixed source")
    source = "url" if "url" in archive else "relative_path"
    h.keys(archive, (source, "bytes", "sha256"))
    h.bounded_integer(archive["bytes"], h.MAX_ARCHIVE)
    h.require(archive["bytes"] > 0 and isinstance(archive["sha256"], str) and
              h.SHA.fullmatch(archive["sha256"]), "invalid archive pin")
    if source == "url":
        prefix = "https://github.com/" + repository + "/releases/download/"
        url = archive["url"]
        h.require(isinstance(url, str) and url.startswith(prefix) and re.fullmatch(
            r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.tar\.gz", url[len(prefix):]),
            "invalid fixed native log release URL")
        h.member_path(url[len(prefix):])
    else:
        h.member_path(archive["relative_path"])
        h.require(archive["relative_path"].endswith(".tar.gz"), "archive must be .tar.gz")

    expected = {}
    for case in saved["cases"].values():
        h.require(isinstance(case, dict), "invalid saved Hessian case")
        if case.get("kind", "matrix") != "native_parts":
            continue
        model = case.get("model_id")
        h.require(isinstance(model, str) and len(h.member_path(model)) == 1,
                  "invalid saved native model")
        parts = case.get("hessian_parts")
        h.require(isinstance(parts, list) and parts, "missing saved native parts")
        for part in parts:
            h.require(isinstance(part, dict), "invalid saved native part")
            match = re.fullmatch(r"parts/part_([1-9][0-9]*)/bet\.hes", part.get("path", ""))
            h.require(match is not None, "invalid saved native part path")
            number = int(match.group(1))
            rows = part.get("row_bounds")
            npar = part.get("n_parameter")
            h.require(type(npar) is int and 1 <= npar <= 100000 and
                      isinstance(rows, list) and len(rows) == 2 and
                      all(type(x) is int for x in rows) and
                      1 <= rows[0] <= rows[1] <= npar, "invalid saved native rows")
            name = model + "/part_" + str(number) + "/mfcl_hessian_log.txt"
            h.require(name not in expected, "duplicate saved native part")
            expected[name] = {"model_id": model, "part": number,
                              "row_bounds": rows, "n_parameter": npar}

    members = data["members"]
    h.require(isinstance(members, dict) and 1 <= len(members) <= 256 and
              members.keys() == expected.keys(),
              "native logs must cover every saved native part exactly")
    folded = set()
    total = 0
    for name, pin in members.items():
        h.member_path(name)
        key = name.casefold()
        h.require(key not in folded, "native log paths collide")
        folded.add(key)
        h.keys(pin, ("bytes", "sha256", "mode", "model_id", "part",
                     "row_bounds", "n_parameter"))
        h.bounded_integer(pin["bytes"], h.MAX_MEMBER)
        h.require(pin["bytes"] > 0 and isinstance(pin["sha256"], str) and
                  h.SHA.fullmatch(pin["sha256"]), "invalid native log member pin")
        h.require(type(pin["mode"]) is int and pin["mode"] == 0o644,
                  "native log mode must preserve original 0644")
        h.require(isinstance(pin["row_bounds"], list) and
                  all(type(x) is int for x in pin["row_bounds"]),
                  "invalid native log row bounds")
        h.require(all(pin[k] == v and type(pin[k]) is type(v)
                      for k, v in expected[name].items()),
                  "native log case/part/row binding differs")
        total += pin["bytes"]
    h.require(total <= h.MAX_EXPANDED, "excessive native log bytes")
    entry = {"archive": archive, "members": {
        name: {key: pin[key] for key in ("bytes", "sha256", "mode")}
        for name, pin in members.items()}}
    return path, data, entry


def verify_archive(entry, manifest, archive):
    with tempfile.TemporaryDirectory(prefix="bet-native-logs-") as scratch:
        scratch = Path(scratch)
        packed = scratch / "archive.tar.gz"
        members = scratch / "members"
        members.mkdir(mode=0o700)
        h.copy_archive(entry, manifest, archive, packed)
        h.validate_tar(packed, entry, members)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default=str(Path(__file__).with_name("native-logs.json")))
    parser.add_argument("--hessians", default=str(Path(__file__).with_name("hessians.json")))
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--archive")
    parser.add_argument("--out")
    args = parser.parse_args(argv)
    try:
        manifest, data, entry = read_manifest(args.manifest, args.hessians)
        if args.verify:
            h.require(args.out is None, "--verify does not create OUT")
            if args.archive is not None:
                verify_archive(entry, manifest, args.archive)
            operation = "archive_verified" if args.archive is not None else "manifest_verified"
        else:
            h.require(args.out is not None, "choose a new absolute OUT directory")
            h.restore(entry, manifest, args.out, args.archive)
            operation = "logs_restored"
        print(json.dumps({"operation": operation, "original_log_count": len(entry["members"]),
                          "original_log_bytes": sum(p["bytes"] for p in entry["members"].values()),
                          "archive_sha256": data["archive"]["sha256"],
                          "hessians_sha256": data["hessians_sha256"]}, sort_keys=True))
        return 0
    except (h.HessianError, OSError, ValueError, KeyError) as exc:
        print("native logs: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
