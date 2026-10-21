import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Live Claude Code sessions. ~/.claude/hooks/omarchy-session-state.sh keeps
// ~/.local/state/claude-sessions/index.json current from Claude's hooks; this
// widget only watches and draws it. The icon turns urgent while any session
// waits for you, pulses while one is working, and hides when none run.
Panel {
  id: root
  moduleName: "jan.claude-sessions"
  ipcTarget: "jan.claude-sessions"

  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/claude-sessions"
  readonly property string hookScript: Quickshell.env("HOME") + "/.claude/hooks/omarchy-session-state.sh"

  property var sessions: []
  property double nowMs: Date.now()

  readonly property int waitingCount: countState("waiting") + countState("error")
  readonly property int workingCount: countState("working")

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function countState(state) {
    var n = 0
    for (var i = 0; i < sessions.length; i++) if (sessions[i].state === state) n++
    return n
  }

  // The index is written in place, so a read can land mid-write; a list that
  // doesn't parse keeps the previous one until the next change.
  function load(raw) {
    var parsed
    try { parsed = JSON.parse(raw) } catch (e) { return }
    if (!Array.isArray(parsed)) return
    var out = []
    for (var i = 0; i < parsed.length && out.length < 50; i++) {
      var s = parsed[i]
      if (!s || typeof s !== "object") continue
      out.push({
        id: String(s.id || "").slice(0, 80),
        project: String(s.project || "?").slice(0, 80),
        cwd: String(s.cwd || "").slice(0, 300),
        state: ["working", "waiting", "idle", "error"].indexOf(s.state) >= 0 ? s.state : "idle",
        message: String(s.message || "").slice(0, 200),
        window: /^0x[0-9a-f]+$/.test(String(s.window || "")) ? String(s.window) : "",
        updated: Number(s.updated) || 0
      })
    }
    sessions = out
  }

  function stateColor(state) {
    if (state === "waiting" || state === "error") return bar ? bar.urgent : Commons.Color.urgent
    if (state === "working") return Commons.Color.accent
    return dim
  }

  function stateLabel(state) {
    if (state === "waiting") return "Needs you"
    if (state === "working") return "Working"
    if (state === "error") return "Error"
    return "Idle"
  }

  function age(updated) {
    var s = Math.max(0, Math.round(nowMs / 1000 - updated))
    if (s < 60) return "just now"
    if (s < 3600) return Math.floor(s / 60) + " min ago"
    if (s < 86400) return Math.floor(s / 3600) + " h ago"
    return Math.floor(s / 86400) + " d ago"
  }

  // The hook script opens the agent shelf (or closes it) as needed, then
  // focuses the terminal, switching to its workspace.
  function focusSession(session) {
    if (session.window === "") return
    focusProc.command = ["sh", root.hookScript, "focus", session.window]
    focusProc.running = true
    close()
  }

  visible: sessions.length > 0
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  onVisibleChanged: if (!visible) close()
  onOpenedChanged: if (opened) nowMs = Date.now()

  FileView {
    path: root.stateDir + "/index.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.load(text())
    onLoadFailed: root.sessions = []
    onFileChanged: reload()
  }

  // Sweeps out sessions whose claude process died without a SessionEnd.
  Process {
    id: pruneProc
    command: ["sh", root.hookScript, "prune"]
  }

  Process {
    id: focusProc
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!pruneProc.running) pruneProc.running = true
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\u{f06a9}"
    labelText: root.waitingCount > 0 ? String(root.waitingCount)
      : (root.workingCount > 1 ? String(root.workingCount) : "")
    slotSize: Style.bar.iconSlot * (labelText !== "" && !vertical ? 1.6 : 1)
    active: root.waitingCount > 0
    dimmed: root.waitingCount === 0 && root.workingCount === 0
    tooltipText: root.waitingCount > 0 ? root.waitingCount + " waiting for you"
      : (root.workingCount > 0 ? root.workingCount + " working" : root.sessions.length + " idle")
    onPressed: root.toggle()

    SequentialAnimation on opacity {
      running: root.workingCount > 0 && root.waitingCount === 0
      loops: Animation.Infinite
      onRunningChanged: if (!running) button.opacity = 1
      NumberAnimation { to: 0.45; duration: 900; easing.type: Easing.InOutSine }
      NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutSine }
    }
  }

  PopupCard {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(10)

      PanelSectionHeader {
        text: "Claude sessions"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Repeater {
        model: root.sessions

        Rectangle {
          id: row
          required property var modelData
          width: column.width
          implicitHeight: rowColumn.implicitHeight + Style.space(12)
          radius: Style.cornerRadius
          color: rowHover.hovered && modelData.window !== ""
            ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
            : "transparent"

          Rectangle {
            id: dot
            width: Style.space(8)
            height: width
            radius: width / 2
            color: root.stateColor(row.modelData.state)
            anchors.left: parent.left
            anchors.leftMargin: Style.space(6)
            anchors.top: parent.top
            anchors.topMargin: Style.space(6) + (projectText.implicitHeight - height) / 2
          }

          Column {
            id: rowColumn
            anchors.left: dot.right
            anchors.leftMargin: Style.space(10)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.top: parent.top
            anchors.topMargin: Style.space(6)
            spacing: Style.space(2)

            Item {
              width: parent.width
              implicitHeight: projectText.implicitHeight

              Text {
                id: projectText
                textFormat: Text.PlainText
                text: row.modelData.project
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
                anchors.left: parent.left
                anchors.right: stateText.left
                anchors.rightMargin: Style.space(8)
              }

              Text {
                id: stateText
                textFormat: Text.PlainText
                text: root.stateLabel(row.modelData.state) + " · " + root.age(row.modelData.updated)
                color: root.stateColor(row.modelData.state)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: projectText.verticalCenter
              }
            }

            Text {
              width: parent.width
              visible: text !== ""
              textFormat: Text.PlainText
              text: row.modelData.message
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: row.modelData.cwd
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }
          }

          HoverHandler {
            id: rowHover
            cursorShape: row.modelData.window !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
          }

          TapHandler {
            onTapped: root.focusSession(row.modelData)
          }
        }
      }
    }
  }
}
