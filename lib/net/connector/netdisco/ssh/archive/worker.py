# 服务器端单次归档事务：锁覆盖上传与核验，客户端断开后退出且不重放设备命令。
"""在一个目标锁内处理单次上传事务，客户端断开后退出且不重放设备操作。"""

from contextlib import ExitStack
import fcntl
import hashlib
import json
import os
import re
import secrets
import stat
import sys
import time

MAX_BYTES = 64 * 1024 * 1024
CHUNK_BYTES = 64 * 1024
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


# 限量读取一行 JSON 请求；超长、断连或空请求直接拒绝，避免无界缓冲。
def receive():
    line = sys.stdin.buffer.readline(16385)
    if not line or len(line) > 16384:
        raise ValueError("invalid request")
    return json.loads(line)


# 发送带成功标记的单行事务响应，并立即刷新以解除客户端等待。
def send(**values):
    print(json.dumps(dict(ok=True, **values)), flush=True)


# 验证文件名仅为单个安全路径分量，拒绝目录穿越与控制字符。
def basename(value):
    if not isinstance(value, str) or not value or value in (".", ".."):
        raise ValueError("invalid filename")
    if any(c in value for c in ("/", "\\", "\0", "\r", "\n")):
        raise ValueError("invalid filename")
    return value


# 提取设备号和 inode，作为已打开对象的稳定身份。
def identity(s):
    return (s.st_dev, s.st_ino)


# 比较目录项与固定描述符的身份，拒绝符号链接或访问期间的替换。
def same_entry(parent, name, fd):
    current = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if identity(current) != identity(os.fstat(fd)) or stat.S_ISLNK(current.st_mode):
        raise ValueError("directory entry changed")


# 固定目录描述符并反复核对路径身份；上传暂存目录可共享，归档和锁目录必须私有。
class Directories:
    """固定目录描述符；允许共享上传暂存区，但元数据目录必须私有。"""

    # 逐级安全打开绝对根目录并登记句柄所有权，后续文件操作均相对该目录执行。
    def __init__(self, stack, root):
        if not os.path.isabs(root) or os.path.normpath(root) != root:
            raise ValueError("TFTP root must be a real absolute directory")
        fd = os.open("/", DIRECTORY_FLAGS)
        try:
            for component in root.split("/"):
                if component:
                    child = os.open(component, DIRECTORY_FLAGS, dir_fd=fd)
                    os.close(fd)
                    fd = child
        except BaseException:
            os.close(fd)
            raise
        self.root = fd
        self.path = root
        self.stack = stack
        self.links = []
        stack.callback(os.close, fd)

    # 取得或创建私有元数据目录，固定描述符并立即验证所有者、权限与目录项身份。
    def private(self, parent, name):
        try:
            os.mkdir(name, 0o700, dir_fd=parent)
            os.fsync(parent)
        except FileExistsError:
            pass
        fd = os.open(name, DIRECTORY_FLAGS, dir_fd=parent)
        self.stack.callback(os.close, fd)
        self.links.append((parent, name, fd))
        self.verify()
        return fd

    # 重新核对根目录及私有子目录，防止事务中途的改名或替换被误报为正常归档。
    def verify(self):
        # 根目录被移动时拒绝继续，避免回执指向与实际写入不同的路径。
        same_entry(None, self.path, self.root)
        if os.path.realpath(self.path) != self.path:
            raise ValueError("TFTP root changed")
        for parent, name, fd in self.links:
            s = os.fstat(fd)
            if not stat.S_ISDIR(s.st_mode) or s.st_uid != os.geteuid() or stat.S_IMODE(s.st_mode) != 0o700:
                raise ValueError("archive directories must be owned with mode 0700")
            same_entry(parent, name, fd)


# 汇集文件身份、大小和纳秒时间戳，用于识别上传前后或读取期间的变化。
def fingerprint(s):
    return (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)


# 从固定目录安全读取有界普通文件，读前、读后和路径身份必须一致。
def read_file(parent, name, missing=False, consume=None):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    except FileNotFoundError:
        if missing:
            return None, None
        raise
    with os.fdopen(fd, "rb") as f:
        before = os.fstat(f.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_BYTES:
            raise ValueError("unsafe or oversized file")
        digest = hashlib.sha256()
        size = 0
        while True:
            chunk = f.read(CHUNK_BYTES)
            if not chunk:
                break
            size += len(chunk)
            if size > MAX_BYTES:
                raise ValueError("oversized file")
            digest.update(chunk)
            if consume is not None and consume(chunk) != len(chunk):
                raise IOError("incomplete file write")
        # 同一时钟粒度内的覆写可能不改变 stat 时间；投递后重读摘要核对已发送字节。
        if consume is not None:
            f.seek(0)
            verified = hashlib.sha256()
            verified_size = 0
            while True:
                chunk = f.read(CHUNK_BYTES)
                if not chunk:
                    break
                verified_size += len(chunk)
                if verified_size > MAX_BYTES:
                    raise ValueError("oversized file")
                verified.update(chunk)
            if verified_size != size or verified.digest() != digest.digest():
                raise ValueError("file changed while delivering")
        after = os.fstat(f.fileno())
        if size != after.st_size or fingerprint(before) != fingerprint(after):
            raise ValueError("file changed while reading")
        if fingerprint(after) != fingerprint(os.stat(name, dir_fd=parent, follow_symlinks=False)):
            raise ValueError("file replaced while reading")
        return digest.hexdigest(), fingerprint(after)


# 在固定目录中以随机名称独占创建私有临时文件，碰撞时重新选择名称。
def temporary(parent, prefix):
    while True:
        name = prefix + secrets.token_hex(16)
        try:
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
            return fd, name
        except FileExistsError:
            pass


# 先写全并同步临时文件，再独占链接到归档名并同步目录，已有归档不会被覆盖。
def persist(parent, name, source_parent, source_name, expected, digest):
    fd, pending = temporary(parent, ".net-connector-")
    try:
        with os.fdopen(fd, "wb") as f:
            copied, current = read_file(source_parent, source_name, consume=f.write)
            if current != expected or copied != digest:
                raise ValueError("source changed before archive commit")
            f.flush()
            os.fsync(f.fileno())
        # 临时名与最终名均相对固定目录解析，父路径改名也不能将写入重定向。
        os.link(pending, name, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
        os.fsync(parent)
    finally:
        os.unlink(pending, dir_fd=parent)


# 验证锁为当前用户所有的单链接 0600 普通文件，且目录项仍匹配持锁描述符。
def verify_lock(parent, name, fd):
    s = os.fstat(fd)
    if not stat.S_ISREG(s.st_mode) or s.st_uid != os.geteuid() or s.st_nlink != 1 or stat.S_IMODE(s.st_mode) != 0o600:
        raise ValueError("archive lock must be an owned private regular file")
    same_entry(parent, name, fd)


# 独占创建目标锁；已存在时只打开旧锁，避免并发创建产生不同锁身份。
def open_lock(parent, name):
    flags = os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        return os.open(name, flags | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=parent)
    except FileExistsError:
        return os.open(name, flags, dir_fd=parent)


# 在同一服务器锁内完成旧文件保留、新上传核验、归档和可选清理；任一阶段失败都不重放设备上传。
def run():
    request = receive()
    root = request["root"]
    name = basename(request["filename"])
    archive_name = basename(request["archive_name"])
    batch = basename(request["batch"])
    if not re.fullmatch(r"[0-9_-]+-ssh-[a-f0-9]{16}", batch):
        raise ValueError("invalid batch name")
    with ExitStack() as stack:
        directories = Directories(stack, root)
        root_fd = directories.root
        archive_fd = directories.private(root_fd, "archive")
        batch_fd = directories.private(archive_fd, batch)
        lock_dir_fd = directories.private(root_fd, ".net-connector-locks")
        if request.get("action") == "preflight":
            directories.verify()
            fd, marker = temporary(root_fd, ".net-connector-upload-")
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
                os.unlink(marker, dir_fd=root_fd)
            directories.verify()
            send(phase="ready")
            return
        lock_name = hashlib.sha256(name.encode()).hexdigest()
        lock_fd = open_lock(lock_dir_fd, lock_name)
        stack.callback(os.close, lock_fd)
        verify_lock(lock_dir_fd, lock_name, lock_fd)
        deadline = time.monotonic() + 240
        while True:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("archive lock timeout")
                time.sleep(0.05)

        # 每个协议阶段重新校验固定目录和锁身份，失去原边界时拒绝继续事务。
        def verify_boundary():
            directories.verify()
            verify_lock(lock_dir_fd, lock_name, lock_fd)

        # 上传前先保留同名历史文件；只有服务器确认就绪后，客户端才允许设备导出。
        verify_boundary()
        old, previous = read_file(root_fd, name, missing=True)
        if previous is not None:
            previous_fd = directories.private(batch_fd, "previous")
            persist(previous_fd, archive_name, root_fd, name, previous, old)
        fd, marker = temporary(root_fd, ".net-connector-upload-")
        try:
            started = os.fstat(fd).st_mtime_ns
        finally:
            os.close(fd)
            os.unlink(marker, dir_fd=root_fd)
        verify_boundary()
        send(phase="ready")
        if receive().get("action") != "verify":
            return
        verify_boundary()
        # 新文件必须非空、区别于旧基线且不早于本次上传边界，旧文件不能冒充新结果。
        digest, current = read_file(root_fd, name)
        if not current[2] or current == previous or current[3] < started:
            raise ValueError("no new nonempty upload")
        persist(batch_fd, archive_name, root_fd, name, current, digest)
        archived, saved = read_file(batch_fd, archive_name)
        if archived != digest or saved[2] != current[2]:
            raise ValueError("archive verification failed")
        verify_boundary()
        destination = os.path.join(root, "archive", batch, archive_name)
        send(phase="archived", bytes=current[2], sha256=digest, archive_path=destination)
        delivered, check = read_file(batch_fd, archive_name, consume=sys.stdout.buffer.write)
        if delivered != digest or check != saved:
            raise ValueError("archive changed during delivery")
        verify_boundary()
        send(phase="delivered")
        # 远端归档及正文已交付客户端；只有收到客户端核验后的明确清理指令才删除 staging。
        action = receive()
        if action.get("action") == "cleanup":
            if action.get("sha256") != digest:
                raise ValueError("cleanup digest mismatch")
            verify_boundary()
            uploaded, check = read_file(root_fd, name)
            if check != current or uploaded != digest:
                raise ValueError("upload changed before cleanup")
            verify_boundary()
            os.unlink(name, dir_fd=root_fd)
            os.fsync(root_fd)
            send(phase="complete")


if __name__ == "__main__":
    try:
        run()
    except Exception:
        # 错误响应只发送固定诊断，不输出远端路径、配置正文或任意异常内容。
        print(json.dumps(dict(ok=False, error="tftp_archive_failed")), flush=True)
        sys.exit(1)
