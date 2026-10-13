# Connection

This computer talks to a paired iPhone over two Bluetooth profiles.

- MAP carries the texts. OBEX `CreateSession` with target `map` opens that channel.
- PBAP carries contacts. OBEX `CreateSession` with target `pbap` opens that channel. The pull asks for names and numbers, not photos, and waits for the whole book. A card whose name is only in the `N` field is kept.

It does not connect as a headset or a speaker. It does not change the adapter class. The ANCS solicit asks iOS to show the message switch. The program does not subscribe to notification contents.

## Profiles that are refused

`AuthorizeService` rejects these profiles while the phone is pairing. A later connection of the same profiles is dropped with `DisconnectProfile`.

| Profile | 16-bit id |
| --- | --- |
| HSP | `1108` |
| HSP audio gateway | `1112` |
| HFP | `111e` |
| HFP audio gateway | `111f` |
| A2DP source | `110a` |
| A2DP sink | `110b` |
| AVRCP target | `110c` |
| AVRCP | `110e` |
| AVRCP controller | `110f` |

MAP `1132`, the MAP notification channel, and PBAP `112f` are allowed. Other non-audio UUIDs are allowed so the pairing handshake can finish.

The pairing agent is the default agent only while a phone is being paired or the radio link is being brought up. It is not held for the whole session, so pairing a headset in the desktop settings still works while this plugin is loaded.

The phone is not marked `Trusted`. Trust is what lets BlueZ attach every profile later with no question. Startup clears `Trusted` on the saved phone.

## How the link comes up

Enter uses `Device1.Connect` when the phone is not bonded yet. That is what makes iOS finish pairing and publish the message service. `p` calls `Pair()` when that connect stops. On some adapters `Pair()` only bonds Classic Bluetooth, which is still enough for texts.

iOS does not publish MAP until the radio link is up. Before `CreateSession`, the program calls `Device1.Connect` if the phone is disconnected. The agent rejects audio profiles during that call, and `DisconnectProfile` drops any audio profile that still attaches. The computer does not stay connected as a headset or a speaker.

If MAP still fails because the service record is missing, the phone refused the channel, or it has not allowed access, the program brings the link up once more and tries `CreateSession` again.

A saved phone is reopened the same way when the daemon starts, so the bar can receive texts while the terminal screen is closed. If the link drops later, the status line stops saying connected and the daemon tries again about twice a minute.

The ANCS advertisement stops when messages connect. If they are still down after 120 seconds, the advertisement stops. A new pair cancels the previous timer.

## Which phone is saved

The picker still lists discovered phones.

If a phone is already saved, it stays saved when it is absent or powered off. If nothing is saved, a phone is stored only when exactly one paired phone is in the list. Zero or several: the phone list waits for Enter.

## Threads and sends

A listing that has only a display name is not stored. The downloaded bMessage inserts the row under the phone number or email. A later update moves an existing `raw:` row onto that `tel:` or `email:` key and sets the direction from the completed body. Setting your own number does the same for a national number that was stored before the country code was known.

Two texts in the same second use the later row as the conversation preview.

Enter sends and closes the composer. A failure shows the error on the status line. A success opens that conversation. A messages payload is applied only when it matches the open thread.

## Files

- `daemon/bluetooth.py` opens MAP and PBAP, refuses audio, and adopts only the saved phone or the single paired phone.
- `daemon/protocol.py` names the audio profiles and turns Bluetooth failures into short sentences.
- `daemon/store.py` rethreads a message when a sendable address arrives, and picks the later preview.
- `daemon/messagesd.py` reports the thread key of a sent text.
- `Service.qml` keeps the daemon running and starts the terminal screen from the bar.
- `README.md` describes the `p` key as another pair, not as a connect-all fallback.

`python3 -m unittest discover -s daemon/tests -v` covers the profile ids, the error sentences, rethreading, and the preview. The BlueZ calls are not unit tested.
