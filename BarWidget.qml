import QtQuick
import Quickshell
import qs.Ui

// Small bar button. The count is the only thing it shows. The text of a
// message stays inside the overlay.
BarWidget {
  id: root
  moduleName: "io.github.nikolaos-gkionis.messages"

  readonly property var svc: (bar && bar.shell && bar.shell.serviceFor)
    ? bar.shell.serviceFor(moduleName) : null
  readonly property int unread: svc ? svc.unread : 0

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.unread > 0 ? ("iMsg " + root.unread) : "iMsg"
    active: root.unread > 0
    tooltipText: root.unread > 0 ? (root.unread + " unread") : "Open iMsg"
    onPressed: function(buttonCode) {
      if (buttonCode !== Qt.LeftButton)
        return
      if (root.bar && root.bar.shell && root.bar.shell.summon)
        root.bar.shell.summon(root.moduleName, "{}")
    }
  }
}
