"""Hold one native output directory and anchor file I/O and child cwd to it."""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import stat


def identity(value):
    return value.st_dev, value.st_ino


def signature(value):
    return identity(value), value.st_size, value.st_mtime_ns, value.st_ctime_ns


def read_fd(fd):
    chunks, offset = [], 0
    while True:
        data = os.pread(fd, 1024 * 1024, offset)
        if not data:
            return b"".join(chunks)
        chunks.append(data)
        offset += len(data)


class NativeDirectory:
    """Bind after restoration; reject later path or ancestor replacement.

    An identical plain-directory replacement before this initial capture cannot
    be distinguished from the restored directory. This class does not claim to
    recover that earlier ownership history.
    """

    def __init__(self, path):
        self.path = Path(os.path.abspath(path))
        self.parent = None
        self.fds, self.links = [], []
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK
        try:
            parent = os.open("/", flags)
            self.fds.append(parent)
            for name in self.path.parts[1:]:
                child = os.open(name, flags, dir_fd=parent)
                self.fds.append(child)
                value = os.fstat(child)
                self.links.append((parent, name, child, identity(value)))
                parent = child
            self.fd = parent
            self.inode = identity(os.fstat(parent))
            self.check()
        except BaseException:
            self.close()
            raise

    def close(self):
        for fd in reversed(self.fds):
            os.close(fd)
        self.fds = []

    def __enter__(self):
        self.check()
        return self

    def __exit__(self, kind, value, traceback):
        try:
            if kind is None:
                self.check()
        finally:
            self.close()

    def check(self):
        if not self.fds:
            raise ValueError("Native directory is closed")
        if self.parent is not None:
            self.parent.check()
        for parent, name, child, expected in self.links:
            held = os.fstat(child)
            named = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if (not stat.S_ISDIR(held.st_mode) or not stat.S_ISDIR(named.st_mode)
                    or identity(held) != expected or identity(named) != expected):
                raise ValueError("Native output directory or ancestor was replaced")
        held = os.fstat(self.fd)
        if not stat.S_ISDIR(held.st_mode) or identity(held) != self.inode:
            raise ValueError("Native output directory identity differs")

    @staticmethod
    def filename(name):
        if not isinstance(name, str) or name in ("", ".", "..") or "/" in name or "\0" in name:
            raise ValueError("Native file must be a plain filename")
        return name

    def exists(self, name):
        self.check()
        try:
            os.stat(self.filename(name), dir_fd=self.fd, follow_symlinks=False)
        except FileNotFoundError:
            result = False
        else:
            result = True
        self.check()
        return result

    def file_check(self, name, fd, before=None, data=None):
        held = os.fstat(fd)
        named = os.stat(name, dir_fd=self.fd, follow_symlinks=False)
        if (not stat.S_ISREG(held.st_mode) or not stat.S_ISREG(named.st_mode)
                or identity(named) != identity(held) or held.st_nlink != 1):
            raise ValueError("Native file was replaced: " + name)
        if before is not None and signature(held) != signature(before):
            raise ValueError("Native file changed while reading: " + name)
        if data is not None and read_fd(fd) != data:
            raise ValueError("Native file bytes changed while reading: " + name)
        self.check()

    @contextlib.contextmanager
    def open_input(self, name):
        name = self.filename(name)
        self.check()
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.fd)
        try:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                raise ValueError("Native input must be one regular file: " + name)
            data = read_fd(fd)
            self.file_check(name, fd, before, data)
            yield fd, data
            self.file_check(name, fd, before, data)
        finally:
            os.close(fd)

    def read_bytes(self, name):
        with self.open_input(name) as (_, data):
            return data

    @contextlib.contextmanager
    def open_new(self, name, mode=0o600, text=False):
        name = self.filename(name)
        self.check()
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_NONBLOCK,
                     mode, dir_fd=self.fd)
        try:
            os.fchmod(fd, mode)
            self.file_check(name, fd)
            with os.fdopen(fd, "w" if text else "wb", closefd=False) as stream:
                yield stream
                stream.flush()
                os.fsync(fd)
                self.file_check(name, fd)
        finally:
            os.close(fd)

    def write_new(self, name, data, mode=0o600):
        with self.open_new(name, mode) as stream:
            stream.write(data)
        if self.read_bytes(name) != data:
            raise ValueError("Native written bytes differ: " + name)

    def create_child(self, name):
        """Exclusively create a case beneath this held collection directory."""
        name = self.filename(name)
        self.check()
        os.mkdir(name, 0o700, dir_fd=self.fd)
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK,
                     dir_fd=self.fd)
        child = object.__new__(NativeDirectory)
        child.path, child.parent = self.path / name, self
        child.fds, child.fd = [fd], fd
        child.inode = identity(os.fstat(fd))
        child.links = [(self.fd, name, fd, child.inode)]
        try:
            child.check()
            return child
        except BaseException:
            child.close()
            raise

    def stage_files(self, files, model):
        """Write already checked original inputs and their read-back receipt."""
        if "saved-inputs.json" in files:
            raise ValueError("Reserved native receipt filename")
        for name, (data, mode) in files.items():
            self.filename(name)
            if not isinstance(data, bytes) or not isinstance(mode, int) or not 0 <= mode <= 0o777:
                raise ValueError("Invalid native file bytes or mode")
        entries = {}
        for name, (data, mode) in files.items():
            self.write_new(name, data, mode)
            observed = self.read_bytes(name)
            actual = os.stat(name, dir_fd=self.fd, follow_symlinks=False)
            if stat.S_IMODE(actual.st_mode) != mode:
                raise ValueError("Native staged file mode differs: " + name)
            entries[name] = {"sha256": hashlib.sha256(observed).hexdigest(),
                             "bytes": len(observed), "mode": mode}
        self.write_new("saved-inputs.json", (json.dumps(
            {"model": model, "purpose": "native_evaluation_inputs", "files": entries},
            indent=2) + "\n").encode())

    def child_kwargs(self, *fds):
        self.check()
        if not Path("/proc/self/fd").is_dir():
            raise ValueError("Native child execution requires Linux /proc/self/fd")
        return {"cwd": f"/proc/self/fd/{self.fd}", "pass_fds": (self.fd, *fds)}

    @staticmethod
    def child_file(fd):
        return f"/proc/self/fd/{fd}"


def original_files(tool, model):
    """Resolve the unchanged accepted restoration recipe without writing files."""
    with tool.frozen_bytes(tool.HERE / "package.json") as data:
        recipe = json.loads(data)
    manifest, closure = tool.read_json(recipe["manifest"]), tool.read_json(recipe["closure"])
    payload = tool.archive_files(recipe, manifest)
    matches = [row for row in closure["models"] if row["model"] == model]
    if len(matches) != 1:
        raise ValueError("Choose a model listed in closure.json")
    required = tool.required_native_inputs(recipe, closure, model) | {"final.par", "doitall.sh", "mfclo64"}
    files = {}

    def add(name, data, mode):
        NativeDirectory.filename(name)
        if name == "saved-inputs.json":
            raise ValueError("Reserved model target")
        if not isinstance(mode, int) or not 0 <= mode <= 0o777:
            raise ValueError("Unsupported saved mode: " + name)
        if name in files and files[name] != (data, mode):
            raise ValueError("Conflicting model target: " + name)
        files[name] = (data, mode)

    for row in manifest["files"]:
        path = Path(row["path"])
        if path.parent.name == model:
            add(path.name, payload[row["path"]], row["mode"])
    for row in matches[0]["reused_git_files"]:
        add(row.get("target_name", Path(row["path"]).name), tool.git_bytes(row), row["mode"])
    engine = recipe.get("engine_by_model", {}).get(model, recipe.get("engine"))
    if engine:
        add("mfclo64", tool.git_bytes(engine), engine["mode"])
    if not required <= files.keys():
        raise ValueError("Native model is incomplete: " + ", ".join(sorted(required - files.keys())))
    return files


def read_regular_bytes(path):
    path = Path(os.path.abspath(path))
    with NativeDirectory(path.parent) as directory:
        return directory.read_bytes(path.name)
