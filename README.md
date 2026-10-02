# iMsg

Read and send texts from a nearby iPhone, in a small terminal-style card on the Omarchy bar. The phone stays in charge. This computer never asks for an Apple ID or an iCloud password. It uses two ordinary Bluetooth profiles:

- **MAP** carries the texts. Carrier SMS and iMessage both arrive as plain text. The phone chooses the route.
- **PBAP** carries contact names, so you can pick a person instead of typing a number.

The pictures below are illustrations. The people and the texts are made up.

## What the card looks like

Unread names are bold and sit at the top of the left list. That list is names only. The conversation is on the right: texts you receive stay on the left, texts you send sit on the right, and each one has the time under it.

![iMsg card with three fake contacts. Ada is selected. Her texts sit on the left, the reply sits on the right, each with a time.](docs/msg-overlay.jpg)

Click **iMsg** on the right side of the bar. Or bind a key in `~/.config/hypr/bindings.lua`. The plugin does not edit Hyprland for you.

```lua
o.bind("SUPER + SHIFT + M", "iMsg", "omarchy-shell shell toggle io.github.nikolaos-gkionis.messages '{}'")
```

## Install

The plugin runs inside `omarchy-shell`. It does not start a second Quickshell.

```sh
omarchy pkg add bluez-obex python-dbus-next
omarchy plugin add https://github.com/Nikolaos-Gkionis/omarchy-imessage.git --enable
```

`omarchy plugin add` clones the repo, checks `manifest.json`, and leaves the code for you to read before you enable it. Plugins are unsandboxed and run as your user for the whole desktop session. Read the code before enabling it.

While you are developing this checkout, link it and enable that id. `omarchy plugin validate` rejects a plugin folder that is itself a symlink, so validate this directory, not the link.

```sh
omarchy plugin validate .
mkdir -p ~/.config/omarchy/plugins
ln -s "$PWD" ~/.config/omarchy/plugins/io.github.nikolaos-gkionis.messages
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.nikolaos-gkionis.messages
omarchy restart shell
```

## Set up the iPhone

1. Open the card. It looks for phones that are already paired. Highlight your iPhone and press Enter.
2. A code appears here and on the phone. Press `y` here and confirm the same code on the phone. Press `n` to reject it.
3. If pairing stops on its own, press `p`. That is explicit pairing. On some adapters it only bonds Classic Bluetooth, which is still enough for texts.
4. On the iPhone open **Settings → Bluetooth**, tap the **i** next to this computer, and turn on both switches in the picture. The phone may label the first one **Show Notifications** or **Show Message Notifications**. The second is **Sync Contacts**. They can take a minute to appear. If you see two entries with the same computer name, check both, then use this one.

![iPhone Bluetooth page for a computer named omarchy, with Show Notifications and Sync Contacts switched on.](docs/iphone-bluetooth-settings.jpg)

5. Come back to the card. The status line should say `connected`. New texts show up from this moment on. Older conversations stay on the phone. The iPhone does not copy history over this link.
6. Press `n` for the contact list. Names appear after Sync Contacts is on. A leading `0` on a mobile number is filled in with the country code from your own number, so a UK `07…` becomes `+44…`.

If the status line says the phone is already in a message session, another computer is using the phone's only message connection. Disconnect that computer and open the card again.

## Keys

| Key | What it does |
| --- | --- |
| `j` / `k` or arrows | Move through the list |
| Enter | Open the highlighted conversation, choose a contact, or send the reply |
| `r` | Reply in the open conversation |
| `n` | New text. Type to filter names, Enter to choose |
| Ctrl+E | Open the emoji list while writing. Type a word, `j` / `k`, Enter to insert |
| `/` | Filter the list you are in |
| `y` / `n` | Accept or reject the pairing code |
| `p` | Explicit pairing, only on the phone list |
| `t` | On the permission screen, include the message text in desktop notifications. This stays off until you turn it on |
| `?` | Show every hint |
| Escape | Step back, then close the card |

The bar shows `iMsg`, and a count when something is unread. A desktop notification uses the contact's name. It does not include the message text unless you pressed `t`.

## What you will not see

Bluetooth does not provide these, so the plugin does not pretend to:

- Photos, video, reactions, typing indicators, or iMessage read receipts. A message with a file shows the words and one line, `attachment omitted`.
- The full history already on the phone. Only texts that arrive after the card is connected, plus replies you send from here.
- Texts you typed on the phone itself. The phone shares its inbox. Replies you send from this card are kept on this computer so your side of the conversation stays visible.
- Group chats. One send goes to one person.
- Texts while the phone is off, out of range, or linked to another computer's message session.

SMS and iMessage look the same on this link. The card does not label a bubble blue or green.

## Where your data lives

Texts, contacts, and the paired phone are stored in `~/.local/share/nikolaos-messages/messages.db`. The directory is private to your user (`0700`) and the file is too (`0600`). Nothing is sent to a server.

The daemon is a normal user process. It does not use sudo. Commands are an argument list, so a text cannot be run as a shell command. Logs record connection state only. They do not record message text, contact names, pairing codes, or your number.

## Remove

```sh
omarchy plugin remove io.github.nikolaos-gkionis.messages
```

That removes the installed copy in `~/.config/omarchy/plugins/`. The GitHub repository stays. To also forget the phone and the saved texts:

```sh
bluetoothctl remove AA:BB:CC:DD:EE:FF
rm -rf ~/.local/share/nikolaos-messages
```

Replace the address with the phone's Bluetooth address. You can see paired devices with `bluetoothctl devices`.

## Check the code

```sh
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" Service.qml Overlay.qml BarWidget.qml
python3 -m unittest discover -s daemon/tests -v
```

Saved QML in `~/.config/omarchy/plugins/` reloads on its own. The service is kept loaded, so a change to the daemon needs `omarchy restart shell`.
