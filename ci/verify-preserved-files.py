#!/usr/bin/env python3
"""Check the exact files retained from the published assessment source."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import sys

root = Path(__file__).resolve().parent.parent
manifest = json.loads((root / "ci/preserved-files.json").read_text())
failures = []
updates = manifest.get("approved_reader_updates", {})
assert isinstance(updates, dict) and set(updates) <= {"Makefile"}
assert all(isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value) for value in updates.values())
additions = manifest.get("approved_additions", [])
assert isinstance(additions, list)
assert len({record["path"] for record in manifest["files"] + additions}) == len(manifest["files"]) + len(additions)
for record in manifest["files"] + additions:
    relative = PurePosixPath(record["path"])
    if relative.is_absolute() or ".." in relative.parts:
        failures.append(f"Invalid preserved path: {relative}")
        continue
    path = root.joinpath(*relative.parts)
    try:
        if record["mode"] == "120000":
            if not path.is_symlink():
                raise ValueError("expected a symbolic link")
            content = os.readlink(path).encode()
        else:
            if path.is_symlink() or not path.is_file():
                raise ValueError("expected a regular file")
            content = path.read_bytes()
            executable = bool(path.stat().st_mode & 0o111)
            if executable != (record["mode"] == "100755"):
                raise ValueError("executable mode changed")
        observed = hashlib.sha256(content).hexdigest()
        if observed != updates.get(record["path"], record["sha256"]):
            raise ValueError("SHA256 changed")
    except (OSError, ValueError) as error:
        failures.append(f"{relative}: {error}")
if failures:
    print("\n".join(failures), file=sys.stderr)
    raise SystemExit(1)
print(f'Preserved {len(manifest["files"]) - len(updates)} original files, checked {len(updates)} approved Make updates and {len(additions)} preserved additions.')
