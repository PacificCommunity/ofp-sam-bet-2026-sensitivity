#!/usr/bin/env python3
"""Assemble original saved Hessian parts with MFCL switch 145=11 only."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import platform
import stat
import struct
import subprocess
import sys
import tempfile

import hessian as h
import restore as native

HERE = Path(__file__).absolute().parent
ARGS = ["bet.frq", "final.par", "ttt", "-switch", "1", "1", "145", "11"]
MAX_GENERATED = 1024 * 1024 * 1024


def package(entry):
    with native.frozen_bytes(native.HERE / "package.json") as raw:
        h.require(len(raw) <= h.MAX_MANIFEST, "native package metadata is excessive")
        recipe = json.loads(raw)
    manifest = native.read_json(recipe["manifest"])
    closure = native.read_json(recipe["closure"])
    model = entry["model_id"]
    matches = [row for row in closure["models"] if row["model"] == model]
    h.require(len(matches) == 1, "exact Hessian model_id is missing from native closure")
    inputs = native.required_native_inputs(recipe, closure, model)
    records = {}

    def add(name, pin):
        h.require(len(h.member_path(name)) == 1, "native input must be a flat filename")
        h.require(name not in records or all(records[name][key] == pin[key]
                  for key in ("sha256", "bytes")), "conflicting native input pins")
        records[name] = pin

    for row in manifest["files"]:
        path = PurePosixPath(row["path"])
        if path.parent.name == model:
            add(path.name, row)
    for row in matches[0]["reused_git_files"]:
        add(row.get("target_name", PurePosixPath(row["path"]).name), row)
    engine = recipe.get("engine_by_model", {}).get(model, recipe.get("engine"))
    if engine:
        add("mfclo64", engine)
    required = inputs | {"final.par", "mfclo64", "doitall.sh"}
    h.require(required <= records.keys(), "native inputs or case engine are incomplete")
    h.require(records["final.par"]["sha256"] == entry["final_par_sha256"] and
              records["final.par"]["bytes"] == entry["members"]["final.par"]["bytes"],
              "native final PAR differs from the original Hessian final PAR")
    return recipe, manifest, closure, inputs, records


def plan(case, entry):
    h.require(entry.get("kind") == "native_parts", "this case already has a saved full matrix")
    h.validate_part_manifest(entry)
    recipe, manifest, closure, inputs, records = package(entry)
    parts = entry["hessian_parts"]
    starts = [part["row_bounds"][0] for part in parts]
    parallel = ("# Number of parallel processes\n" + str(len(parts)) +
                "\n# Total number of independent variables\n" + str(parts[0]["n_parameter"]) +
                "\n# Start positions of each process\n" + " ".join(map(str, starts)) + "\n")
    return {"case": case, "model_id": entry["model_id"],
            "command": ["./mfclo64", *ARGS], "switch_145": 11,
            "parall_hess": parallel, "part_targets": ["bet.hes_" + str(i)
                for i in range(1, len(parts) + 1)], "required_inputs": sorted(inputs),
            "final_par_sha256": entry["final_par_sha256"],
            "engine_pin": {key: records["mfclo64"][key] for key in ("bytes", "sha256")},
            "historical_executed_engine_sha256": "UNKNOWN",
            "assembled_hessian_bit_equivalence": "UNVERIFIED"}, (recipe, manifest, closure, inputs, records)


def stage_native(entry, bundle, destination):
    recipe, manifest, closure, inputs, records = bundle
    payload = native.archive_files(recipe, manifest)
    native.restore(entry["model_id"], destination, recipe, manifest, closure, payload)
    selected = {}
    for name in sorted(inputs | {"final.par", "mfclo64"}):
        with native.frozen_bytes(destination / name) as raw:
            native.checked(raw, {"path": name, **records[name]})
            selected[name] = raw
    h.require(hashlib.sha256(selected["final.par"]).hexdigest() == entry["final_par_sha256"],
              "staged final PAR differs from original Hessian final PAR")
    engine = selected["mfclo64"]
    h.require(len(engine) >= 20 and engine[:6] == b"\x7fELF\x02\x01" and
              struct.unpack("<H", engine[18:20])[0] == 62,
              "case engine must be the pinned Linux x86-64 ELF")
    return selected


class Output:
    """Keep descriptors for every protected file and directory until completion."""

    def __init__(self, path, entry, manifest, expected_identity):
        self.path = Path(path)
        self.parents = h.PinnedParents(path)
        try:
            root = os.open(self.path.name, h.DIR_FLAGS, dir_fd=self.parents.fd)
        except BaseException:
            self.parents.close()
            raise
        self.root_identity = h.identity(os.fstat(root))[:2]
        self.tree = h.NewTree(root)
        self.pins = dict(entry["members"])
        self.held = {}
        try:
            h.require(self.root_identity == expected_identity, "restored output directory changed")
            for name in entry["members"]:
                parts = tuple(h.member_path(name))
                self.directory(parts[:-1], create=False)
            self.tree.check_files(self.pins)
            for name in self.pins:
                self.hold(name)
            self.check()
        except BaseException:
            self.close()
            raise

    def directory(self, parts, create=True):
        for i in range(1, len(parts) + 1):
            key = tuple(parts[:i])
            if key not in self.tree.fds:
                parent = self.tree.fds[key[:-1]]
                if create:
                    os.mkdir(key[-1], 0o700, dir_fd=parent)
                    self.tree.fds[key] = h.open_reserved_directory(key[-1], parent)
                else:
                    self.tree.fds[key] = os.open(key[-1], h.DIR_FLAGS, dir_fd=parent)
        return self.tree.fds[tuple(parts)]

    def hold(self, name):
        parts = tuple(h.member_path(name))
        fd = os.open(parts[-1], h.FILE_FLAGS, dir_fd=self.tree.fds[parts[:-1]])
        self.held[name] = (fd, h.identity(os.fstat(fd)))

    def check(self):
        self.parents.check()
        current = os.stat(self.path.name, dir_fd=self.parents.fd, follow_symlinks=False)
        h.require(stat.S_ISDIR(current.st_mode) and h.identity(current)[:2] ==
                  self.root_identity, "reserved output directory changed")
        self.tree.check()
        for name, (fd, before) in self.held.items():
            parts = tuple(h.member_path(name))
            named = os.stat(parts[-1], dir_fd=self.tree.fds[parts[:-1]], follow_symlinks=False)
            h.require(stat.S_ISREG(named.st_mode) and h.identity(named) == before and
                      h.identity(os.fstat(fd)) == before, "protected source file changed: " + name)
            digest = hashlib.sha256()
            count = 0
            while True:
                raw = os.pread(fd, h.CHUNK, count)
                if not raw:
                    break
                count += len(raw)
                h.require(count <= self.pins[name]["bytes"], "protected source file grew")
                digest.update(raw)
            h.require(count == self.pins[name]["bytes"] and digest.hexdigest() ==
                      self.pins[name]["sha256"], "protected source bytes changed: " + name)
            h.require(h.identity(os.fstat(fd)) == before and h.identity(os.stat(parts[-1],
                      dir_fd=self.tree.fds[parts[:-1]], follow_symlinks=False)) == before,
                      "protected source leaf changed: " + name)

    def add(self, name, raw, executable=False):
        self.check()
        pin = {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
        if name in self.pins:
            h.require(self.pins[name] == pin, "existing original input differs: " + name)
            return
        with self.tree.open_new(name) as handle:
            handle.write(raw)
            if executable:
                os.fchmod(handle.fileno(), 0o700)
            handle.flush()
            os.fsync(handle.fileno())
        self.pins[name] = pin
        self.hold(name)
        self.check()

    def source_bytes(self, name):
        self.check()
        return native.read_fd(self.held[name][0])

    def close(self):
        for fd, _ in self.held.values():
            os.close(fd)
        self.held = {}
        self.tree.close()
        self.parents.close()


def full_hessian(output, n):
    work = output.tree.fds[("stitched",)]
    fd = os.open("bet.hes", h.FILE_FLAGS, dir_fd=work)
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        h.require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1,
                  "derived Hessian is not a regular separate file")
        h.require(before.st_size <= MAX_GENERATED, "derived Hessian exceeds the output limit")
        if before.st_size == 4 + 8 * n * n:
            header_bytes = 4
            h.require(struct.unpack("<i", stream.read(4)) == (n,), "invalid full Hessian header")
        elif before.st_size == 12 + 8 * n * n:
            header_bytes = 12
            h.require(struct.unpack("<iii", stream.read(12)) == (n, 1, n),
                      "incomplete full Hessian row bounds")
        else:
            raise h.HessianError("derived Hessian has the wrong complete matrix size")
        digest = hashlib.sha256()
        stream.seek(0)
        first = stream.read(header_bytes)
        digest.update(first)
        count = header_bytes
        for block in iter(lambda: stream.read(h.CHUNK), b""):
            count += len(block)
            h.require(count <= before.st_size and len(block) % 8 == 0,
                      "derived Hessian byte layout changed")
            h.require(all(math.isfinite(value[0]) for value in struct.iter_unpack("<d", block)),
                      "derived Hessian contains non-finite values")
            digest.update(block)
        current = os.stat("bet.hes", dir_fd=work, follow_symlinks=False)
        h.require(h.identity(before) == h.identity(os.fstat(stream.fileno())) ==
                  h.identity(current) and count == before.st_size,
                  "derived Hessian changed while verifying")
        return {"path": "stitched/bet.hes", "bytes": count, "sha256": digest.hexdigest(),
                "header_bytes": header_bytes, "n_parameter": n,
                "row_bounds": [1, n], "finite_values": True}


def child_limits():
    # Bound each generated file. This is an execution limit, not a sandbox.
    import resource
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_GENERATED, MAX_GENERATED))


def child(argv, work, engine, log):
    return subprocess.run(argv, cwd="/proc/self/fd/" + str(work),
                          stdout=log, stderr=subprocess.STDOUT,
                          pass_fds=(engine, work), preexec_fn=child_limits,
                          timeout=600, check=False).returncode


def assemble(case, entry, manifest, out, archive=None):
    h.require(platform.system() == "Linux" and platform.machine() in ("x86_64", "AMD64"),
              "Hessian assembly requires Linux x86-64")
    selected_plan, bundle = plan(case, entry)
    guard = h.output_parents(out, manifest)
    guard.close()
    reserved = False
    output = None
    try:
        with tempfile.TemporaryDirectory(prefix="bet-stitch-inputs-") as tmp:
            native_files = stage_native(entry, bundle, Path(tmp).resolve() / "native")
            restored_identity = h.restore(entry, manifest, out, archive)
            reserved = True
            output = Output(out, entry, manifest, restored_identity)
            for name, raw in native_files.items():
                output.add(name, raw, executable=name == "mfclo64")
            output.directory(("stitched",))
            for name, raw in native_files.items():
                if name != "mfclo64":
                    output.add("stitched/" + name, raw)
            for index, part in enumerate(entry["hessian_parts"], 1):
                output.add("stitched/bet.hes_" + str(index), output.source_bytes(part["path"]))
            output.add("stitched/parall_hess", selected_plan["parall_hess"].encode())
            output.check()
            work = output.tree.fds[("stitched",)]
            engine = output.held["mfclo64"][0]
            log = os.open("mfcl_stitch_log.txt", os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                          os.O_NOFOLLOW, 0o600, dir_fd=work)
            argv = ["/proc/self/fd/" + str(engine), *ARGS]
            receipt = {"schema_version": 1, "case": case, "model_id": entry["model_id"],
                       "purpose": "assemble_original_saved_hessian_parts",
                       "command": argv, "logical_command": selected_plan["command"],
                       "engine_sha256": selected_plan["engine_pin"]["sha256"],
                       "historical_executed_engine_sha256": "UNKNOWN",
                       "assembled_hessian_bit_equivalence": "UNVERIFIED",
                       "original_final_par_sha256": entry["final_par_sha256"],
                       "original_parts": entry["hessian_parts"], "return_code": None,
                       "structural_output_valid": False, "derived_hessian": None}
            error = None
            try:
                receipt["return_code"] = child(argv, work, engine, log)
                output.check()
                receipt["derived_hessian"] = full_hessian(output, entry["hessian_parts"][0]["n_parameter"])
                receipt["structural_output_valid"] = True
                h.require(receipt["return_code"] in (0, 1), "MFCL returned an unsupported code")
            except (OSError, ValueError, h.HessianError, subprocess.SubprocessError) as exc:
                error = exc
                receipt["error"] = str(exc)
            finally:
                os.fsync(log)
                os.close(log)
            output.check()
            output.add("stitch.json", (json.dumps(receipt, indent=2) + "\n").encode())
            output.check()
            if error is not None:
                raise h.HessianError(str(error))
    except BaseException as exc:
        if reserved:
            raise h.HessianError("assembly failed; original parts and output retained: " +
                                 out + " (" + str(exc) + ")") from exc
        raise
    finally:
        if output is not None:
            output.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", required=True)
    parser.add_argument("--out")
    parser.add_argument("--archive", help="exact local saved-parts archive")
    parser.add_argument("--plan", action="store_true")
    args = parser.parse_args(argv)
    try:
        manifest, data = h.read_manifest(HERE / "hessians.json")
        h.require(args.case in data["cases"], "choose a case listed in hessians.json")
        entry = data["cases"][args.case]
        if args.plan:
            h.require(args.out is None and args.archive is None, "plan takes only CASE")
            print(json.dumps(plan(args.case, entry)[0], indent=2))
        else:
            h.require(args.out is not None, "OUT must be a new absolute directory")
            assemble(args.case, entry, manifest, args.out, args.archive)
            print("Assembled saved parts for " + args.case + " in " + args.out + "/stitched")
        return 0
    except (h.HessianError, OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        print("Hessian assembly: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
