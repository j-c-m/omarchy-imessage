import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Centered terminal-style card. The dim layer behind it is the overlay;
// the card itself stays in the middle of the screen. Message text is
// escaped. A web address is the only thing that becomes a link.
Item {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  property bool opened: false
  // True only while the card is on screen and should receive keys.
  // The grab is dropped before the window hides. See dismiss().
  property bool holdingKeys: false
  property string screen: "setup"
  property int selected: 0
  property string filterText: ""
  property bool filterOn: false
  property string notice: ""
  property string draft: ""
  property bool composeFocus: false

  onComposeFocusChanged: {
    if (root.composeFocus)
      composer.forceActiveFocus()
    else
      keyCatcher.forceActiveFocus()
  }
  property bool helpOn: false
  property string toAddress: ""
  property string toLabel: ""
  property bool sendPending: false
  property string lastOpened: ""
  property bool caretOn: true

  Timer {
    // A blinking mark at the end of the line, so it is obvious the card
    // is waiting for what you want to send.
    interval: 500
    repeat: true
    running: root.opened && root.composeFocus
    onTriggered: root.caretOn = !root.caretOn
  }

  readonly property var svc: (shell && shell.serviceFor)
    ? shell.serviceFor((manifest && manifest.id) || "io.github.nikolaos-gkionis.messages") : null

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  // One quiet pixel around the card. Theme border widths are not used,
  // so the edge stays a hairline on every theme.
  property var borderSpec: Border.flat(Util.alpha(foreground, 0.35), 1)
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.accent
  property color selectedText: Color.background
  property color incomingBubble: Util.alpha(foreground, 0.12)
  property color muted: Color.muted
  property string fontFamily: Style.font.family
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  // A window in the middle, not a sheet that covers the desktop.
  property int cardWidth: Math.min(Style.space(760), Math.max(Style.space(520), panel.width * 0.52))
  property int cardHeight: Math.min(Style.space(480), Math.max(Style.space(340), panel.height * 0.52))
  // Width only. The measured height must not depend on the card height,
  // or the layout loop freezes the desktop.
  readonly property int draftInnerWidth: Math.max(40, Math.min(cardWidth, panel.width - Style.gapsOut * 2) - card.contentLeftInset - card.contentRightInset)
  readonly property int draftLimit: draftOneLine.implicitHeight * 5
  readonly property int composeGrow: root.composeFocus
    ? Math.max(0, Math.min(draftMeasure.implicitHeight, root.draftLimit) - draftOneLine.implicitHeight)
    : 0

  function open(payloadJson) {
    root.opened = true
    root.holdingKeys = true
    root.helpOn = false
    root.composeFocus = false
    root.toAddress = ""
    root.toLabel = ""
    root.filterText = ""
    root.filterOn = false
    root.selected = 0
    root.followState(true)
    // A saved phone retries the message link. A missing phone starts a scan.
    if (root.svc && (root.svc.state === "waiting_for_switches" || root.svc.state === "phone_nearby"))
      root.svc.reconnect()
    else if (root.screen === "setup" && root.svc)
      root.svc.scan()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    // Drop the keyboard grab in this frame. The window itself hides on
    // the next frame, so the compositor never unmaps a surface that
    // still owns every key. That unmap is what froze the session.
    root.holdingKeys = false
    root.composeFocus = false
    if (root.opened)
      Qt.callLater(function() { root.opened = false })
  }

  function dismiss() {
    var pluginId = (root.manifest && root.manifest.id) || "io.github.nikolaos-gkionis.messages"
    root.close()
    Qt.callLater(function() {
      if (root.shell && typeof root.shell.hide === "function")
        root.shell.hide(pluginId)
    })
  }

  // Escape walks back one step, then closes. One function, so the
  // window shortcut and the key handler cannot disagree. The guard
  // ignores a second call from the same key press.
  property bool stepping: false
  function stepBack() {
    if (root.stepping)
      return
    root.stepping = true
    Qt.callLater(function() { root.stepping = false })
    if (root.helpOn) {
      root.helpOn = false
      return
    }
    if (root.screen === "emoji") {
      root.screen = "inbox"
      root.composeFocus = true
      return
    }
    if (root.composeFocus) {
      root.cancelCompose()
      return
    }
    if (root.filterOn) {
      root.filterOn = false
      root.filterText = ""
      return
    }
    if (root.screen === "contacts") {
      root.screen = "inbox"
      return
    }
    if (root.screen === "code") {
      if (root.svc)
        root.svc.cancelPair()
      return
    }
    if (root.screen === "checklist" && root.svc && root.svc.threads.count > 0) {
      root.screen = "inbox"
      return
    }
    root.dismiss()
  }

  function followState(initial) {
    if (!root.svc) {
      root.screen = "setup"
      return
    }
    if (root.svc.pairCode) {
      root.screen = "code"
      return
    }
    if (!initial && (root.screen === "contacts" || root.screen === "emoji"))
      return
    if (root.svc.state === "waiting_for_switches" && root.screen !== "inbox") {
      root.screen = "checklist"
      return
    }
    if (root.svc.state === "connected" && (initial || root.screen === "setup" || root.screen === "code" || root.screen === "checklist")) {
      root.screen = "inbox"
      root.rebuildShown()
      root.openSelectedThread()
      return
    }
    if (initial && root.svc.threads.count === 0)
      root.screen = "setup"
    root.rebuildShown()
  }

  function paneModel() {
    if (root.screen === "emoji")
      return emojiModel
    if (root.screen === "contacts" && root.svc)
      return root.svc.contacts
    return shownModel
  }

  function rebuildShown() {
    if (root.screen === "contacts" || root.screen === "emoji")
      return
    var keep = ""
    if (root.selected >= 0 && root.selected < shownModel.count) {
      var current = shownModel.get(root.selected)
      keep = current ? (current.key || current.address || "") : ""
    }
    shownModel.clear()
    if (!root.svc)
      return
    var source = root.screen === "setup" ? root.svc.devices : root.svc.threads
    var needle = root.filterText.toLowerCase()
    var restore = 0
    var rows = []
    for (var i = 0; i < source.count; i++) {
      var row = source.get(i)
      var hay = ((row.label || row.name || "") + " " + (row.preview || row.address || "")).toLowerCase()
      if (needle && hay.indexOf(needle) === -1)
        continue
      rows.push({
        key: row.key || "",
        label: row.label || row.name || "",
        preview: row.preview || "",
        unread: row.unread || 0,
        timestamp: row.timestamp || "",
        address: row.address || "",
        name: row.name || "",
        pending: 0
      })
    }
    // A person with no texts yet still needs a row, or the highlight
    // stays on whoever you were reading before.
    if (root.screen === "inbox" && root.toLabel && !root.listHasRecipient(rows)) {
      rows.unshift({
        key: "",
        label: root.toLabel,
        preview: "",
        unread: 0,
        timestamp: "",
        address: root.toAddress,
        name: root.toLabel,
        pending: 1
      })
    }
    // Unread conversations stay at the top. Read ones follow, newest first.
    if (root.screen === "inbox") {
      rows.sort(function(a, b) {
        var ap = a.pending ? 1 : 0
        var bp = b.pending ? 1 : 0
        if (ap !== bp)
          return bp - ap
        var au = a.unread > 0 ? 1 : 0
        var bu = b.unread > 0 ? 1 : 0
        if (au !== bu)
          return bu - au
        if (a.timestamp === b.timestamp)
          return 0
        return a.timestamp < b.timestamp ? 1 : -1
      })
    }
    var addressed = -1
    for (var n = 0; n < rows.length; n++) {
      if ((rows[n].key || rows[n].address || "") === keep)
        restore = shownModel.count
      if (root.toLabel && (rows[n].pending || root.samePerson(rows[n], root.toAddress, root.toLabel)))
        addressed = shownModel.count
      shownModel.append(rows[n])
    }
    if (addressed >= 0)
      restore = addressed
    root.selected = shownModel.count === 0 ? 0 : Math.min(restore, shownModel.count - 1)
  }

  function digitsOnly(value) {
    return String(value || "").replace(/\D/g, "")
  }

  // Same person if the name matches, or the phone numbers share an ending.
  // A UK 07… number and a +44… number are the same last digits.
  function samePerson(row, address, name) {
    if (!row)
      return false
    if (name && row.label && String(row.label) === String(name))
      return true
    var wanted = String(address || "").trim().toLowerCase()
    var key = String(row.key || "").toLowerCase()
    if (wanted && (key === wanted || key === "email:" + wanted || key === "tel:" + wanted))
      return true
    var wantDigits = root.digitsOnly(wanted)
    var keyDigits = root.digitsOnly(key)
    if (wantDigits.length >= 7 && keyDigits.length >= 7) {
      var n = Math.min(10, wantDigits.length, keyDigits.length)
      return wantDigits.slice(-n) === keyDigits.slice(-n)
    }
    return false
  }

  function listHasRecipient(rows) {
    for (var i = 0; i < rows.length; i++) {
      if (root.samePerson(rows[i], root.toAddress, root.toLabel))
        return true
    }
    return false
  }

  function recipientLabel() {
    if (root.toLabel)
      return root.toLabel
    if (root.screen !== "inbox" || root.selected < 0 || root.selected >= shownModel.count)
      return ""
    var row = shownModel.get(root.selected)
    return row ? (row.label || "") : ""
  }

  function cancelCompose() {
    var addressed = root.toAddress !== ""
    root.composeFocus = false
    root.toAddress = ""
    root.toLabel = ""
    if (addressed)
      root.rebuildShown()
  }

  function openSelectedThread() {
    if (root.screen !== "inbox" || !root.svc)
      return
    if (root.selected < 0 || root.selected >= shownModel.count)
      return
    var row = shownModel.get(root.selected)
    if (!row || !row.key || row.key === root.lastOpened)
      return
    root.lastOpened = row.key
    root.svc.loadMessages(row.key)
    root.svc.markRead(row.key)
  }

  function move(delta) {
    var model = root.paneModel()
    if (!model || model.count === 0)
      return
    root.selected = (root.selected + delta + model.count) % model.count
    if (leftList)
      leftList.positionViewAtIndex(root.selected, ListView.Contain)
    if (root.screen === "inbox")
      root.openSelectedThread()
  }

  function rowText(index) {
    var model = root.paneModel()
    if (!model || index < 0 || index >= model.count)
      return ""
    var row = model.get(index)
    if (root.screen === "setup")
      return (row.name || "Phone") + "  " + (row.address || "")
    if (root.screen === "contacts")
      return row.name || "Contact"
    if (root.screen === "emoji")
      return (row.emoji || "") + "  " + (row.keywords || "")
    return row.label || "Unknown"
  }

  function pairSelected(explicit) {
    if (!root.svc || root.selected < 0 || root.selected >= shownModel.count)
      return
    var row = shownModel.get(root.selected)
    if (!row || !row.address)
      return
    if (explicit)
      root.svc.pairExplicit(row.address)
    else
      root.svc.pair(row.address)
  }

  function pickContact() {
    if (!root.svc)
      return
    var model = root.svc.contacts
    if (root.selected < 0 || root.selected >= model.count)
      return
    var row = model.get(root.selected)
    root.toAddress = row.address || ""
    root.toLabel = row.name || row.address || "Contact"
    root.screen = "inbox"
    root.filterText = ""
    root.filterOn = false
    root.rebuildShown()
    var chosen = root.selected >= 0 && root.selected < shownModel.count ? shownModel.get(root.selected) : null
    if (chosen && chosen.key) {
      root.lastOpened = ""
      root.openSelectedThread()
    } else if (root.svc) {
      root.svc.clearMessages()
      root.lastOpened = ""
    }
    if (leftList && shownModel.count > 0)
      leftList.positionViewAtIndex(root.selected, ListView.Contain)
    root.startReply()
  }

  function revealCaret() {
    if (!root.composeFocus)
      return
    var rect = composer.cursorRectangle
    var top = rect.y
    var bottom = rect.y + rect.height
    if (top < draftBox.contentY)
      draftBox.contentY = top
    else if (bottom > draftBox.contentY + draftBox.height)
      draftBox.contentY = bottom - draftBox.height
  }

  function startReply() {
    // The text field receives letters, paste, and the arrow keys.
    composer.clear()
    root.draft = ""
    root.caretOn = true
    root.composeFocus = true
  }

  function loadEmojis(raw) {
    try {
      var data = JSON.parse(String(raw || ""))
      root.emojiAll = Array.isArray(data) ? data : []
    } catch (ignore) {
      root.emojiAll = []
    }
  }

  function openEmoji() {
    // Leave the text field. While it has focus it eats Ctrl+E, and the
    // emoji list only receives keys when the catcher behind it is focused.
    root.emojiFilter = ""
    root.selected = 0
    root.screen = "emoji"
    root.composeFocus = false
    root.rebuildEmoji()
  }

  function rebuildEmoji() {
    emojiModel.clear()
    var needle = root.emojiFilter.toLowerCase()
    for (var i = 0; i < root.emojiAll.length; i++) {
      var item = root.emojiAll[i]
      if (!item || !item.e)
        continue
      var words = String(item.k || "").toLowerCase()
      if (needle && words.indexOf(needle) === -1)
        continue
      emojiModel.append({ emoji: String(item.e), keywords: String(item.k || "") })
      if (emojiModel.count >= 80)
        break
    }
    root.selected = 0
  }

  function insertEmoji() {
    if (root.selected < 0 || root.selected >= emojiModel.count)
      return
    var row = emojiModel.get(root.selected)
    var picture = row ? (row.emoji || "") : ""
    if (!picture)
      return
    composer.insert(composer.cursorPosition, picture)
    root.draft = composer.text
    root.screen = "inbox"
    root.composeFocus = true
  }

  function selectThread(thread) {
    if (!thread)
      return
    for (var i = 0; i < shownModel.count; i++) {
      var row = shownModel.get(i)
      if (row && row.key === thread) {
        root.selected = i
        if (leftList)
          leftList.positionViewAtIndex(i, ListView.Contain)
        return
      }
    }
  }

  function acceptSend() {
    if (!root.sendPending || !root.svc)
      return
    var thread = root.svc.sentThread || ""
    root.sendPending = false
    composer.clear()
    root.draft = ""
    root.toAddress = ""
    root.toLabel = ""
    root.composeFocus = false
    root.screen = "inbox"
    root.rebuildShown()
    root.selectThread(thread)
  }

  function failSend() {
    if (!root.sendPending)
      return
    root.sendPending = false
    root.composeFocus = true
  }

  function sendDraft() {
    if (!root.svc || root.sendPending)
      return
    var body = root.draft
    if (!body.trim())
      return
    var thread = ""
    if (!root.toAddress && root.selected >= 0 && root.selected < shownModel.count) {
      var row = shownModel.get(root.selected)
      thread = row ? row.key : ""
    }
    root.svc.lastError = ""
    root.sendPending = true
    root.composeFocus = true
    root.svc.sendText(thread, root.toAddress, body)
  }

  function escapeHtml(value) {
    return String(value || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
  }

  function trimUrl(url) {
    var cut = String(url || "")
    while (cut.length && /[.,;:!?)]$/.test(cut)) {
      if (cut.charAt(cut.length - 1) === ")") {
        var open = (cut.match(/\(/g) || []).length
        var close = (cut.match(/\)/g) || []).length
        if (close <= open)
          break
      }
      cut = cut.slice(0, -1)
    }
    return cut
  }

  function linkify(value) {
    // The iPhone also links a bare host such as voterep.co/j237n.
    // The address is escaped, so the message cannot add its own markup.
    var text = String(value || "")
    var tlds = "com|org|net|edu|gov|mil|int|io|co|app|dev|me|tv|ai|info|biz|us|uk|ca|au|de|fr|nl|se|no|fi|es|it|ch|at|be|nz|ie|eu|xyz|link|news|blog|online|site|store|tech|cloud|live|page|pro|gg|ly"
    var pattern = new RegExp("(?:https?:\\/\\/|www\\.)[^\\s<>\"']+|(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+(?:" + tlds + ")(?:\\/[^\\s<>\"']*)?", "gi")
    var out = ""
    var last = 0
    var match
    while ((match = pattern.exec(text)) !== null) {
      var prev = match.index > 0 ? text.charAt(match.index - 1) : ""
      if (/[\w@]/.test(prev) && !/^(?:https?:\/\/|www\.)/i.test(match[0]))
        continue
      out += root.escapeHtml(text.slice(last, match.index))
      var shown = root.trimUrl(match[0])
      var href = /^https?:\/\//i.test(shown) ? shown : "https://" + shown
      // A long address has no spaces. Rich text will not wrap it, and the
      // layout pass then never finishes.
      out += "<a href=\"" + root.escapeHtml(href) + "\">" + root.escapeHtml(root.breakLink(shown)) + "</a>"
      out += root.escapeHtml(match[0].slice(shown.length))
      last = match.index + match[0].length
    }
    out += root.escapeHtml(text.slice(last))
    return out
  }

  function isEmojiCode(code) {
    return (code >= 0xD800 && code <= 0xDFFF) || code === 0xFE0F || code === 0x200D || (code >= 0x2600 && code <= 0x27BF)
  }

  function linkRanges(value) {
    // Linear scans. The old rich-text anchor is what pegged the shell
    // on a long address, so these ranges are only for underlines and clicks.
    var text = String(value || "")
    var ranges = []
    var pattern = /https?:\/\/[^\s<>"']+|www\.[^\s<>"']+/gi
    var match
    while ((match = pattern.exec(text)) !== null) {
      if (!match[0].length) {
        pattern.lastIndex += 1
        continue
      }
      var shown = root.trimUrl(match[0])
      if (!shown)
        continue
      var href = /^https?:\/\//i.test(shown) ? shown : "https://" + shown
      ranges.push({ start: match.index, end: match.index + shown.length, href: href })
    }
    var bare = /(?:^|[^A-Za-z0-9@])([A-Za-z0-9][A-Za-z0-9-]*\.(?:com|org|net|edu|gov|io|co|app|dev|me|tv|ai|us|uk|ca|de|ly|gg)(?:\/[^\s<>"']*)?)/gi
    while ((match = bare.exec(text)) !== null) {
      var word = root.trimUrl(match[1] || "")
      if (!word)
        continue
      var start = match.index + match[0].length - (match[1] || "").length
      var end = start + word.length
      var overlaps = false
      for (var n = 0; n < ranges.length; n++) {
        if (start < ranges[n].end && end > ranges[n].start)
          overlaps = true
      }
      if (overlaps)
        continue
      ranges.push({ start: start, end: end, href: "https://" + word })
    }
    ranges.sort(function(a, b) { return a.start - b.start })
    return ranges
  }

  function hrefAt(value, index) {
    var ranges = root.linkRanges(value)
    for (var i = 0; i < ranges.length; i++) {
      if (index >= ranges[i].start && index < ranges[i].end)
        return ranges[i].href
    }
    return ""
  }

  function messageHtml(value) {
    // Underlines, not anchors. Qt's link objects retrigger layout forever.
    var text = String(value || "")
    var ranges = root.linkRanges(text)
    var out = ""
    var i = 0
    var r = 0
    while (i < text.length) {
      if (r < ranges.length && i === ranges[r].start) {
        out += "<u>" + root.escapeHtml(text.slice(ranges[r].start, ranges[r].end)) + "</u>"
        i = ranges[r].end
        r++
        continue
      }
      if (isEmojiCode(text.charCodeAt(i))) {
        var run = ""
        while (i < text.length && isEmojiCode(text.charCodeAt(i)) && !(r < ranges.length && i === ranges[r].start)) {
          run += text.charAt(i)
          i++
        }
        out += "<span style=\"font-family: 'Noto Color Emoji'\">" + run + "</span>"
        continue
      }
      var ch = text.charAt(i)
      out += ch === "\n" ? "<br/>" : root.escapeHtml(ch)
      i++
    }
    return out
  }

  function openLink(url) {
    var target = String(url || "")
    if (!/^https?:\/\//i.test(target))
      return
    Qt.openUrlExternally(target)
  }

  function withEmojiFont(value, links) {
    // The card font has no emoji pictures. Qt on this desktop has no
    // "families" fallback, so emoji are wrapped in the emoji font.
    // Only an open message is linkified. A link in the conversation
    // list, watched for hover, retriggers layout until the shell pegs.
    var raw = links ? root.linkify(value) : root.escapeHtml(String(value || ""))
    var out = ""
    var run = ""
    for (var i = 0; i < raw.length; i++) {
      var code = raw.charCodeAt(i)
      var emoji = (code >= 0xD800 && code <= 0xDFFF) || code === 0xFE0F || code === 0x200D || (code >= 0x2600 && code <= 0x27BF)
      if (emoji)
        run += raw.charAt(i)
      else {
        if (run) {
          out += "<span style=\"font-family: 'Noto Color Emoji'\">" + run + "</span>"
          run = ""
        }
        out += raw.charAt(i) === "\n" ? "<br/>" : raw.charAt(i)
      }
    }
    if (run)
      out += "<span style=\"font-family: 'Noto Color Emoji'\">" + run + "</span>"
    return out
  }

  function typingText(event) {
    // One emoji is several code units, so length is not always 1.
    // Control shortcuts, including paste, are left for the text field.
    if (!event.text)
      return false
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
      return false
    for (var i = 0; i < event.text.length; i++) {
      var code = event.text.charCodeAt(i)
      if (code < 32 || code === 127)
        return false
    }
    return true
  }

  function typeInto(target, character) {
    if (target === "filter")
      root.filterText += character
    else
      root.draft += character
  }

  function backspace(target) {
    if (target === "filter")
      root.filterText = root.filterText.slice(0, -1)
    else
      root.draft = root.draft.slice(0, -1)
  }

  function clockText(stamp) {
    // Stored times look like 2026-10-02T15:04:00. Today shows the clock.
    // Another day shows the date and the clock.
    var value = String(stamp || "")
    if (value.length < 16)
      return ""
    var hm = value.substring(11, 16)
    var now = new Date()
    var month = ("0" + (now.getMonth() + 1)).slice(-2)
    var day = ("0" + now.getDate()).slice(-2)
    var today = now.getFullYear() + "-" + month + "-" + day
    if (value.substring(0, 10) === today)
      return hm
    var names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    var monthName = names[parseInt(value.substring(5, 7), 10) - 1] || ""
    return parseInt(value.substring(8, 10), 10) + " " + monthName + "  " + hm
  }

  function toggleNotify() {
    if (!root.svc)
      return
    var next = !root.svc.notifyBody
    root.svc.setNotifyBody(next)
    root.notice = next ? "notification text on" : "notification text off"
  }

  function stateLabel() {
    if (!root.svc)
      return "starting"
    var state = root.svc.state
    if (state === "not_paired") return "not paired"
    if (state === "phone_nearby") return "phone nearby"
    if (state === "waiting_for_switches") return "waiting for iOS switches"
    if (state === "connected") return "connected"
    if (state === "pairing") return "pairing"
    if (state === "scanning") return "scanning"
    return state || "starting"
  }

  function hintLine() {
    if (root.helpOn)
      return "esc close help    j/k move    enter select    n new text    r reply    / filter    t notification text    y/n pairing    p explicit pair"
    if (root.screen === "code")
      return "y accept on this computer    n reject    esc cancel"
    if (root.screen === "checklist")
      return "t include message text in notifications (" + ((root.svc && root.svc.notifyBody) ? "on" : "off") + ")    esc back    ? help"
    if (root.screen === "contacts")
      return "/ filter    j/k move    enter choose    esc back    ? help"
    if (root.screen === "emoji")
      return "type to search    j/k move    enter insert    esc back    ? help"
    if (root.composeFocus) {
      var who = root.recipientLabel()
      return "enter send" + (who ? " to " + who : "") + "    ctrl+e emoji    esc back"
    }
    if (root.screen === "setup")
      return "j/k move    / filter    enter pair    p other pairing    esc close"
    return "j/k move    enter open    r reply    n new    / filter    esc close    ? help"
  }

  ListModel { id: shownModel }
  ListModel { id: emojiModel }
  property var emojiAll: []
  property string emojiFilter: ""

  FileView {
    // The desktop already ships a searchable emoji list. Read it, do not copy it.
    path: (root.omarchyPath || "/usr/share/omarchy") + "/shell/plugins/emojis/emojis.json"
    onLoaded: root.loadEmojis(text())
  }

  Connections {
    target: root.svc
    ignoreUnknownSignals: true
    function onStateChanged() { if (root.opened) root.followState(false) }
    function onPairCodeChanged() { if (root.opened && root.svc && root.svc.pairCode) root.screen = "code" }
    function onThreadRevisionChanged() { if (root.screen === "inbox") root.rebuildShown() }
    function onDeviceRevisionChanged() { if (root.screen === "setup") root.rebuildShown() }
    function onContactRevisionChanged() { if (root.screen === "contacts") root.selected = 0 }
    function onSentRevisionChanged() { if (root.opened) root.acceptSend() }
    function onErrorRevisionChanged() { if (root.opened) root.failSend() }
  }

  onScreenChanged: root.rebuildShown()
  onFilterTextChanged: {
    if (root.screen === "contacts" && root.svc)
      root.svc.searchContacts(root.filterText)
    else
      root.rebuildShown()
  }

  Text {
    id: draftOneLine
    visible: false
    width: Math.max(40, root.draftInnerWidth - draftPrompt.implicitWidth)
    textFormat: Text.PlainText
    text: " "
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  Text {
    id: draftMeasure
    visible: false
    width: Math.max(40, root.draftInnerWidth - draftPrompt.implicitWidth)
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    text: root.draft.length ? root.draft : " "
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "nikolaos-messages"
    WlrLayershell.layer: WlrLayer.Overlay
    // None whenever the card is closing or already hidden. Exclusive
    // while a hidden keepLoaded window exists is what ate Escape and
    // locked the keyboard for the rest of the desktop.
    WlrLayershell.keyboardFocus: root.holdingKeys ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    onVisibleChanged: {
      if (visible)
        keyCatcher.forceActiveFocus()
    }

    // Window-level, so Escape still arrives when no list row has focus.
    // The text field used to swallow it, and the card never closed.
    Shortcut {
      enabled: root.opened
      sequence: "Escape"
      context: Qt.WindowShortcut
      onActivated: root.stepBack()
    }

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: Math.min(root.cardWidth, panel.width - Style.gapsOut * 2)
      height: Math.min(root.cardHeight + root.composeGrow, panel.height - Style.gapsOut * 2)
      radius: root.cornerRadius > 0 ? root.cornerRadius : Style.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: !root.composeFocus

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          var printable = root.typingText(event)

          if (event.key === Qt.Key_Question || (event.text === "?" && event.modifiers & Qt.ShiftModifier)) {
            root.helpOn = !root.helpOn
            event.accepted = true
            return
          }

          if (event.key === Qt.Key_Escape) {
            root.stepBack()
            event.accepted = true
            return
          }

          var allowNotifyToggle = event.key === Qt.Key_T && !root.composeFocus && !root.filterOn && root.screen !== "emoji" && root.svc
          if (!allowNotifyToggle)
            root.notice = ""
          else {
            root.toggleNotify()
            event.accepted = true
            return
          }

          if (root.screen === "code") {
            if (event.key === Qt.Key_Y && root.svc) root.svc.confirm(true)
            else if (event.key === Qt.Key_N && root.svc) root.svc.confirm(false)
            event.accepted = true
            return
          }

          if (root.screen === "checklist") {
            event.accepted = true
            return
          }

          if (root.screen === "emoji") {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.insertEmoji()
            else if (event.key === Qt.Key_Backspace) {
              root.emojiFilter = root.emojiFilter.slice(0, -1)
              root.rebuildEmoji()
            } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_J && !root.emojiFilter)) root.move(1)
            else if (event.key === Qt.Key_Up || (event.key === Qt.Key_K && !root.emojiFilter)) root.move(-1)
            else if (printable && event.text !== "/") {
              root.emojiFilter += event.text
              root.rebuildEmoji()
            }
            event.accepted = true
            return
          }

          if (root.composeFocus) {
            // Ctrl+E opens the emoji list. Enter sends. Arrows and letters
            // stay with the text field so the cursor can move.
            if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_E) {
              root.openEmoji()
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.sendDraft()
              event.accepted = true
            } else {
              event.accepted = false
            }
            return
          }

          if (root.screen === "contacts") {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.pickContact()
            else if (event.key === Qt.Key_Backspace) {
              if (root.filterOn && root.filterText.length === 0) root.filterOn = false
              else if (root.filterOn) root.backspace("filter")
            } else if (!root.filterOn && (event.key === Qt.Key_Down || event.key === Qt.Key_J)) root.move(1)
            else if (!root.filterOn && (event.key === Qt.Key_Up || event.key === Qt.Key_K)) root.move(-1)
            else if (!root.filterOn && event.key === Qt.Key_Slash) {
              root.filterOn = true
              root.filterText = ""
            } else if (root.filterOn && printable) root.typeInto("filter", event.text)
            event.accepted = true
            return
          }

          // A letter moves or runs a command until / starts a filter.
          // Inside the filter, j and k are letters in the search.
          var filtering = root.filterOn
          if (event.key === Qt.Key_Down || (event.key === Qt.Key_J && !filtering)) root.move(1)
          else if (event.key === Qt.Key_Up || (event.key === Qt.Key_K && !filtering)) root.move(-1)
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.screen === "setup") {
              if (shownModel.count === 0 && root.svc) root.svc.scan()
              else root.pairSelected(false)
            } else root.composeFocus = true
          } else if (!filtering && event.key === Qt.Key_R && root.screen === "inbox") {
            root.toAddress = ""
            root.toLabel = ""
            root.startReply()
          } else if (!filtering && (event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_E && root.screen === "inbox") {
            root.startReply()
            root.openEmoji()
          } else if (!filtering && event.key === Qt.Key_N && root.screen === "inbox") {
            root.screen = "contacts"
            root.filterOn = false
            root.filterText = ""
            root.selected = 0
            root.composeFocus = false
            if (root.svc) root.svc.searchContacts("")
          } else if (!filtering && event.key === Qt.Key_P && root.screen === "setup") root.pairSelected(true)
          else if (!filtering && event.key === Qt.Key_Slash) {
            root.filterOn = true
            root.filterText = ""
          } else if (filtering && event.key === Qt.Key_Backspace) {
            if (root.filterText.length === 0) root.filterOn = false
            else root.backspace("filter")
          } else if (filtering && printable) root.typeInto("filter", event.text)
          event.accepted = true
        }

        ColumnLayout {
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset
          spacing: Style.space(8)

          // The example card puts the name in the middle, then a quiet status.
          Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: "iMsg"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: {
              if (root.filterOn && root.screen !== "code" && root.screen !== "emoji" && root.screen !== "checklist")
                return "/" + root.filterText
              if (root.screen === "code")
                return "Pairing code  " + (root.svc ? root.svc.pairCode : "")
              if (root.notice)
                return root.notice
              if (root.screen === "checklist")
                return "On the iPhone open Bluetooth, tap this computer, then turn on Show Message Notifications and Sync Contacts."
              if (root.screen === "emoji")
                return root.emojiFilter ? ("Emoji  " + root.emojiFilter) : "Pick an emoji"
              if (root.screen === "contacts")
                return "Choose who to text"
              if (root.svc && root.svc.lastError)
                return root.svc.lastError
              if (root.screen === "setup")
                return root.svc && root.svc.state === "scanning" ? "Looking for your iPhone" : "Select your iPhone"
              return root.stateLabel() + (root.svc && root.svc.phoneName ? "  " + root.svc.phoneName : "")
            }
          }

          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            height: 1
            color: root.border
          }

          Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ListView {
              id: leftList
              width: root.screen === "inbox" ? parent.width * 0.38 : parent.width
              height: parent.height
              clip: true
              model: root.screen === "emoji" ? emojiModel : (root.screen === "contacts" && root.svc ? root.svc.contacts : shownModel)
              boundsBehavior: Flickable.StopAtBounds
              delegate: Rectangle {
                required property int index
                width: leftList.width
                height: Style.space(36)
                color: index === root.selected ? root.selectedBackground : "transparent"

                Text {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(8)
                  verticalAlignment: Text.AlignVCenter
                  textFormat: root.linkRanges(root.rowText(index)).length ? Text.PlainText : Text.RichText
                  elide: Text.ElideRight
                  text: root.linkRanges(root.rowText(index)).length ? root.rowText(index) : root.withEmojiFont(root.rowText(index))
                  color: index === root.selected ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: root.screen === "inbox" && shownModel.get(index) !== undefined && (shownModel.get(index).unread || 0) > 0
                }

                MouseArea {
                  anchors.fill: parent
                  onClicked: {
                    root.selected = index
                    if (root.screen === "inbox") root.openSelectedThread()
                    else if (root.screen === "contacts") root.pickContact()
                    else if (root.screen === "setup") root.pairSelected(false)
                  }
                }
              }
            }

            Rectangle {
              visible: root.screen === "inbox"
              x: leftList.width
              width: 1
              height: parent.height
              color: root.border
            }

            ListView {
              id: transcript
              visible: root.screen === "inbox"
              x: leftList.width + Style.space(8)
              width: parent.width - leftList.width - Style.space(8)
              height: parent.height
              clip: true
              model: root.svc ? root.svc.messages : 0
              boundsBehavior: Flickable.StopAtBounds
              onCountChanged: if (count > 0) positionViewAtEnd()

              delegate: Item {
                required property string body
                required property string direction
                required property string timestamp
                width: transcript.width
                height: bubbleColumn.height + Style.space(10)

                // A hidden line measures the words so the bubble can hug them
                // instead of stretching across the whole conversation.
                Text {
                  id: measure
                  visible: false
                  // Plain text on purpose. Qt's default AutoText parser can
                  // treat a message as HTML and start an image download while
                  // it measures the width, even when this line is hidden.
                  textFormat: Text.PlainText
                  text: body
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Column {
                  id: bubbleColumn
                  spacing: Style.space(3)
                  width: bubble.width
                  x: direction === "out" ? parent.width - width - Style.space(6) : Style.space(6)

                  Rectangle {
                    id: bubble
                    radius: Style.space(8)
                    color: direction === "out" ? root.selectedBackground : root.incomingBubble
                    width: bodyText.width + Style.space(20)
                    height: bodyText.implicitHeight + Style.space(14)

                    Text {
                      id: bodyText
                      x: Style.space(10)
                      y: Style.space(7)
                      width: Math.min(measure.implicitWidth, Math.max(1, transcript.width * 0.62))
                      wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                      textFormat: Text.PlainText
                      text: body
                      color: direction === "out" ? root.selectedText : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body

                      Repeater {
                        model: bodyText.underlines
                        delegate: Rectangle {
                          x: modelData.x
                          y: modelData.y
                          width: modelData.w
                          height: 1
                          color: bodyText.color
                        }
                      }

                      TextEdit {
                        id: hit
                        opacity: 0
                        enabled: false
                        width: bodyText.width
                        height: bodyText.implicitHeight
                        text: body
                        textFormat: Text.PlainText
                        wrapMode: bodyText.wrapMode
                        readOnly: true
                        cursorVisible: false
                        activeFocusOnPress: false
                        selectByMouse: false
                        font.family: bodyText.font.family
                        font.pixelSize: bodyText.font.pixelSize
                      }

                      property var underlines: []
                      function refreshUnderlines() {
                        if (width < 2)
                          return
                        var ranges = root.linkRanges(body)
                        var drawn = []
                        for (var r = 0; r < ranges.length; r++) {
                          var pos = ranges[r].start
                          var end = ranges[r].end
                          while (pos < end) {
                            var rect = hit.positionToRectangle(pos)
                            var lineY = rect.y
                            var linePos = pos
                            var right = rect.x
                            while (linePos < end) {
                              var step = hit.positionToRectangle(linePos)
                              if (linePos > pos && Math.abs(step.y - lineY) > 1)
                                break
                              right = step.x + Math.max(step.width, 1)
                              linePos++
                            }
                            drawn.push({ x: rect.x, y: rect.y + rect.height - 1, w: Math.max(1, right - rect.x) })
                            if (linePos <= pos)
                              break
                            pos = linePos
                          }
                        }
                        underlines = drawn
                      }
                      onWidthChanged: Qt.callLater(refreshUnderlines)
                      Component.onCompleted: Qt.callLater(refreshUnderlines)

                      MouseArea {
                        anchors.fill: parent
                        onClicked: function(mouse) {
                          var link = root.hrefAt(body, hit.positionAt(mouse.x, mouse.y))
                          if (link)
                            root.openLink(link)
                        }
                      }
                    }
                  }

                  Text {
                    width: bubble.width
                    horizontalAlignment: direction === "out" ? Text.AlignRight : Text.AlignLeft
                    textFormat: Text.PlainText
                    text: (direction === "out" ? "sent" : "received") + "  " + root.clockText(timestamp)
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            Text {
              // No history with this person yet. Say their name here so the
              // blank side is not mistaken for someone else's conversation.
              visible: root.screen === "inbox" && transcript.count === 0 && leftList.count > 0
              x: leftList.width + Style.space(12)
              width: parent.width - leftList.width - Style.space(24)
              anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              text: root.recipientLabel()
                ? ("New text to " + root.recipientLabel())
                : "No texts in this conversation yet."
            }

            Text {
              anchors.centerIn: parent
              // The checklist has no rows. Still show the paired phone,
              // or the middle of the card looks like nothing was found.
              visible: root.screen === "checklist" || (leftList.count === 0 && root.screen !== "code")
              width: parent.width - Style.space(24)
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              text: {
                if (root.screen === "checklist") {
                  var phone = root.svc && root.svc.phoneName ? root.svc.phoneName : "iPhone"
                  var why = root.svc && root.svc.detail ? root.svc.detail : "Turn on Show Message Notifications."
                  return phone + " is paired.\n\n" + why
                }
                if (root.screen === "setup") {
                  if (root.svc && root.svc.state === "scanning")
                    return "Looking for your iPhone…"
                  if (root.svc && root.svc.bluetoothReady)
                    return "No phone found. Press Enter to scan again."
                  return "Bluetooth is not ready. Press Enter to try again."
                }
                if (root.screen === "emoji")
                  return "No matching emoji."
                if (root.screen === "contacts")
                  return root.filterText
                    ? "No matching contacts."
                    : "No contacts yet.\n\nOn the iPhone open Bluetooth, tap this computer, and turn on Sync Contacts."
                return "No conversations yet.\n\nThe iPhone only shares texts that arrive after this connection. Older ones stay on the phone."
              }
            }
          }

          Rectangle {
            // The name you just chose, in the same solid bar as a selected row.
            Layout.fillWidth: true
            visible: root.composeFocus && root.recipientLabel().length > 0
            implicitHeight: toName.implicitHeight + Style.space(12)
            radius: Style.space(4)
            color: root.selectedBackground

            Text {
              id: toName
              anchors.fill: parent
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              verticalAlignment: Text.AlignVCenter
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: "To  " + root.recipientLabel()
              color: root.selectedText
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }

          Flickable {
            id: draftBox
            Layout.fillWidth: true
            visible: root.composeFocus
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            interactive: draftMeasure.implicitHeight > height
            contentWidth: root.draftInnerWidth
            contentHeight: draftMeasure.implicitHeight
            Layout.preferredHeight: Math.min(draftMeasure.implicitHeight, root.draftLimit)

            Row {
              width: root.draftInnerWidth
              height: Math.max(draftMeasure.implicitHeight, draftOneLine.implicitHeight)
              spacing: 0

              Text {
                id: draftPrompt
                text: "> "
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              TextEdit {
                id: composer
                width: Math.max(40, root.draftInnerWidth - draftPrompt.implicitWidth)
                height: Math.max(draftMeasure.implicitHeight, draftOneLine.implicitHeight)
                focus: root.composeFocus
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                selectByMouse: true
                color: root.foreground
                selectionColor: root.selectedBackground
                selectedTextColor: root.selectedText
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                inputMethodHints: Qt.ImhNoAutoUppercase
                onTextChanged: root.draft = text
                onCursorPositionChanged: Qt.callLater(root.revealCaret)
                // BeforeItem runs before the field's own shortcuts. Ctrl+E
                // would otherwise jump to the end of the line.
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                  event.accepted = false
                  var ctrl = (event.modifiers & Qt.ControlModifier) && !(event.modifiers & Qt.AltModifier)
                  if (ctrl && event.key === Qt.Key_E) {
                    root.openEmoji()
                    event.accepted = true
                    return
                  }
                  if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ControlModifier)) {
                    root.sendDraft()
                    event.accepted = true
                  }
                }
              }
            }
          }

          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            height: 1
            color: root.border
          }

          // The example spreads the main keys across the bottom. Other
          // screens keep one hint line, because their keys change.
          RowLayout {
            Layout.fillWidth: true
            visible: root.screen === "inbox" && !root.composeFocus && !root.helpOn
            spacing: 0

            Text {
              text: "j/k move"
              Layout.fillWidth: true
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              text: "r reply"
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignHCenter
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              text: "n new"
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignHCenter
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              text: "/ filter"
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignHCenter
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              text: "ctrl+e emoji"
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignHCenter
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              text: "esc close"
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignRight
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            Layout.fillWidth: true
            visible: !(root.screen === "inbox" && !root.composeFocus && !root.helpOn)
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: root.hintLine()
          }
        }
      }
    }
  }
}
