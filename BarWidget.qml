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
    if (!toggleProc.running) toggleProc.running = true
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

  // toggleVpn() used to fire-and-forget the toggle script via bar.run()
  // (untrackable -- Bar.run() is Util.execDetached(), no completion signal)
  // and then just restart the 5s status timer, meaning the toggle visibly
  // lagged by up to 5s after nmcli itself had already finished. Running
  // the script through our own Process instead gives a real completion
  // signal (stdout closes once nmcli connection up/down returns, which
  // itself blocks until the change has landed), so the toggle and details
  // refresh fire right when the state actually changed, not on a timer.
  Process {
    id: toggleProc
    command: [Quickshell.env("HOME") + "/.config/omarchy/plugins/remco.wireguard/scripts/wireguard-toggle"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.refreshStatus()
        if (root.popupOpen) root.refreshDetails()
      }
    }
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

  // ---- Health-check ping target (configurable for split tunnels) ----
  // Split-tunnel configs only route specific subnets through wg0, so the
  // default 1.1.1.1 health ping is dropped -- the icon goes red even though
  // the VPN is healthy. Expose the target so the user can point it at a host
  // the tunnel actually routes, without editing the config file by hand.
  property string pingTargetInput: ""
  property string pingTargetError: ""
  property bool pingTargetSaving: false
  // Tracks field focus at root scope so detailsProc can avoid clobbering a
  // mid-edit value (the TextField itself lives deep inside the popup, out of
  // the Process's lexical scope).
  property bool pingTargetFocused: false

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

  function savePingTarget() {
    if (setPingTargetProc.running) return
    setPingTargetProc.command = [
      Quickshell.env("HOME") + "/.config/omarchy/plugins/remco.wireguard/scripts/wireguard-set-ping-target",
      root.pingTargetInput.trim()
    ]
    root.pingTargetSaving = true
    root.pingTargetError = ""
    setPingTargetProc.running = true
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
        // Refresh the ping-target field from disk, but only when the user
        // isn't mid-edit in it (editingFinished drives the value otherwise).
        if (!root.pingTargetFocused && data.ping_target !== undefined) {
          root.pingTargetInput = data.ping_target || ""
        }
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

  // ---- Remove the wg0 profile ----
  property bool confirmRemoveOpen: false
  property string removeError: ""

  function removeProfile() {
    if (!removeProc.running) removeProc.running = true
  }

  Process {
    id: removeProc
    command: [Quickshell.env("HOME") + "/.config/omarchy/plugins/remco.wireguard/scripts/wireguard-remove"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        let data
        try {
          data = JSON.parse(text || "{}")
        } catch (e) {
          return
        }
        if (data.ok) {
          root.removeError = ""
          // hasProfile is derived live from nmcli by wireguard-status, not
          // set optimistically here -- this just asks for a fresh read
          // right away instead of waiting out the 5s poll interval.
          root.refreshStatus()
        } else {
          root.removeError = data.error || "remove failed"
        }
      }
    }
  }

  // ---- Persist the health-check ping target to the config file ----
  Process {
    id: setPingTargetProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.pingTargetSaving = false
        let data
        try {
          data = JSON.parse(text || "{}")
        } catch (e) {
          return
        }
        if (data.ok) {
          root.pingTargetError = ""
          // Re-read so the panel and the health check agree on the live
          // value, and give the ping window a clean start on the new host.
          root.refreshDetails()
          root.pingSamples = []
        } else {
          root.pingTargetError = data.error || "save failed"
        }
      }
    }
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
  // Off by default -- this plugin is built around a manual connect/disconnect
  // toggle, so a profile silently coming up on every boot would be
  // surprising unless someone opts in for this particular import.
  property bool importAutoconnect: false

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
    importProc.command = [
      Quickshell.env("HOME") + "/.config/omarchy/plugins/remco.wireguard/scripts/wireguard-import",
      root.browseDir + "/" + fileName,
      root.importAutoconnect ? "yes" : "no"
    ]
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
          data = { ok: false, error: "unknown error" }
        }
        if (data.ok) {
          root.importError = ""
          root.refreshStatus()
          if (root.popupOpen) root.refreshDetails()
        } else {
          root.importError = data.error || "import failed"
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
    // Floored at Style.space(230): the ConfirmDialog below is a sibling of
    // `column`, sharing this same fixed-size popup window, but its centered
    // card isn't part of `column`'s implicitHeight at all. In the
    // disconnected-with-profile state -- just the hero row plus the Remove
    // profile link, nothing else visible -- `column` alone is short enough
    // that the window sized to fit only it left no room for the dialog's
    // card, which got silently clipped by the window's real edges rather
    // than visually overflowing (a PopupWindow is its own fixed-size
    // Wayland surface, not a clipped-but-present Item). The floor is sized
    // for the dialog's message + button row regardless of which state
    // triggered it.
    contentHeight: popup.fittedContentHeight(Math.max(column.implicitHeight, Style.space(230)))

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
            text: !root.hasProfile ? "NO PROFILE" : (root.connected ? "CONNECTED" : "NOT CONNECTED")
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
          InfoLabel { id: ipLabel; text: "IP Address  " }
          // Width derived from the label's own (measured) width, not a
          // fixed magic number -- "IP Address  " and "Endpoint  " aren't
          // the same width, so a shared fixed value left one row's value
          // ending short of the other's right edge instead of both lining
          // up flush right.
          DetailValue { text: root.details.ip || "--"; width: parent.width - ipLabel.width }
        }
        Row {
          width: parent.width
          InfoLabel { id: endpointLabel; text: "Endpoint  " }
          DetailValue { text: root.details.endpoint || "--"; width: parent.width - endpointLabel.width }
        }
      }

      // ---------- Health-check ping target ----------
      // Full-width settings row shown regardless of how wg0 is managed
      // (NetworkManager profile or wg-quick) and whether it's connected yet
      // -- it's a config option, not a connection detail. Split-tunnel
      // configs only route specific subnets through wg0, so the default
      // 1.1.1.1 health ping gets dropped and the icon goes red even though
      // the VPN is healthy; let the user point it at a host the tunnel
      // actually routes instead of editing the config file by hand. Empty
      // input clears the override back to the default.
      Column {
        visible: true
        width: parent.width
        spacing: Style.spacing.labelGap

        RowLayout {
          width: parent.width
          spacing: Style.space(8)

          InfoLabel {
            id: pingTargetLabel
            text: "Ping Target"
            Layout.alignment: Qt.AlignVCenter
          }

          TextField {
            id: pingTargetField
            text: root.pingTargetInput
            placeholderText: "1.1.1.1 (default)"
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            foreground: root.bar.foreground
            Layout.fillWidth: true
            enabled: !root.pingTargetSaving
            onActiveFocusChanged: root.pingTargetFocused = activeFocus
            onEditingFinished: root.pingTargetInput = text
            Keys.onReturnPressed: root.savePingTarget()
            Keys.onEnterPressed: root.savePingTarget()
          }

          Button {
            text: root.pingTargetSaving ? "Saving…" : "Save"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            enabled: !root.pingTargetSaving
            Layout.alignment: Qt.AlignVCenter
            onClicked: root.savePingTarget()
          }
        }

        Text {
          visible: root.pingTargetError !== ""
          width: parent.width
          text: root.pingTargetError
          color: root.bar.urgent
          wrapMode: Text.WordWrap
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText
        }
      }

      // ---------- Remove profile ----------
      // Visible whenever a profile exists, connected or not -- this is an
      // escape hatch for "wrong file" or "start over", not tied to being
      // connected. Text-link styling (not a full Button) so it reads as a
      // secondary, deliberate action rather than competing with the
      // primary connect toggle above.
      Item {
        visible: root.hasProfile
        width: parent.width
        implicitHeight: removeLink.implicitHeight

        Text {
          id: removeLink
          anchors.right: parent.right
          text: "Remove profile"
          color: root.bar.urgent
          opacity: removeMouse.containsMouse ? 1.0 : 0.6
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText

          MouseArea {
            id: removeMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.confirmRemoveOpen = true
          }
        }
      }

      Text {
        visible: root.removeError !== ""
        width: parent.width
        text: root.removeError
        color: root.bar.urgent
        wrapMode: Text.WordWrap
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        textFormat: Text.PlainText
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
          text: "Choose a WireGuard .conf file to import:"
          color: root.bar.foreground
          opacity: 0.8
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
        }

        // Applies to the profile this import creates, not a global setting --
        // nmcli's own import default is autoconnect=yes, which would
        // otherwise bring the tunnel up on every boot with no prompt.
        Row {
          width: parent.width
          spacing: Style.space(8)

          ToggleSwitch {
            id: autoconnectToggle
            checked: root.importAutoconnect
            anchors.verticalCenter: parent.verticalCenter
            onToggled: root.importAutoconnect = !root.importAutoconnect
          }

          Text {
            width: parent.width - autoconnectToggle.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            text: "Connect automatically at startup"
            color: root.bar.foreground
            opacity: 0.8
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            text: ".. (up)"
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
          text: "No folders or .conf files found."
          color: root.bar.foreground
          opacity: 0.5
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText
        }

        Text {
          visible: root.importing
          width: parent.width
          text: "Importing..."
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

    ConfirmDialog {
      anchors.fill: parent
      opened: root.confirmRemoveOpen
      z: 10
      message: "Remove this WireGuard profile? You'll need to re-import the .conf file to reconnect."
      confirmText: "Remove"
      onCanceled: root.confirmRemoveOpen = false
      onConfirmed: {
        root.confirmRemoveOpen = false
        root.removeProfile()
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
