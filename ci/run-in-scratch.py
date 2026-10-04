#!/usr/bin/env python3
"""Run an existing validator with generated audits in a temporary copy."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
manifest = json.loads((root / "ci/preserved-files.json").read_text())
if len(sys.argv) < 2:
    raise SystemExit("Provide the existing validation command.")
with tempfile.TemporaryDirectory(
    prefix="bet-validation-", dir=os.environ.get("RUNNER_TEMP")
) as temporary:
    work = Path(temporary)
    for record in manifest["files"]:
        source = root / record["path"]
        target = work / record["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        if record["mode"] == "120000":
            target.symlink_to(os.readlink(source))
        else:
            shutil.copy2(source, target)
    result = subprocess.run(sys.argv[1:], cwd=work)
    raise SystemExit(result.returncode)
