"""The terminal UI asks the daemon to open a conversation and mark it read."""

import asyncio
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

try:
    from textual.pilot import Pilot  # noqa: F401
except ImportError:  # pragma: no cover
    raise unittest.SkipTest("textual is not installed")

from tui.app import ImsgApp, render_message
from tui.render import link_spans


class QueueClient:
    def __init__(self) -> None:
        self.sent = []
        self.queue: asyncio.Queue = asyncio.Queue()

    def send(self, command: dict) -> None:
        self.sent.append(command)

    async def lines(self):
        while True:
            item = await self.queue.get()
            if item is None:
                return
            yield item

    async def push(self, event: dict) -> None:
        await self.queue.put(event)


class LinkTests(unittest.TestCase):
    def test_a_bare_host_is_a_link(self):
        spans = link_spans("Stop him: voterep.co/j237n today")
        self.assertEqual(spans, [(10, 26, "https://voterep.co/j237n")])

    def test_a_rendered_message_keeps_the_link_target(self):
        text = render_message({"body": "see https://example.com/a now", "direction": "in", "timestamp": "2026-10-02T12:00:00"})
        styles = [str(span.style) for span in text.spans]
        self.assertTrue(any("https://example.com/a" in style for style in styles))


class OpenTests(unittest.IsolatedAsyncioTestCase):
    async def test_moving_onto_a_conversation_marks_it_read_and_loads_it(self):
        client = QueueClient()
        app = ImsgApp(client=client)
        async with app.run_test(size=(100, 24)) as pilot:
            await client.push({
                "event": "threads",
                "threads": [
                    {"key": "tel:+15550001111", "label": "Ada", "unread": 1, "preview": "hi"},
                    {"key": "tel:+15550002222", "label": "Bo", "unread": 0, "preview": "yo"},
                ],
            })
            await pilot.pause()
            await pilot.press("j")
            await pilot.pause()
            await client.push({
                "event": "messages",
                "thread": "tel:+15550002222",
                "messages": [
                    {"body": "yo https://example.com/a", "direction": "in", "timestamp": "2026-10-02T12:00:00"},
                ],
            })
            await pilot.pause()
        commands = [item["cmd"] for item in client.sent]
        self.assertIn("messages", commands)
        self.assertIn("mark-read", commands)
        marked = [item for item in client.sent if item["cmd"] == "mark-read"]
        self.assertEqual(marked[-1]["thread"], "tel:+15550002222")


if __name__ == "__main__":
    unittest.main()
