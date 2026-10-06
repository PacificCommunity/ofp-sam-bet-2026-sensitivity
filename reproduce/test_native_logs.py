"""Offline source-byte and hostile-archive checks; no model execution."""

import contextlib
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import struct
import tarfile
import tempfile
import unittest
from unittest import mock

import hessian as h
import native_logs as logs


class NativeLogsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="bet-log-test-")
        self.root = Path(self.tmp.name).resolve()
        self.repo = self.root / "repo"
        self.reproduce = self.repo / "reproduce"
        self.reproduce.mkdir(parents=True)
        self.manifest = self.reproduce / "native-logs.json"
        self.hessians = self.reproduce / "hessians.json"
        self.archive = self.reproduce / "logs.tar.gz"
        self.out = self.root / "restored"
        self.bodies = {"case-a/part_1/mfcl_hessian_log.txt": b"row 1\nlikelihood -2.5\n",
                       "case-a/part_2/mfcl_hessian_log.txt": b"row 2\npenalty 0.25\n"}
        self.saved = {"schema_version": 1, "classification": "PUBLIC",
                      "repository": "PacificCommunity/ofp-sam-bet-2026-stepwise",
                      "cases": {"case-a": {
                          "kind": "native_parts", "model_id": "case-a", "pdh_status": "No",
                          "final_par_sha256": "1" * 64,
                          "archive": {"relative_path": "unused-hessian.tar.gz",
                                      "bytes": 1, "sha256": "2" * 64},
                          "members": {"final.par": {"bytes": 1, "sha256": "1" * 64}},
                          "hessian_parts": []}}}
        case = self.saved["cases"]["case-a"]
        for part in (1, 2):
            path = "parts/part_" + str(part) + "/bet.hes"
            case["members"][path] = {"bytes": 28, "sha256": str(part + 2) * 64}
            case["hessian_parts"].append({"path": path, "row_bounds": [part, part],
                                           "n_parameter": 2,
                                           "bytes_hex": struct.pack("<iii", 2, part, part).hex(),
                                           "sha256": str(part + 2) * 64})
        self.hessians.write_text(json.dumps(self.saved) + "\n")
        self.data = {"schema_version": 1, "classification": "PUBLIC", "kind": "native_logs",
                     "repository": self.saved["repository"],
                     "hessians_sha256": self.sha(self.hessians.read_bytes()),
                     "archive": {"relative_path": "logs.tar.gz", "bytes": 1, "sha256": "0" * 64},
                     "members": {}}
        for part, (name, body) in enumerate(self.bodies.items(), 1):
            self.data["members"][name] = {"bytes": len(body), "sha256": self.sha(body),
                                          "mode": 0o644, "model_id": "case-a", "part": part,
                                          "row_bounds": [part, part], "n_parameter": 2}
        self.pack()

    def tearDown(self):
        self.tmp.cleanup()

    @staticmethod
    def sha(raw):
        return hashlib.sha256(raw).hexdigest()

    def save(self):
        self.manifest.write_text(json.dumps(self.data) + "\n")

    def pack(self, entries=None):
        if entries is None:
            entries = [(name, body, 0o644, tarfile.REGTYPE, "")
                       for name, body in self.bodies.items()]
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for name, body, mode, kind, target in entries:
                info = tarfile.TarInfo(name)
                info.size = len(body)
                info.mode = mode
                info.type = kind
                info.linkname = target
                archive.addfile(info, io.BytesIO(body))
        self.archive.write_bytes(gzip.compress(stream.getvalue(), mtime=0))
        self.data["archive"] = {"relative_path": "logs.tar.gz", "bytes": self.archive.stat().st_size,
                                "sha256": self.sha(self.archive.read_bytes())}
        self.save()

    def invoke(self, *args):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = logs.main(["--manifest", str(self.manifest), "--hessians", str(self.hessians),
                              *args])
        return code, stdout.getvalue(), stderr.getvalue()

    def reject_archive(self):
        code, _, error = self.invoke("--out", str(self.out))
        self.assertEqual(code, 2, error)
        self.assertFalse(self.out.exists())

    def test_restore_exact_original_bytes_to_private_new_tree(self):
        code, stdout, error = self.invoke("--out", str(self.out))
        self.assertEqual(code, 0, error)
        receipt = json.loads(stdout)
        self.assertEqual(receipt["operation"], "logs_restored")
        self.assertEqual(receipt["original_log_count"], 2)
        self.assertEqual(stat.S_IMODE(self.out.stat().st_mode), 0o700)
        for name, body in self.bodies.items():
            self.assertEqual((self.out / name).read_bytes(), body)
            self.assertEqual(stat.S_IMODE((self.out / name).stat().st_mode), 0o600)

    def test_offline_archive_verification_makes_no_out(self):
        code, stdout, error = self.invoke("--verify", "--archive", str(self.archive))
        self.assertEqual(code, 0, error)
        self.assertEqual(json.loads(stdout)["operation"], "archive_verified")
        self.assertFalse(self.out.exists())

    def test_manifest_only_verification_does_not_download(self):
        with mock.patch.object(h, "copy_archive", side_effect=AssertionError("downloaded")):
            code, stdout, error = self.invoke("--verify")
        self.assertEqual(code, 0, error)
        self.assertEqual(json.loads(stdout)["operation"], "manifest_verified")

    def test_sensitivity_family_uses_the_same_exact_restore(self):
        repository = "PacificCommunity/ofp-sam-bet-2026-sensitivity"
        self.saved["repository"] = repository
        self.hessians.write_text(json.dumps(self.saved) + "\n")
        self.data["repository"] = repository
        self.data["hessians_sha256"] = self.sha(self.hessians.read_bytes())
        self.save()
        self.assertEqual(self.invoke("--out", str(self.out))[0], 0)

    def test_duplicate_json_keys_and_wrong_release_repository_are_rejected(self):
        raw = self.manifest.read_text()
        self.manifest.write_text(raw.replace('"kind": "native_logs"',
                                            '"kind": "native_logs", "kind": "native_logs"'))
        self.assertEqual(self.invoke("--verify")[0], 2)
        self.data["archive"].pop("relative_path")
        self.data["archive"]["url"] = (
            "https://github.com/Other/repo/releases/download/tag/native-mfcl-logs.tar.gz")
        self.save()
        self.assertEqual(self.invoke("--verify")[0], 2)

    def test_manifest_and_archive_symlinks_are_rejected(self):
        original = self.manifest.read_bytes()
        linked = self.reproduce / "linked.json"
        linked.symlink_to(self.manifest)
        with self.assertRaises(OSError):
            logs.document(linked)
        linked_archive = self.reproduce / "linked.tar.gz"
        linked_archive.symlink_to(self.archive)
        self.assertEqual(self.invoke("--verify", "--archive", str(linked_archive))[0], 2)
        self.assertEqual(self.manifest.read_bytes(), original)

    def test_missing_case_part_is_rejected(self):
        self.data["members"].pop(next(iter(self.bodies)))
        self.save()
        self.reject_archive()

    def test_changed_row_binding_is_rejected(self):
        self.data["members"][next(iter(self.bodies))]["row_bounds"] = [2, 2]
        self.save()
        self.reject_archive()

    def test_boolean_row_is_rejected(self):
        self.data["members"][next(iter(self.bodies))]["row_bounds"] = [True, True]
        self.save()
        self.reject_archive()

    def test_hessian_manifest_hash_change_is_rejected(self):
        self.hessians.write_bytes(self.hessians.read_bytes() + b"\n")
        self.reject_archive()

    def test_mode_manifest_and_tar_are_both_checked(self):
        names = list(self.bodies)
        self.pack([(names[0], self.bodies[names[0]], 0o755, tarfile.REGTYPE, ""),
                   (names[1], self.bodies[names[1]], 0o644, tarfile.REGTYPE, "")])
        self.reject_archive()
        self.pack()
        self.data["members"][names[0]]["mode"] = 0o755
        self.save()
        self.reject_archive()

    def test_duplicate_or_missing_or_extra_member_is_rejected(self):
        name = next(iter(self.bodies))
        for entries in [
            [(name, self.bodies[name], 0o644, tarfile.REGTYPE, "")] * 2,
            [(name, self.bodies[name], 0o644, tarfile.REGTYPE, "")],
            [(name, self.bodies[name], 0o644, tarfile.REGTYPE, ""),
             ("extra.txt", b"extra", 0o644, tarfile.REGTYPE, "")],
        ]:
            with self.subTest(entries=[x[0] for x in entries]):
                self.pack(entries)
                self.reject_archive()

    def test_links_and_traversal_are_rejected(self):
        name = next(iter(self.bodies))
        for kind, path, target in [(tarfile.SYMTYPE, name, "/tmp/escaped"),
                                   (tarfile.LNKTYPE, name, "other"),
                                   (tarfile.REGTYPE, "../escaped", ""),
                                   (tarfile.DIRTYPE, name, "")]:
            with self.subTest(kind=kind, path=path):
                self.pack([(path, b"", 0o644, kind, target)])
                self.reject_archive()

    def test_wrong_archive_or_member_bytes_are_rejected(self):
        self.data["archive"]["sha256"] = "f" * 64
        self.save()
        self.reject_archive()
        names = list(self.bodies)
        self.pack([(names[0], b"x" * len(self.bodies[names[0]]), 0o644, tarfile.REGTYPE, ""),
                   (names[1], self.bodies[names[1]], 0o644, tarfile.REGTYPE, "")])
        self.reject_archive()

    def test_existing_out_and_symlink_parent_are_preserved(self):
        self.out.mkdir()
        marker = self.out / "keep"
        marker.write_bytes(b"keep")
        self.assertEqual(self.invoke("--out", str(self.out))[0], 2)
        self.assertEqual(marker.read_bytes(), b"keep")
        link = self.root / "parent-link"
        link.symlink_to(self.root, target_is_directory=True)
        self.assertEqual(self.invoke("--out", str(link / "new"))[0], 2)
        self.assertFalse((self.root / "new").exists())

    def test_repository_output_is_rejected(self):
        self.assertEqual(self.invoke("--out", str(self.repo / "new"))[0], 2)
        self.assertFalse((self.repo / "new").exists())

    def test_partial_output_survives_write_failure(self):
        original = h.NewTree.open_new
        calls = 0

        def fail_second_output(tree, name):
            nonlocal calls
            calls += 1
            if calls == 4:
                raise OSError("simulated write failure")
            return original(tree, name)

        with mock.patch.object(h.NewTree, "open_new", fail_second_output):
            code, _, error = self.invoke("--out", str(self.out))
        self.assertEqual(code, 2)
        self.assertIn("no reserved output was removed", error)
        name = next(iter(self.bodies))
        self.assertEqual((self.out / name).read_bytes(), self.bodies[name])

    def test_logs_are_rejected_by_existing_hessian_schema(self):
        with self.assertRaises(h.HessianError):
            h.read_manifest(self.manifest)

    def test_anonymous_release_download_checks_exact_archive(self):
        self.data["archive"]["url"] = (
            "https://github.com/PacificCommunity/ofp-sam-bet-2026-stepwise/"
            "releases/download/bet2026-hessians-20261006/native-mfcl-logs.tar.gz")
        self.data["archive"].pop("relative_path")
        self.save()
        packed = self.archive.read_bytes()
        seen = []

        class AnonymousOpener:
            def open(self, request, timeout):
                seen.append(request)
                return io.BytesIO(packed)

        with mock.patch.object(h.urllib.request, "build_opener", return_value=AnonymousOpener()):
            code, _, error = self.invoke("--out", str(self.out))
        self.assertEqual(code, 0, error)
        self.assertEqual(len(seen), 1)
        self.assertNotIn("Authorization", dict(seen[0].header_items()))


if __name__ == "__main__":
    unittest.main()
