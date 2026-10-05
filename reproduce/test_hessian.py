"""Offline fixtures for byte preservation and refusal of unsafe archives/paths."""

import contextlib
import copy
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import struct
import tarfile
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location("saved_hessian", HERE / "hessian.py")
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def pack(rows):
    target = io.BytesIO()
    with tarfile.open(fileobj=target, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, body, kind, link in rows:
            item = tarfile.TarInfo(name)
            item.type = kind
            item.linkname = link
            item.size = len(body)
            item.mode = 0o644
            archive.addfile(item, io.BytesIO(body))
    return gzip.compress(target.getvalue(), mtime=0)


class SavedHessianTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="hessian-fixture-")
        self.base = Path(self.tmp.name).resolve()
        self.repo = self.base / "repository"
        self.reproduce = self.repo / "reproduce"
        self.reproduce.mkdir(parents=True)
        self.manifest = self.reproduce / "hessians.json"
        self.archive = self.base / "original.tar.gz"
        self.out = self.base / "restored"
        self.bodies = {
            "bet.hes": b"original Hessian\n0.125 7.25\n",
            "final.par": b"original final PAR\n123.456\n",
            "hessian_info.rds": b"X\n\x00\x01original binary info\xff",
            "hessian_runs.rds": b"X\n\x00\x02original binary runs\xfe",
            "mfcl_hessian_log.txt": b"original optimizer record\n",
            "full/bet.dep": b"original full dependency file\n",
            "compact/bet.dep": b"original compact dependency file\n",
            "full/deplabel.tmp": b"original full labels\n",
            "compact/deplabel.tmp": b"original compact labels\n",
        }
        self.rows = [(name, body, tarfile.REGTYPE, "")
                     for name, body in self.bodies.items()]
        self.data = {
            "schema_version": 1, "classification": "PUBLIC",
            "repository": "PacificCommunity/ofp-sam-bet-2026-ensemble",
            "cases": {"ensemble-005": {
                "model_id": "original-model-005", "report_id": "report-003",
                "pdh_status": "FALSE",
                "hessian_sha256": sha(self.bodies["bet.hes"]),
                "final_par_sha256": sha(self.bodies["final.par"]),
                "archive": {
                    "url": "https://github.com/PacificCommunity/ofp-sam-bet-2026-ensemble/releases/download/hessians-2026/ensemble-005.tar.gz",
                    "bytes": 0, "sha256": ""},
                "members": {name: {"bytes": len(body), "sha256": sha(body)}
                            for name, body in self.bodies.items()}}}}
        self.replace_archive(pack(self.rows))
        self.save()

    def tearDown(self):
        self.tmp.cleanup()

    @property
    def entry(self):
        return self.data["cases"]["ensemble-005"]

    def save(self):
        self.manifest.write_text(json.dumps(self.data), encoding="utf-8")

    def replace_archive(self, raw):
        self.archive.write_bytes(raw)
        self.entry["archive"]["bytes"] = len(raw)
        self.entry["archive"]["sha256"] = sha(raw)

    def call(self, *args):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = h.main(["--manifest", str(self.manifest), *args])
        return result, stdout.getvalue(), stderr.getvalue()

    def restore(self):
        return self.call("--case", "ensemble-005", "--out", str(self.out),
                         "--archive", str(self.archive))

    def rejected_archive(self, raw):
        # Repin compressed bytes so rejection must come from member/TAR verification.
        self.replace_archive(raw)
        self.save()
        result, _, error = self.restore()
        self.assertEqual(result, 1, error)
        self.assertFalse(self.out.exists(), "OUT was reserved before archive validation")

    def test_cli_restores_by_original_model_id(self):
        result, stdout, stderr = self.call("--case", "original-model-005",
                                           "--out", str(self.out),
                                           "--archive", str(self.archive))
        self.assertEqual((result, stderr), (0, ""))
        for name, body in self.bodies.items():
            self.assertEqual((self.out / name).read_bytes(), body)
        self.assertIn("ensemble-005", stdout)

    def test_cli_refuses_ambiguous_model_id_before_output(self):
        self.data["cases"]["ensemble-006"] = copy.deepcopy(self.entry)
        self.save()
        result, _, stderr = self.call("--case", "original-model-005",
                                      "--out", str(self.out),
                                      "--archive", str(self.archive))
        self.assertEqual(result, 1)
        self.assertIn("unique model ID", stderr)
        self.assertFalse(self.out.exists())

    def test_manifest_only_never_downloads(self):
        with patch.object(h.urllib.request, "build_opener", side_effect=AssertionError("network")):
            result, output, _ = self.call("--verify")
        self.assertEqual(result, 0)
        self.assertIn("1 cases", output)

    def test_offline_full_archive_verification_without_output(self):
        result, output, error = self.call("--verify", "--case", "ensemble-005",
                                         "--archive", str(self.archive))
        self.assertEqual(result, 0, error)
        self.assertIn("Archive verified", output)
        self.assertFalse(self.out.exists())

    def test_restore_all_original_bytes_and_metadata(self):
        result, output, error = self.restore()
        self.assertEqual(result, 0, error)
        self.assertIn("Restored ensemble-005", output)
        self.assertEqual(stat.S_IMODE(self.out.stat().st_mode), 0o700)
        for name, body in self.bodies.items():
            self.assertEqual((self.out / name).read_bytes(), body)
            self.assertEqual(stat.S_IMODE((self.out / name).stat().st_mode), 0o600)
        original = h.read_manifest(self.manifest)[1]
        self.assertEqual(original, self.data)

    def test_tracked_relative_archive_uses_same_pins(self):
        assets = self.reproduce / "archives"
        assets.mkdir()
        (assets / "ensemble-005.tar.gz").write_bytes(self.archive.read_bytes())
        self.entry["archive"].pop("url")
        self.entry["archive"]["relative_path"] = "archives/ensemble-005.tar.gz"
        self.save()
        result, _, error = self.call("--case", "ensemble-005", "--out", str(self.out))
        self.assertEqual(result, 0, error)
        self.assertEqual((self.out / "bet.hes").read_bytes(), self.bodies["bet.hes"])

    def test_minimal_case_does_not_invent_optional_metadata_files(self):
        self.rows = self.rows[:2]
        self.entry["members"] = {k: self.entry["members"][k] for k in ("bet.hes", "final.par")}
        self.entry.pop("report_id")
        self.replace_archive(pack(self.rows))
        self.save()
        result, _, error = self.restore()
        self.assertEqual(result, 0, error)
        self.assertEqual(set(os.listdir(self.out)), {"bet.hes", "final.par"})

    def test_optional_hessian_header_preserves_both_legacy_and_new_prefixes(self):
        for length in (4, 12):
            with self.subTest(length=length):
                self.entry["hessian_header"] = {
                    "bytes_hex": self.bodies["bet.hes"][:length].hex(),
                    "n_parameter": 1997, "row_bounds": [1, 1997]}
                self.save()
                self.assertEqual(self.call("--verify", "--case", "ensemble-005",
                                          "--archive", str(self.archive))[0], 0)
        self.entry["hessian_header"]["bytes_hex"] = "00" * 12
        self.save()
        self.assertEqual(self.restore()[0], 1)
        self.assertFalse(self.out.exists())

    def test_existing_directory_file_and_symlinks_are_untouched(self):
        for kind in ("directory", "file", "symlink", "broken-symlink"):
            with self.subTest(kind=kind):
                if kind == "directory":
                    self.out.mkdir()
                    (self.out / "keep.txt").write_bytes(b"foreign bytes")
                elif kind == "file":
                    self.out.write_bytes(b"foreign file")
                else:
                    self.out.symlink_to(self.archive if kind == "symlink" else self.base / "absent")
                with patch.object(h, "copy_archive", side_effect=AssertionError("read before refusal")):
                    result, _, error = self.restore()
                self.assertEqual(result, 1, error)
                if kind == "directory":
                    self.assertEqual((self.out / "keep.txt").read_bytes(), b"foreign bytes")
                    (self.out / "keep.txt").unlink()
                    self.out.rmdir()
                else:
                    if kind == "file":
                        self.assertEqual(self.out.read_bytes(), b"foreign file")
                    else:
                        self.assertTrue(self.out.is_symlink())
                    self.out.unlink()

    def test_output_must_be_external_absolute_canonical_new_path(self):
        for out in ("relative", str(self.base) + "/./x", str(self.base) + "//x",
                    str(self.base) + "/x/../y", str(self.repo / "out"), str(self.repo)):
            with self.subTest(out=out):
                result, _, error = self.call("--case", "ensemble-005", "--out", out,
                                             "--archive", str(self.archive))
                self.assertEqual(result, 1, error)
        self.assertFalse((self.repo / "out").exists())
        # An ancestor of the repository is refused too; no existence test is relied on.
        with self.assertRaises(h.HessianError):
            h.output_parents(str(self.base), self.manifest)

    def test_output_parent_symlink_is_refused(self):
        link = self.base / "linked-parent"
        link.symlink_to(self.base, target_is_directory=True)
        result, _, error = self.call("--case", "ensemble-005", "--out", str(link / "new"),
                                     "--archive", str(self.archive))
        self.assertEqual(result, 1, error)
        self.assertFalse((self.base / "new").exists())

    def test_local_archive_link_relative_path_and_parent_link_refused(self):
        link = self.base / "linked.tar.gz"
        link.symlink_to(self.archive)
        parent_link = self.base / "linked-parent"
        parent_link.symlink_to(self.base, target_is_directory=True)
        for value in (str(link), str(parent_link / self.archive.name), "relative.tar.gz"):
            with self.subTest(value=value):
                result, _, error = self.call("--case", "ensemble-005", "--out", str(self.out),
                                             "--archive", value)
                self.assertEqual(result, 1, error)
                self.assertFalse(self.out.exists())

    def test_compressed_sha_and_length_drift_refused(self):
        original = self.archive.read_bytes()
        for raw in (original[:-1], original + b"x", bytes([original[0] ^ 1]) + original[1:]):
            with self.subTest(length=len(raw)):
                self.archive.write_bytes(raw)
                result, _, error = self.restore()
                self.assertEqual(result, 1, error)
                self.assertFalse(self.out.exists())

    def test_scientific_member_sha_and_size_drift_refused(self):
        for replacement in (b"X" + self.bodies["bet.hes"][1:], b"longer Hessian data"):
            with self.subTest(body=replacement):
                changed = copy.deepcopy(self.rows)
                changed[0] = ("bet.hes", replacement, tarfile.REGTYPE, "")
                self.rejected_archive(pack(changed))

    def test_missing_extra_and_duplicate_members_refused(self):
        for rows in (self.rows[1:], self.rows + [("extra.txt", b"extra", tarfile.REGTYPE, "")],
                     self.rows + [self.rows[0]]):
            with self.subTest(rows=len(rows)):
                self.rejected_archive(pack(rows))

    def test_symlink_hardlink_directory_and_special_members_refused(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.DIRTYPE,
                     tarfile.FIFOTYPE, tarfile.CHRTYPE, tarfile.BLKTYPE,
                     tarfile.XHDTYPE, tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_SPARSE):
            with self.subTest(kind=kind):
                rows = copy.deepcopy(self.rows)
                rows[0] = ("bet.hes", self.bodies["bet.hes"], kind, "target")
                self.rejected_archive(pack(rows))

    def test_alternate_header_paths_refused(self):
        for name in ("../bet.hes", "/bet.hes", "./bet.hes", "full//bet.hes",
                     "full/../bet.hes", "full\\bet.hes", "different/bet.hes"):
            with self.subTest(name=name):
                rows = copy.deepcopy(self.rows)
                rows[0] = (name, self.bodies["bet.hes"], tarfile.REGTYPE, "")
                self.rejected_archive(pack(rows))

    def test_standard_ustar_prefix_path_is_preserved(self):
        name = "full/" + "a" * 95 + "/original.grad"
        body = b"original gradient bytes\n"
        self.rows.append((name, body, tarfile.REGTYPE, ""))
        self.entry["members"][name] = {"bytes": len(body), "sha256": sha(body)}
        self.replace_archive(pack(self.rows))
        self.save()
        result, _, error = self.restore()
        self.assertEqual(result, 0, error)
        self.assertEqual((self.out / name).read_bytes(), body)

    def test_invalid_header_truncation_end_padding_and_trailer_refused(self):
        plain = gzip.decompress(self.archive.read_bytes())
        corrupt_header = bytearray(plain)
        corrupt_header[0] ^= 1
        corrupt_padding = bytearray(plain)
        corrupt_padding[512 + len(self.bodies["bet.hes"])] = 1
        consumed = sum(512 + ((len(body) + 511) // 512) * 512 for _, body, _, _ in self.rows)
        for raw in (self.archive.read_bytes()[:-6], gzip.compress(bytes(corrupt_header), mtime=0),
                    gzip.compress(bytes(corrupt_padding), mtime=0),
                    gzip.compress(plain[:consumed + 512], mtime=0),
                    gzip.compress(plain[:520], mtime=0),
                    gzip.compress(plain + b"nonzero trailer", mtime=0)):
            with self.subTest(length=len(raw)):
                self.rejected_archive(raw)

    def test_excessive_compressible_tar_trailer_refused(self):
        plain = gzip.decompress(self.archive.read_bytes())
        self.rejected_archive(gzip.compress(plain + bytes(2 * 1024 * 1024), mtime=0))

    def test_public_schema_bounds_metadata_pins_and_path_collisions(self):
        mutations = [
            lambda d: d.update(schema_version=True),
            lambda d: d.update(classification="PRIVATE"),
            lambda d: d.update(extra="private audit field"),
            lambda d: d.update(cases={}),
            lambda d: d.update(repository="Other/other-repository"),
            lambda d: d["cases"]["ensemble-005"].update(pdh_status="FALSE\n"),
            lambda d: d["cases"]["ensemble-005"].update(final_par_sha256="0" * 64),
            lambda d: d["cases"]["ensemble-005"]["archive"].update(bytes=True),
            lambda d: d["cases"]["ensemble-005"]["archive"].update(bytes=-1),
            lambda d: d["cases"]["ensemble-005"]["archive"].update(bytes=h.MAX_ARCHIVE + 1),
            lambda d: d["cases"]["ensemble-005"]["archive"].update(relative_path="a.tar.gz"),
            lambda d: d["cases"]["ensemble-005"]["members"]["bet.hes"].update(bytes=h.MAX_MEMBER + 1),
            lambda d: d["cases"]["ensemble-005"]["members"].update({"BET.HES": {"bytes": 1, "sha256": "0" * 64}}),
            lambda d: d["cases"]["ensemble-005"]["members"].update({"full": {"bytes": 1, "sha256": "0" * 64}}),
            lambda d: d["cases"]["ensemble-005"]["members"].pop("final.par"),
        ]
        for mutate in mutations:
            changed = copy.deepcopy(self.data)
            mutate(changed)
            self.manifest.write_text(json.dumps(changed))
            with self.subTest(data=changed):
                result, _, error = self.call("--verify")
                self.assertEqual(result, 1, error)

    def test_fixed_release_url_rejects_external_query_or_parent_path(self):
        original = self.entry["archive"]["url"]
        for url in (original.replace("https:", "http:"), original + "?skip=1",
                    original.replace("PacificCommunity", "Other"),
                    original.replace("hessians-2026", ".."),
                    "https://example.test/model.tar.gz"):
            self.entry["archive"]["url"] = url
            self.save()
            with self.subTest(url=url):
                result, _, error = self.call("--verify")
                self.assertEqual(result, 1, error)

    def test_duplicate_json_keys_and_large_manifest_refused(self):
        self.manifest.write_text('{"schema_version":1,"schema_version":1}')
        self.assertEqual(self.call("--verify")[0], 1)
        self.manifest.write_bytes(b" " * (h.MAX_MANIFEST + 1))
        self.assertEqual(self.call("--verify")[0], 1)

    def test_archive_verify_never_fetches_without_local_archive(self):
        with patch.object(h, "copy_archive", side_effect=AssertionError("unexpected fetch")):
            self.assertEqual(self.call("--verify", "--case", "ensemble-005")[0], 1)
            self.assertEqual(self.call("--verify", "--case", "ensemble-005", "--out", str(self.out))[0], 1)

    def test_interrupted_write_retains_partial_output(self):
        original = h.NewTree.open_new
        output_calls = []

        def fail_second(tree, name):
            if self.out.exists() and os.fstat(tree.fds[()]).st_ino == self.out.stat().st_ino:
                output_calls.append(name)
                if len(output_calls) == 2:
                    raise OSError("fixture disk full")
            return original(tree, name)

        with patch.object(h.NewTree, "open_new", fail_second):
            result, _, error = self.restore()
        self.assertEqual(result, 1)
        self.assertIn("no reserved output was removed", error)
        self.assertEqual((self.out / "bet.hes").read_bytes(), self.bodies["bet.hes"])
        self.assertFalse((self.out / "final.par").exists())

    def test_exclusive_mkdir_race_never_modifies_foreign_output(self):
        original = os.mkdir

        def race(path, mode=0o777, *, dir_fd=None):
            if path == self.out.name and dir_fd is not None:
                original(path, mode, dir_fd=dir_fd)
                (self.out / "foreign.txt").write_bytes(b"foreign winner")
            return original(path, mode, dir_fd=dir_fd)

        with patch.object(h.os, "mkdir", race):
            result, _, error = self.restore()
        self.assertEqual(result, 1, error)
        self.assertEqual(set(os.listdir(self.out)), {"foreign.txt"})
        self.assertEqual((self.out / "foreign.txt").read_bytes(), b"foreign winner")

    def test_output_substitution_never_writes_replacement_directory(self):
        original = h.NewTree.open_new
        moved = self.base / "moved-owned-output"

        def substitute(tree, name):
            if self.out.exists() and os.fstat(tree.fds[()]).st_ino == self.out.stat().st_ino:
                self.out.rename(moved)
                self.out.mkdir()
                (self.out / "foreign.txt").write_bytes(b"foreign replacement")
            return original(tree, name)

        with patch.object(h.NewTree, "open_new", substitute):
            result, _, error = self.restore()
        self.assertEqual(result, 1, error)
        self.assertEqual(set(os.listdir(self.out)), {"foreign.txt"})
        self.assertEqual((self.out / "foreign.txt").read_bytes(), b"foreign replacement")
        self.assertEqual((moved / "bet.hes").read_bytes(), self.bodies["bet.hes"])

    def test_unknown_added_output_entry_prevents_success_and_is_retained(self):
        original = h.NewTree.check_files

        def add_foreign(tree, members):
            if self.out.exists() and os.fstat(tree.fds[()]).st_ino == self.out.stat().st_ino:
                (self.out / "foreign.txt").write_bytes(b"do not delete")
            return original(tree, members)

        with patch.object(h.NewTree, "check_files", add_foreign):
            result, _, error = self.restore()
        self.assertEqual(result, 1, error)
        self.assertEqual((self.out / "foreign.txt").read_bytes(), b"do not delete")
        for name, body in self.bodies.items():
            self.assertEqual((self.out / name).read_bytes(), body)

    def test_output_parent_substitution_is_detected(self):
        parent = self.base / "external-parent"
        parent.mkdir()
        self.out = parent / "new-output"
        moved = self.base / "moved-external-parent"
        original = h.NewTree.open_new

        def substitute(tree, name):
            if self.out.exists() and os.fstat(tree.fds[()]).st_ino == self.out.stat().st_ino:
                parent.rename(moved)
                parent.mkdir()
                (parent / "foreign.txt").write_bytes(b"foreign parent")
            return original(tree, name)

        with patch.object(h.NewTree, "open_new", substitute):
            result, _, error = self.restore()
        self.assertEqual(result, 1, error)
        self.assertEqual(set(os.listdir(parent)), {"foreign.txt"})
        self.assertEqual((parent / "foreign.txt").read_bytes(), b"foreign parent")
        self.assertEqual((moved / "new-output/bet.hes").read_bytes(), self.bodies["bet.hes"])

    def test_output_subdirectory_substitution_is_detected(self):
        original = h.NewTree.open_new
        moved = self.base / "moved-full-members"

        def substitute(tree, name):
            target = original(tree, name)
            if name == "full/bet.dep" and self.out.exists() and \
                    os.fstat(tree.fds[()]).st_ino == self.out.stat().st_ino:
                (self.out / "full").rename(moved)
                (self.out / "full").mkdir()
                (self.out / "full/foreign.txt").write_bytes(b"foreign subtree")
            return target

        with patch.object(h.NewTree, "open_new", substitute):
            result, _, error = self.restore()
        self.assertEqual(result, 1, error)
        self.assertEqual(set(os.listdir(self.out / "full")), {"foreign.txt"})
        self.assertEqual((self.out / "full/foreign.txt").read_bytes(), b"foreign subtree")
        self.assertEqual((moved / "bet.dep").read_bytes(), self.bodies["full/bet.dep"])

    def test_member_leaf_substitution_during_hash_is_detected_in_scratch_and_output(self):
        for phase in ("scratch", "output"):
            with self.subTest(phase=phase):
                original_open = os.open
                observed = []
                moved = self.base / ("moved-" + phase + "-bet.hes")

                def substitute(path, flags, mode=0o777, *, dir_fd=None):
                    fd = original_open(path, flags, mode, dir_fd=dir_fd)
                    output_phase = self.out.exists() and dir_fd is not None and \
                        os.fstat(dir_fd).st_ino == self.out.stat().st_ino
                    if path == "bet.hes" and flags == h.FILE_FLAGS and dir_fd is not None \
                            and not observed and output_phase == (phase == "output"):
                        os.rename("bet.hes", moved, src_dir_fd=dir_fd)
                        replacement = original_open("bet.hes", os.O_WRONLY | os.O_CREAT |
                            os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dir_fd)
                        with os.fdopen(replacement, "wb") as target:
                            target.write(b"X" * len(self.bodies["bet.hes"]))
                        observed.append((os.fstat(fd).st_ino, os.stat("bet.hes",
                            dir_fd=dir_fd, follow_symlinks=False).st_ino))
                    return fd

                with patch.object(h.os, "open", substitute):
                    result, _, error = self.restore()
                self.assertEqual(result, 1, error)
                self.assertIn("member path changed", error)
                self.assertEqual(len(observed), 1)
                self.assertNotEqual(*observed[0])
                self.assertEqual(moved.read_bytes(), self.bodies["bet.hes"])
                if phase == "scratch":
                    self.assertFalse(self.out.exists())
                else:
                    self.assertEqual((self.out / "bet.hes").read_bytes(),
                                     b"X" * len(self.bodies["bet.hes"]))

    def test_redirect_only_allows_known_https_release_hosts(self):
        handler = h.ReleaseRedirect()
        request = h.urllib.request.Request(self.entry["archive"]["url"])
        for url in ("http://release-assets.githubusercontent.com/a", "https://example.test/a",
                    "https://github.com:8443/a", "https://user@github.com/a", "https://github.com/a#x"):
            with self.subTest(url=url), self.assertRaises(h.HessianError):
                handler.redirect_request(request, None, 302, "", {}, url)
        redirected = handler.redirect_request(request, None, 302, "", {},
            "https://release-assets.githubusercontent.com/a?signature=original")
        self.assertEqual(redirected.host, "release-assets.githubusercontent.com")


class NativePartsTests(unittest.TestCase):
    def setUp(self):
        self.f = SavedHessianTests()
        self.f.setUp()
        entry = self.f.entry
        entry.pop("hessian_sha256")
        entry["kind"] = "native_parts"
        entry["pdh_status"] = "UNKNOWN"
        self.f.bodies = {"final.par": self.f.bodies["final.par"]}
        entry["hessian_parts"] = []
        for index, (start, end) in enumerate(((1, 2), (3, 4)), 1):
            name = "parts/part_" + str(index) + "/bet.hes"
            header = struct.pack("<iii", 4, start, end)
            body = header + struct.pack("<" + "d" * 8, *range(8))
            self.f.bodies[name] = body
            entry["hessian_parts"].append({"path": name, "n_parameter": 4,
                "row_bounds": [start, end], "bytes_hex": header.hex(), "sha256": sha(body)})
        self.f.bodies["parts/part_1/hessian_info.rds"] = b"opaque original part metadata\x00"
        entry["members"] = {name: {"bytes": len(body), "sha256": sha(body)}
                            for name, body in self.f.bodies.items()}
        self.repack()

    def tearDown(self):
        self.f.tearDown()

    def repack(self):
        self.f.rows = [(name, body, tarfile.REGTYPE, "") for name, body in self.f.bodies.items()]
        self.f.replace_archive(pack(self.f.rows))
        self.f.save()

    def rejected_manifest(self, changed):
        self.f.manifest.write_text(json.dumps(changed))
        result, _, error = self.f.restore()
        self.assertEqual(result, 1, error)
        self.assertFalse(self.f.out.exists())

    def test_parts_restore_exact_bytes_without_invented_full_matrix(self):
        result, _, error = self.f.restore()
        self.assertEqual(result, 0, error)
        for name, body in self.f.bodies.items():
            self.assertEqual((self.f.out / name).read_bytes(), body)
        self.assertFalse((self.f.out / "bet.hes").exists())
        self.assertNotIn("hessian_sha256", self.f.entry)
        self.assertEqual(self.f.entry["pdh_status"], "UNKNOWN")

    def test_one_original_complete_part_is_restored_as_a_part(self):
        entry = self.f.entry
        header = struct.pack("<iii", 4, 1, 4)
        body = header + struct.pack("<" + "d" * 16, *range(16))
        path = "parts/part_1/bet.hes"
        self.f.bodies = {"final.par": self.f.bodies["final.par"], path: body}
        entry["members"] = {name: {"bytes": len(raw), "sha256": sha(raw)}
                            for name, raw in self.f.bodies.items()}
        entry["hessian_parts"] = [{"path": path, "n_parameter": 4,
            "row_bounds": [1, 4], "bytes_hex": header.hex(), "sha256": sha(body)}]
        self.repack()
        result, _, error = self.f.restore()
        self.assertEqual(result, 0, error)
        self.assertEqual((self.f.out / path).read_bytes(), body)
        self.assertFalse((self.f.out / "bet.hes").exists())

    def test_gaps_overlap_reverse_order_and_incomplete_coverage_refused(self):
        for bounds in (([1, 2], [4, 4]), ([1, 2], [2, 4]),
                       ([3, 4], [1, 2]), ([0, 2], [3, 4]),
                       ([1, 0], [1, 4]), ([1, 2], [3, 3])):
            with self.subTest(bounds=bounds):
                changed = copy.deepcopy(self.f.data)
                parts = changed["cases"]["ensemble-005"]["hessian_parts"]
                for part, value in zip(parts, bounds):
                    part["row_bounds"] = list(value)
                    part["bytes_hex"] = struct.pack("<iii", 4, *value).hex()
                self.rejected_manifest(changed)
        changed = copy.deepcopy(self.f.data)
        changed["cases"]["ensemble-005"]["hessian_parts"].pop()
        self.rejected_manifest(changed)

    def test_missing_duplicate_part_and_inconsistent_dimension_refused(self):
        mutations = [
            lambda e: e["hessian_parts"].append(copy.deepcopy(e["hessian_parts"][0])),
            lambda e: e["members"].pop(e["hessian_parts"][0]["path"]),
            lambda e: e["hessian_parts"][1].update(n_parameter=5),
            lambda e: e["hessian_parts"][0].update(n_parameter=0),
            lambda e: e.update(hessian_parts=[]),
            lambda e: e["hessian_parts"][0].update(n_parameter=True),
            lambda e: e["hessian_parts"][0].update(row_bounds=[True, 2]),
        ]
        for mutate in mutations:
            changed = copy.deepcopy(self.f.data)
            mutate(changed["cases"]["ensemble-005"])
            self.rejected_manifest(changed)

    def test_native_header_source_sha_and_expected_byte_layout_refused_on_drift(self):
        mutations = [
            lambda e: e["hessian_parts"][0].update(bytes_hex="00" * 12),
            lambda e: e["hessian_parts"][0].update(bytes_hex="00" * 4),
            lambda e: e["hessian_parts"][0].update(sha256="0" * 64),
            lambda e: e["members"][e["hessian_parts"][0]["path"]].update(bytes=77),
            lambda e: e["hessian_parts"][0].update(extra="not in schema"),
        ]
        for mutate in mutations:
            changed = copy.deepcopy(self.f.data)
            mutate(changed["cases"]["ensemble-005"])
            self.rejected_manifest(changed)

    def test_actual_part_header_mismatch_refused_after_repinned_file_sha(self):
        part = self.f.entry["hessian_parts"][0]
        path = part["path"]
        body = struct.pack("<iii", 4, 1, 3) + self.f.bodies[path][12:]
        self.f.bodies[path] = body
        part["sha256"] = sha(body)
        self.f.entry["members"][path]["sha256"] = sha(body)
        self.repack()
        result, _, error = self.f.restore()
        self.assertEqual(result, 1, error)
        self.assertIn("header bytes differ", error)
        self.assertFalse(self.f.out.exists())

    def test_full_matrix_label_or_hash_cannot_be_added_to_native_parts(self):
        mutations = [
            lambda e: e["members"].update({"bet.hes": copy.deepcopy(e["members"][e["hessian_parts"][0]["path"]])}),
            lambda e: e.update(hessian_sha256="0" * 64),
            lambda e: e.update(hessian_header={"bytes_hex": "00" * 12, "n_parameter": 4}),
            lambda e: e["hessian_parts"][0].update(path="bet.hes"),
        ]
        for mutate in mutations:
            changed = copy.deepcopy(self.f.data)
            mutate(changed["cases"]["ensemble-005"])
            self.rejected_manifest(changed)

    def test_missing_and_wrong_final_par_source_pin_refused(self):
        for change in ("missing", "wrong-pin"):
            changed = copy.deepcopy(self.f.data)
            entry = changed["cases"]["ensemble-005"]
            if change == "missing":
                entry["members"].pop("final.par")
            else:
                entry["final_par_sha256"] = "0" * 64
            self.rejected_manifest(changed)

    def test_part_archive_corruption_and_missing_actual_part_refused(self):
        original_rows = copy.deepcopy(self.f.rows)
        for rows in (original_rows[:-1], [row for row in original_rows if row[0] != "parts/part_2/bet.hes"]):
            self.f.replace_archive(pack(rows))
            self.f.save()
            result, _, error = self.f.restore()
            self.assertEqual(result, 1, error)
            self.assertFalse(self.f.out.exists())
        changed = copy.deepcopy(original_rows)
        name, body, kind, link = changed[1]
        changed[1] = (name, body[:-1] + b"X", kind, link)
        self.f.replace_archive(pack(changed)); self.f.save()
        self.assertEqual(self.f.restore()[0], 1)
        self.assertFalse(self.f.out.exists())

    def test_parts_existing_output_is_never_overwritten(self):
        self.f.out.mkdir()
        (self.f.out / "keep.txt").write_bytes(b"preserve existing data")
        result, _, error = self.f.restore()
        self.assertEqual(result, 1, error)
        self.assertEqual((self.f.out / "keep.txt").read_bytes(), b"preserve existing data")

    def test_unknown_kind_is_rejected(self):
        changed = copy.deepcopy(self.f.data)
        changed["cases"]["ensemble-005"]["kind"] = "assembled_parts"
        self.rejected_manifest(changed)

    def test_unlisted_native_part_member_is_rejected(self):
        changed = copy.deepcopy(self.f.data)
        entry = changed["cases"]["ensemble-005"]
        entry["members"]["parts/unlisted/bet.hes"] = copy.deepcopy(
            entry["members"][entry["hessian_parts"][0]["path"]])
        self.rejected_manifest(changed)


if __name__ == "__main__":
    unittest.main()
