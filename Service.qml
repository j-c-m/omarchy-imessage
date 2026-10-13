import QtQuick
import Quickshell
import Quickshell.Io

// Headless half of the plugin. It stays loaded while the overlay is closed
// so a new text can still arrive. The Bluetooth work happens in messagesd,
// a separate program started with an argument list (no shell).
Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  property int unread: 0
  property string state: "not_paired"
  property string detail: "Starting…"
  property string phoneName: ""
  property string phoneAddress: ""
  property string ownNumber: ""
  property string pairCode: ""
  property bool notifyBody: false
  property bool bluetoothReady: false
  property string lastError: ""
  property int errorRevision: 0
  property string sentThread: ""
  property int sentRevision: 0
  property int threadRevision: 0
  property int messageRevision: 0
  property int deviceRevision: 0
  property int contactRevision: 0
  property string activeThread: ""

  function fileUrl(relative) {
    var url = Qt.resolvedUrl(relative).toString()
    if (url.indexOf("file://") === 0)
      url = url.substring(7)
    return decodeURIComponent(url)
  }

  function send(command) {
    if (!bridge.running)
      return
    bridge.write(JSON.stringify(command) + "\n")
  }

  function refresh() { root.send({ "cmd": "status" }) }
  function setNumber(number) { root.send({ "cmd": "set-number", "number": number }) }
  function setNotifyBody(enabled) { root.send({ "cmd": "set-notify-body", "enabled": enabled }) }
  function scan() { root.send({ "cmd": "scan" }) }
  function reconnect() { root.send({ "cmd": "reconnect" }) }
  function pair(address) { root.send({ "cmd": "pair", "address": address, "explicit": false }) }
  function pairExplicit(address) { root.send({ "cmd": "pair", "address": address, "explicit": true }) }
  function confirm(accept) { root.send({ "cmd": "confirm", "accept": accept }) }
  function cancelPair() { root.send({ "cmd": "cancel" }) }
  function loadThreads() { root.send({ "cmd": "threads" }) }
  function loadMessages(thread) {
    root.activeThread = thread
    root.send({ "cmd": "messages", "thread": thread })
  }
  function clearMessages() {
    // Used when a new person has no conversation yet, so the card does
    // not keep showing somebody else's texts.
    root.activeThread = ""
    messageModel.clear()
  }
  function searchContacts(query) { root.send({ "cmd": "contacts", "query": query }) }
  function sendText(thread, address, body) {
    root.send({ "cmd": "send", "thread": thread, "address": address, "body": body })
  }
  function markRead(thread) { root.send({ "cmd": "mark-read", "thread": thread }) }
  function deleteThread(thread) { root.send({ "cmd": "delete-thread", "thread": thread }) }

  function applyStatus(status) {
    if (!status)
      return
    root.state = status.state || "not_paired"
    root.detail = status.detail || ""
    root.phoneName = status.phoneName || ""
    root.phoneAddress = status.phoneAddress || ""
    root.ownNumber = status.ownNumber || ""
    root.unread = Number(status.unread || 0)
    root.notifyBody = status.notifyBody === true
    root.bluetoothReady = status.bluetoothReady === true
    if (root.state !== "pairing")
      root.pairCode = ""
  }

  function fill(model, rows, fields) {
    model.clear()
    if (!rows)
      return
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var item = {}
      for (var f = 0; f < fields.length; f++) {
        var key = fields[f]
        var value = row[key]
        item[key] = value === undefined || value === null ? "" : value
      }
      model.append(item)
    }
  }

  function handleLine(line) {
    var text = String(line || "").trim()
    if (!text)
      return
    var event
    try {
      event = JSON.parse(text)
    } catch (ignore) {
      return
    }
    if (!event || !event.event)
      return
    if (event.event === "ready" || event.event === "status") {
      root.applyStatus(event.status)
    } else if (event.event === "pair-code") {
      root.pairCode = event.code || ""
      root.state = "pairing"
    } else if (event.event === "error") {
      root.lastError = event.message || "Something went wrong."
      root.errorRevision += 1
    } else if (event.event === "threads") {
      root.fill(threadModel, event.threads, ["key", "label", "preview", "unread", "timestamp"])
      root.threadRevision += 1
    } else if (event.event === "messages") {
      if (root.activeThread && event.thread === root.activeThread) {
        root.fill(messageModel, event.messages, ["id", "thread", "label", "body", "direction", "timestamp", "read"])
        root.messageRevision += 1
      }
    } else if (event.event === "message") {
      root.loadThreads()
      if (root.activeThread && event.message && event.message.thread === root.activeThread)
        root.loadMessages(root.activeThread)
    } else if (event.event === "devices") {
      root.fill(deviceModel, event.devices, ["address", "name", "paired", "connected"])
      root.deviceRevision += 1
    } else if (event.event === "contacts") {
      root.fill(contactModel, event.contacts, ["name", "address", "kind"])
      root.contactRevision += 1
    } else if (event.event === "sent") {
      var sentKey = event.thread || ""
      if (sentKey)
        root.activeThread = sentKey
      root.sentThread = sentKey
      root.sentRevision += 1
      root.loadThreads()
      if (root.activeThread)
        root.loadMessages(root.activeThread)
    }
  }

  ListModel { id: threadModel }
  ListModel { id: messageModel }
  ListModel { id: contactModel }
  ListModel { id: deviceModel }

  property alias threads: threadModel
  property alias messages: messageModel
  property alias contacts: contactModel
  property alias devices: deviceModel

  Process {
    id: bridge
    stdinEnabled: true
    command: ["setpriv", "--pdeathsig", "TERM", "python3", "-u", root.fileUrl("daemon/messagesd.py")]
    stdout: SplitParser {
      onRead: function(data) { root.handleLine(data) }
    }
    // Stderr is connection state only. It is drained so the pipe cannot fill
    // and stall the daemon. It is not shown in the overlay.
    stderr: SplitParser {
      onRead: function(data) {}
    }
    onExited: restartTimer.restart()
  }

  Timer {
    id: restartTimer
    interval: 1500
    repeat: false
    onTriggered: bridge.running = true
  }

  Component.onCompleted: bridge.running = true
}
