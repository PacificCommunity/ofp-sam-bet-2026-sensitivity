"""Offline stitch fixtures: no MFCL, model, subprocess or network execution."""
import copy
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import hessian_stitch as s
sys.path.pop(0)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def pin(raw):
    return {"bytes": len(raw), "sha256": sha(raw)}


class StitchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="bet-stitch-fixture-")
        self.base = Path(self.tmp.name).resolve()
        self.manifest = self.base / "repo" / "reproduce" / "hessians.json"
        self.manifest.parent.mkdir(parents=True)
        self.out = self.base / "result"
        self.archive = self.base / "original.tar.gz"
        self.parts = {
            "parts/part_1/bet.hes": struct.pack("<iii4d", 2, 1, 2, 1., 2., 3., 4.),
            "final.par": b"original final par\n"}
        target = io.BytesIO()
        with tarfile.open(fileobj=target, mode="w", format=tarfile.USTAR_FORMAT) as tar:
            for name, body in self.parts.items():
                item = tarfile.TarInfo(name)
                item.size = len(body)
                tar.addfile(item, io.BytesIO(body))
        archive = gzip.compress(target.getvalue(), mtime=0)
        self.archive.write_bytes(archive)
        self.entry = {"kind": "native_parts", "model_id": "test-model", "pdh_status": "No",
                      "final_par_sha256": sha(self.parts["final.par"]),
                      "archive": {"url": "https://github.com/PacificCommunity/ofp-sam-bet-2026-sensitivity/releases/download/test/test.tar.gz", **pin(archive)},
                      "members": {name: pin(body) for name, body in self.parts.items()},
                      "hessian_parts": [{"path": "parts/part_1/bet.hes", "n_parameter": 2,
                                         "row_bounds": [1, 2], "bytes_hex": self.parts["parts/part_1/bet.hes"][:12].hex(),
                                         "sha256": sha(self.parts["parts/part_1/bet.hes"])}]}
        self.manifest.write_text(json.dumps({"schema_version": 1, "classification": "PUBLIC",
            "repository": "PacificCommunity/ofp-sam-bet-2026-sensitivity", "cases": {"test": self.entry}}))
        self.native_files = {name: (name + "\n").encode() for name in s.native.NATIVE_INPUTS}
        self.native_files["final.par"] = self.parts["final.par"]
        elf = bytearray(20)
        elf[:6] = b"\x7fELF\x02\x01"
        elf[18:20] = struct.pack("<H", 62)
        self.native_files["mfclo64"] = bytes(elf)  # Deliberately not an executable.
        self.records = {name: pin(body) for name, body in self.native_files.items()}
        self.records["doitall.sh"] = pin(b"original doitall\n")
        self.bundle = ({}, {}, {}, set(s.native.NATIVE_INPUTS), self.records)

    def tearDown(self):
        self.tmp.cleanup()

    def restore_and_open(self):
        expected = s.h.restore(self.entry, self.manifest, str(self.out), str(self.archive))
        return s.Output(str(self.out), self.entry, self.manifest, expected)

    def fixture_child(self, raw=None, code=0):
        body = struct.pack("<i4d", 2, 1., 2., 3., 4.) if raw is None else raw
        def run(argv, work, engine, log):
            self.assertEqual(argv[1:], s.ARGS)
            self.assertEqual(os.fstat(engine).st_size, 20)
            fd = os.open("bet.hes", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=work)
            try:
                os.write(fd, body)
            finally:
                os.close(fd)
            os.write(log, b"offline fixture, no engine execution\n")
            return code
        return run

    def assemble(self, child=None):
        with patch.object(s, "package", return_value=self.bundle), \
             patch.object(s, "stage_native", return_value=self.native_files), \
             patch.object(s.platform, "system", return_value="Linux"), \
             patch.object(s.platform, "machine", return_value="x86_64"), \
             patch.object(s, "child", side_effect=child or self.fixture_child()):
            s.assemble("test", self.entry, self.manifest, str(self.out), str(self.archive))

    def assert_originals(self):
        for name, body in self.parts.items():
            self.assertEqual((self.out / name).read_bytes(), body)

    def test_plan_has_only_source_stitch_command_and_exact_comments(self):
        with patch.object(s, "package", return_value=self.bundle):
            plan, _ = s.plan("test", self.entry)
        self.assertEqual(plan["command"], ["./mfclo64", "bet.frq", "final.par", "ttt", "-switch", "1", "1", "145", "11"])
        self.assertEqual(plan["parall_hess"], "# Number of parallel processes\n1\n# Total number of independent variables\n2\n# Start positions of each process\n1\n")
        self.assertEqual(plan["historical_executed_engine_sha256"], "UNKNOWN")
        self.assertEqual(plan["assembled_hessian_bit_equivalence"], "UNVERIFIED")

    def test_plan_refuses_saved_matrix_and_incomplete_components(self):
        for change in [{"kind": "matrix"}, {"hessian_parts": []},
                       {"hessian_parts": [dict(self.entry["hessian_parts"][0], row_bounds=[2, 2])]}]:
            with self.subTest(change=change), patch.object(s, "package", return_value=self.bundle):
                entry = dict(self.entry, **change)
                with self.assertRaises(s.h.HessianError):
                    s.plan("test", entry)

    def package_fixture(self, changes=None):
        directory = self.base / "metadata"
        directory.mkdir(exist_ok=True)
        rows = [{"path": "saved/test-model/" + name, **pin(body)} for name, body in self.native_files.items() if name != "mfclo64"]
        rows.append({"path": "saved/test-model/doitall.sh", **self.records["doitall.sh"]})
        manifest = {"files": rows}
        closure = {"models": [{"model": "test-model", "reused_git_files": []}]}
        recipe = {"manifest": {"path": "files.json", "sha256": ""}, "closure": {"path": "closure.json", "sha256": ""},
                  "engine": self.records["mfclo64"]}
        if changes:
            changes(recipe, manifest, closure)
        for field, data in [("manifest", manifest), ("closure", closure)]:
            raw = json.dumps(data).encode()
            (directory / recipe[field]["path"]).write_bytes(raw)
            recipe[field]["sha256"] = sha(raw)
        (directory / "package.json").write_text(json.dumps(recipe))
        return directory

    def test_package_exact_native_par_and_candidate_pin(self):
        directory = self.package_fixture()
        with patch.object(s.native, "HERE", directory):
            plan, _ = s.plan("test", self.entry)
        self.assertEqual(plan["engine_pin"], self.records["mfclo64"])

    def test_package_refuses_missing_case_engine_and_wrong_par(self):
        mutations = [lambda recipe, files, closure: recipe.update(engine_by_model={"test-model": None}),
                     lambda recipe, files, closure: files["files"][next(i for i, row in enumerate(files["files"]) if row["path"].endswith("final.par"))].update(sha256="0"*64),
                     lambda recipe, files, closure: closure["models"].append(copy.deepcopy(closure["models"][0]))]
        for mutation in mutations:
            directory = self.package_fixture(mutation)
            with patch.object(s.native, "HERE", directory), self.assertRaises(s.h.HessianError):
                s.plan("test", self.entry)

    def test_stage_native_checks_exact_inputs_and_linux_elf_before_execution(self):
        def restore(model, output, recipe, manifest, closure, payload):
            output.mkdir()
            for name, raw in self.native_files.items():
                (output / name).write_bytes(raw)
        destination = self.base / "native-stage"
        with patch.object(s.native, "archive_files", return_value={}), patch.object(s.native, "restore", side_effect=restore):
            selected = s.stage_native(self.entry, self.bundle, destination)
        self.assertEqual(selected, self.native_files)
        for change in ["pin-drift", "not-elf", "not-x86-64"]:
            destination = self.base / change
            files = copy.deepcopy(self.native_files)
            records = copy.deepcopy(self.records)
            if change == "pin-drift":
                files["bet.frq"] = b"different FRQ"
            elif change == "not-elf":
                files["mfclo64"] = b"not ELF" + bytes(13)
                records["mfclo64"] = pin(files["mfclo64"])
            else:
                files["mfclo64"] = files["mfclo64"][:18] + struct.pack("<H", 183)
                records["mfclo64"] = pin(files["mfclo64"])
            def bad_restore(model, output, recipe, manifest, closure, payload):
                output.mkdir()
                for name, raw in files.items():
                    (output / name).write_bytes(raw)
            bundle = self.bundle[:-1] + (records,)
            with patch.object(s.native, "archive_files", return_value={}), patch.object(s.native, "restore", side_effect=bad_restore), \
                 self.assertRaises((ValueError, s.h.HessianError)):
                s.stage_native(self.entry, bundle, destination)

    def test_success_retains_originals_and_labels_derived_matrix(self):
        self.assemble()
        self.assert_originals()
        receipt = json.loads((self.out / "stitch.json").read_text())
        self.assertEqual(receipt["historical_executed_engine_sha256"], "UNKNOWN")
        self.assertEqual(receipt["assembled_hessian_bit_equivalence"], "UNVERIFIED")
        self.assertTrue(receipt["structural_output_valid"])
        self.assertEqual(receipt["derived_hessian"]["sha256"], sha((self.out / "stitched/bet.hes").read_bytes()))
        self.assertEqual((self.out / "stitched/bet.hes_1").read_bytes(), self.parts["parts/part_1/bet.hes"])
        self.assertNotEqual((self.out / "stitched/final.par").stat().st_ino, (self.out / "final.par").stat().st_ino)

    def test_unsupported_return_code_and_missing_hessian_retain_sources(self):
        for child in [self.fixture_child(code=9), lambda *args: 0]:
            self.out = self.base / ("failed-" + str(id(child)))
            with self.assertRaises(s.h.HessianError):
                self.assemble(child)
            self.assert_originals()
            receipt = json.loads((self.out / "stitch.json").read_text())
            self.assertIn("error", receipt)

    def test_timeout_retains_sources_and_receipt(self):
        def timed(*args):
            raise s.subprocess.TimeoutExpired("fixture", 600)
        with self.assertRaises(s.h.HessianError):
            self.assemble(timed)
        self.assert_originals()
        self.assertIn("error", json.loads((self.out / "stitch.json").read_text()))

    def test_refuse_existing_output_before_staging(self):
        self.out.mkdir()
        (self.out / "foreign.txt").write_bytes(b"keep")
        with patch.object(s, "package", return_value=self.bundle), patch.object(s.platform, "system", return_value="Linux"), \
             patch.object(s.platform, "machine", return_value="x86_64"), patch.object(s, "stage_native") as stage:
            with self.assertRaises(s.h.HessianError):
                s.assemble("test", self.entry, self.manifest, str(self.out), str(self.archive))
            stage.assert_not_called()
        self.assertEqual((self.out / "foreign.txt").read_bytes(), b"keep")

    def test_restore_identity_rejects_new_root_with_same_bytes(self):
        expected = s.h.restore(self.entry, self.manifest, str(self.out), str(self.archive))
        renamed = self.base / "original-kept"
        self.out.rename(renamed)
        self.out.mkdir()
        for name, raw in self.parts.items():
            target = self.out / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
        with self.assertRaisesRegex(s.h.HessianError, "restored output directory changed"):
            s.Output(str(self.out), self.entry, self.manifest, expected)
        self.assertEqual(set(self.out.iterdir()), {self.out / "final.par", self.out / "parts"})
        self.assertEqual((renamed / "final.par").read_bytes(), self.parts["final.par"])

    def test_output_leaf_directory_root_and_parent_substitution_refused(self):
        for attack in ["leaf", "directory", "root", "parent"]:
            with self.subTest(attack=attack):
                self.out = self.base / ("case-" + attack)
                output = self.restore_and_open()
                try:
                    if attack == "leaf":
                        (self.out / "final.par").rename(self.out / "moved.par")
                        (self.out / "final.par").write_bytes(self.parts["final.par"])
                    elif attack == "directory":
                        (self.out / "parts").rename(self.out / "moved-parts")
                        (self.out / "parts").mkdir()
                    elif attack == "root":
                        self.out.rename(self.base / "moved-root")
                        self.out.mkdir()
                    else:
                        moved = self.base.parent / (self.base.name + "-moved")
                        self.base.rename(moved)
                        self.base.mkdir()
                    with self.assertRaises((s.h.HessianError, OSError)):
                        output.add("foreign-new", b"never written")
                    self.assertFalse((self.out / "foreign-new").exists())
                finally:
                    output.close()
                    if attack == "parent":
                        self.base.rmdir()
                        moved.rename(self.base)

    def test_output_inplace_source_change_refused(self):
        output = self.restore_and_open()
        try:
            (self.out / "final.par").write_bytes(b"changed source")
            with self.assertRaises(s.h.HessianError):
                output.check()
        finally:
            output.close()

    def test_output_exclusive_write_never_replaces_foreign_leaf(self):
        output = self.restore_and_open()
        try:
            (self.out / "foreign").write_bytes(b"keep")
            with self.assertRaises(FileExistsError):
                output.add("foreign", b"replacement")
            self.assertEqual((self.out / "foreign").read_bytes(), b"keep")
        finally:
            output.close()

    def test_derived_hessian_headers_finite_and_exact_size(self):
        specimens = [struct.pack("<i4d", 2, 1., 2., 3., 4.),
                     struct.pack("<iii4d", 2, 1, 2, 1., 2., 3., 4.)]
        output = self.restore_and_open()
        try:
            output.directory(("stitched",))
            target = self.out / "stitched/bet.hes"
            for raw in specimens:
                target.write_bytes(raw)
                result = s.full_hessian(output, 2)
                self.assertEqual(result["sha256"], sha(raw))
            for raw in [specimens[0][:-1], struct.pack("<i4d", 3, 1., 2., 3., 4.),
                        struct.pack("<iii4d", 2, 2, 2, 1., 2., 3., 4.),
                        struct.pack("<i4d", 2, 1., float("nan"), 3., 4.)]:
                target.write_bytes(raw)
                with self.assertRaises(s.h.HessianError):
                    s.full_hessian(output, 2)
            target.unlink()
            target.symlink_to(self.out / "parts/part_1/bet.hes")
            with self.assertRaises(OSError):
                s.full_hessian(output, 2)
        finally:
            output.close()

    def test_child_only_configures_bounded_pinned_process(self):
        with patch.object(s.subprocess, "run") as run:
            run.return_value.returncode = 1
            self.assertEqual(s.child(["/proc/self/fd/42", *s.ARGS], 41, 42, 43), 1)
        self.assertEqual(run.call_args.kwargs["cwd"], "/proc/self/fd/41")
        self.assertEqual(run.call_args.kwargs["pass_fds"], (42, 41))
        self.assertEqual(run.call_args.kwargs["timeout"], 600)
        self.assertIs(run.call_args.kwargs["preexec_fn"], s.child_limits)


if __name__ == "__main__":
    unittest.main()
