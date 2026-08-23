import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// WireGuard status icon, plus a click-to-open detail panel modeled on the
// built-in network panel's connection-details grid (Ping / Packet Loss /
// Receiving / Sending / Downloaded / Uploaded / IP Address), with an
// "Endpoint" row standing in for "Gateway" -- a full-tunnel WireGuard peer
// doesn't have a LAN gateway the way a Wi-Fi/Ethernet link does, but the
// peer endpoint is the closest equivalent.
BarWidget {
  id: root
  moduleName: "remco.wireguard"

  readonly property string iface: "wg0"

  // ---- Bar icon (unchanged behavior: poll every 5s regardless of the panel) ----
  property string statusText: ""
  property string statusTooltip: "WireGuard VPN"
  property bool vpnActive: false
  // Whether an "wg0" NetworkManager connection exists at all. False on a
  // fresh install / new machine before any .conf has been imported -- the
  // panel then shows the file browser below instead of the connection UI.
  property bool hasProfile: true

  function refreshStatus() {
    if (!statusProc.running) statusProc.running = true
  }

  function toggleVpn() {
    if (root.bar) root.bar.run("~/.config/omarchy/plugins/remco.wireguard/scripts/wireguard-toggle")
    statusRefreshTimer.restart()
    if (popupOpen) detailsRefreshTimer.restart()
  }

  Component.onCompleted: root.refreshStatus()

  Process {
    id: statusProc
    command: [Quickshell.env("HOME") + "/.config/omarchy/plugins/remco.wireguard/scripts/wireguard-status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        let data
        try {
          data = JSON.parse(text || "{}")
        } catch (e) {
          return
        }
        root.statusText = data.text || ""
        root.statusTooltip = data.tooltip || "WireGuard VPN"
        root.vpnActive = data.class === "active"
        root.hasProfile = data.hasProfile !== false
      }
    }
  }

  Timer {
    id: statusRefreshTimer
    interval: 5000
    running: true
    repeat: true
    onTriggered: root.refreshStatus()
  }

  // ---- Detail panel ----
  property bool popupOpen: false
  property var details: ({})  // { connected, ip, endpoint, rx_bytes, tx_bytes }
  readonly property bool connected: details.connected === true

  property real prevRxBytes: 0
  property real prevTxBytes: 0
  property real prevSampleTime: 0
  property real downloadRate: 0
  property real uploadRate: 0

  // Rolling window of the last N one-shot pings, each {ok, ms}. Packet loss
  // is the failure ratio across the window; latency is the most recent
  // successful sample (matches the bar-icon-adjacent "current reading" feel
  // rather than an average that lags a just-noticed problem).
  readonly property int pingWindow: 10
  property var pingSamples: []
  readonly property var lastOkPing: {
    for (var i = pingSamples.length - 1; i >= 0; i--) {
      if (pingSamples[i].ok) return pingSamples[i]
    }
    return null
  }
  readonly property real pingLatencyMs: lastOkPing ? lastOkPing.ms : -1
  readonly property int pingLossPercent: pingSamples.length === 0
    ? 0
    : Math.round(100 * pingSamples.filter(function(s) { return !s.ok }).length / pingSamples.length)

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root (see the built-in
  // clock's BarWidget.qml for the same comment/pattern).
  readonly property bool opened: popupOpen

  function open() {
    popupOpen = true
  }

  function togglePopup() {
    popupOpen = !popupOpen
  }

  function close() {
    popupOpen = false
  }

  onPopupOpenChanged: {
    if (popupOpen) {
      prevSampleTime = 0
      downloadRate = 0
      uploadRate = 0
      pingSamples = []
      refreshDetails()
      refreshPing()
      if (!root.hasProfile) {
        root.browseDir = Quickshell.env("HOME")
        root.importError = ""
        root.refreshBrowse()
      }
    }
  }

  function refreshDetails() {
    if (!detailsProc.running) detailsProc.running = true
  }

  function refreshPing() {
    if (!pingProc.running) pingProc.running = true
  }

  function updateThroughput(next) {
    var rx = parseFloat(next.rx_bytes || 0)
    var tx = parseFloat(next.tx_bytes || 0)
    var now = Date.now() / 1000

    if (prevSampleTime > 0 && next.connected) {
      var dt = now - prevSampleTime
      if (dt > 0) {
        downloadRate = Math.max(0, (rx - prevRxBytes) / dt)
        uploadRate = Math.max(0, (tx - prevTxBytes) / dt)
      }
    }

    prevRxBytes = rx
    prevTxBytes = tx
    prevSampleTime = now
  }

  function formatBytes(bytes) {
    bytes = Number(bytes) || 0
    if (bytes < 1024) return bytes.toFixed(0) + " B"
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB"
    if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + " MB"
    return (bytes / (1024 * 1024 * 1024)).toFixed(2) + " GB"
  }

  function formatRate(bytesPerSec) {
    return formatBytes(bytesPerSec) + "/s"
  }

  function formatPing(ms) {
    return ms >= 0 ? ms.toFixed(1) + " ms" : "--"
  }

  // Text elements below default to Text.AutoText, which sniffs a string
  // for HTML-looking content and, if it matches, renders it as rich text
  // (including fetching any <img src="..."> it finds). Filenames, paths,
  // and error/endpoint strings ultimately come from the filesystem or from
  // a peer's own .conf, so they're not something to trust as markup --
  // this drops the one character (`<`) that triggers that sniff, for the
  // handful of strings that get displayed through a shared component
  // (Button) that doesn't expose a textFormat override.
  function plainText(s) {
    return String(s === undefined || s === null ? "" : s).replace(/</g, "‹")
  }

  Process {
    id: detailsProc
    command: [Quickshell.env("HOME") + "/.config/omarchy/plugins/remco.wireguard/scripts/wireguard-details"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        let data
        try {
          data = JSON.parse(text || "{}")
        } catch (e) {
          return
        }
        root.details = data
        root.updateThroughput(data)
      }
    }
  }

  Timer {
    id: detailsRefreshTimer
    interval: 1500
    running: root.popupOpen
    repeat: true
    onTriggered: root.refreshDetails()
  }

  Process {
    id: pingProc
    command: [Quickshell.env("HOME") + "/.config/omarchy/plugins/remco.wireguard/scripts/wireguard-ping"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        let data
        try {
          data = JSON.parse(text || "{}")
        } catch (e) {
          return
        }
        var next = root.pingSamples.concat([{ ok: data.ok === true, ms: data.ms || -1 }])
        if (next.length > root.pingWindow) next = next.slice(next.length - root.pingWindow)
        root.pingSamples = next
      }
    }
  }

  Timer {
    id: pingRefreshTimer
    interval: 3000
    running: root.popupOpen
    repeat: true
    triggeredOnStart: false
    onTriggered: root.refreshPing()
  }

  // ---- "No profile yet" import browser ----
  // Only relevant while !hasProfile. A plain in-panel directory listing
  // (dirs first, then *.conf files) rather than a native file dialog --
  // Quickshell's layer-shell panels don't have one, and this keeps the
  // plugin dependency-free (no zenity/kdialog/portal requirement).
  property string browseDir: Quickshell.env("HOME")
  property string browseParent: ""
  property var browseDirs: []
  property var browseFiles: []
  property bool importing: false
  property string importError: ""

  readonly property var browseEntries: {
    var out = []
    for (var i = 0; i < browseDirs.length; i++) out.push({ name: browseDirs[i], kind: "dir" })
    for (var j = 0; j < browseFiles.length; j++) out.push({ name: browseFiles[j], kind: "file" })
    return out
  }

  function refreshBrowse() {
    if (!browseProc.running) browseProc.running = true
  }

  function navigateTo(dir) {
    root.browseDir = dir
    root.refreshBrowse()
  }

  function importFile(fileName) {
    if (importProc.running) return
    root.importing = true
    root.importError = ""
    importProc.command = [Quickshell.env("HOME") + "/.config/omarchy/plugins/remco.wireguard/scripts/wireguard-import", root.browseDir + "/" + fileName]
    importProc.running = true
  }

  Process {
    id: browseProc
    command: [Quickshell.env("HOME") + "/.config/omarchy/plugins/remco.wireguard/scripts/wireguard-browse", root.browseDir]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        let data
        try {
          data = JSON.parse(text || "{}")
        } catch (e) {
          return
        }
        root.browseDir = data.dir || root.browseDir
        root.browseParent = data.parent || ""
        root.browseDirs = data.dirs || []
        root.browseFiles = data.files || []
      }
    }
  }

  Process {
    id: importProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.importing = false
        let data
        try {
          data = JSON.parse(text || "{}")
        } catch (e) {
          data = { ok: false, error: "onbekende fout" }
        }
        if (data.ok) {
          root.importError = ""
          root.refreshStatus()
          if (root.popupOpen) root.refreshDetails()
        } else {
          root.importError = data.error || "import mislukt"
        }
      }
    }
  }

  visible: statusText !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.statusText
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.statusTooltip
    active: root.vpnActive
    onPressed: root.togglePopup()
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(12)

      // ---------- Hero: icon · name + status · toggle ----------
      Item {
        width: parent.width
        implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroToggle.implicitHeight)

        Text {
          id: heroIcon
          text: root.statusText
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.display
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
        }

        ToggleSwitch {
          id: heroToggle
          visible: root.hasProfile
          checked: root.vpnActive
          foreground: root.bar.foreground
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          onToggled: root.toggleVpn()
        }

        Column {
          id: heroLabels
          anchors.left: heroIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.right: heroToggle.left
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            width: parent.width
            text: "WireGuard"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }

          Text {
            width: parent.width
            text: !root.hasProfile ? "GEEN PROFIEL" : (root.connected ? "CONNECTED" : "NOT CONNECTED")
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }
        }
      }

      // ---------- Connection details ----------
      GridLayout {
        visible: root.connected
        width: parent.width
        columns: 4
        columnSpacing: Style.space(20)
        rowSpacing: Style.spacing.labelGap

        InfoLabel { text: "Ping" }
        DetailValue {
          text: root.formatPing(root.pingLatencyMs)
          color: root.pingLossPercent > 0 ? root.bar.urgent : root.bar.foreground
        }
        InfoLabel { text: "Packet Loss" }
        DetailValue {
          text: root.pingSamples.length > 0 ? root.pingLossPercent + "%" : "--"
          color: root.pingLossPercent > 0 ? root.bar.urgent : root.bar.foreground
        }

        InfoLabel { text: "Receiving" }
        DetailValue { text: root.formatRate(root.downloadRate) }
        InfoLabel { text: "Sending" }
        DetailValue { text: root.formatRate(root.uploadRate) }

        InfoLabel { text: "Downloaded" }
        DetailValue { text: root.formatBytes(root.details.rx_bytes || 0) }
        InfoLabel { text: "Uploaded" }
        DetailValue { text: root.formatBytes(root.details.tx_bytes || 0) }
      }

      // IP and endpoint get their own full-width rows rather than sharing
      // the 4-column grid above -- "host:port" endpoints run long enough to
      // get badly truncated squeezed into a quarter-width cell.
      Column {
        visible: root.connected
        width: parent.width
        spacing: Style.spacing.labelGap

        Row {
          width: parent.width
          InfoLabel { text: "IP Address  " }
          DetailValue { text: root.details.ip || "--"; width: parent.width - Style.space(80) }
        }
        Row {
          width: parent.width
          InfoLabel { text: "Endpoint  " }
          DetailValue { text: root.details.endpoint || "--"; width: parent.width - Style.space(80) }
        }
      }

      // ---------- No profile yet: pick a .conf to import ----------
      // Plain in-panel directory listing rather than a native file dialog --
      // Quickshell's layer-shell panels don't have one available, and this
      // keeps the plugin dependency-free (no zenity/kdialog/portal needed).
      Column {
        visible: !root.hasProfile
        width: parent.width
        spacing: Style.space(8)

        Text {
          width: parent.width
          text: "Kies een WireGuard .conf-bestand om te importeren:"
          color: root.bar.foreground
          opacity: 0.8
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            text: ".. (boven)"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            enabled: root.browseParent !== ""
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.navigateTo(root.browseParent)
          }

          Text {
            width: parent.width - Style.space(90)
            anchors.verticalCenter: parent.verticalCenter
            text: root.browseDir
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideMiddle
            textFormat: Text.PlainText
          }
        }

        ListView {
          id: browseList
          width: parent.width
          height: Math.min(Math.max(root.browseEntries.length, 1) * Style.space(30), Style.space(180))
          clip: true
          visible: root.browseEntries.length > 0
          model: root.browseEntries.length

          delegate: Button {
            id: entryButton
            required property int index
            readonly property var entry: root.browseEntries[index]

            width: browseList.width
            leftAlign: true
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            text: entry ? root.plainText(entry.kind === "dir" ? entry.name + "/" : entry.name) : ""
            onClicked: {
              if (!entry) return
              if (entry.kind === "dir") root.navigateTo(root.browseDir + "/" + entry.name)
              else root.importFile(entry.name)
            }
          }
        }

        Text {
          visible: root.browseEntries.length === 0
          width: parent.width
          text: "Geen mappen of .conf-bestanden gevonden."
          color: root.bar.foreground
          opacity: 0.5
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText
        }

        Text {
          visible: root.importing
          width: parent.width
          text: "Bezig met importeren..."
          color: root.bar.foreground
          opacity: 0.7
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText
        }

        Text {
          visible: root.importError !== ""
          width: parent.width
          text: root.importError
          color: root.bar.urgent
          wrapMode: Text.WordWrap
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText
        }
      }
    }
  }

  component InfoLabel: Text {
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
    textFormat: Text.PlainText
  }

  component DetailValue: Text {
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
    Layout.fillWidth: true
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight
    textFormat: Text.PlainText
  }
}
