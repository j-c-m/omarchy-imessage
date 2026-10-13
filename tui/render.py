"""Turn a message body into link spans. The terminal draws the underline."""

from __future__ import annotations

import re

_URL = re.compile(r"https?://[^\s<>\"']+|www\.[^\s<>\"']+", re.IGNORECASE)
_BARE = re.compile(
    r"(?:^|[^A-Za-z0-9@])([A-Za-z0-9][A-Za-z0-9-]*\.(?:com|org|net|edu|gov|io|co|app|dev|me|tv|ai|us|uk|ca|de|ly|gg)(?:/[^\s<>\"']*)?)",
    re.IGNORECASE,
)
_TAIL = re.compile(r"[.,;:!?)]+$")


def link_spans(body: str) -> list[tuple[int, int, str]]:
    """Return (start, end, href) for each link in `body`. Ranges do not overlap."""
    text = body or ""
    spans: list[tuple[int, int, str]] = []

    def add(start: int, raw: str) -> None:
        shown = _TAIL.sub("", raw)
        if not shown:
            return
        end = start + len(shown)
        href = shown if shown.lower().startswith(("http://", "https://")) else "https://" + shown
        spans.append((start, end, href))

    for match in _URL.finditer(text):
        add(match.start(), match.group(0))
    covered = [(start, end) for start, end, _href in spans]
    for match in _BARE.finditer(text):
        word = match.group(1) or ""
        start = match.start() + match.group(0).rfind(word)
        end = start + len(word)
        if any(not (end <= left or start >= right) for left, right in covered):
            continue
        add(start, word)
    spans.sort()
    return spans
