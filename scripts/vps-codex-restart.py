#!/usr/bin/env python3
"""Explicit, identity-bound restart of the desktop VPS Unix app-server."""

from __future__ import annotations

import argparse
import asyncio
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import socket
import stat
import struct
import tomllib

MAX_BYTES = 1024 * 1024
MAX_THREADS = 4096
STOP_TIMEOUT = 120


class Blocked(RuntimeError):
    pass


class Uncertain(RuntimeError):
    pass


def bounded_read(path: Path, limit: int = MAX_BYTES) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise Blocked("A required VPS file has unexpected ownership or type.")
        data = os.read(fd, limit + 1)
        if len(data) > limit or os.read(fd, 1):
            raise Blocked("A required VPS file exceeds the inspection limit.")
        return data
    finally:
        os.close(fd)


def config_digest(codex_home: Path) -> str:
    data = bounded_read(codex_home / "config.toml")
    try:
        tomllib.loads(data.decode("utf-8"))
    except (ValueError, UnicodeError):
        raise Blocked("VPS config.toml is invalid. Correct it before restarting.") from None
    return hashlib.sha256(data).hexdigest()


def allowed_argv(argv: list[bytes]) -> bool:
    if argv.count(b"app-server") != 1:
        return False
    index = argv.index(b"app-server")
    prefix = argv[1:index]
    if len(prefix) % 2 or any(prefix[i] not in {b"-c", b"--config"} for i in range(0, len(prefix), 2)):
        return False
    return argv[index:] in [
        [b"app-server", b"--listen", b"unix://"],
        [b"app-server", b"--remote-control", b"--listen", b"unix://"],
    ]


def process_identity(pid: int, runtime: Path, proc_root: Path = Path("/proc")) -> dict:
    root = proc_root / str(pid)
    if pid <= 1 or root.stat().st_uid != os.geteuid():
        raise Blocked("The desktop server owner could not be verified.")
    before = bounded_read(root / "stat", 8192)
    fields = before.decode().rsplit(")", 1)[1].split()
    start = fields[19]
    argv = [part for part in bounded_read(root / "cmdline", 65536).split(b"\0") if part]
    if not allowed_argv(argv) or not os.path.samefile(root / "exe", runtime):
        raise Blocked("The desktop server is not the current managed Unix runtime.")
    if bounded_read(root / "stat", 8192).decode().rsplit(")", 1)[1].split()[19] != start:
        raise Blocked("The desktop server changed during inspection.")
    return {"pid": pid, "processStart": start}


async def rpc(ws, request_id: int, method: str, params: dict | None = None) -> dict:
    request = {"id": request_id, "method": method}
    if params is not None:
        request["params"] = params
    async with asyncio.timeout(10):
        await ws.send(json.dumps(request))
        while True:
            message = json.loads(await ws.recv())
            if message.get("id") != request_id:
                continue
            if "error" in message or not isinstance(message.get("result"), dict):
                raise Blocked("The desktop server could not complete its readiness check.")
            return message["result"]


async def connect_owner(socket_path: Path, runtime: Path):
    import websockets

    ws = await websockets.unix_connect(
        str(socket_path), uri="ws://localhost/", compression=None,
        open_timeout=10, close_timeout=2, max_size=MAX_BYTES,
    )
    try:
        peer = ws.transport.get_extra_info("socket").getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
        pid, uid, _ = struct.unpack("3i", peer)
        if uid != os.geteuid():
            raise Blocked("The desktop socket belongs to a different user.")
        identity = process_identity(pid, runtime)
        await rpc(ws, 1, "initialize", {
            "clientInfo": {"name": "codexswitch-config-restart", "version": "1"},
            "capabilities": {"experimentalApi": True},
        })
        await asyncio.wait_for(ws.send(json.dumps({"method": "initialized"})), 10)
        return ws, identity
    except BaseException:
        await ws.close()
        raise


async def require_idle(ws) -> None:
    cursor = None
    seen_cursors = set()
    count = 0
    request_id = 2
    async with asyncio.timeout(30):
        while True:
            page = await rpc(ws, request_id, "thread/loaded/list", {"limit": 100, "cursor": cursor})
            request_id += 1
            ids = page.get("data")
            if not isinstance(ids, list) or any(not isinstance(value, str) for value in ids):
                raise Blocked("Loaded VPS tasks could not be verified.")
            count += len(ids)
            if count > MAX_THREADS:
                raise Blocked("Too many loaded VPS tasks to verify safely.")
            for thread_id in ids:
                result = await rpc(ws, request_id, "thread/read", {"threadId": thread_id, "includeTurns": False})
                request_id += 1
                thread = result.get("thread") or {}
                status = thread.get("status")
                if not isinstance(status, dict) or status.get("type") != "idle":
                    raise Blocked("VPS work is active or its state is unknown. Finish it before restarting.")
            cursor = page.get("nextCursor")
            if cursor is None:
                return
            if not isinstance(cursor, str) or not cursor or cursor in seen_cursors:
                raise Blocked("Loaded VPS task pagination could not be verified.")
            seen_cursors.add(cursor)


def acquire_lock(path: Path, *, exclusive: bool, create: bool = False) -> int:
    flags = (os.O_RDWR | os.O_CREAT if create else os.O_RDONLY) | os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise Blocked("The VPS maintenance lock could not be verified.")
        fcntl.flock(fd, (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | fcntl.LOCK_NB)
        return fd
    except BaseException:
        os.close(fd)
        raise


async def start_native(runtime: Path, codex_home: Path) -> dict:
    env = dict(os.environ, CODEX_HOME=str(codex_home))
    process = await asyncio.create_subprocess_exec(
        str(runtime), "app-server", "daemon", "start", env=env,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
    )
    try:
        async with asyncio.timeout(45):
            output = bytearray()
            while len(output) <= 65536:
                chunk = await process.stdout.read(min(4096, 65537 - len(output)))
                if not chunk:
                    break
                output.extend(chunk)
            if len(output) > 65536 or await process.wait() != 0:
                raise Uncertain("The desktop server stopped, but startup could not be verified.")
        result = json.loads(output)
        if result.get("status") not in {"started", "alreadyRunning"} or not result.get("appServerVersion"):
            raise Uncertain("The desktop server startup response was incomplete.")
        return result
    finally:
        if process.returncode is None:
            process.terminate()
            try:
                await asyncio.wait_for(process.wait(), 2)
            except asyncio.TimeoutError:
                # Only the spawned lifecycle command, never the app-server, is reaped here.
                process.kill()
                await process.wait()


async def wait_for_exit(pidfd: int) -> None:
    deadline = asyncio.get_running_loop().time() + STOP_TIMEOUT
    while not select.select([pidfd], [], [], 0)[0]:
        if asyncio.get_running_loop().time() >= deadline:
            raise Uncertain("The desktop server has not stopped. It was not force-killed or restarted again.")
        await asyncio.sleep(0.1)


async def run(args) -> dict:
    codex_home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex").expanduser()
    install = Path.home() / ".local/share/codexswitch"
    runtime = install / "current/patched-codex/codex"
    socket_path = codex_home / "app-server-control/app-server-control.sock"
    if not codex_home.is_absolute() or not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        raise Blocked("This VPS does not support a verified desktop restart.")
    locks = []
    ws = None
    pidfd = None
    signalled = False
    try:
        locks.append(acquire_lock(install / "runtime-start-install.lock", exclusive=False))
        if args.restart:
            locks.append(acquire_lock(install / "vps-config-restart.lock", exclusive=True, create=True))
        digest = config_digest(codex_home)
        ws, identity = await connect_owner(socket_path, runtime)
        await require_idle(ws)
        # Let Codex validate config types too, without displaying the returned values.
        await rpc(ws, 100000, "config/read", {"includeLayers": False})
        plan = dict(identity, configDigest=digest)
        if not args.restart:
            return {"schemaVersion": 1, "status": "ready", **plan}
        if plan != {"pid": args.pid, "processStart": args.process_start, "configDigest": args.config_digest}:
            raise Blocked("The VPS process or config changed. Check again before restarting.")
        pidfd = os.pidfd_open(identity["pid"])
        verified_ws, verified_identity = await connect_owner(socket_path, runtime)
        await verified_ws.close()
        if verified_identity != identity:
            raise Blocked("The desktop socket owner changed. Nothing was restarted.")
        if process_identity(identity["pid"], runtime) != identity or config_digest(codex_home) != digest:
            raise Blocked("The VPS process or config changed. Nothing was restarted.")
        signal.pidfd_send_signal(pidfd, signal.SIGINT)
        signalled = True
        await ws.close()
        ws = None
        await wait_for_exit(pidfd)
        started = await start_native(runtime, codex_home)
        ws, replacement = await connect_owner(socket_path, runtime)
        if replacement == identity or config_digest(codex_home) != digest:
            raise Uncertain("The replacement desktop server or configuration could not be verified.")
        return {"schemaVersion": 1, "status": "restarted", **replacement,
                "configDigest": digest, "appServerVersion": started["appServerVersion"]}
    except Uncertain:
        raise
    except Blocked:
        if signalled:
            raise Uncertain("Restart began, but the replacement server could not be verified. Check VPS readiness.") from None
        raise
    except Exception:
        if signalled:
            raise Uncertain("Restart outcome is unknown. Check VPS readiness before trying again.") from None
        raise Blocked("VPS preflight failed. No server was restarted; check connection, config, and runtime readiness.") from None
    finally:
        if ws is not None:
            try:
                await ws.close()
            except Exception:
                pass
        if pidfd is not None:
            os.close(pidfd)
        for fd in reversed(locks):
            os.close(fd)


def main() -> None:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--restart", action="store_true")
    parser.add_argument("--pid", type=int)
    parser.add_argument("--process-start")
    parser.add_argument("--config-digest")
    args = parser.parse_args()
    if args.restart and (not args.pid or not args.process_start or not args.config_digest):
        parser.error("restart requires the confirmed preflight identity")
    try:
        result = asyncio.run(run(args))
    except (Blocked, Uncertain) as error:
        result = {"schemaVersion": 1, "status": "unknown" if isinstance(error, Uncertain) else "blocked",
                  "message": str(error)}
    except Exception:
        result = {"schemaVersion": 1, "status": "unknown", "message": "VPS restart could not be verified. Check readiness."}
    print(json.dumps(result))


if __name__ == "__main__":
    main()
