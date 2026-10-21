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

  readonly property string accountsDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/agents"

  property var sessions: []
  // Claude subscription accounts from `omarchy agent account`, with the usage
  // Omarchy's agents plugin last collected for each.
  property var accounts: []
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
        home: String(s.home || "").slice(0, 300),
        updated: Number(s.updated) || 0
      })
    }
    sessions = out
  }

  // A limit whose window already reset reads as unused until the next usage
  // update catches up, the same way the agents panel shows it.
  function loadAccounts(raw) {
    var parsed
    try { parsed = JSON.parse(raw) } catch (e) { return }
    var provider = Array.isArray(parsed) ? parsed[0] : null
    if (!provider || !Array.isArray(provider.accounts)) return
    var out = []
    for (var i = 0; i < provider.accounts.length && out.length < 10; i++) {
      var a = provider.accounts[i]
      if (!a || typeof a !== "object" || !a.id) continue
      var limits = []
      var rawLimits = Array.isArray(a.limits) ? a.limits : []
      for (var j = 0; j < rawLimits.length && limits.length < 4; j++) {
        var l = rawLimits[j]
        var reset = Date.parse(l.resetsAt || "") || 0
        var percent = Number(l.percent)
        if (!(percent >= 0)) continue
        limits.push({
          label: String(l.label || "").slice(0, 40),
          percent: reset > 0 && reset < Date.now() ? 0 : Math.min(1, percent),
          reset: reset
        })
      }
      out.push({
        id: String(a.id).slice(0, 40),
        label: String(a.label || a.id).slice(0, 40),
        plan: String(a.plan || "").slice(0, 40),
        email: String(a.email || "").slice(0, 80),
        home: String(a.home || "").replace(/\/+$/, ""),
        active: a.active === true,
        signedIn: a.signedIn === true,
        limits: limits
      })
    }
    accounts = out
  }

  function refreshAccounts() {
    if (!accountsProc.running) accountsProc.running = true
  }

  // A session started before the hook recorded homes has none yet; it gets
  // one from its next hook event.
  function accountLabel(home) {
    if (home === "" || accounts.length < 2) return ""
    for (var i = 0; i < accounts.length; i++) if (accounts[i].home === home) return accounts[i].label
    return ""
  }

  function sessionCount(home) {
    var n = 0
    for (var i = 0; i < sessions.length; i++) if (sessions[i].home === home) n++
    return n
  }

  function launch(account) {
    Quickshell.execDetached(["sh", root.hookScript, "launch", account.id])
    close()
  }

  function resetIn(reset) {
    var s = Math.round((reset - nowMs) / 1000)
    if (reset <= 0 || s <= 0) return ""
    if (s < 3600) return "resets in " + Math.max(1, Math.floor(s / 60)) + " min"
    if (s < 86400) return "resets in " + Math.floor(s / 3600) + " h"
    return "resets in " + Math.floor(s / 86400) + " d"
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

  // With accounts to start a session from, the icon stays even when none run.
  visible: sessions.length > 0 || accounts.length > 0
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  onVisibleChanged: if (!visible) close()
  // Opening the list asks for limits no older than five minutes.
  onOpenedChanged: if (opened) { nowMs = Date.now(); refreshAccounts(); updateUsage(300) }

  function updateUsage(maxAge) {
    if (usageProc.running) return
    usageProc.command = ["sh", root.hookScript, "usage", String(maxAge)]
    usageProc.running = true
  }

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

  // Reads the registry and the cached usage records; it never asks Anthropic
  // itself, so it is cheap enough to run on every change.
  Process {
    id: accountsProc
    command: ["omarchy", "agent", "account", "list", "claude", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadAccounts(text)
    }
  }

  // Asks Anthropic for the limits, which Omarchy's agents plugin would
  // otherwise do; the new record then arrives through the file watch below.
  Process {
    id: usageProc
  }

  // Limits are a remote API with no change signal, so they are polled, at
  // the agents plugin's own fifteen-minute pace.
  Timer {
    interval: 900000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.updateUsage(840)
  }

  // The registry changes when an account is added, renamed or switched to;
  // the usage record each time the limits are collected again.
  FileView {
    path: root.accountsDir + "/accounts/claude.json"
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshAccounts()
  }

  FileView {
    path: root.accountsDir + "/usage/claude.json"
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshAccounts()
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!pruneProc.running) pruneProc.running = true
      root.refreshAccounts()
    }
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
      : (root.workingCount > 0 ? root.workingCount + " working"
      : (root.sessions.length > 0 ? root.sessions.length + " idle" : "No Claude sessions"))
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

            Item {
              width: parent.width
              implicitHeight: cwdText.implicitHeight

              Text {
                id: accountText
                visible: text !== ""
                textFormat: Text.PlainText
                text: root.accountLabel(row.modelData.home)
                color: Commons.Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.left: parent.left
              }

              Text {
                id: cwdText
                textFormat: Text.PlainText
                text: row.modelData.cwd
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
                anchors.left: accountText.visible ? accountText.right : parent.left
                anchors.leftMargin: accountText.visible ? Style.space(6) : 0
                anchors.right: parent.right
              }
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

      Text {
        visible: root.sessions.length === 0
        textFormat: Text.PlainText
        text: "No sessions running"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      PanelSeparator {
        visible: root.accounts.length > 0
        width: column.width
      }

      PanelSectionHeader {
        visible: root.accounts.length > 0
        text: "Accounts"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      // One block per account: who it is, how many sessions run as it, its
      // limits, and a button that opens a new session signed in as it.
      Repeater {
        model: root.accounts

        Column {
          id: account
          required property var modelData
          width: column.width
          spacing: Style.space(4)

          Item {
            width: parent.width
            implicitHeight: Math.max(accountName.implicitHeight, launchButton.implicitHeight)

            Text {
              id: accountName
              textFormat: Text.PlainText
              text: account.modelData.label + (account.modelData.active ? "  \u{f012c}" : "")
              color: account.modelData.signedIn ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              textFormat: Text.PlainText
              text: {
                var parts = []
                if (account.modelData.plan !== "") parts.push(account.modelData.plan)
                if (!account.modelData.signedIn) parts.push("signed out")
                var n = root.sessionCount(account.modelData.home)
                if (n > 0) parts.push(n + (n === 1 ? " session" : " sessions"))
                return parts.join(" · ")
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              anchors.left: accountName.right
              anchors.leftMargin: Style.space(8)
              anchors.right: launchButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
            }

            PanelActionButton {
              id: launchButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\u{f0415}"
              tooltipText: "New session as " + account.modelData.label
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: account.modelData.signedIn
              onClicked: root.launch(account.modelData)
            }
          }

          Text {
            width: parent.width
            visible: text !== ""
            textFormat: Text.PlainText
            text: account.modelData.email
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Repeater {
            model: account.modelData.limits

            Item {
              id: limit
              required property var modelData
              readonly property color tint: modelData.percent >= 0.9
                ? (root.bar ? root.bar.urgent : Commons.Color.urgent)
                : Commons.Color.accent
              width: account.width
              implicitHeight: limitLabel.implicitHeight + meter.height + Style.space(3)

              Text {
                id: limitLabel
                textFormat: Text.PlainText
                text: limit.modelData.label
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.left: parent.left
                anchors.right: limitValue.left
                anchors.rightMargin: Style.space(8)
                elide: Text.ElideRight
              }

              Text {
                id: limitValue
                textFormat: Text.PlainText
                text: {
                  var reset = root.resetIn(limit.modelData.reset)
                  return Math.round(limit.modelData.percent * 100) + "%" + (reset !== "" ? " · " + reset : "")
                }
                color: limit.modelData.percent >= 0.9 ? limit.tint : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
              }

              Rectangle {
                id: meter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Style.space(4)
                radius: height / 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

                Rectangle {
                  width: parent.width * limit.modelData.percent
                  height: parent.height
                  radius: parent.radius
                  color: limit.tint
                }
              }
            }
          }
        }
      }
    }
  }
}
