#!/usr/bin/env python3
"""Run native hotkey tests on a private, authenticated Xvfb server."""

import os
from pathlib import Path
import resource
import secrets
import select
import shutil
import signal
import struct
import subprocess
import tempfile


def limits():
    resource.setrlimit(resource.RLIMIT_CPU, (10, 10))
    resource.setrlimit(resource.RLIMIT_AS, (512 * 1024 * 1024,) * 2)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def main():
    server = shutil.which(os.environ.get("XVFB", "Xvfb"))
    if not server:
        raise SystemExit("Xvfb is required; tests never use the desktop DISPLAY.")
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="fulcrum-hotkey-") as directory:
        work = Path(directory)
        auth = work / "Xauthority"
        # FamilyWild lets the cookie work with the server-assigned display number.
        fields = [b"", b"", b"MIT-MAGIC-COOKIE-1", secrets.token_bytes(16)]
        auth.write_bytes(struct.pack(">H", 65535) + b"".join(
            struct.pack(">H", len(field)) + field for field in fields))
        auth.chmod(0o600)
        env = dict(os.environ, XAUTHORITY=str(auth), XDG_RUNTIME_DIR=directory)
        for key in ("DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS"):
            env.pop(key, None)
        read_fd, write_fd = os.pipe()
        process = None
        try:
            with (work / "xvfb.log").open("w+") as log:
                process = subprocess.Popen(
                    [server, "-displayfd", str(write_fd), "-auth", str(auth),
                     "-nolisten", "tcp", "-noreset", "-screen", "0", "1024x768x24"],
                    pass_fds=(write_fd,), env=env, stdout=log, stderr=log,
                    start_new_session=True, preexec_fn=limits)
                os.close(write_fd)
                write_fd = -1
                if not select.select([read_fd], [], [], 15)[0]:
                    log.flush()
                    log.seek(0)
                    raise RuntimeError("Private Xvfb startup timed out: " + log.read())
                number = os.read(read_fd, 32).decode().strip()
                if not number.isdigit():
                    log.seek(0)
                    raise RuntimeError("Private Xvfb failed: " + log.read())
                env["DISPLAY"] = ":" + number
                binary = os.environ.get("HOTKEY_TEST_BINARY")
                if not binary:
                    binary = str(work / "hotkey-test")
                    flags = subprocess.check_output(
                        ["pkg-config", "--cflags", "--libs", "glib-2.0", "x11"],
                        text=True).split()
                    subprocess.run(
                        [os.environ.get("CXX", "c++"), "-std=c++20", "-Wall",
                         "-Wextra", "-Werror", str(root / "tests/linux-hotkey-test.cpp"),
                         "-o", binary, *flags, "-l:libXtst.so.6"], check=True,
                        timeout=30)
                subprocess.run([binary], env=env, check=True, timeout=15,
                               start_new_session=True, preexec_fn=limits)
        finally:
            os.close(read_fd)
            if write_fd != -1:
                os.close(write_fd)
            if process and process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()


if __name__ == "__main__":
    main()
