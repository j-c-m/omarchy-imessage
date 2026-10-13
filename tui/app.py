"""iMsg in the terminal.

    python3 -m tui
    python3 -m tui --standalone

The plugin's messages daemon owns the phone. This program only draws.
"""

from __future__ import annotations

import sys

from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.widgets import Input, OptionList, RichLog, Static, TextArea
from textual.widgets.option_list import Option

from tui.client import connect
from tui.render import link_spans

HINT = "j/k move    enter open    r reply    n new    ctrl+d delete    / filter    esc back"


class ThreadList(OptionList):
    BINDINGS = [
        Binding("j", "cursor_down", "down"),
        Binding("k", "cursor_up", "up"),
        Binding("down", "cursor_down", "down"),
        Binding("up", "cursor_up", "up"),
        Binding("enter", "select", "open"),
    ]


class Composer(TextArea):
    BINDINGS = [
        Binding("enter", "submit", "send", priority=True),
        Binding("escape", "cancel", "cancel", priority=True),
    ]

    def action_submit(self) -> None:
        self.app.action_send()

    def action_cancel(self) -> None:
        self.app.action_close_compose()


class ImsgApp(App):
    TITLE = "iMsg"
    BINDINGS = [
        Binding("r", "reply", "reply"),
        Binding("n", "new_text", "new"),
        Binding("ctrl+d", "delete_thread", "delete"),
        Binding("slash", "filter", "filter"),
        Binding("escape", "back", "back", priority=True),
        Binding("t", "notify", "notification text"),
        Binding("y", "accept_pair", "yes"),
    ]

    def __init__(self, client=None, standalone: bool = False) -> None:
        super().__init__()
        self.client = client
        self.standalone = standalone
        self.threads: list[dict] = []
        self.shown: list[dict] = []
        self.contacts: list[dict] = []
        self.mode = "threads"
        self.open_key = ""
        self.compose_address = ""
        self.filter_text = ""
        self.filter_on = False
        self.pair_code = ""
        self.notify_body = False
        self._filling = False

    def compose(self) -> ComposeResult:
        yield Static("", id="status")
        yield Input(placeholder="filter", id="filter")
        with Horizontal(id="body"):
            yield ThreadList(id="threads")
            with Vertical(id="stack"):
                yield RichLog(id="transcript", wrap=True, markup=False, min_width=8, auto_scroll=True)
                yield Composer("", id="composer", show_line_numbers=False)
        yield Static(HINT, id="hint")

    def on_mount(self) -> None:
        composer = self.query_one("#composer", Composer)
        composer.display = False
        composer.can_focus = False
        box = self.query_one("#filter", Input)
        box.display = False
        box.can_focus = False
        self.query_one("#threads", ThreadList).focus()
        self.run_worker(self._pump(), exclusive=True)

    async def _pump(self) -> None:
        if self.client is None:
            try:
                self.client = await connect(self.standalone)
            except OSError as exc:
                self.exit(message=str(exc))
                return
        self.client.send({"cmd": "status"})
        self.client.send({"cmd": "threads"})
        async for event in self.client.lines():
            self.apply(event)

    def apply(self, event: dict) -> None:
        kind = event.get("event")
        if kind == "threads":
            self.threads = list(event.get("threads") or [])
            if self.mode == "threads":
                self._show_threads()
        elif kind == "messages":
            if event.get("thread") == self.open_key:
                self._show_messages(list(event.get("messages") or []))
        elif kind == "message":
            message = event.get("message") or {}
            if message.get("thread") == self.open_key and self.open_key:
                self.client.send({"cmd": "messages", "thread": self.open_key})
                self.client.send({"cmd": "mark-read", "thread": self.open_key})
        elif kind == "contacts":
            self.contacts = list(event.get("contacts") or [])
            if self.mode == "contacts":
                self._show_contacts()
        elif kind == "sent":
            key = str(event.get("thread") or self.open_key)
            if key:
                self.open_key = key
                self.client.send({"cmd": "messages", "thread": key})
                self.client.send({"cmd": "threads"})
        elif kind == "status":
            status = event.get("status") or {}
            self.notify_body = bool(status.get("notifyBody"))
            detail = str(status.get("detail") or status.get("state") or "")
            self._set_status(detail)
        elif kind == "pair-code":
            self.pair_code = str(event.get("code") or "")
            self._set_status("Pairing code " + self.pair_code)
        elif kind == "error":
            self._set_status(str(event.get("message") or "Error"))

    def _set_status(self, text: str) -> None:
        self.query_one("#status", Static).update(text)

    def _matches(self, label: str) -> bool:
        if not self.filter_text:
            return True
        return self.filter_text.casefold() in (label or "").casefold()

    def _show_threads(self) -> None:
        self.shown = [row for row in self.threads if self._matches(str(row.get("label") or ""))]
        self._fill(self._thread_prompt)

    def _show_contacts(self) -> None:
        self.shown = [row for row in self.contacts if self._matches(str(row.get("name") or ""))]
        self._fill(lambda row: str(row.get("name") or row.get("address") or ""))

    def _thread_prompt(self, row: dict) -> str:
        mark = "• " if row.get("unread") else ""
        return mark + str(row.get("label") or "")

    def _fill(self, prompt) -> None:
        widget = self.query_one("#threads", ThreadList)
        previous = self.open_key
        self._filling = True
        widget.clear_options()
        for row in self.shown:
            widget.add_option(Option(prompt(row)))
        restore = 0
        for index, row in enumerate(self.shown):
            if row.get("key") == previous or row.get("address") == previous:
                restore = index
                break
        if self.shown:
            widget.highlighted = restore
            if not self.query_one("#composer").display and not self.filter_on:
                widget.focus()
        self._filling = False

    def _current(self) -> dict | None:
        widget = self.query_one("#threads", ThreadList)
        index = widget.highlighted
        if index is None or index < 0 or index >= len(self.shown):
            return None
        return self.shown[index]

    def on_option_list_option_highlighted(self, event: OptionList.OptionHighlighted) -> None:
        if self._filling or self.mode != "threads":
            return
        self._open_highlighted()

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        if self.mode == "contacts":
            self._pick_contact()
            return
        self._open_highlighted()

    def _open_highlighted(self) -> None:
        row = self._current()
        if not row:
            return
        key = str(row.get("key") or "")
        if not key or key == self.open_key:
            return
        self.open_key = key
        self.compose_address = ""
        self.client.send({"cmd": "messages", "thread": key})
        self.client.send({"cmd": "mark-read", "thread": key})

    def _show_messages(self, messages: list[dict]) -> None:
        log = self.query_one("#transcript", RichLog)
        log.clear()
        for message in messages:
            log.write(render_message(message))
        log.scroll_end(animate=False)

    def action_reply(self) -> None:
        if self._typing() or self.mode != "threads":
            return
        row = self._current()
        if not row or not row.get("key"):
            return
        self.compose_address = ""
        self._open_composer()

    def action_new_text(self) -> None:
        if self._typing():
            return
        if self.pair_code:
            self.action_reject_pair()
            return
        self.mode = "contacts"
        self.filter_text = ""
        self.client.send({"cmd": "contacts", "query": ""})
        self._show_contacts()

    def _pick_contact(self) -> None:
        row = self._current()
        if not row or not row.get("address"):
            return
        self.compose_address = str(row["address"])
        self.open_key = ""
        self.mode = "threads"
        self._show_threads()
        self._open_composer()

    def _open_composer(self) -> None:
        composer = self.query_one("#composer", Composer)
        composer.display = True
        composer.can_focus = True
        composer.focus()

    def action_close_compose(self) -> None:
        composer = self.query_one("#composer", Composer)
        composer.display = False
        composer.can_focus = False
        composer.clear()
        self.query_one("#threads", ThreadList).focus()

    def action_send(self) -> None:
        composer = self.query_one("#composer", Composer)
        body = composer.text.strip()
        if not body:
            return
        command = {"cmd": "send", "body": body}
        if self.compose_address:
            command["address"] = self.compose_address
        elif self.open_key:
            command["thread"] = self.open_key
        else:
            return
        self.client.send(command)
        self.action_close_compose()

    def action_delete_thread(self) -> None:
        if self._typing() or self.mode != "threads":
            return
        row = self._current()
        if not row or not row.get("key"):
            return
        key = str(row["key"])
        if key == self.open_key:
            self.open_key = ""
            self.query_one("#transcript", RichLog).clear()
        self.client.send({"cmd": "delete-thread", "thread": key})

    def action_filter(self) -> None:
        if self.query_one("#composer").display:
            return
        box = self.query_one("#filter", Input)
        self.filter_on = True
        box.can_focus = True
        box.display = True
        box.focus()

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id != "filter":
            return
        self.filter_text = event.value
        if self.mode == "contacts":
            self.client.send({"cmd": "contacts", "query": self.filter_text})
        else:
            self._show_threads()

    def action_back(self) -> None:
        if self.query_one("#composer").display:
            self.action_close_compose()
            return
        if self.filter_on:
            self.filter_on = False
            self.filter_text = ""
            box = self.query_one("#filter", Input)
            box.value = ""
            box.display = False
            box.can_focus = False
            self.query_one("#threads", ThreadList).focus()
            if self.mode == "contacts":
                self._show_contacts()
            else:
                self._show_threads()
            return
        if self.mode == "contacts":
            self.mode = "threads"
            self._show_threads()
            return
        self.exit()

    def action_notify(self) -> None:
        if self._typing():
            return
        self.client.send({"cmd": "set-notify-body", "enabled": not self.notify_body})

    def action_accept_pair(self) -> None:
        if self._typing() or not self.pair_code:
            return
        self.client.send({"cmd": "confirm", "accept": True})
        self.pair_code = ""

    def action_reject_pair(self) -> None:
        if self._typing() or not self.pair_code:
            return
        self.client.send({"cmd": "confirm", "accept": False})
        self.pair_code = ""

    def _typing(self) -> bool:
        focused = self.focused
        return isinstance(focused, (Composer, Input))


def render_message(message: dict) -> Text:
    raw = str(message.get("body") or "")
    body = Text()
    cursor = 0
    for start, end, href in link_spans(raw):
        body.append(raw[cursor:start])
        body.append(raw[start:end], style=f"underline link {href}")
        cursor = end
    body.append(raw[cursor:])
    stamp = str(message.get("timestamp") or "")[11:16]
    who = "you  " if message.get("direction") == "out" else ""
    head = Text(f"{who}{stamp}\n", style="dim")
    head.append(body)
    head.append("\n")
    return head


def main(argv: list[str] | None = None) -> None:
    args = list(sys.argv[1:] if argv is None else argv)
    standalone = "--standalone" in args
    app = ImsgApp(standalone=standalone)
    app.run()


if __name__ == "__main__":
    main()
