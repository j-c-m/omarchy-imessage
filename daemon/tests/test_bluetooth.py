"""Tests for MAP session transfer selection (no phone needed)."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from bluetooth import _session_transfer_paths


class SessionTransferTests(unittest.TestCase):
    def test_a_transfer_on_the_map_session_is_kept(self):
        objects = {
            "/org/bluez/obex/session1/transfer1": {"org.bluez.obex.Transfer1": {}},
        }
        self.assertEqual(
            _session_transfer_paths("/org/bluez/obex/session1", objects),
            ["/org/bluez/obex/session1/transfer1"],
        )

    def test_a_message_object_and_a_pbap_transfer_are_not(self):
        objects = {
            "/org/bluez/obex/session1/message42": {"org.bluez.obex.Message1": {}},
            "/org/bluez/obex/session2/transfer1": {"org.bluez.obex.Transfer1": {}},
        }
        self.assertEqual(_session_transfer_paths("/org/bluez/obex/session1", objects), [])


if __name__ == "__main__":
    unittest.main()
