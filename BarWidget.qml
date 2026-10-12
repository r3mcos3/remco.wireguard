import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// WireGuard status icon, plus a click-to-open panel listing every WireGuard
// NetworkManager profile -- each with its own connect switch, Autoconnect
// switch, Rename and Remove -- and a connection-details grid for the
// connected one, modeled on the built-in network panel (Ping / Packet Loss /
// Receiving / Sending / Downloaded / Uploaded / IP Address), with an
// "Endpoint" row standing in for "Gateway" -- a full-tunnel WireGuard peer
// doesn't have a LAN gateway the way a Wi-Fi/Ethernet link does, but the
// peer endpoint is the closest equivalent.
//
// Profiles are addressed by NetworkManager UUID throughout, never by name:
// names are user-editable here and NetworkManager doesn't require them to
// be unique.
BarWidget {
  id: root
  moduleName: "remco.wireguard"

  readonly property string scriptDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/remco.wireguard/scripts/"

  function parseJson(text) {
    try {
      return JSON.parse(text || "{}")
    } catch (e) {
      return null
    }
  }

  // ---- Bar icon + profile list (polled every 5s regardless of the panel) ----
  property string statusText: ""
  property string statusTooltip: "WireGuard VPN"
  property bool vpnActive: false
  // [{uuid, name, device, state, active, autoconnect}], from wireguard-status.
  property var profiles: []
  property string profilesJson: "[]"
  // Until the first status read lands, "no profiles" just means "not
  // loaded yet" -- don't flash the import browser on a fresh shell start.
  property bool statusLoaded: false
  readonly property bool hasProfile: profiles.length > 0

  // A refresh asked for while a poll is already in flight is queued rather
  // than dropped -- otherwise a toggle that finishes mid-poll would show
  // the pre-toggle state until the next 5s tick.
  property bool statusPending: false

  function refreshStatus() {
    if (statusProc.running) statusPending = true
    else statusProc.running = true
  }

  Component.onCompleted: root.refreshStatus()

  Process {
    id: statusProc
    command: [root.scriptDir + "wireguard-status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = root.parseJson(text)
        if (!data) return
        root.statusText = data.text || ""
        root.statusTooltip = data.tooltip || "WireGuard VPN"
        root.vpnActive = data.class === "active"
        // Only swap the array when something actually changed: the profile
        // rows are a Repeater over it, and rebuilding them every 5s would
        // reset hover state and anything else a row holds.
        var next = Array.isArray(data.profiles) ? data.profiles : []
        var nextJson = JSON.stringify(next)
        if (nextJson !== root.profilesJson) {
          root.profilesJson = nextJson
          root.profiles = next
        }
        root.statusLoaded = true
      }
    }
    onExited: {
      if (root.statusPending) {
        root.statusPending = false
        running = true
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

  // ---- Connect / disconnect ----
  // Run through our own Process rather than bar.run() (fire-and-forget,
  // no completion signal): wireguard-toggle's nmcli up/down blocks until
  // the change has landed, so the switch and details refresh fire right
  // when the state actually changed, not on a timer.
  property string busyUuid: ""
  property string actionError: ""

  function setProfileActive(uuid, up) {
    if (toggleProc.running) return
    root.actionError = ""
    root.busyUuid = uuid
    if (up) root.selectedUuid = uuid
    toggleProc.command = [root.scriptDir + "wireguard-toggle", uuid, up ? "up" : "down"]
    toggleProc.running = true
  }

  Process {
    id: toggleProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busyUuid = ""
        var data = root.parseJson(text)
        if (!data || !data.ok) root.actionError = (data && data.error) || "connect/disconnect failed"
        root.refreshStatus()
        if (root.popupOpen) root.refreshDetails()
      }
    }
  }

  // ---- Autoconnect ----
  // NetworkManager acts on autoconnect=yes right away, so switching it on
  // can also bring a profile up (unless it was disconnected by hand since
  // the last boot); switching it off never drops a connected tunnel.
  //
  // The switch shows the requested value while the change is in flight and
  // the new value is written into `profiles` once it succeeds, so the knob
  // doesn't snap back for the moment until the next status read lands.
  property string autoconnectBusyUuid: ""
  property bool autoconnectTarget: false

  function setProfileAutoconnect(uuid, on) {
    if (autoconnectProc.running) return
    root.actionError = ""
    root.autoconnectBusyUuid = uuid
    root.autoconnectTarget = on
    autoconnectProc.command = [root.scriptDir + "wireguard-autoconnect", uuid, on ? "yes" : "no"]
    autoconnectProc.running = true
  }

  Process {
    id: autoconnectProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var uuid = root.autoconnectBusyUuid
        var data = root.parseJson(text)
        if (data && data.ok) {
          root.profiles = root.profiles.map(function(p) {
            return p.uuid === uuid ? Object.assign({}, p, { autoconnect: root.autoconnectTarget }) : p
          })
        } else {
          root.actionError = (data && data.error) || "changing autoconnect failed"
        }
        root.autoconnectBusyUuid = ""
        root.refreshStatus()
      }
    }
  }

  // ---- Which connected profile the details grid describes ----
  // The one picked by clicking its name, if it's connected; otherwise the
  // first connected profile. Only matters when more than one tunnel is up.
  property string selectedUuid: ""
  readonly property var activeProfiles: profiles.filter(function(p) { return p.active === true })
  readonly property var detailsProfile: {
    for (var i = 0; i < activeProfiles.length; i++) {
      if (activeProfiles[i].uuid === selectedUuid) return activeProfiles[i]
    }
    return activeProfiles.length > 0 ? activeProfiles[0] : null
  }
  readonly property string detailsUuid: detailsProfile ? detailsProfile.uuid : ""
  readonly property string detailsIface: detailsProfile ? (detailsProfile.device || "") : ""

  onDetailsIfaceChanged: {
    resetDetails()
    if (popupOpen && detailsIface !== "") {
      refreshDetails()
      refreshPing()
    }
  }

  // ---- Detail panel ----
  property bool popupOpen: false
  property var details: ({})  // { iface, connected, ip, endpoint, rx_bytes, tx_bytes }
  readonly property bool connected: detailsIface !== "" && details.connected === true

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
      resetDetails()
      root.actionError = ""
      root.refreshStatus()
      if (root.detailsIface !== "") {
        refreshDetails()
        refreshPing()
      }
      if (root.showImport) root.startBrowse()
    } else {
      // Reopening always starts from the plain profile list.
      root.renamingUuid = ""
      root.confirmRemoveUuid = ""
      root.adding = false
      root.pendingImportPath = ""
      root.importError = ""
    }
  }

  function resetDetails() {
    details = ({})
    prevSampleTime = 0
    downloadRate = 0
    uploadRate = 0
    pingSamples = []
  }

  function refreshDetails() {
    if (detailsIface !== "" && !detailsProc.running) detailsProc.running = true
  }

  function refreshPing() {
    if (detailsIface !== "" && !pingProc.running) pingProc.running = true
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
  // profile names and error/endpoint strings ultimately come from the
  // filesystem, from a peer's own .conf or from the user, so they're not
  // something to trust as markup -- this drops the one character (`<`)
  // that triggers that sniff, for the handful of strings that get displayed
  // through a shared component (Button, ConfirmDialog) that doesn't expose
  // a textFormat override.
  function plainText(s) {
    return String(s === undefined || s === null ? "" : s).replace(/</g, "‹")
  }

  Process {
    id: detailsProc
    command: [root.scriptDir + "wireguard-details", root.detailsIface, root.detailsUuid]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = root.parseJson(text)
        // A poll started for a profile the panel has since switched away
        // from would otherwise feed the old tunnel's byte counters into the
        // new one's throughput math.
        if (!data || data.iface !== root.detailsIface) return
        root.details = data
        root.updateThroughput(data)
      }
    }
  }

  Timer {
    id: detailsRefreshTimer
    interval: 1500
    running: root.popupOpen && root.detailsIface !== ""
    repeat: true
    onTriggered: root.refreshDetails()
  }

  Process {
    id: pingProc
    command: [root.scriptDir + "wireguard-ping", root.detailsIface]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = root.parseJson(text)
        if (!data || data.iface !== root.detailsIface) return
        var next = root.pingSamples.concat([{ ok: data.ok === true, ms: data.ms || -1 }])
        if (next.length > root.pingWindow) next = next.slice(next.length - root.pingWindow)
        root.pingSamples = next
      }
    }
  }

  Timer {
    id: pingRefreshTimer
    interval: 3000
    running: root.popupOpen && root.detailsIface !== ""
    repeat: true
    triggeredOnStart: false
    onTriggered: root.refreshPing()
  }

  // ---- Rename ----
  // Only the display name (connection.id) changes; the kernel interface
  // keeps its name, so renaming a connected profile doesn't drop it.
  property string renamingUuid: ""
  property string renamingFrom: ""

  function startRename(profile) {
    root.actionError = ""
    root.renamingUuid = profile.uuid
    root.renamingFrom = profile.name
    Qt.callLater(function() {
      renameField.text = profile.name
      renameField.selectAll()
      renameField.forceActiveFocus()
    })
  }

  function cancelRename() {
    root.renamingUuid = ""
    keyCatcher.forceActiveFocus()
  }

  function commitRename() {
    if (renameProc.running) return
    var name = renameField.text.trim()
    if (name === "") {
      root.actionError = "Names must be 1-64 characters."
      return
    }
    if (name === root.renamingFrom) {
      root.cancelRename()
      return
    }
    root.actionError = ""
    renameProc.command = [root.scriptDir + "wireguard-rename", root.renamingUuid, name]
    renameProc.running = true
  }

  Process {
    id: renameProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = root.parseJson(text)
        if (data && data.ok) {
          root.cancelRename()
          root.refreshStatus()
        } else {
          root.actionError = (data && data.error) || "rename failed"
        }
      }
    }
  }

  // ---- Remove a profile ----
  property string confirmRemoveUuid: ""
  property string confirmRemoveName: ""

  function askRemove(profile) {
    root.actionError = ""
    root.confirmRemoveName = profile.name
    root.confirmRemoveUuid = profile.uuid
  }

  function removeProfile(uuid) {
    if (removeProc.running) return
    removeProc.command = [root.scriptDir + "wireguard-remove", uuid]
    removeProc.running = true
  }

  Process {
    id: removeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = root.parseJson(text)
        if (data && data.ok) {
          root.actionError = ""
          // The profile list is derived live from nmcli by wireguard-status,
          // not edited optimistically here -- this just asks for a fresh
          // read right away instead of waiting out the 5s poll interval.
          root.refreshStatus()
        } else {
          root.actionError = (data && data.error) || "remove failed"
        }
      }
    }
  }

  // ---- Add a profile: pick a .conf, then name it ----
  // Shown on demand via "Add profile", and automatically when there are no
  // profiles at all. A plain in-panel directory listing rather than a
  // native file dialog -- Quickshell's layer-shell panels don't have one,
  // and this keeps the plugin dependency-free (no zenity/kdialog/portal).
  property bool adding: false
  readonly property bool showImport: adding || (statusLoaded && !hasProfile)

  onShowImportChanged: if (showImport && popupOpen) startBrowse()

  property string browseDir: Quickshell.env("HOME")
  property string browseParent: ""
  property var browseDirs: []
  property var browseFiles: []
  // Full path of the .conf picked in the browser; non-empty switches the
  // import section from browsing to the "name it" step.
  property string pendingImportPath: ""
  property bool importing: false
  property string importError: ""
  // Off by default -- this plugin is built around a manual connect/disconnect
  // switch, so a profile silently coming up on every boot would be
  // surprising unless someone opts in for this particular import.
  property bool importAutoconnect: false

  readonly property var browseEntries: {
    var out = []
    for (var i = 0; i < browseDirs.length; i++) out.push({ name: browseDirs[i], kind: "dir" })
    for (var j = 0; j < browseFiles.length; j++) out.push({ name: browseFiles[j], kind: "file" })
    return out
  }

  function startAdding() {
    root.actionError = ""
    root.renamingUuid = ""
    root.adding = true
  }

  function cancelAdding() {
    root.adding = false
    root.pendingImportPath = ""
    root.importError = ""
    keyCatcher.forceActiveFocus()
  }

  function startBrowse() {
    root.pendingImportPath = ""
    root.importError = ""
    root.importAutoconnect = false
    root.navigateTo(Quickshell.env("HOME"))
  }

  function refreshBrowse() {
    if (!browseProc.running) browseProc.running = true
  }

  function navigateTo(dir) {
    root.browseDir = dir
    root.refreshBrowse()
  }

  function pickFile(fileName) {
    root.importError = ""
    root.pendingImportPath = root.browseDir + "/" + fileName
    var suggested = fileName.replace(/\.conf$/i, "")
    Qt.callLater(function() {
      importNameField.text = suggested
      importNameField.selectAll()
      importNameField.forceActiveFocus()
    })
  }

  function backToBrowse() {
    root.pendingImportPath = ""
    root.importError = ""
    keyCatcher.forceActiveFocus()
  }

  function commitImport() {
    if (importProc.running || root.pendingImportPath === "") return
    var name = importNameField.text.trim()
    if (name === "") {
      root.importError = "Give the profile a name."
      return
    }
    root.importing = true
    root.importError = ""
    importProc.command = [
      root.scriptDir + "wireguard-import",
      root.pendingImportPath,
      root.importAutoconnect ? "yes" : "no",
      name
    ]
    importProc.running = true
  }

  Process {
    id: browseProc
    command: [root.scriptDir + "wireguard-browse", root.browseDir]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = root.parseJson(text)
        if (!data) return
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
        var data = root.parseJson(text) || { ok: false, error: "unknown error" }
        if (data.ok) {
          if (data.uuid) root.selectedUuid = data.uuid
          root.cancelAdding()
          root.refreshStatus()
        } else {
          root.importError = data.error || "import failed"
        }
      }
    }
  }

  // Escape steps back one level at a time: dialog, then an open editor,
  // then the import flow, and only then closes the panel.
  function handleEscape() {
    if (root.confirmRemoveUuid !== "") root.confirmRemoveUuid = ""
    else if (root.renamingUuid !== "") root.cancelRename()
    else if (root.pendingImportPath !== "") root.backToBrowse()
    else if (root.adding && root.hasProfile) root.cancelAdding()
    else root.close()
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

  // KeyboardPanel rather than PopupCard: the rename and import-name fields
  // need keyboard input, and an xdg-popup only receives keys after focus
  // has been routed to it through its parent surface.
  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(380))
    // While the remove dialog is up, floored at Style.space(230): the
    // ConfirmDialog is a sibling of `column`, centered over the card, but
    // isn't part of `column`'s implicitHeight -- with only a profile or two
    // listed the card would be too short to hold the dialog's message and
    // button row.
    contentHeight: popup.fittedContentHeight(Math.max(column.implicitHeight, root.confirmRemoveUuid !== "" ? Style.space(230) : 0))

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(event) {
        if (removeDialog.handleKey(event)) {
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          root.handleEscape()
          event.accepted = true
        }
      }
    }

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(12)

      // ---------- Hero: icon · connected profile + status ----------
      Item {
        width: parent.width
        implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

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

        Column {
          id: heroLabels
          anchors.left: heroIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            width: parent.width
            text: root.detailsProfile ? root.detailsProfile.name : "WireGuard"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }

          Text {
            width: parent.width
            text: !root.hasProfile ? "NO PROFILE"
              : root.activeProfiles.length > 1 ? "CONNECTED · " + root.activeProfiles.length + " TUNNELS"
              : root.detailsProfile ? "CONNECTED"
              : "NOT CONNECTED"
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
        visible: root.connected && !root.showImport
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
        visible: root.connected && !root.showImport
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

      // ---------- Profiles ----------
      Column {
        visible: root.hasProfile && !root.showImport
        width: parent.width
        spacing: Style.space(10)

        SectionLabel { text: "PROFILES" }

        Repeater {
          model: root.profiles

          delegate: Item {
            id: row
            required property var modelData
            readonly property bool isActive: modelData.active === true
            // Switching autoconnect on can start an activation, so the
            // connect switch holds off while that change is in flight too.
            readonly property bool autoconnectBusy: root.autoconnectBusyUuid === modelData.uuid
            readonly property bool autoconnectOn: autoconnectBusy ? root.autoconnectTarget : modelData.autoconnect === true
            readonly property bool isBusy: root.busyUuid === modelData.uuid || (autoconnectBusy && root.autoconnectTarget)
              || modelData.state === "activating" || modelData.state === "deactivating"
            // Marks which tunnel the details above describe, but only when
            // there's more than one to choose between.
            readonly property bool isShown: root.activeProfiles.length > 1 && root.detailsUuid === modelData.uuid

            width: parent ? parent.width : 0
            implicitHeight: Math.max(rowLabels.implicitHeight, rowToggle.implicitHeight)

            ToggleSwitch {
              id: rowToggle
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: row.isActive
              busy: row.isBusy
              foreground: root.bar.foreground
              onToggled: root.setProfileActive(row.modelData.uuid, !row.isActive)
            }

            Column {
              id: rowLabels
              anchors.left: parent.left
              anchors.right: rowToggle.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: (row.isShown ? "› " : "") + row.modelData.name
                color: root.bar.foreground
                opacity: row.isActive ? 1.0 : 0.8
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: row.isActive
                elide: Text.ElideRight
                textFormat: Text.PlainText

                MouseArea {
                  anchors.fill: parent
                  enabled: row.isActive && root.activeProfiles.length > 1
                  cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.selectedUuid = row.modelData.uuid
                }
              }

              Row {
                spacing: Style.space(12)

                Text {
                  text: row.isBusy ? "WORKING…" : row.isActive ? "CONNECTED" : "OFF"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.2
                  textFormat: Text.PlainText
                }

                LinkText {
                  text: "Rename"
                  onClicked: root.startRename(row.modelData)
                }

                LinkText {
                  text: "Remove"
                  urgent: true
                  onClicked: root.askRemove(row.modelData)
                }
              }

              // A compact switch sized off its caption, like the network
              // panel's "AUTOMATIC" band switch. Not a Row: the switch is
              // shifted left by its hover-ring padding so the track lines up
              // with the text above it.
              Item {
                implicitWidth: autoconnectSwitch.width - autoconnectSwitch.cursorPad + Style.space(6) + autoconnectLabel.implicitWidth
                implicitHeight: Math.max(autoconnectSwitch.implicitHeight, autoconnectLabel.implicitHeight)

                ToggleSwitch {
                  id: autoconnectSwitch
                  x: -cursorPad
                  anchors.verticalCenter: parent.verticalCenter
                  trackHeight: Math.round(autoconnectLabel.font.pixelSize * 1.2)
                  cursorPad: Style.space(3)
                  checked: row.autoconnectOn
                  busy: row.autoconnectBusy
                  foreground: root.bar.foreground
                  onToggled: root.setProfileAutoconnect(row.modelData.uuid, !row.autoconnectOn)

                  PanelToolTip {
                    visible: autoconnectSwitch.containsMouse || autoconnectLabelMouse.containsMouse
                    text: row.autoconnectOn
                      ? (row.isActive ? "Stop connecting automatically. Stays connected for now." : "Stop connecting automatically.")
                      : (row.isActive ? "Connect automatically, e.g. at startup." : "Connect automatically, e.g. at startup. May also connect it right away.")
                    fontFamily: root.bar.fontFamily
                  }
                }

                Text {
                  id: autoconnectLabel
                  anchors.left: autoconnectSwitch.right
                  anchors.leftMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "AUTOCONNECT"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  opacity: row.autoconnectOn ? 1.0 : 0.7
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.2
                  textFormat: Text.PlainText

                  MouseArea {
                    id: autoconnectLabelMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (!row.autoconnectBusy) root.setProfileAutoconnect(row.modelData.uuid, !row.autoconnectOn)
                  }
                }
              }
            }
          }
        }
      }

      // ---------- Rename editor ----------
      // Lives outside the Repeater on purpose: a status poll that changes
      // any profile rebuilds every row, which would throw away a half-typed
      // name and the field's focus along with it.
      Column {
        visible: root.renamingUuid !== "" && !root.showImport
        width: parent.width
        spacing: Style.space(6)

        InfoLabel {
          width: parent.width
          text: "Rename “" + root.renamingFrom + "” to:"
          elide: Text.ElideRight
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          TextField {
            id: renameField
            width: parent.width - renameSave.width - renameCancel.width - parent.spacing * 2
            anchors.verticalCenter: parent.verticalCenter
            foreground: root.bar.foreground
            font.pixelSize: Style.font.bodySmall
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            maximumLength: 64
            enabled: !renameProc.running
            onAccepted: root.commitRename()
            Keys.onEscapePressed: root.handleEscape()
          }

          Button {
            id: renameSave
            anchors.verticalCenter: parent.verticalCenter
            text: "Save"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            onClicked: root.commitRename()
          }

          Button {
            id: renameCancel
            anchors.verticalCenter: parent.verticalCenter
            text: "Cancel"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            onClicked: root.cancelRename()
          }
        }
      }

      ErrorText {
        visible: root.actionError !== "" && !root.showImport
        text: root.actionError
      }

      LinkText {
        visible: root.hasProfile && !root.showImport
        text: "+ Add profile"
        onClicked: root.startAdding()
      }

      // ---------- Add a profile ----------
      Column {
        visible: root.showImport
        width: parent.width
        spacing: Style.space(8)

        // Step 1: browse to a .conf file.
        Column {
          visible: root.pendingImportPath === ""
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: parent.width
            text: root.hasProfile ? "Choose a WireGuard .conf file to add:" : "Choose a WireGuard .conf file to import:"
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
                else root.pickFile(entry.name)
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

          LinkText {
            visible: root.hasProfile
            text: "Cancel"
            onClicked: root.cancelAdding()
          }
        }

        // Step 2: name the profile, then import.
        Column {
          visible: root.pendingImportPath !== ""
          width: parent.width
          spacing: Style.space(8)

          InfoLabel {
            width: parent.width
            text: root.pendingImportPath
            elide: Text.ElideMiddle
          }

          Text {
            width: parent.width
            text: "Name for this profile:"
            color: root.bar.foreground
            opacity: 0.8
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
          }

          TextField {
            id: importNameField
            width: parent.width
            foreground: root.bar.foreground
            font.pixelSize: Style.font.bodySmall
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            maximumLength: 64
            placeholderText: "e.g. Home, Office, Buenos Aires"
            enabled: !root.importing
            onAccepted: root.commitImport()
            Keys.onEscapePressed: root.handleEscape()
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
              foreground: root.bar.foreground
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
            spacing: Style.space(6)

            Button {
              text: "Import"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              enabled: !root.importing
              onClicked: root.commitImport()
            }

            Button {
              text: "Back"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              enabled: !root.importing
              onClicked: root.backToBrowse()
            }
          }
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

        ErrorText {
          visible: root.importError !== ""
          text: root.importError
        }
      }
    }

    ConfirmDialog {
      id: removeDialog
      anchors.fill: parent
      opened: root.confirmRemoveUuid !== ""
      z: 10
      message: "Remove “" + root.plainText(root.confirmRemoveName) + "”? You'll need to re-import its .conf file to use it again."
      confirmText: "Remove"
      onCanceled: root.confirmRemoveUuid = ""
      onConfirmed: {
        var uuid = root.confirmRemoveUuid
        root.confirmRemoveUuid = ""
        root.removeProfile(uuid)
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

  component SectionLabel: Text {
    color: Qt.darker(root.bar.foreground, 1.4)
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.2
    textFormat: Text.PlainText
  }

  component ErrorText: Text {
    width: parent ? parent.width : 0
    color: root.bar.urgent
    wrapMode: Text.WordWrap
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
    textFormat: Text.PlainText
  }

  // Text-link styling (not a full Button) for secondary actions, so they
  // read as deliberate extras rather than competing with the connect
  // switches.
  component LinkText: Text {
    id: link
    property bool urgent: false
    signal clicked()

    color: urgent ? root.bar.urgent : root.bar.foreground
    opacity: linkMouse.containsMouse ? 1.0 : 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
    textFormat: Text.PlainText

    MouseArea {
      id: linkMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: link.clicked()
    }
  }
}
