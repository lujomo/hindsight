import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Hindsight bar icon and status popup.
// All state comes from `hindsight status --json`, which reads world-readable
// files written by the root backup service, so nothing here needs a password.
Panel {
  id: root
  moduleName: "hindsight.backup"
  ipcTarget: "hindsight.backup"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property var status: ({})
  property string previousState: ""
  property string actionMessage: ""

  readonly property bool configured: status.configured === true
  readonly property bool running: status.state === "running"
  readonly property bool failed: status.state === "error"
  readonly property bool connected: status.drive_connected === true
  readonly property real nowSec: Number(status.now || Date.now() / 1000)
  readonly property real lastSuccess: Number(status.last_success || 0)
  readonly property real ageSeconds: lastSuccess > 0 ? Math.max(0, nowSec - lastSuccess) : -1
  // Time Machine nags after ten days without a backup.
  readonly property bool overdue: configured && lastSuccess > 0 && ageSeconds > 10 * 86400
  readonly property int percent: Math.max(0, Math.min(100, Math.floor(Number(status.percent || 0))))
  readonly property var recent: Array.isArray(status.recent) ? status.recent.slice(0, 8) : []

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string glyphOk: "󰁯"      // nf-md-backup_restore
  readonly property string glyphFailed: "󰗖"  // nf-md-alert_circle_outline

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---------------------------------------------------------------- data ---

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function clip(text, n) {
    var s = String(text || "").replace(/\s+/g, " ").trim()
    return s.length > n ? s.slice(0, n - 1) + "…" : s
  }

  function relative(seconds) {
    if (seconds < 90) return strings.t("justNow")
    var m = Math.floor(seconds / 60)
    if (m < 90) return strings.tn("minutesAgo", m).arg(Commons.I18n.formatNumber(m))
    var h = Math.floor(seconds / 3600)
    if (h < 36) return strings.tn("hoursAgo", h).arg(Commons.I18n.formatNumber(h))
    var d = Math.floor(seconds / 86400)
    return strings.tn("daysAgo", d).arg(Commons.I18n.formatNumber(d))
  }

  function formatTime(iso) {
    var d = new Date(String(iso || ""))
    if (isNaN(d.getTime())) return ""
    var loc = Qt.locale(Commons.I18n.formatLocale)
    var today = new Date(nowSec * 1000)
    var sameDay = d.toDateString() === today.toDateString()
    return sameDay ? strings.t("todayAt").arg(d.toLocaleTimeString(loc, Locale.ShortFormat))
                   : d.toLocaleString(loc, Locale.ShortFormat)
  }

  function headline() {
    if (!configured) return strings.t("notSetUp")
    if (running) return status.phase ? strings.t("runningPhase").arg(clip(status.phase, 40)).arg(Commons.I18n.formatNumber(percent))
                                     : strings.t("running").arg(Commons.I18n.formatNumber(percent))
    if (failed) return strings.t("failedShort")
    if (lastSuccess > 0) return strings.t("lastBackup").arg(relative(ageSeconds))
    return strings.t("never")
  }

  function nextText() {
    if (running) return strings.t("nextRunning")
    if (!connected) return strings.t("nextWhenConnected")
    var due = Number(status.next_due || 0)
    if (due <= 0 || due <= nowSec) return strings.t("nextSoon")
    var mins = Math.max(1, Math.round((due - nowSec) / 60))
    return strings.tn("inMinutes", mins).arg(Commons.I18n.formatNumber(mins))
  }

  function tooltip() {
    var lines = [strings.t("title"), headline()]
    if (configured) lines.push(connected ? strings.t("driveConnected") : strings.t("driveMissing"))
    return lines.join("\n")
  }

  function notifyTransition(next) {
    if (previousState === "running" && next.state === "error") {
      Quickshell.execDetached(["notify-send", "-a", "Hindsight", "-i", "drive-harddisk",
                               strings.t("failedNotifyTitle"), clip(next.last_error, 200)])
    }
    previousState = String(next.state || "")
  }

  // ------------------------------------------------------------- actions ---

  function terminal(args) {
    Quickshell.execDetached(["uwsm-app", "--", "xdg-terminal-exec", "--app-id=org.omarchy.terminal",
                             "--title=Hindsight", "-e"].concat(args))
  }

  function backupNow() {
    actionMessage = ""
    Quickshell.execDetached(["systemctl", "start", "--no-block", "hindsight-backup-now.service"])
    fastPoll.restart()
  }

  function stopBackup() {
    Quickshell.execDetached(["systemctl", "stop", "--no-block", "hindsight-backup-now.service", "hindsight-backup.service"])
    fastPoll.restart()
  }

  function browse() { close(); terminal(["hindsight", "browse"]) }
  function moreOptions() { close(); terminal(["hindsight", "menu"]) }
  function setUp() { close(); terminal(["sudo", "hindsight", "setup"]) }

  function eject() {
    if (ejectProc.running) return
    actionMessage = strings.t("ejecting")
    ejectProc.running = true
  }

  onOpenedChanged: if (opened) {
    actionMessage = ""
    refresh()
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function backup(): string { root.backupNow(); return "ok" }
  }

  Process {
    id: statusProc
    command: ["hindsight", "status", "--json"]
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = String(text || "")
        if (raw.length > 262144) return
        try {
          var parsed = JSON.parse(raw)
          if (parsed && typeof parsed === "object") {
            root.notifyTransition(parsed)
            root.status = parsed
          }
        } catch (e) {}
      }
    }
  }

  Process {
    id: ejectProc
    command: ["hindsight", "eject"]
    stdout: StdioCollector { id: ejectOut }
    stderr: StdioCollector { id: ejectErr }
    onExited: function(code) {
      var msg = root.clip((code === 0 ? ejectOut.text : (ejectErr.text || ejectOut.text)), 160)
      root.actionMessage = msg.replace(/^hindsight: /, "")
      root.refresh()
    }
  }

  // Poll quickly while a backup runs or the popup is open, slowly otherwise.
  Timer {
    interval: root.running || root.opened ? 2000 : 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // A burst of fast polls after starting or stopping, so the UI reacts at once.
  Timer {
    id: fastPoll
    interval: 700
    repeat: true
    property int ticks: 0
    onRunningChanged: if (running) ticks = 0
    onTriggered: { root.refresh(); if (++ticks >= 10) stop() }
  }

  // ------------------------------------------------------------- bar icon ---

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.failed || root.overdue ? root.glyphFailed : root.glyphOk
    slotSize: Style.bar.statusSlot
    active: root.failed || root.overdue
    dimmed: root.configured && !root.connected && !root.running && !root.failed && !root.overdue
    tooltipText: root.opened ? "" : root.tooltip()
    onPressed: function(b) {
      if (b === Qt.RightButton) root.backupNow()
      else if (b === Qt.MiddleButton) root.browse()
      else root.toggle()
    }

    // Gentle pulse while a backup runs (constant motion, so linear is fine).
    SequentialAnimation on opacity {
      running: root.running
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { from: 1; to: 0.45; duration: Style.duration(900) }
      NumberAnimation { from: 0.45; to: 1; duration: Style.duration(900) }
    }
  }

  // --------------------------------------------------------------- popup ---

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(560))

    content: PanelKeyCatcher {
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "b" || t === "B") root.running ? root.stopBackup() : root.backupNow()
        else if (t === "o" || t === "O") root.browse()
        else if (t === "e" || t === "E") root.eject()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: strings.t("title")
          meta: root.headline()
          detail: root.configured ? (root.connected ? strings.t("driveConnected") : strings.t("driveMissing")) : ""
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.connected || root.running ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: root.failed || root.overdue ? root.glyphFailed : root.glyphOk
              color: root.failed || root.overdue ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        // Progress while backing up.
        Column {
          visible: root.running
          width: parent.width
          spacing: Style.space(6)

          Rectangle {
            width: parent.width
            height: Style.space(6)
            radius: height / 2
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

            Rectangle {
              width: Math.max(parent.height, parent.width * root.percent / 100)
              height: parent.height
              radius: parent.radius
              color: root.accent
              Behavior on width { NumberAnimation { duration: Style.duration(250); easing.type: Easing.OutCubic } }
            }
          }

          PlainLabel {
            width: parent.width
            text: strings.t("runningHint")
            color: root.dim
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        PlainLabel {
          visible: root.failed && !root.running
          width: parent.width
          text: strings.t("error").arg(root.clip(root.status.last_error, 220))
          color: root.urgent
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PlainLabel {
          visible: root.overdue && !root.running
          width: parent.width
          text: strings.t("overdue").arg(strings.tn("days", Math.floor(root.ageSeconds / 86400)).arg(Commons.I18n.formatNumber(Math.floor(root.ageSeconds / 86400))))
          color: root.urgent
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PlainLabel {
          visible: root.actionMessage !== ""
          width: parent.width
          text: root.actionMessage
          color: root.dim
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // Not set up yet.
        Button {
          visible: !root.configured
          width: parent.width
          text: strings.t("setUp")
          iconText: "󰒓"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.setUp()
        }

        Column {
          visible: root.configured
          width: parent.width
          spacing: Style.spacing.labelGap

          InfoPair {
            label: strings.t("labelLast")
            value: root.lastSuccess > 0 ? root.formatTime(new Date(root.lastSuccess * 1000).toISOString()) : strings.t("neverShort")
          }
          InfoPair { label: strings.t("labelNext"); value: root.nextText() }
          InfoPair {
            visible: Number(root.status.snapshot_count || 0) > 0
            label: strings.t("labelKept")
            value: Commons.I18n.formatNumber(Number(root.status.snapshot_count || 0))
          }
          InfoPair {
            visible: !!root.status.oldest_snapshot
            label: strings.t("labelOldest")
            value: root.formatTime(root.status.oldest_snapshot)
          }
          InfoPair {
            visible: Number(root.status.last_added || -1) >= 0 && root.lastSuccess > 0
            label: strings.t("labelAdded")
            value: root.bytes(Number(root.status.last_added || 0))
          }
        }

        // Actions.
        RowLayout {
          visible: root.configured
          width: parent.width
          spacing: Style.space(8)

          Button {
            Layout.fillWidth: true
            text: root.running ? strings.t("stop") : strings.t("backUpNow")
            iconText: root.running ? "󰓛" : "󰁯"
            bordered: true
            enabled: root.running || root.connected
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.running ? root.stopBackup() : root.backupNow()
          }
          Button {
            Layout.fillWidth: true
            text: strings.t("browse")
            iconText: "󰉋"
            bordered: true
            enabled: root.connected && Number(root.status.snapshot_count || 0) > 0
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.browse()
          }
        }

        PanelSeparator {
          visible: root.recent.length > 0
          foreground: root.foreground
        }

        Column {
          visible: root.recent.length > 0
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: strings.t("recent")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.recent
            Row {
              required property var modelData
              width: parent.width
              spacing: Style.space(8)
              PlainLabel {
                width: parent.width * 0.7
                text: root.formatTime(modelData.time)
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
              PlainLabel {
                width: parent.width * 0.3 - parent.spacing
                horizontalAlignment: Text.AlignRight
                text: (modelData.tags || []).indexOf("manual") >= 0 ? strings.t("tagManual") : strings.t("tagAuto")
                color: root.dim
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground; visible: root.configured }

        RowLayout {
          visible: root.configured
          width: parent.width
          spacing: Style.space(8)

          Button {
            Layout.fillWidth: true
            text: strings.t("eject")
            iconText: "󰇪"
            enabled: root.connected && !root.running && !ejectProc.running
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.eject()
          }
          Button {
            Layout.fillWidth: true
            text: strings.t("more")
            iconText: "󰇘"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.moreOptions()
          }
        }
      }
    }
  }

  function bytes(n) {
    var units = ["B", "KB", "MB", "GB", "TB"]
    var i = 0
    while (n >= 1000 && i < units.length - 1) { n /= 1000; i++ }
    return Commons.I18n.formatNumber(n, i === 0 ? 0 : 1) + " " + units[i]
  }

  component PlainLabel: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""
    width: parent.width
    spacing: Style.space(8)

    Text {
      id: labelText
      textFormat: Text.PlainText
      text: parent.label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      textFormat: Text.PlainText
      width: parent.width - labelText.implicitWidth - parent.spacing
      horizontalAlignment: Text.AlignRight
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }
}
