#!/usr/bin/env python3
"""Restore saved native evaluation inputs to one new folder; never run MFCL."""
import argparse
import contextlib
import ctypes
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
import tarfile
import urllib.parse
import uuid


HERE = Path(__file__).resolve().parent
REPO = HERE.parent


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe_path(name):
    path = PurePosixPath(name)
    if path.is_absolute() or not path.parts or any(x in ("", ".", "..") for x in name.split("/")):
        raise ValueError("Unsafe saved path: " + name)
    return path


def checked(data, record):
    if len(data) != record["bytes"] or digest(data) != record["sha256"]:
        raise ValueError("Saved bytes differ: " + record["path"])
    return data


def identity(value):
    return value.st_dev, value.st_ino


def signature(value):
    return (identity(value), value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def read_fd(fd):
    result, offset = [], 0
    while True:
        data = os.pread(fd, 1024 * 1024, offset)
        if not data:
            return b"".join(result)
        result.append(data)
        offset += len(data)


@contextlib.contextmanager
def frozen_bytes(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("Source must be a regular file: " + str(path))
        data = read_fd(fd)

        def stable():
            now = os.fstat(fd)
            named = os.stat(path, follow_symlinks=False)
            if (signature(now) != signature(before) or identity(named) != identity(before)
                    or not stat.S_ISREG(named.st_mode) or read_fd(fd) != data):
                raise ValueError("Source changed while checking: " + str(path))

        stable()
        yield data
        stable()
    finally:
        os.close(fd)


def read_json(record):
    with frozen_bytes(HERE / safe_path(record["path"])) as data:
        if digest(data) != record["sha256"]:
            raise ValueError("Manifest checksum mismatch: " + record["path"])
        return json.loads(data)


def archive_files(recipe, manifest):
    record = recipe["archive"]
    archive = HERE / safe_path(record["path"])
    expected = {row["path"]: row for row in manifest["files"]}
    if len(expected) != len(manifest["files"]):
        raise ValueError("Duplicate manifest path")
    result = {}
    with frozen_bytes(archive) as archive_data:
        checked(archive_data, record)
        # The exact bytes hashed above are the only bytes decoded below.
        with tarfile.open(fileobj=io.BytesIO(archive_data), mode="r:gz") as stream:
            for member in stream:
                safe_path(member.name)
                if member.name not in expected or member.name in result:
                    raise ValueError("Unexpected or duplicate archive path")
                if not (member.isfile() or member.islnk()) or member.pax_headers:
                    raise ValueError("Unsupported archive member")
                row = expected[member.name]
                if member.mode != row["mode"]:
                    raise ValueError("Saved permission mode differs")
                if member.islnk():
                    safe_path(member.linkname)
                    if member.linkname not in result:
                        raise ValueError("Hardlink target must be an earlier checked file")
                    data = result[member.linkname]
                else:
                    data = stream.extractfile(member).read()
                result[member.name] = checked(data, row)
        if set(result) != set(expected):
            raise ValueError("Missing archive members")
    return result


@contextlib.contextmanager
def directory_chain(path):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    held = [os.open(path.anchor, flags)]
    links = []
    try:
        for name in path.parts[1:]:
            parent = held[-1]
            try:
                child = os.open(name, flags, dir_fd=parent)
            except FileNotFoundError:
                os.mkdir(name, 0o700, dir_fd=parent)
                child = os.open(name, flags, dir_fd=parent)
            held.append(child)
            links.append((parent, name, child))

        def stable():
            for parent, name, child in links:
                named = os.stat(name, dir_fd=parent, follow_symlinks=False)
                if not stat.S_ISDIR(named.st_mode) or identity(named) != identity(os.fstat(child)):
                    raise ValueError("Output ancestor changed")

        stable()
        yield held[-1], stable
    finally:
        for fd in reversed(held):
            os.close(fd)


def publish_new_directory(parent, stage, target):
    # Both APIs atomically refuse even an empty existing destination directory.
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        function, flag = library.renameatx_np, 0x00000004  # RENAME_EXCL
    elif sys.platform.startswith("linux"):
        function, flag = library.renameat2, 1  # RENAME_NOREPLACE
    else:
        raise ValueError("Exclusive restoration requires Linux or macOS")
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(parent, os.fsencode(stage), parent, os.fsencode(target), flag):
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number), target)


def save_files(output, files, model):
    with directory_chain(output.parent) as (parent, ancestors_stable):
        stage = ".bet-native-" + uuid.uuid4().hex
        os.mkdir(stage, 0o700, dir_fd=parent)
        directory = os.open(stage, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        held = {}
        location = stage
        try:
            def namespace_stable():
                ancestors_stable()
                named = os.stat(location, dir_fd=parent, follow_symlinks=False)
                if not stat.S_ISDIR(named.st_mode) or identity(named) != identity(os.fstat(directory)):
                    raise ValueError("Output directory changed")
                if set(os.listdir(directory)) != set(held):
                    raise ValueError("Unexpected output directory entry")
                for name, (fd, data, mode) in held.items():
                    actual = os.fstat(fd)
                    named = os.stat(name, dir_fd=directory, follow_symlinks=False)
                    if (not stat.S_ISREG(named.st_mode) or identity(named) != identity(actual)
                            or actual.st_nlink != 1 or stat.S_IMODE(actual.st_mode) != mode
                            or read_fd(fd) != data):
                        raise ValueError("Saved file changed: " + name)

            def save(name, data, mode):
                namespace_stable()
                fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
                held[name] = (fd, data, mode)
                remaining = memoryview(data)
                while remaining:
                    count = os.write(fd, remaining)
                    if not count:
                        raise OSError("Incomplete file write")
                    remaining = remaining[count:]
                os.fchmod(fd, mode)
                os.fsync(fd)
                namespace_stable()
                return fd

            namespace_stable()
            for name, (data, mode) in files.items():
                save(name, data, mode)
            receipt = {"model": model, "purpose": "native_evaluation_inputs", "files": {}}
            for name, (fd, _, _) in sorted(held.items()):
                data, actual = read_fd(fd), os.fstat(fd)
                receipt["files"][name] = {"sha256": digest(data), "bytes": len(data), "mode": stat.S_IMODE(actual.st_mode)}
            save("saved-inputs.json", (json.dumps(receipt, indent=2) + "\n").encode(), 0o600)
            namespace_stable()
            publish_new_directory(parent, stage, output.name)
            location = output.name
            namespace_stable()
        except BaseException:
            # Remove only our own receipt through the held directory descriptor.
            # Partial files are left in our staging folder rather than following a changed path.
            receipt = held.get("saved-inputs.json")
            if receipt is not None:
                try:
                    named = os.stat("saved-inputs.json", dir_fd=directory, follow_symlinks=False)
                    if identity(named) == identity(os.fstat(receipt[0])):
                        os.unlink("saved-inputs.json", dir_fd=directory)
                except OSError:
                    pass
            raise
        finally:
            for fd, _, _ in held.values():
                os.close(fd)
            os.close(directory)


def git_bytes(record):
    path = safe_path(record["path"])
    local = REPO / path
    if local.is_file() and not local.is_symlink():
        with frozen_bytes(local) as data:
            if len(data) == record["bytes"] and digest(data) == record["sha256"]:
                return data
    repo, commit = record["repository"], record["commit"]
    if not repo.startswith("PacificCommunity/") or len(commit) != 40 or any(x not in "0123456789abcdef" for x in commit):
        raise ValueError("Invalid public source pin")
    url = "https://raw.githubusercontent.com/" + repo + "/" + commit + "/" + urllib.parse.quote(str(path))
    response = subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "2",
                               "--max-time", "120", "--max-filesize", str(record["bytes"]), url],
                              stdout=subprocess.PIPE, check=True)
    return checked(response.stdout, record)


NATIVE_INPUTS = frozenset({"bet.frq", "bet.ini", "bet.tag", "bet.age_length", "bet.reg_scaling", "mfcl.cfg"})
LEGACY_NATIVE_INPUTS = NATIVE_INPUTS - {"bet.reg_scaling"}


def required_native_inputs(recipe, closure, model):
    overrides = recipe.get("required_inputs_by_model", {})
    if not isinstance(overrides, dict):
        raise ValueError("Native input policies must be a model mapping")
    known = {row["model"] for row in closure["models"]}
    for name, inputs in overrides.items():
        if not isinstance(name, str) or name not in known:
            raise ValueError("Unknown native input policy model")
        if (not isinstance(inputs, list) or not all(isinstance(value, str) for value in inputs)
                or len(inputs) != len(set(inputs))
                or frozenset(inputs) not in (NATIVE_INPUTS, LEGACY_NATIVE_INPUTS)):
            raise ValueError("Native input policy must contain all six inputs or omit only bet.reg_scaling")
    return set(overrides.get(model, NATIVE_INPUTS))


def restore(model, output, recipe, manifest, closure, payload):
    if os.path.lexists(output):
        raise ValueError("Existing output directory refused")
    output = output.resolve()
    if output == REPO or (REPO in output.parents and REPO / "outputs" not in output.parents):
        raise ValueError("Output inside the checkout must be beneath outputs/")
    matches = [row for row in closure["models"] if row["model"] == model]
    if len(matches) != 1:
        raise ValueError("Choose a model listed in closure.json")
    native_inputs = required_native_inputs(recipe, closure, model)
    files = {}

    def add(name, data, mode):
        if len(safe_path(name).parts) != 1:
            raise ValueError("Model targets must be plain filenames")
        if not isinstance(mode, int) or mode < 0 or mode > 0o777:
            raise ValueError("Unsupported saved mode: " + name)
        if name == "saved-inputs.json":
            raise ValueError("Reserved model target")
        if name in files and files[name] != (data, mode):
            raise ValueError("Conflicting model target: " + name)
        files[name] = (data, mode)

    for row in manifest["files"]:
        path = PurePosixPath(row["path"])
        if path.parent.name == model:
            add(path.name, payload[row["path"]], row["mode"])
    for row in matches[0]["reused_git_files"]:
        add(row.get("target_name", PurePosixPath(row["path"]).name), git_bytes(row), row["mode"])
    engine = recipe.get("engine_by_model", {}).get(model, recipe.get("engine"))
    if engine:
        add("mfclo64", git_bytes(engine), engine["mode"])
    required = native_inputs | {"final.par", "doitall.sh", "mfclo64"}
    if not required <= files.keys():
        raise ValueError("Native model is incomplete: " + ", ".join(sorted(required - files.keys())))
    save_files(output, files, model)
    print("Restored exact saved files for", model, "to", output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", nargs="?")
    parser.add_argument("output", nargs="?", type=Path)
    parser.add_argument("--verify", action="store_true", help="check compact native bytes without downloading or running MFCL")
    args = parser.parse_args()
    with frozen_bytes(HERE / "package.json") as data:
        recipe = json.loads(data)
    manifest, closure = read_json(recipe["manifest"]), read_json(recipe["closure"])
    payload = archive_files(recipe, manifest)
    if args.verify:
        print("Verified", len(payload), "saved native files.")
    else:
        if not args.model or not args.output:
            parser.error("Provide MODEL and a new OUTPUT directory, or --verify")
        restore(args.model, args.output, recipe, manifest, closure, payload)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, AttributeError, subprocess.CalledProcessError, tarfile.TarError) as error:
        raise SystemExit(str(error))
