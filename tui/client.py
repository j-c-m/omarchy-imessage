"""Connect to the one messages daemon."""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

DAEMON = Path(__file__).resolve().parents[1] / "daemon"
sys.path.insert(0, str(DAEMON))

from hub import socket_path  # noqa: E402


class SocketClient:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.reader = reader
        self.writer = writer

    def send(self, command: dict) -> None:
        # Keys pressed while the daemon is down are dropped, not queued:
        # replaying a stale pair or scan after a reconnect would surprise.
        if self.writer.is_closing():
            return
        try:
            self.writer.write((json.dumps(command, ensure_ascii=False) + "\n").encode())
        except (ConnectionError, OSError):
            pass

    def close(self) -> None:
        try:
            self.writer.close()
        except (OSError, RuntimeError):
            pass

    async def lines(self):
        while True:
            line = await self.reader.readline()
            if not line:
                return
            text = line.decode("utf-8", errors="replace").strip()
            if not text:
                continue
            yield json.loads(text)


async def connect(standalone: bool = False) -> SocketClient:
    path = socket_path()
    try:
        reader, writer = await asyncio.open_unix_connection(path)
        return SocketClient(reader, writer)
    except (FileNotFoundError, ConnectionRefusedError, OSError):
        if not standalone:
            raise OSError(
                "tMsg daemon is not listening. Restart the shell so the plugin starts it, "
                "or run with --standalone."
            )
    process = await asyncio.create_subprocess_exec(
        sys.executable,
        "-u",
        str(DAEMON / "messagesd.py"),
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
        start_new_session=True,
        cwd=str(DAEMON),
    )
    for _ in range(50):
        if process.returncode is not None:
            break
        try:
            reader, writer = await asyncio.open_unix_connection(path)
            return SocketClient(reader, writer)
        except (FileNotFoundError, ConnectionRefusedError, OSError):
            await asyncio.sleep(0.05)
    raise OSError("tMsg daemon did not open its socket.")
