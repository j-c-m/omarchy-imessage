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

from tui.app import Composer, ImsgApp, Transcript, render_message


def _background_columns(text, prefix: str) -> list[list[int]]:
    """Columns of each line whose style starts with prefix. Drops the trailing blank line."""
    rows: list[list[int]] = []
    start = 0
    plain = text.plain
    while start < len(plain):
        end = plain.find("\n", start)
        if end == -1:
            end = len(plain)
        columns = []
        for index in range(start, end):
            if any(str(span.style).startswith(prefix) and span.start <= index < span.end for span in text.spans):
                columns.append(index - start)
        rows.append(columns)
        if end == len(plain):
            break
        start = end + 1
    if rows and not rows[-1] and plain.endswith("\n"):
        rows.pop()
    return rows
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


class ThemeTests(unittest.TestCase):
    def test_the_screen_uses_terminal_ansi_colors(self):
        app = ImsgApp(client=QueueClient())
        self.assertTrue(app.ansi_color)
        self.assertEqual(app.theme, "ansi-dark")


class LinkTests(unittest.TestCase):
    def test_a_bare_host_is_a_link(self):
        spans = link_spans("Stop him: voterep.co/j237n today")
        self.assertEqual(spans, [(10, 26, "https://voterep.co/j237n")])

    def test_a_rendered_message_keeps_the_link_target(self):
        text = render_message({"body": "see https://example.com/a now", "direction": "in", "timestamp": "2026-10-02T12:00:00"})
        styles = [str(span.style) for span in text.spans]
        self.assertTrue(any("https://example.com/a" in style for style in styles))

    def test_a_sent_message_is_on_the_right_without_you(self):
        text = render_message(
            {"body": "hi", "direction": "out", "timestamp": "2026-10-02T12:04:00"},
            width=10,
        )
        self.assertNotIn("you", text.plain)
        lines = text.plain.splitlines()
        self.assertTrue(any(line.endswith("12:04") for line in lines))
        self.assertTrue(all(len(line) <= 10 for line in lines))
        self.assertTrue(any("hi" in line and line.startswith(" ") for line in lines))
        sent = [str(span.style) for span in text.spans]
        self.assertTrue(sent)
        self.assertTrue(all("on blue" in style and "bright_black" not in style for style in sent))
        self.assertEqual(_background_columns(text, "black on blue"), [list(range(5, 10)), list(range(5, 10))])

    def test_a_received_message_is_black_on_bright_black(self):
        text = render_message({"body": "hello", "direction": "in", "timestamp": "2026-10-02T12:00:00"})
        styles = [str(span.style) for span in text.spans]
        self.assertTrue(styles)
        self.assertTrue(all(style.startswith("black on bright_black") for style in styles))
        wide = render_message(
            {"body": "hi", "direction": "in", "timestamp": "2026-10-02T12:00:00"},
            width=20,
        )
        self.assertEqual(_background_columns(wide, "black on bright_black"), [list(range(5)), list(range(5))])


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

    async def test_a_notification_thread_opens_that_conversation(self):
        client = QueueClient()
        app = ImsgApp(client=client, thread="tel:+15550002222")
        async with app.run_test(size=(100, 24)) as pilot:
            await client.push({
                "event": "threads",
                "threads": [
                    {"key": "tel:+15550001111", "label": "Ada", "unread": 1, "preview": "hi"},
                    {"key": "tel:+15550002222", "label": "Bo", "unread": 1, "preview": "yo"},
                ],
            })
            await pilot.pause()
            self.assertEqual(app.open_key, "tel:+15550002222")
        marked = [item for item in client.sent if item["cmd"] == "mark-read"]
        self.assertEqual(marked[-1]["thread"], "tel:+15550002222")

    async def test_a_summon_focuses_this_screen_and_opens_the_conversation(self):
        from tui import instance

        focused: list[bool] = []
        original = instance.focus_this_window
        instance.focus_this_window = lambda: focused.append(True)
        client = QueueClient()
        app = ImsgApp(client=client)
        try:
            async with app.run_test(size=(100, 24)) as pilot:
                await client.push({
                    "event": "threads",
                    "threads": [
                        {"key": "tel:+15550001111", "label": "Ada", "unread": 0, "preview": "hi"},
                        {"key": "tel:+15550002222", "label": "Bo", "unread": 1, "preview": "yo"},
                    ],
                })
                await pilot.pause()
                app.summon("tel:+15550002222")
                await pilot.pause()
                self.assertEqual(app.open_key, "tel:+15550002222")
                self.assertEqual(focused, [True])
        finally:
            instance.focus_this_window = original

    async def test_t_toggles_notification_text(self):
        client = QueueClient()
        app = ImsgApp(client=client)
        async with app.run_test(size=(100, 24)) as pilot:
            await client.push({"event": "status", "status": {"state": "connected", "phoneName": "JM iPhone", "notifyBody": False}})
            await client.push({
                "event": "threads",
                "threads": [{"key": "tel:+15550001111", "label": "Ada", "unread": 0, "preview": "hi"}],
            })
            await pilot.pause()
            await pilot.press("t")
            await pilot.pause()
            self.assertTrue(app.notify_body)
        toggles = [item for item in client.sent if item["cmd"] == "set-notify-body"]
        self.assertEqual(toggles, [{"cmd": "set-notify-body", "enabled": True}])

    async def test_contacts_list_is_twenty_characters_wide(self):
        client = QueueClient()
        app = ImsgApp(client=client)
        async with app.run_test(size=(100, 24)) as pilot:
            await client.push({"event": "threads", "threads": [{"key": "tel:+15550001111", "label": "Ada", "unread": 0}]})
            await pilot.pause()
            status = app.query_one("#status")
            hint = app.query_one("#hint")
            self.assertEqual(status.styles.padding.left, 1)
            self.assertEqual(hint.styles.padding.right, 1)
            self.assertEqual(status.styles.background.ansi, 8)
            self.assertEqual(status.styles.color.ansi, 15)
            self.assertEqual(hint.styles.background.ansi, 8)
            self.assertEqual(hint.styles.color.ansi, 15)
            top_gap, bottom_gap = app.query(".bar-gap")
            self.assertEqual(top_gap.region.height, 1)
            self.assertEqual(bottom_gap.region.height, 1)
            self.assertEqual(top_gap.styles.background.ansi, 0)
            self.assertEqual(bottom_gap.styles.background.ansi, 0)
            self.assertEqual(top_gap.region.y, status.region.bottom)
            body = app.query_one("#body")
            self.assertEqual(body.region.y, top_gap.region.bottom)
            self.assertEqual(bottom_gap.region.y, body.region.bottom)
            self.assertEqual(hint.region.y, bottom_gap.region.bottom)
            threads = app.query_one("#threads")
            self.assertEqual(threads.region.width, 23)
            self.assertEqual(threads.styles.background.ansi, 0)
            self.assertEqual(threads.styles.border.right[0], "solid")
            self.assertEqual(threads.styles.border.right[1].ansi, 8)
            self.assertFalse(threads.styles.border.left[0])
            self.assertNotEqual(app.query_one("#transcript").styles.background.ansi, 8)
            await pilot.press("n")
            await client.push({
                "event": "contacts",
                "contacts": [{"name": "A very long contact name indeed", "address": "+15550001111", "kind": "tel"}],
            })
            await pilot.pause()
            panel = app.query_one("#threads")
            self.assertEqual(panel.region.width, 23)
            self.assertEqual(panel.content_region.width, 20)
            self.assertEqual(panel.get_option_at_index(0).prompt, "A very long contact ")

    async def test_resizing_the_window_reflows_the_conversation(self):
        client = QueueClient()
        app = ImsgApp(client=client)
        async with app.run_test(size=(100, 24)) as pilot:
            await client.push({
                "event": "threads",
                "threads": [
                    {"key": "tel:+15550001111", "label": "Ada", "unread": 0, "preview": "hi"},
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
                    {"body": "hello " * 40, "direction": "in", "timestamp": "2026-10-02T12:00:00"},
                ],
            })
            await pilot.pause()
            log = app.query_one("#transcript", Transcript)
            wide_lines = len(log.lines)
            wide = log.scrollable_content_region.width
            self.assertGreater(wide_lines, 1)
            self.assertGreater(wide, 40)
            await pilot.resize_terminal(52, 24)
            narrow = log.scrollable_content_region.width
            self.assertLess(narrow, wide)
            self.assertGreater(len(log.lines), wide_lines)
            self.assertLessEqual(max(strip.cell_length for strip in log.lines), narrow)
            await pilot.resize_terminal(100, 24)
            self.assertEqual(len(log.lines), wide_lines)
            self.assertLessEqual(max(strip.cell_length for strip in log.lines), log.scrollable_content_region.width)

    async def test_reply_starts_at_one_line_and_grows_to_five(self):
        client = QueueClient()
        app = ImsgApp(client=client)
        async with app.run_test(size=(100, 24)) as pilot:
            await client.push({
                "event": "threads",
                "threads": [{"key": "tel:+15550001111", "label": "Ada", "unread": 0, "preview": "hi"}],
            })
            await pilot.pause()
            await pilot.press("r")
            await pilot.pause()
            composer = app.query_one("#composer", Composer)
            self.assertEqual(composer.region.height, 1)
            self.assertEqual(composer.content_region.height, 1)
            width = composer.wrap_width
            self.assertGreater(width, 5)
            composer.insert("x" * (width + 1))
            await pilot.pause()
            self.assertGreater(composer.region.height, 1)
            self.assertLessEqual(composer.region.height, Composer.MAX_LINES)
            composer.insert("x" * (width * 8))
            await pilot.pause()
            self.assertEqual(composer.region.height, Composer.MAX_LINES)
            self.assertGreater(composer.wrapped_document.height, Composer.MAX_LINES)
            composer.clear()
            await pilot.pause()
            self.assertEqual(composer.region.height, 1)


class PairTests(unittest.IsolatedAsyncioTestCase):
    async def test_an_unpaired_phone_lists_phones_and_enter_pairs(self):
        client = QueueClient()
        app = ImsgApp(client=client)
        async with app.run_test(size=(100, 24)) as pilot:
            await client.push({"event": "status", "status": {"state": "not_paired", "detail": "Select your iPhone."}})
            await client.push({
                "event": "devices",
                "devices": [
                    {"address": "AA:BB:CC:DD:EE:FF", "name": "Ada iPhone", "paired": False},
                    {"address": "11:22:33:44:55:66", "name": "Other Phone", "paired": False},
                ],
            })
            await pilot.pause()
            self.assertEqual(app.mode, "phones")
            self.assertEqual(str(app.query_one("#hint").content), "j/k move    enter pair    p other pairing    / filter    esc back")
            panel = app.query_one("#threads")
            self.assertEqual(panel.get_option_at_index(0).prompt, "Ada iPhone")
            await pilot.press("enter")
            await pilot.pause()
        self.assertIn({"cmd": "devices"}, client.sent)
        self.assertEqual(
            [item for item in client.sent if item["cmd"] == "pair"],
            [{"cmd": "pair", "address": "AA:BB:CC:DD:EE:FF", "explicit": False}],
        )

    async def test_p_pairs_without_connecting_first(self):
        client = QueueClient()
        app = ImsgApp(client=client)
        async with app.run_test(size=(100, 24)) as pilot:
            await client.push({"event": "status", "status": {"state": "not_paired", "detail": ""}})
            await client.push({
                "event": "devices",
                "devices": [
                    {"address": "AA:BB:CC:DD:EE:FF", "name": "Ada iPhone", "paired": False},
                    {"address": "11:22:33:44:55:66", "name": "Other Phone", "paired": False},
                ],
            })
            await pilot.pause()
            await pilot.press("j")
            await pilot.press("p")
            await pilot.pause()
        self.assertEqual(
            [item for item in client.sent if item["cmd"] == "pair"],
            [{"cmd": "pair", "address": "11:22:33:44:55:66", "explicit": True}],
        )

    async def test_enter_on_an_empty_phone_list_scans(self):
        client = QueueClient()
        app = ImsgApp(client=client)
        async with app.run_test(size=(100, 24)) as pilot:
            await client.push({"event": "status", "status": {"state": "not_paired", "detail": ""}})
            await pilot.pause()
            await pilot.press("enter")
            await pilot.pause()
        self.assertIn({"cmd": "scan"}, client.sent)

    async def test_a_phone_filter_hides_other_phones(self):
        client = QueueClient()
        app = ImsgApp(client=client)
        async with app.run_test(size=(100, 24)) as pilot:
            await client.push({"event": "status", "status": {"state": "not_paired", "detail": ""}})
            await client.push({
                "event": "devices",
                "devices": [
                    {"address": "AA:BB:CC:DD:EE:FF", "name": "Ada iPhone", "paired": False},
                    {"address": "11:22:33:44:55:66", "name": "Other Phone", "paired": False},
                ],
            })
            await pilot.pause()
            await pilot.press("slash")
            await pilot.press("o", "t", "h")
            await pilot.pause()
            panel = app.query_one("#threads")
            self.assertEqual(panel.option_count, 1)
            self.assertEqual(panel.get_option_at_index(0).prompt, "Other Phone")

    async def test_a_connected_phone_leaves_the_phone_list(self):
        client = QueueClient()
        app = ImsgApp(client=client)
        async with app.run_test(size=(100, 24)) as pilot:
            await client.push({
                "event": "threads",
                "threads": [{"key": "tel:+15550001111", "label": "Ada", "unread": 0, "preview": "hi"}],
            })
            await client.push({"event": "status", "status": {"state": "not_paired", "detail": ""}})
            await pilot.pause()
            self.assertEqual(app.mode, "phones")
            await client.push({"event": "status", "status": {"state": "connected", "phoneName": "Ada iPhone"}})
            await pilot.pause()
            self.assertEqual(app.mode, "threads")
            self.assertEqual(app.query_one("#threads").get_option_at_index(0).prompt, "Ada")
            self.assertEqual(str(app.query_one("#status").content), "Connected: Ada iPhone")

    async def test_a_pairing_code_accepts_rejects_and_cancels(self):
        client = QueueClient()
        app = ImsgApp(client=client)
        async with app.run_test(size=(100, 24)) as pilot:
            await client.push({"event": "pair-code", "code": "123456"})
            await client.push({"event": "status", "status": {"state": "pairing", "detail": "Confirm this code on the iPhone too."}})
            await pilot.pause()
            self.assertEqual(str(app.query_one("#status").content), "Pairing code 123456")
            self.assertEqual(str(app.query_one("#hint").content), "y accept    n reject    esc cancel")
            await pilot.press("y")
            await pilot.pause()
            self.assertEqual(app.pair_code, "")
            await client.push({"event": "pair-code", "code": "654321"})
            await pilot.pause()
            await pilot.press("n")
            await pilot.pause()
            await client.push({"event": "pair-code", "code": "111222"})
            await pilot.pause()
            await pilot.press("escape")
            await pilot.pause()
        confirms = [item for item in client.sent if item["cmd"] == "confirm"]
        self.assertEqual(confirms, [
            {"cmd": "confirm", "accept": True},
            {"cmd": "confirm", "accept": False},
        ])
        self.assertIn({"cmd": "cancel"}, client.sent)
        self.assertEqual(app.pair_code, "")


if __name__ == "__main__":
    unittest.main()
