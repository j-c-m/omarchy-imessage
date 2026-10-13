# Connection

This computer talks to a paired iPhone over two Bluetooth profiles.

- MAP carries the texts. OBEX `CreateSession` with target `map` opens that channel.
- PBAP carries contacts. OBEX `CreateSession` with target `pbap` opens that channel.

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

The pairing agent is registered only during `pair()`. It is not the default agent for the whole session, so pairing a headset in the desktop settings still works while this plugin is loaded.

The phone is not marked `Trusted`. Trust is what lets BlueZ attach every profile later with no question. Startup clears `Trusted` on the saved phone.

## How the link comes up

Enter and `p` both call `Pair()` when the phone is not bonded, then open MAP and PBAP. Neither calls `Device1.Connect` or `Device1.Disconnect`. Those calls attach every profile the desktop has registered, including A2DP and HFP.

If MAP fails because the service record is missing, the phone is busy, or the phone has not allowed access, the program drops the OBEX session and tries `CreateSession` once more. If the ACL is down, that retry uses `ConnectProfile` for the MAP Message Access Server UUID `00001132-0000-1000-8000-00805f9b34fb` only.

A saved phone is reopened with MAP and PBAP when the daemon starts, so the bar can receive texts while the card is closed. That path does not connect audio.

The ANCS advertisement stops when messages connect. If they are still down after 120 seconds, the advertisement stops. A new pair cancels the previous timer.

## Which phone is saved

The picker still lists discovered phones.

If a phone is already saved, it stays saved when it is absent or powered off. If nothing is saved, a phone is stored only when exactly one paired phone is in the list. Zero or several: the card waits for Enter.

## Threads and sends

A listing that has only a display name is not stored. The downloaded bMessage inserts the row under the phone number or email. A later update moves an existing `raw:` row onto that `tel:` or `email:` key and sets the direction from the completed body. Setting your own number does the same for a national number that was stored before the country code was known.

Two texts in the same second use the later row as the conversation preview.

The composer stays until the phone accepts the send. A failure leaves the text in place and shows the error on the caption line. A success opens that conversation. A messages payload is applied only when it matches the open thread.

## Files

- `daemon/bluetooth.py` opens MAP and PBAP, refuses audio, and adopts only the saved phone or the single paired phone.
- `daemon/protocol.py` names the audio profiles and turns Bluetooth failures into short sentences.
- `daemon/store.py` rethreads a message when a sendable address arrives, and picks the later preview.
- `daemon/messagesd.py` reports the thread key of a sent text.
- `Service.qml` and `Overlay.qml` keep a failed draft, show the error, and load only the open thread.
- `README.md` describes the `p` key as another pair, not as a connect-all fallback.

`python3 -m unittest discover -s daemon/tests -v` covers the profile ids, the error sentences, rethreading, and the preview. The BlueZ calls are not unit tested.
