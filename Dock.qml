import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Flat taskbar dock — full Windows/Mac behavior. No magnification, no bounce.
// Bottom / left / right / top placements. The dock reserves its strip; the
// interactive popups (tooltip, preview card, jump menu, launcher) live in
// Top/Overlay-layer windows so they float above app windows.
//
// Top placement: the dock maps on the Top layer (same as Omarchy's bar), so
// the compositor keeps the bar at the very edge and docks below it.
//
// Left-click: launch, focus, cycle, or un-minimize (restores scratchpad windows).
// Right-click: jump menu — Minimize, Maximize/Restore, window list with close
// buttons, New Window, Close All, Force Close, Pin/Unpin.
// Hover a running app: live window preview with title + Minimize/Maximize/Close
// (plus Pin for unpinned apps) — a snapshot of the real window refreshed live.
// Hover a launcher: name tooltip. Drag pinned apps to reorder.
// Apps button: Launchpad-style app grid with instant search (Esc closes).
// Running apps get a rounded "shell" ring instead of a dot.
// Hover popups are force-closed after popupTimeoutMs (default 30 s).
Item {
  id: root

  property var shell: null
  property string omarchyPath: ""
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

  // ------------------------------------------------------------ settings

  readonly property string settingsPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/dino.dock.settings.json"
  // position: "bottom" | "top" | "left" | "right"
  property string position: "bottom"
  // autohide: dock hides; a thin edge strip reveals it on pointer contact
  property bool autohide: false
  // hover popups (tooltip, preview, menu) are force-closed after this long
  property int popupTimeoutMs: 30000

  function applySettings(rawText) {
    try {
      var s = JSON.parse(String(rawText || "{}"))
      var p = String(s.position || "bottom").toLowerCase()
      if (p === "bottom" || p === "top" || p === "left" || p === "right") root.position = p
      root.autohide = s.autohide === true
      var t = parseInt(s.popupTimeoutMs, 10)
      if (isFinite(t) && t >= 1000) root.popupTimeoutMs = t
    } catch (e) {}
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applySettings(text())
    onFileChanged: reload()
    onLoadFailed: {}
  }

  readonly property bool isHorizontal: root.position === "bottom" || root.position === "top"
  readonly property bool isSide: !root.isHorizontal

  // ------------------------------------------------------------ Omarchy bar inset (top placement)

  // With top placement the dock maps on the Top layer and the compositor keeps
  // the bar at the edge; the popup window needs the bar's height to place its
  // content below the dock card. Probed from hyprctl layers -j.
  property int topInset: 0

  Process {
    id: barProbe
    command: ["hyprctl", "layers", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var d = JSON.parse(this.text)
          var best = 0
          for (var mon in d) {
            var levels = d[mon].levels || {}
            for (var lvl in levels) {
              if (String(lvl) !== "2") continue
              var arr = levels[lvl]
              for (var i = 0; i < arr.length; i++) {
                var s = arr[i]
                if (s.namespace === "omarchy-bar" && s.y === 0 && s.h > 0 && s.h < 200)
                  best = Math.max(best, s.h)
              }
            }
          }
          root.topInset = best
        } catch (e) { root.topInset = 0 }
      }
    }
  }

  onPositionChanged: {
    if (position === "top") barProbe.running = true
  }

  Component.onCompleted: {
    root.rebuildEntryIndex()
    root.rebuildRunning()
    if (root.appLibrary) root.appLibrary.refreshIcons()
    barProbe.running = true
  }

  // ------------------------------------------------------------ pinned apps

  readonly property string pinnedPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/dino.dock.pinned.json"
  readonly property string legacyPinnedPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/dino.dock/pinned.json"
  readonly property int maxPinned: 20

  property var pinnedIds: []
  property var entryIndex: ({})

  function loadPinned(rawText) {
    var text = String(rawText || "").trim()
    var ids = []
    if (text.length > 0) {
      try {
        var parsed = JSON.parse(text)
        if (Array.isArray(parsed)) {
          for (var i = 0; i < parsed.length; i++) {
            var id = String(parsed[i] || "").trim()
            if (id.length > 0) ids.push(id)
          }
        }
      } catch (e) {}
    }
    if (ids.length > root.maxPinned) ids = ids.slice(0, root.maxPinned)
    root.pinnedIds = ids
  }

  property string pinnedRaw: ""
  property bool pinnedFileExists: false
  property string legacyPinnedRaw: ""
  function applyPinned() {
    root.loadPinned(root.pinnedFileExists ? root.pinnedRaw : root.legacyPinnedRaw)
  }

  FileView {
    id: pinnedFile
    path: root.pinnedPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: { root.pinnedRaw = text(); root.pinnedFileExists = true; root.applyPinned() }
    onFileChanged: reload()
    onLoadFailed: { root.pinnedRaw = ""; root.pinnedFileExists = false; root.applyPinned() }
  }

  FileView {
    id: legacyPinnedFile
    path: root.legacyPinnedPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.legacyPinnedRaw = text(); root.applyPinned() }
    onFileChanged: reload()
    onLoadFailed: { root.legacyPinnedRaw = ""; root.applyPinned() }
  }

  function writePinned(ids) {
    root.pinnedIds = ids
    var text = JSON.stringify(ids, null, 2) + "\n"
    root.pinnedRaw = text
    root.pinnedFileExists = true
    try { pinnedFile.setText(text) } catch (e) {}
  }

  function pinApp(entryId) {
    var id = String(entryId || "").trim()
    if (id.length === 0 || root.pinnedIds.indexOf(id) !== -1) return
    if (root.pinnedIds.length >= root.maxPinned) return
    root.writePinned(root.pinnedIds.concat([id]))
  }

  function unpinApp(id) {
    var ids = root.pinnedIds.filter(function(x) { return x !== id })
    if (ids.length !== root.pinnedIds.length) root.writePinned(ids)
  }

  function rebuildEntryIndex() {
    var idx = {}
    var values = (typeof DesktopEntries !== "undefined" && DesktopEntries.applications) ? DesktopEntries.applications.values : []
    for (var i = 0; i < values.length; i++) {
      if (values[i] && values[i].id) idx[String(values[i].id)] = values[i]
    }
    root.entryIndex = idx
  }

  Connections {
    target: (typeof DesktopEntries !== "undefined") ? DesktopEntries.applications : null
    function onValuesChanged() { root.rebuildEntryIndex() }
  }

  readonly property var resolvedPins: {
    var out = []
    for (var i = 0; i < root.pinnedIds.length; i++) {
      var id = root.pinnedIds[i]
      var entry = root.entryIndex[id] || null
      out.push({ id: id, entry: entry, name: entry ? String(entry.name || id) : id, icon: entry ? entry.icon : id })
    }
    return out
  }

  // ------------------------------------------------------------ running apps

  property var runningAppIds: ({})

  function rebuildRunning() {
    var map = {}
    try {
      var values = ToplevelManager.toplevels.values
      for (var i = 0; i < values.length; i++) {
        var t = values[i]
        var key = String((t && t.appId) || "").toLowerCase()
        if (key.length === 0) continue
        try { if (t.parent) continue } catch (e) {}
        if (key.indexOf("xdg-desktop-portal") === 0) continue
        if (!map[key]) map[key] = []
        map[key].push(t)
      }
    } catch (e) {}
    root.runningAppIds = map
  }

  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() { root.rebuildRunning() }
  }

  function webappTokens(appId) {
    var s = String(appId || "").toLowerCase()
    if (s.indexOf("chrome-") !== 0) return []
    var host = s.slice(7).split("__")[0]
    var parts = host.split(".")
    var skip = { www: 1, app: 1, web: 1, mail: 1, com: 1, net: 1, org: 1, io: 1, dev: 1, co: 1 }
    var out = []
    if (parts.length >= 2) out.push(parts[parts.length - 2])
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].length > 2 && !skip[parts[i]] && out.indexOf(parts[i]) === -1) out.push(parts[i])
    }
    return out
  }

  function entryMatchesAppId(entry, appId) {
    if (!entry) return false
    var key = String(appId || "").toLowerCase()
    if (String(entry.id || "").toLowerCase() === key) return true
    try { if (String(entry.startupClass || "").toLowerCase() === key) return true } catch (e) {}
    var toks = root.webappTokens(key)
    if (toks.length > 0) {
      var eid = String(entry.id || "").toLowerCase()
      var ename = String(entry.name || "").toLowerCase()
      for (var i = 0; i < toks.length; i++) {
        if (eid === toks[i] || ename === toks[i]) return true
      }
    }
    return false
  }

  function runningKeyFor(pin) {
    var needle = String(pin.id || "").toLowerCase()
    var entry = pin.entry || root.entryIndex[pin.id] || null
    for (var key in root.runningAppIds) {
      if (key === needle) return key
      if (root.entryMatchesAppId(entry, key)) return key
    }
    return ""
  }

  function toplevelsFor(pin) {
    var key = root.runningKeyFor(pin)
    return key.length > 0 ? root.runningAppIds[key] : null
  }

  function windowsFor(d) {
    if (d === null || d === undefined) return []
    return (d.isExtra === true) ? (root.runningAppIds[d.key] || []) : (root.toplevelsFor(d) || [])
  }

  function focusNext(toplevels) {
    if (!toplevels || toplevels.length === 0) return
    var active = -1
    for (var i = 0; i < toplevels.length; i++) {
      if (toplevels[i] && toplevels[i].activated === true) { active = i; break }
    }
    var next = toplevels[(active + 1) % toplevels.length]
    if (next && typeof next.activate === "function") next.activate()
  }

  function launchApp(desktopId, name) {
    if (root.appLibrary && typeof root.appLibrary.launch === "function") {
      root.appLibrary.launch(desktopId, name)
    } else {
      var id = String(desktopId || "").trim()
      if (id.length > 0) {
        if (id.slice(-8) === ".desktop") id = id.slice(0, -8)
        Quickshell.execDetached(["uwsm-app", "--", "gtk-launch", id + ".desktop"])
      }
    }
  }

  // Left-click on a running app: cycle windows when one is active, otherwise
  // bring the app forward (also un-minimizes windows parked on the scratchpad).
  function launchOrFocus(pin, toplevels) {
    if (toplevels && toplevels.length > 0) {
      var anyActive = false
      for (var i = 0; i < toplevels.length; i++) {
        if (toplevels[i] && toplevels[i].activated === true) { anyActive = true; break }
      }
      // Windows 11 / macOS taskbar semantics: clicking the icon of the app
      // you're already looking at minimizes it; clicking again brings it back.
      if (anyActive) root.runWindowAction("minimize", toplevels)
      else root.restoreApp(toplevels)
    } else if (!pin.isExtra) {
      root.launchApp(pin.id, pin.name)
    }
  }

  function entryForAppId(appId) {
    try { var e = DesktopEntries.heuristicLookup(String(appId)); if (e) return e } catch (err) {}
    var keys = Object.keys(root.entryIndex)
    for (var i = 0; i < keys.length; i++) {
      if (root.entryMatchesAppId(root.entryIndex[keys[i]], appId)) return root.entryIndex[keys[i]]
    }
    return null
  }

  readonly property var runningExtras: {
    var claimed = {}
    for (var i = 0; i < root.resolvedPins.length; i++) {
      var key = root.runningKeyFor(root.resolvedPins[i])
      if (key.length > 0) claimed[key] = true
    }
    var out = []
    var keys = Object.keys(root.runningAppIds).sort()
    for (i = 0; i < keys.length; i++) {
      if (claimed[keys[i]]) continue
      var tls = root.runningAppIds[keys[i]]
      var appId = tls[0] ? String(tls[0].appId || keys[i]) : keys[i]
      var entry = root.entryForAppId(appId)
      out.push({
        isExtra: true, key: keys[i], id: appId, entry: entry,
        name: entry ? String(entry.name || appId) : ((tls[0] && tls[0].title) ? String(tls[0].title) : appId),
        icon: (entry && entry.icon) ? entry.icon : appId
      })
    }
    return out
  }

  readonly property var dockModel: {
    var out = root.resolvedPins.slice()
    if (root.runningExtras.length > 0) {
      out.push({ isSeparator: true })
      out = out.concat(root.runningExtras)
    }
    return out
  }

  // ------------------------------------------------------------ window actions via helper

  // Hyprland 0.56 evaluates every `dispatch` through Lua, so window-targeted
  // actions go through dock_helper.py (verified dispatcher calls live there).
  readonly property string helperPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/dino.dock/dock_helper.py"

  function runWindowAction(action, toplevels) {
    // NOTE: foreign toplevels expose NO pid — match via appId (hyprctl class)
    var pids = []
    var cls = ""
    if (toplevels) {
      for (var i = 0; i < toplevels.length; i++) {
        var t = toplevels[i]
        if (!t) continue
        var pid = t.pid || 0
        if (pid > 0 && pids.indexOf(pid) === -1) pids.push(pid)
        if (cls.length === 0 && t.appId) cls = String(t.appId)
      }
    }
    Quickshell.execDetached(["/usr/bin/python3", root.helperPath, action, pids.join(","), cls])
  }

  function minimizeApp(d) {
    root.runWindowAction("minimize", root.windowsFor(d))
  }

  function maximizeApp(d) {
    root.runWindowAction("togglemax", root.windowsFor(d))
  }

  function restoreApp(toplevels) {
    root.runWindowAction("restore", toplevels)
  }

  function closeApp(toplevels) {
    if (!toplevels) return
    for (var i = 0; i < toplevels.length; i++) {
      if (toplevels[i] && typeof toplevels[i].close === "function") toplevels[i].close()
    }
  }

  function forceCloseApp(toplevels) {
    if (!toplevels) return
    for (var i = 0; i < toplevels.length; i++) {
      if (toplevels[i] && toplevels[i].pid > 0) {
        Quickshell.execDetached(["kill", "-9", String(toplevels[i].pid)])
      }
    }
  }

  // ------------------------------------------------------------ window preview snapshots

  // Hover previews grab the hovered app's visible window with a region
  // screenshot (grim) and refresh on a short timer — cheap, no GPU loop.
  readonly property string previewPath: "/tmp/dock-preview-" + (Quickshell.env("USER") || "u") + ".png"
  property var previewTarget: null   // { x, y, w, h } | null
  property int previewSeq: 0
  property var previewToplevels: null

  Process {
    id: geometryProbe
    command: ["/usr/bin/python3", root.helperPath, "geometry"]
    stdout: StdioCollector {
      onStreamFinished: root.pickPreviewTarget(this.text)
    }
  }

  function pickPreviewTarget(raw) {
    try {
      var d = JSON.parse(raw)
      var activeWs = (d.activeWorkspace !== undefined) ? d.activeWorkspace : -2
      // foreign toplevels expose no pid — match hyprctl clients by class/appId
      var idset = {}
      var tls = root.previewToplevels || []
      for (var i = 0; i < tls.length; i++) {
        var t = tls[i]
        var a = (t && t.appId) ? String(t.appId).toLowerCase() : ""
        if (a.length > 0) idset[a] = true
      }
      var best = null
      var bestArea = 0
      for (i = 0; i < d.clients.length; i++) {
        var c = d.clients[i]
        if (!c.mapped || c.hidden) continue
        if (c.workspace !== activeWs) continue
        var ckey = String(c.class || "").toLowerCase()
        if (!(idset[ckey])) continue
        var w = (c.size && c.size[0]) || 0
        var h = (c.size && c.size[1]) || 0
        if (w < 60 || h < 60) continue
        var area = w * h
        if (area > bestArea) { bestArea = area; best = { x: c.at[0], y: c.at[1], w: w, h: h } }
      }
      root.previewTarget = best
      if (best !== null) root.grabPreview()
    } catch (e) { root.previewTarget = null }
  }

  Process {
    id: shotProbe
    command: []
    stdout: StdioCollector {}
    onExited: root.previewSeq++
  }

  function grabPreview() {
    var t = root.previewTarget
    if (t === null || t.w <= 0 || t.h <= 0) return
    if (shotProbe.running) return
    // grim: -g (global region) only — -o conflicts with -g
    var geo = Math.max(0, t.x) + "," + Math.max(0, t.y) + " " + t.w + "x" + t.h
    shotProbe.command = ["grim", "-g", geo, root.previewPath]
    shotProbe.running = true
  }

  Timer {
    id: previewRefreshTimer
    interval: 2500
    repeat: true
    running: root.previewTarget !== null && dockCard.hoverRunning
    onTriggered: {
      geometryProbe.running = true
      root.grabPreview()
    }
  }

  function refreshPreview() {
    root.previewToplevels = root.windowsFor(dockCard.hoverSlotData)
    geometryProbe.running = true
  }

  Connections {
    target: dockCard
    function onHoverSlotDataChanged() {
      if (dockCard.hoverSlotData !== null && dockCard.hoverRunning) root.refreshPreview()
    }
  }

  // ------------------------------------------------------------ launcher (Launchpad-style app grid)

  property bool launcherOpen: false
  property string launcherQuery: ""

  readonly property var launcherApps: {
    var out = []
    try {
      var vals = DesktopEntries.applications.values
      for (var i = 0; i < vals.length; i++) {
        var e = vals[i]
        if (!e || e.noDisplay === true) continue
        var nm = String(e.name || "").trim()
        if (nm.length === 0) continue
        out.push({ id: String(e.id), name: nm, icon: String(e.icon || e.id), comment: String(e.comment || "") })
      }
    } catch (err) {}
    out.sort(function(a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1 })
    return out
  }

  readonly property var launcherFiltered: {
    var q = root.launcherQuery.toLowerCase().trim()
    if (q.length === 0) return root.launcherApps
    return root.launcherApps.filter(function(e) {
      return e.name.toLowerCase().indexOf(q) !== -1
        || e.id.toLowerCase().indexOf(q) !== -1
        || e.comment.toLowerCase().indexOf(q) !== -1
    })
  }

  function launchFromLauncher(entry) {
    if (!entry) return
    root.launcherOpen = false
    root.launcherQuery = ""
    root.launchApp(entry.id, entry.name)
  }

  // ------------------------------------------------------------ monitor

  readonly property string monitorPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/dino.dock.monitor.json"
  property string monitorMatch: ""

  FileView {
    id: monitorFile
    path: root.monitorPath
    watchChanges: true
    printErrors: false
    onLoaded: { try { root.monitorMatch = String(JSON.parse(text()) || "").trim().toLowerCase() } catch (e) { root.monitorMatch = text().toLowerCase() } }
    onFileChanged: reload()
    onLoadFailed: { root.monitorMatch = "" }
  }

  function screenMatches(screen) {
    if (!screen || root.monitorMatch.length === 0) return false
    return (String(screen.manufacturer || "") + " " + String(screen.model || "") + " " + String(screen.name || "")).toLowerCase().indexOf(root.monitorMatch) !== -1
  }

  readonly property var targetScreen: {
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++) {
      if (root.screenMatches(screens[i])) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  // ------------------------------------------------------------ constants
  readonly property int iconSize: Style.space(36)
  readonly property int iconGap: Style.space(6)
  readonly property int padX: Style.space(10)
  readonly property int padY: Style.space(8)
  readonly property int appsBtnWidth: Style.space(36)   // same rhythm as icon slots
  readonly property int cardHeight: iconSize + padY * 2   // card thickness (perpendicular)
  readonly property int panelHeight: cardHeight + Style.space(16)

  // perpendicular distance from the card's inner edge to popup content
  readonly property int cardTopGap: Style.space(8) + root.cardHeight + Style.space(6)
  readonly property int popupExtent: root.cardTopGap + Style.space(470)
  readonly property int menuMaxWindows: 6

  // ------------------------------------------------------------ popup state

  readonly property bool popupActive: {
    if (dockCard.menuData !== null) return true
    if (dockCard.hoverSlotData === null) return false
    if (dockCard.dragIndex >= 0) return false
    return true
  }

  onPopupActiveChanged: {
    if (popupActive) popupMaxTimer.restart()
    else popupMaxTimer.stop()
  }

  // ------------------------------------------------------------ popup dismissal watchdog
  // MouseArea hover-exit does NOT fire when the pointer leaves through an
  // input-mask boundary, so popup keep-alive can't rely on it. Watch the real
  // cursor: while a popup is open, dismiss it once the cursor leaves the dock
  // card and every visible popup region. (popupMaxTimer stays as the hard cap.)
  Timer {
    id: popupWatch
    interval: 250
    repeat: true
    running: root.popupActive
    onTriggered: cursorProbe.running = true
  }

  Process {
    id: cursorProbe
    command: ["hyprctl", "cursorpos"]
    stdout: StdioCollector { onStreamFinished: root.cursorCheck(this.text) }
  }

  function popupOrigin() {
    var s = root.targetScreen
    var sw = s ? s.width : 1920
    var sh = s ? s.height : 1080
    if (root.position === "bottom") return { x: 0, y: sh - popupPanel.implicitHeight }
    if (root.position === "top") return { x: 0, y: 0 }
    if (root.position === "left") return { x: 0, y: 0 }
    return { x: sw - popupPanel.implicitWidth, y: 0 }
  }

  function dockCardScreenRect() {
    var s = root.targetScreen
    var sw = s ? s.width : 1920
    var sh = s ? s.height : 1080
    var g = Style.space(8)
    if (root.isHorizontal) {
      var cy = root.position === "bottom" ? sh - g - root.cardHeight : root.topInset + g
      return { x: dockCard.x, y: cy, w: dockCard.width, h: root.cardHeight }
    }
    var cx = root.position === "left" ? g : sw - g - root.cardHeight
    return { x: cx, y: dockCard.y, w: root.cardHeight, h: dockCard.height }
  }

  function insideRect(r, x, y, pad) {
    return r && x >= r.x - pad && x <= r.x + r.w + pad && y >= r.y - pad && y <= r.y + r.h + pad
  }

  function cursorCheck(text) {
    var parts = String(text).trim().split(",")
    if (parts.length !== 2) return
    var cx = parseFloat(parts[0])
    var cy = parseFloat(parts[1])
    if (!isFinite(cx) || !isFinite(cy)) return
    var keep = insideRect(dockCardScreenRect(), cx, cy, 4)
    if (!keep && root.popupActive) {
      var o = popupOrigin()
      var px = cx - o.x
      var py = cy - o.y
      keep = insideRect(popupPanel.cardRect(), px, py, 4)
        || insideRect({ x: previewCard.x, y: previewCard.y, w: previewCard.width, h: previewCard.visible ? previewCard.height : 0 }, px, py, 2)
        || insideRect({ x: pillItem.x, y: pillItem.y, w: pillItem.width, h: pillItem.visible ? pillItem.height : 0 }, px, py, 2)
        || insideRect({ x: ctxMenu.x, y: ctxMenu.y, w: ctxMenu.width, h: ctxMenu.visible ? ctxMenu.height : 0 }, px, py, 2)
        || insideRect({ x: tooltip.x, y: tooltip.y, w: tooltip.width, h: tooltip.visible ? tooltip.height : 0 }, px, py, 2)
    }
    if (!keep && root.popupActive) {
      dockCard.hoverSlotData = null
      dockCard.menuData = null
      dockCard.pillHover = false
      dockCard.slotHoverCount = 0
    }
  }

  // ------------------------------------------------------------ dock panel

  PanelWindow {
    id: panel
    visible: !root.autohide || root.revealed
    screen: root.targetScreen
    anchors.bottom: root.position === "bottom" || root.isSide
    anchors.top: root.position === "top" || root.isSide
    anchors.left: root.position === "left" || root.isHorizontal
    anchors.right: root.position === "right" || root.isHorizontal
    implicitWidth: root.isHorizontal ? 0 : root.panelHeight
    implicitHeight: root.isHorizontal ? root.panelHeight : 0
    color: "transparent"
    WlrLayershell.namespace: "omarchy-dock"
    // Top placement rides the Top layer so the compositor keeps Omarchy's bar
    // at the very edge and stacks the dock right below it (verified ordering).
    WlrLayershell.layer: root.position === "top" ? WlrLayer.Top : WlrLayer.Bottom
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: (root.autohide && !root.revealed) ? ExclusionMode.Ignore : ExclusionMode.Auto

    // Input is only the dock card itself — popups live in the popup window.
    mask: Region {
      x: dockCard.x
      y: dockCard.y
      width: dockCard.width
      height: dockCard.height
    }

    Item {
      id: dockCard
      anchors.horizontalCenter: root.isHorizontal ? parent.horizontalCenter : undefined
      anchors.verticalCenter: root.isSide ? parent.verticalCenter : undefined
      anchors.left: root.position === "left" ? parent.left : undefined
      anchors.right: root.position === "right" ? parent.right : undefined
      anchors.top: root.position === "top" ? parent.top : undefined
      anchors.bottom: root.position === "bottom" ? parent.bottom : undefined
      anchors.margins: Style.space(8)
      width: root.isHorizontal ? rowLength : root.cardHeight
      height: root.isHorizontal ? root.cardHeight : rowLength

      readonly property bool hasSeparator: root.runningExtras.length > 0
      readonly property int sepWidth: 1
      readonly property int iconCount: Math.max(1, root.dockModel.length - (hasSeparator ? 1 : 0))
      readonly property int slotCount: iconCount + (hasSeparator ? 1 : 0)
      readonly property int fixedPad: root.padX * 2 + (slotCount - 1) * root.iconGap + (hasSeparator ? sepWidth : 0) + root.appsBtnWidth
      readonly property int rowLength: (iconCount * root.iconSize) + fixedPad

      property var menuData: null
      property real menuX: 0
      property int dragIndex: -1
      property int dragTargetIndex: -1

      // hover state shared with the popup window (pill / tooltip)
      property var hoverSlotData: null
      property bool hoverRunning: false
      property bool hoverIsExtra: false
      property real hoverX: 0
      property bool pillHover: false
      property int slotHoverCount: 0

      function noteHover(data, running, isExtra, axisCenter) {
        // set flags FIRST — hoverSlotData last (its change drives the preview refresh)
        hoverRunning = running === true
        hoverIsExtra = isExtra === true
        hoverX = axisCenter
        hoverSlotData = data
        hoverHideTimer.restart()
      }

      function hoverLeft(data) {
        if (hoverSlotData === data) hoverHideTimer.restart()
      }

      // ids are NOT reachable as properties from other scopes/scenes
      // (popup panel MouseAreas), so wrap timer access in functions.
      function hoverHideTimerStop() { hoverHideTimer.stop() }
      function hoverHideTimerRestart() { hoverHideTimer.restart() }

      Timer {
        id: hoverHideTimer
        interval: 300
        onTriggered: {
          if (!dockCard.pillHover && dockCard.slotHoverCount <= 0) dockCard.hoverSlotData = null
        }
      }

      Connections {
        target: root
        function onDockModelChanged() {
          // delegates were rebuilt — stale hover state must not linger
          dockCard.hoverSlotData = null
          dockCard.pillHover = false
          dockCard.slotHoverCount = 0
        }
      }

      // ---- background ----
      Rectangle {
        width: dockCard.width
        height: dockCard.height
        radius: Style.space(12)
        color: "#13141c"
        border.width: 1
        border.color: Util.alpha(Color.accent, 0.15)
      }

      Flow {
        id: mainRow
        flow: root.isHorizontal ? Flow.LeftToRight : Flow.TopToBottom
        spacing: root.iconGap
        anchors.horizontalCenter: root.isHorizontal ? parent.horizontalCenter : undefined
        anchors.verticalCenter: root.isSide ? parent.verticalCenter : undefined
        anchors.left: root.position === "left" ? parent.left : undefined
        anchors.right: root.position === "right" ? parent.right : undefined
        anchors.top: root.position === "top" ? parent.top : undefined
        anchors.bottom: root.position === "bottom" ? parent.bottom : undefined
        anchors.margins: root.padX

        // ---- Apps button (vector glyph, opens the Launchpad-style grid) ----
        Rectangle {
          id: appsBtn
          width: root.appsBtnWidth
          height: root.iconSize
          radius: Style.space(8)
          color: appsBtnMa.containsMouse ? Util.alpha(Color.accent, 0.2) : "transparent"

          Item {
            id: launcherGlyph
            anchors.centerIn: parent
            width: Style.space(24)
            height: Style.space(24)

            readonly property real cell: (width - Style.space(4)) / 2
            readonly property real bright: appsBtnMa.containsMouse ? 1.0 : 0.0

            // 2x2 rounded-square grid — top-right tile lit, Launchpad style
            Rectangle {
              x: 0; y: 0
              width: launcherGlyph.cell; height: launcherGlyph.cell
              radius: Style.space(3)
              color: Color.accent
              opacity: 0.85 + 0.15 * launcherGlyph.bright
            }
            Rectangle {
              x: launcherGlyph.cell + Style.space(4); y: 0
              width: launcherGlyph.cell; height: launcherGlyph.cell
              radius: Style.space(3)
              color: Color.accent
              opacity: 1.0
            }
            Rectangle {
              x: 0; y: launcherGlyph.cell + Style.space(4)
              width: launcherGlyph.cell; height: launcherGlyph.cell
              radius: Style.space(3)
              color: Color.accent
              opacity: 0.75 + 0.25 * launcherGlyph.bright
            }
            Rectangle {
              x: launcherGlyph.cell + Style.space(4); y: launcherGlyph.cell + Style.space(4)
              width: launcherGlyph.cell; height: launcherGlyph.cell
              radius: Style.space(3)
              color: Color.accent
              opacity: 0.75 + 0.25 * launcherGlyph.bright
            }
          }

          MouseArea {
            id: appsBtnMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.launcherOpen = !root.launcherOpen
          }
        }

        // ---- icon slots ----
        Repeater {
          model: root.dockModel

          delegate: Item {
            id: slot
            required property var modelData
            required property int index
            readonly property bool isSep: modelData.isSeparator === true
            readonly property bool isExtra: modelData.isExtra === true
            readonly property bool isPinned: !isSep && !isExtra
            width: isSep ? (root.isHorizontal ? dockCard.sepWidth : root.iconSize) : root.iconSize
            height: isSep ? (root.isHorizontal ? root.iconSize : dockCard.sepWidth) : root.iconSize

            readonly property var runningToplevels: isSep ? null
              : (isExtra ? (root.runningAppIds[modelData.key] || null) : root.toplevelsFor(modelData))
            readonly property bool isRunning: runningToplevels !== null && runningToplevels.length > 0

            // separator
            Rectangle {
              visible: isSep
              width: root.isHorizontal ? dockCard.sepWidth : root.iconSize * 0.6
              height: root.isHorizontal ? root.iconSize * 0.6 : dockCard.sepWidth
              color: Util.alpha(Color.accent, 0.35)
              anchors.centerIn: parent
            }

            // icon tile
            Rectangle {
              id: tile
              visible: !isSep
              width: root.iconSize
              height: root.iconSize
              radius: Style.space(10)
              color: slotMa.containsMouse ? Util.alpha(Color.accent, 0.15) : "transparent"
              anchors.centerIn: parent
              opacity: dockCard.dragIndex === index ? 0.4 : 1.0

              Image {
                id: icon
                anchors.fill: parent
                anchors.margins: Style.space(4)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                sourceSize.width: 128
                sourceSize.height: 128
                visible: true
                smooth: true
                mipmap: true

                readonly property string themedPath: {
                  var ic = String(slot.modelData.icon || "")
                  if (!ic) return ""
                  if (ic.charAt(0) === "/") return "file://" + ic
                  try { var p = Quickshell.iconPath(ic, true); if (p) return p.charAt(0) === "/" ? "file://" + p : p } catch (e) {}
                  return root.appLibrary ? root.appLibrary.iconSource(ic) : ""
                }
                readonly property string genericPath: {
                  try { var p = Quickshell.iconPath("application-x-executable", true); if (p) return p.charAt(0) === "/" ? "file://" + p : p } catch (e) {}
                  return "file://" + (Quickshell.env("HOME") || "") + "/.local/share/icons/Papirus/64x64/apps/application-default-icon.svg"
                }
                readonly property var candidates: {
                  var ic = String(slot.modelData.icon || "")
                  var out = []
                  if (themedPath) out.push(themedPath)
                  if (ic.length > 0) {
                    out.push("file://" + (Quickshell.env("HOME") || "") + "/.local/share/icons/Papirus/64x64/apps/" + ic + ".svg")
                    out.push("file://" + (Quickshell.env("HOME") || "") + "/.local/share/icons/Papirus/64x64/apps/" + ic + ".png")
                    out.push("file://" + (Quickshell.env("HOME") || "") + "/.local/share/icons/hicolor/512x512/apps/" + ic + ".png")
                  }
                  out.push(genericPath)
                  return out
                }
                property int stage: 0
                onCandidatesChanged: stage = 0
                source: candidates[Math.min(stage, candidates.length - 1)]
                onStatusChanged: { if (status === Image.Error && stage < candidates.length - 1) stage += 1 }
              }
            }

            // running "shell": rounded ring around the icon (replaces the dot)
            Rectangle {
              visible: isRunning && !isSep
              width: root.iconSize + Style.space(4)
              height: root.iconSize + Style.space(4)
              radius: Style.space(12)
              color: "transparent"
              border.color: Color.accent
              border.width: Math.max(2, Style.space(2))
              anchors.centerIn: parent
              z: 5
            }

            // click + drag handler
            MouseArea {
              id: slotMa
              anchors.fill: parent
              visible: !isSep
              enabled: !isSep
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              cursorShape: Qt.PointingHandCursor

              property bool isDragging: false
              property real dragPressX: 0
              property real dragPressY: 0

              onContainsMouseChanged: {
                if (containsMouse) {
                  dockCard.slotHoverCount++
                  var axis = root.isHorizontal
                    ? (mainRow.x + slot.x + slot.width / 2)
                    : (mainRow.y + slot.y + slot.height / 2)
                  dockCard.noteHover(slot.modelData, slot.isRunning, slot.isExtra, axis)
                } else {
                  dockCard.slotHoverCount = Math.max(0, dockCard.slotHoverCount - 1)
                  dockCard.hoverLeft(slot.modelData)
                }
              }

              onPressed: (mouse) => {
                if (mouse.button === Qt.LeftButton) {
                  dragPressX = mouse.x
                  dragPressY = mouse.y
                  isDragging = false
                }
              }

              onPositionChanged: (mouse) => {
                if (!pressed || isSep || isExtra) return
                var axisDelta = root.isHorizontal
                  ? Math.abs(mouse.x - dragPressX)
                  : Math.abs(mouse.y - dragPressY)
                if (!isDragging && axisDelta > root.iconSize * 0.5) {
                  isDragging = true
                  dockCard.dragIndex = index
                  dockCard.menuData = null
                }
                if (isDragging) {
                  var rel = root.isHorizontal
                    ? mapToItem(dockCard, mouse.x, 0).x
                    : mapToItem(dockCard, 0, mouse.y).y
                  dockCard.dragTargetIndex = Math.max(0, Math.min(root.pinnedIds.length, Math.round(rel / (root.iconSize + root.iconGap))))
                }
              }

              onReleased: (mouse) => {
                if (isDragging && dockCard.dragIndex >= 0 && dockCard.dragTargetIndex >= 0) {
                  var from = dockCard.dragIndex
                  var to = dockCard.dragTargetIndex
                  if (from !== to && from < root.pinnedIds.length) {
                    var ids = root.pinnedIds.slice()
                    var moved = ids.splice(from, 1)[0]
                    var insertAt = to > from ? to - 1 : to
                    if (insertAt !== from) {
                      ids.splice(insertAt, 0, moved)
                      root.writePinned(ids)
                    }
                  }
                }
                dockCard.dragIndex = -1
                dockCard.dragTargetIndex = -1
                isDragging = false
              }

              onClicked: (mouse) => {
                if (isDragging) return
                if (mouse.button === Qt.RightButton) {
                  dockCard.menuX = root.isHorizontal
                    ? (mainRow.x + x + width / 2)
                    : (mainRow.y + y + height / 2)
                  dockCard.menuData = (dockCard.menuData === modelData) ? null : modelData
                  return
                }
                dockCard.menuData = null
                root.launcherOpen = false
                root.launchOrFocus(modelData, runningToplevels)
              }
            }
          }
        }
      }

      // ---- drag insertion indicator ----
      Rectangle {
        visible: dockCard.dragTargetIndex >= 0
        width: root.isHorizontal ? Style.space(3) : root.iconSize
        height: root.isHorizontal ? root.iconSize : Style.space(3)
        radius: width / 2
        color: Color.accent
        z: 50
        x: root.isHorizontal
          ? mainRow.x + root.appsBtnWidth + root.iconGap + dockCard.dragTargetIndex * (root.iconSize + root.iconGap) - root.iconGap / 2 - width / 2
          : (root.position === "left" ? mainRow.x + mainRow.width + Style.space(2) : mainRow.x - Style.space(2) - width)
        y: root.isHorizontal
          ? (root.position === "bottom" ? mainRow.y + mainRow.height + Style.space(2) : mainRow.y - Style.space(2) - height)
          : mainRow.y + root.appsBtnWidth + root.iconGap + dockCard.dragTargetIndex * (root.iconSize + root.iconGap) - root.iconGap / 2 - height / 2
      }
    }
  }

  // ------------------------------------------------------------ popup window
  // Top-layer window hosting the hover preview card, tooltip and the
  // right-click menu so they float above app windows.

  PanelWindow {
    id: popupPanel
    visible: root.popupActive
    screen: root.targetScreen
    anchors.bottom: root.position === "bottom" || root.isSide
    anchors.top: root.position === "top" || root.isSide
    anchors.left: root.isHorizontal || root.position === "left"
    anchors.right: root.isHorizontal || root.position === "right"
    implicitWidth: root.isHorizontal ? 0 : root.popupExtent
    implicitHeight: root.isHorizontal ? root.popupExtent + (root.position === "top" ? root.topInset : 0) : 0
    color: "transparent"
    WlrLayershell.namespace: "omarchy-dock-popup"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    readonly property int topInset: root.position === "top" ? root.topInset : 0

    readonly property bool menuOpen: dockCard.menuData !== null
    readonly property bool dragBusy: dockCard.dragIndex >= 0
    readonly property bool previewVisible: !menuOpen && !dragBusy
      && dockCard.hoverSlotData !== null && dockCard.hoverRunning
    readonly property bool pillVisible: !menuOpen && !dragBusy
      && dockCard.hoverSlotData !== null
      && !dockCard.hoverRunning && !dockCard.hoverIsExtra
    readonly property bool tooltipVisible: !menuOpen && !dragBusy
      && dockCard.hoverSlotData !== null
      && !dockCard.hoverRunning

    // dock card rectangle mapped into this window's coordinates
    function cardRect() {
      if (root.isHorizontal) {
        var cy = root.position === "bottom"
          ? height - Style.space(8) - root.cardHeight
          : topInset + Style.space(8)
        return { x: dockCard.x, y: cy, w: dockCard.width, h: root.cardHeight }
      }
      var cx = root.position === "left"
        ? Style.space(8)
        : width - Style.space(8) - root.cardHeight
      return { x: cx, y: dockCard.y, w: root.cardHeight, h: dockCard.height }
    }

    function maskRect() {
      var cr = cardRect()
      if (menuOpen) {
        var mx = Math.min(ctxMenu.x, cr.x)
        var my = Math.min(ctxMenu.y, cr.y)
        var right = Math.max(ctxMenu.x + ctxMenu.width, cr.x + cr.w)
        var bottom = Math.max(ctxMenu.y + ctxMenu.height, cr.y + cr.h)
        return [mx, my, right - mx, bottom - my]
      }
      if (previewVisible) return [previewCard.x - 8, previewCard.y - 8, previewCard.width + 16, previewCard.height + 16]
      if (pillVisible) return [pillItem.x - 8, pillItem.y - 8, pillItem.width + 16, pillItem.height + 16]
      return [0, 0, 0, 0]
    }

    mask: Region {
      property var r: popupPanel.maskRect()
      x: r[0]
      y: r[1]
      width: r[2]
      height: r[3]
    }

    Item {
      id: popupRoot
      anchors.fill: parent

      // ---- tooltip (launcher names) ----
      Rectangle {
        id: tooltip
        visible: popupPanel.tooltipVisible && dockCard.hoverSlotData !== null
          && dockCard.hoverSlotData.isExtra !== true && !dockCard.hoverRunning
        radius: Style.space(6)
        color: Util.alpha(Color.tooltip.background, 0.95)
        width: tooltipLabel.implicitWidth + Style.space(16)
        height: tooltipLabel.implicitHeight + Style.space(8)
        x: {
          if (root.isHorizontal) {
            var want = dockCard.x + dockCard.hoverX - width / 2
            return Math.max(4, Math.min(want, popupRoot.width - width - 4))
          }
          var stack = (popupPanel.pillVisible && popupPanel.tooltipVisible) ? pillItem.width + Style.space(4) : 0
          var tx = root.position === "left"
            ? root.cardTopGap + stack
            : popupRoot.width - root.cardTopGap - width - stack
          return Math.max(4, Math.min(tx, popupRoot.width - width - 4))
        }
        y: {
          if (root.isHorizontal) {
            var stack2 = (popupPanel.pillVisible && popupPanel.tooltipVisible) ? pillItem.height + Style.space(4) : 0
            return root.position === "bottom"
              ? popupRoot.height - root.cardTopGap - height - stack2
              : popupPanel.topInset + root.cardTopGap + stack2
          }
          var wantY = dockCard.y + dockCard.hoverX - height / 2
          return Math.max(4, Math.min(wantY, popupRoot.height - height - 4))
        }

        Text {
          id: tooltipLabel
          anchors.centerIn: parent
          text: (dockCard.hoverSlotData && dockCard.hoverSlotData.name) ? String(dockCard.hoverSlotData.name) : ""
          color: Color.tooltip.text
          font.family: Style.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      // ---- unpin pill (pinned apps that are NOT running) ----
      Rectangle {
        id: pillItem

        readonly property var buttons: {
          var d = dockCard.hoverSlotData
          var out = []
          if (d === null || popupPanel.menuOpen) return out
          if (!dockCard.hoverRunning && !dockCard.hoverIsExtra) out.push({ k: "unpin", l: "✕" })
          return out
        }

        readonly property int btnSize: Style.space(26)
        width: buttons.length * btnSize + Style.space(10)
        height: btnSize + Style.space(8)
        radius: Style.space(9)
        color: Util.alpha(Color.popups.background, 0.98)
        border.color: Util.alpha(Color.popups.border, 0.5)
        border.width: 1
        x: {
          if (root.isHorizontal) {
            var want = dockCard.x + dockCard.hoverX - width / 2
            return Math.max(4, Math.min(want, popupRoot.width - width - 4))
          }
          var px = root.position === "left"
            ? root.cardTopGap - Style.space(4)
            : popupRoot.width - root.cardTopGap - width + Style.space(4)
          return Math.max(4, Math.min(px, popupRoot.width - width - 4))
        }
        y: {
          if (root.isHorizontal) {
            return root.position === "bottom"
              ? popupRoot.height - root.cardTopGap + Style.space(4) - height
              : popupPanel.topInset + root.cardTopGap - Style.space(4)
          }
          var wantY = dockCard.y + dockCard.hoverX - height / 2
          return Math.max(4, Math.min(wantY, popupRoot.height - height - 4))
        }
        visible: popupPanel.pillVisible && buttons.length > 0
        z: 10

        MouseArea {
          id: pillMa
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton
          cursorShape: Qt.PointingHandCursor
          onEntered: { dockCard.pillHover = true; dockCard.hoverHideTimerStop() }
          onExited: { dockCard.pillHover = false; dockCard.hoverHideTimerRestart() }
        }

        Flow {
          x: Style.space(5)
          anchors.verticalCenter: parent.verticalCenter
          spacing: 0
          flow: Flow.LeftToRight

          Repeater {
            model: pillItem.buttons

            delegate: Rectangle {
              id: pillBtn
              required property var modelData
              width: pillItem.btnSize
              height: pillItem.btnSize
              radius: Style.space(6)
              color: pillBtnMa.containsMouse ? Util.alpha(Color.accent, 0.25) : "transparent"

              Text {
                anchors.centerIn: parent
                text: pillBtn.modelData.l
                color: Color.popups.text
                font.family: Style.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                id: pillBtnMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: (mouse) => {
                  mouse.accepted = true
                  var d = dockCard.hoverSlotData
                  if (d === null) return
                  var kind = pillBtn.modelData.k
                  if (kind === "unpin") root.unpinApp(String(d.id || ""))
                  dockCard.hoverSlotData = null
                }
              }
            }
          }
        }
      }

      // ---- live window preview card (hover on a running app) ----
      Rectangle {
        id: previewCard

        readonly property var d: dockCard.hoverSlotData
        readonly property var tls: root.windowsFor(d)
        readonly property string title: {
          if (d === null) return ""
          for (var i = 0; i < tls.length; i++) {
            if (tls[i] && tls[i].activated === true) return String(tls[i].title || d.name)
          }
          return String((tls[0] && tls[0].title) || d.name || "")
        }

        readonly property var buttons: {
          var out = []
          if (d === null) return out
          out.push({ k: "min", l: "–" })
          out.push({ k: "max", l: "□" })
          out.push({ k: "close", l: "✕" })
          if (dockCard.hoverIsExtra) out.push({ k: "pin", l: "＋" })
          return out
        }

        readonly property int headerH: Style.space(38)
        readonly property int bodyH: Style.space(190)
        width: Style.space(336)
        height: headerH + bodyH + Style.space(10)
        radius: Style.space(12)
        color: Util.alpha(Color.popups.background, 0.98)
        border.color: Util.alpha(Color.popups.border, 0.5)
        border.width: 1
        x: {
          if (root.isHorizontal) {
            var want = dockCard.x + dockCard.hoverX - width / 2
            return Math.max(4, Math.min(want, popupRoot.width - width - 4))
          }
          var px = root.position === "left"
            ? root.cardTopGap - Style.space(4)
            : popupRoot.width - root.cardTopGap - width + Style.space(4)
          return Math.max(4, Math.min(px, popupRoot.width - width - 4))
        }
        y: {
          if (root.isHorizontal) {
            return root.position === "bottom"
              ? popupRoot.height - root.cardTopGap + Style.space(4) - height
              : popupPanel.topInset + root.cardTopGap - Style.space(4)
          }
          var wantY = dockCard.y + dockCard.hoverX - height / 2
          return Math.max(4, Math.min(wantY, popupRoot.height - height - 4))
        }
        visible: popupPanel.previewVisible && buttons.length > 0
        z: 10
        clip: true

        MouseArea {
          id: previewMa
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton
          cursorShape: Qt.PointingHandCursor
          onEntered: { dockCard.pillHover = true; dockCard.hoverHideTimerStop() }
          onExited: { dockCard.pillHover = false; dockCard.hoverHideTimerRestart() }
        }

        // header: app icon + window title + window buttons
        Item {
          id: previewHeader
          width: previewCard.width
          height: previewCard.headerH

          Rectangle {
            id: headIconBg
            x: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(22)
            height: Style.space(22)
            radius: Style.space(6)
            color: Util.alpha(Color.accent, 0.15)

            Image {
              anchors.fill: parent
              anchors.margins: Style.space(2)
              fillMode: Image.PreserveAspectFit
              smooth: true
              mipmap: true
              source: {
                var ic = String(previewCard.d ? (previewCard.d.icon || "") : "")
                if (!ic) return ""
                if (ic.charAt(0) === "/") return "file://" + ic
                try { var p = Quickshell.iconPath(ic, true); if (p) return p.charAt(0) === "/" ? "file://" + p : p } catch (e) {}
                return "file://" + (Quickshell.env("HOME") || "") + "/.local/share/icons/Papirus/64x64/apps/" + ic + ".svg"
              }
            }
          }

          Text {
            id: previewTitle
            x: headIconBg.x + headIconBg.width + Style.space(8)
            width: parent.width - x - (previewCard.buttons.length * Style.space(24) + Style.space(14)) - Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: previewCard.title
            color: Color.popups.text
            font.family: Style.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Row {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            Repeater {
              model: previewCard.buttons

              delegate: Rectangle {
                id: prevBtn
                required property var modelData
                width: Style.space(24)
                height: Style.space(24)
                radius: Style.space(6)
                color: prevBtnMa.containsMouse ? Util.alpha(Color.accent, 0.25) : "transparent"

                Text {
                  anchors.centerIn: parent
                  text: prevBtn.modelData.l
                  color: Color.popups.text
                  font.family: Style.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  id: prevBtnMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: (mouse) => {
                    mouse.accepted = true
                    var d = previewCard.d
                    if (d === null) return
                    var tls = root.windowsFor(d)
                    var kind = prevBtn.modelData.k
                    if (kind === "min") root.minimizeApp(d)
                    else if (kind === "max") root.maximizeApp(d)
                    else if (kind === "close") root.closeApp(tls)
                    else if (kind === "pin") root.pinApp(d.entry ? d.entry.id : "")
                    dockCard.hoverSlotData = null
                  }
                }
              }
            }
          }
        }

        // body: live snapshot of the window (fallback when unavailable)
        Item {
          x: Style.space(5)
          y: previewCard.headerH + Style.space(4)
          width: previewCard.width - Style.space(10)
          height: previewCard.bodyH

          Rectangle {
            anchors.fill: parent
            radius: Style.space(8)
            color: Util.alpha("#000000", 0.35)
            border.color: Util.alpha(Color.popups.border, 0.3)
            border.width: 1
          }

          Image {
            id: previewShot
            anchors.fill: parent
            anchors.margins: Style.space(1)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            visible: root.previewTarget !== null && status === Image.Ready
            source: root.previewTarget !== null
              ? ("file://" + root.previewPath + "?v=" + root.previewSeq)
              : ""
            smooth: true
          }

          Text {
            anchors.centerIn: parent
            visible: !previewShot.visible
            text: (previewCard.tls && previewCard.tls.length > 1)
              ? previewCard.tls.length + " windows"
              : "window preview"
            color: Util.alpha(Color.popups.text, 0.7)
            font.family: Style.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Rectangle {
            visible: previewCard.tls.length > 1
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(6)
            width: countLabel.implicitWidth + Style.space(10)
            height: Style.space(18)
            radius: Style.space(9)
            color: Util.alpha(Color.popups.background, 0.9)
            Text {
              id: countLabel
              anchors.centerIn: parent
              text: previewCard.tls.length + " windows"
              color: Color.popups.text
              font.family: Style.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }

      // ---- right-click context menu ----
      Rectangle {
        id: ctxMenu

        readonly property var menuRows: {
          var d = dockCard.menuData
          if (d === null) return []
          var tls = root.windowsFor(d)
          var rows = []

          if (tls.length > 0) {
            rows.push({ kind: "minimize", label: "Minimize" })
            var best = null
            for (var i = 0; i < tls.length; i++) {
              var t = tls[i]
              if (t && (t.fullscreen === true || t.maximized === true)) { best = t; break }
            }
            if (best === null) best = tls[0]
            var maxed = false
            try { maxed = (best.fullscreen === true || best.maximized === true) } catch (e) { maxed = false }
            rows.push({ kind: "togglemax", label: maxed ? "Restore" : "Maximize" })
            rows.push({ kind: "sep" })
            for (i = 0; i < tls.length && i < root.menuMaxWindows; i++) {
              var title = String((tls[i] && tls[i].title) || "(untitled)")
              if (title.length > 38) title = title.slice(0, 37) + "…"
              rows.push({ kind: "window", label: title, tl: tls[i] })
            }
            rows.push({ kind: "sep" })
          }

          if (d.isExtra !== true || (d.entry && d.entry.id)) {
            rows.push({ kind: "launch", label: "New Window" })
            rows.push({ kind: "sep" })
          }

          if (tls.length > 0) {
            rows.push({ kind: "close", label: tls.length > 1 ? "Close All" : "Close" })
            rows.push({ kind: "forceclose", label: "Force Close" })
            rows.push({ kind: "sep" })
          }

          if (d.isExtra === true) {
            if (d.entry && d.entry.id) rows.push({ kind: "pin", label: "Pin to Dock" })
          } else {
            rows.push({ kind: "unpin", label: "Unpin from Dock" })
          }
          while (rows.length > 0 && rows[rows.length - 1].kind === "sep") rows.pop()
          return rows
        }

        function doAction(row) {
          var d = dockCard.menuData
          dockCard.menuData = null
          if (d === null || !row) return
          var tls = root.windowsFor(d)
          if (row.kind === "window") {
            if (row.tl && typeof row.tl.activate === "function") row.tl.activate()
          } else if (row.kind === "launch") {
            var id = d.isExtra === true ? (d.entry ? d.entry.id : "") : d.id
            if (id) root.launchApp(String(id), String(d.name || ""))
          } else if (row.kind === "minimize") {
            root.runWindowAction("minimize", tls)
          } else if (row.kind === "togglemax") {
            root.runWindowAction("togglemax", tls)
          } else if (row.kind === "close") {
            root.closeApp(tls)
          } else if (row.kind === "forceclose") {
            root.forceCloseApp(tls)
          } else if (row.kind === "pin") {
            root.pinApp(d.entry ? d.entry.id : "")
          } else if (row.kind === "unpin") {
            root.unpinApp(String(d.id || ""))
          }
        }

        readonly property string longestLabel: {
          var best = ""
          for (var i = 0; i < menuRows.length; i++) {
            var l = String(menuRows[i].label || "")
            if (l.length > best.length) best = l
          }
          return best
        }
        readonly property real rowWidth: Math.max(menuMetrics.width + Style.space(60), Style.space(170))
        readonly property real rowHeight: menuMetrics.height + Style.space(12)

        TextMetrics {
          id: menuMetrics
          font.family: Style.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: ctxMenu.longestLabel
        }

        visible: dockCard.menuData !== null && menuRows.length > 0
        z: 100
        radius: Style.space(8)
        color: Util.alpha(Color.popups.background, 0.98)
        border.color: Util.alpha(Color.popups.border, 0.5)
        border.width: 1
        width: rowWidth
        height: menuCol.implicitHeight + Style.space(8)

        x: {
          if (root.isHorizontal) {
            var want = dockCard.x + dockCard.menuX - width / 2
            var minX = dockCard.x - Style.space(24)
            var maxX = dockCard.x + dockCard.width - width + Style.space(24)
            return Math.max(4, Math.min(want, Math.max(minX, maxX)))
          }
          var cx = root.position === "left"
            ? root.cardTopGap
            : popupRoot.width - root.cardTopGap - width
          return Math.max(4, Math.min(cx, popupRoot.width - width - 4))
        }
        y: {
          if (root.isHorizontal) {
            return root.position === "bottom"
              ? popupRoot.height - root.cardTopGap - height
              : popupPanel.topInset + root.cardTopGap
          }
          var wantY = dockCard.y + dockCard.menuX - height / 2
          return Math.max(4, Math.min(wantY, popupRoot.height - height - 4))
        }

        MouseArea {
          id: menuHover
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
          onEntered: menuCloseTimer.stop()
          onExited: menuCloseTimer.restart()
        }

        Column {
          id: menuCol
          x: Style.space(4)
          y: Style.space(4)

          Repeater {
            model: ctxMenu.menuRows

            delegate: Item {
              id: menuRow
              required property var modelData
              readonly property bool isSep: modelData.kind === "sep"
              readonly property bool isWindowRow: modelData.kind === "window"
              width: ctxMenu.rowWidth
              height: isSep ? Style.space(7) : ctxMenu.rowHeight

              Rectangle {
                visible: isSep
                anchors.centerIn: parent
                width: parent.width - Style.space(8)
                height: 1
                color: Util.alpha(Color.popups.border, 0.4)
              }

              Rectangle {
                visible: !isSep
                anchors.fill: parent
                radius: Style.space(6)
                color: rowMa.containsMouse && !winCloseMa.containsMouse ? Style.hoverFill : "transparent"
              }

              Text {
                id: rowText
                visible: !isSep
                anchors.verticalCenter: parent.verticalCenter
                x: Style.space(14)
                text: isSep ? "" : menuRow.modelData.label
                color: Color.popups.text
                font.family: Style.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                width: parent.width - Style.space(44)
              }

              // full-row activator (declared before the ✕ so the ✕ gets priority)
              MouseArea {
                id: rowMa
                anchors.fill: parent
                visible: !isSep
                enabled: !isSep
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: ctxMenu.doAction(menuRow.modelData)
              }

              // per-window close button (Windows jump-list style)
              MouseArea {
                id: winCloseMa
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(22)
                height: parent.height - Style.space(8)
                visible: isWindowRow
                enabled: isWindowRow
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: (mouse) => {
                  mouse.accepted = true
                  if (menuRow.modelData.tl && typeof menuRow.modelData.tl.close === "function") {
                    menuRow.modelData.tl.close()
                  }
                  dockCard.menuData = null
                }

                Text {
                  anchors.centerIn: parent
                  text: "✕"
                  color: winCloseMa.containsMouse ? Color.accent : Color.popups.text
                  font.family: Style.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  opacity: winCloseMa.containsMouse ? 1.0 : 0.55
                }
              }
            }
          }
        }
      }

      Timer {
        id: menuCloseTimer
        interval: 500
        onTriggered: dockCard.menuData = null
      }

      // hard cap: no popup stays on screen longer than popupTimeoutMs
      Timer {
        id: popupMaxTimer
        interval: Math.max(2000, root.popupTimeoutMs)
        onTriggered: {
          dockCard.hoverSlotData = null
          dockCard.menuData = null
          dockCard.pillHover = false
          dockCard.slotHoverCount = 0
        }
      }

      Connections {
        target: dockCard
        function onMenuDataChanged() {
          if (dockCard.menuData !== null) {
            menuCloseTimer.stop()
            popupMaxTimer.restart()
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ launcher overlay
  // Launchpad-style full-screen app grid with instant search.

  PanelWindow {
    id: launcherPanel
    visible: root.launcherOpen
    screen: root.targetScreen
    anchors.left: true
    anchors.right: true
    anchors.top: true
    anchors.bottom: true
    color: "transparent"
    WlrLayershell.namespace: "omarchy-dock-launcher"
    WlrLayershell.layer: WlrLayer.Overlay
    // Exclusive while open: typing goes straight to the search field
    // (same contract as omarchy's own keyboard panel overlay).
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore
    // Exact screen rect — matches omarchy's working overlay mask pattern.
    mask: Region {
      width: launcherPanel.screen ? launcherPanel.screen.width : 4096
      height: launcherPanel.screen ? launcherPanel.screen.height : 4096
    }

    onVisibleChanged: {
      if (visible) {
        root.launcherQuery = ""
        launcherSearch.text = ""
        launcherSearch.forceActiveFocus()
      } else {
        launcherSearch.focus = false
      }
    }

    // dimmed backdrop: ANY button press outside the card dismisses
    Rectangle {
      anchors.fill: parent
      color: Util.alpha("#000000", 0.42)

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.AllButtons
        onPressed: (mouse) => {
          mouse.accepted = true
          root.launcherOpen = false
        }
      }
    }

    Rectangle {
      id: launcherCard
      width: Math.min(parent.width * 0.62, Style.space(920))
      height: Math.min(parent.height * 0.72, Style.space(640))
      anchors.centerIn: parent
      radius: Style.space(16)
      color: Util.alpha(Color.popups.background, 0.97)
      border.color: Util.alpha(Color.accent, 0.25)
      border.width: 1
      clip: true

      MouseArea { anchors.fill: parent; onClicked: launcherSearch.forceActiveFocus() }

      Column {
        x: Style.space(20)
        y: Style.space(16)
        width: parent.width - Style.space(40)
        spacing: Style.space(12)

        // search row
        Rectangle {
          width: parent.width
          height: Style.space(42)
          radius: Style.space(10)
          color: Util.alpha(Color.popups.border, 0.25)
          border.color: launcherSearch.activeFocus ? Util.alpha(Color.accent, 0.6) : Util.alpha(Color.popups.border, 0.3)
          border.width: 1

          Text {
            x: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            visible: launcherSearch.text.length === 0
            text: "Search apps…"
            color: Util.alpha(Color.popups.text, 0.5)
            font.family: Style.fontFamily
            font.pixelSize: Style.font.body
          }

          TextInput {
            id: launcherSearch
            x: Style.space(14)
            width: parent.width - Style.space(28)
            anchors.verticalCenter: parent.verticalCenter
            color: Color.popups.text
            font.family: Style.fontFamily
            font.pixelSize: Style.font.body
            clip: true
            cursorVisible: activeFocus
            onTextChanged: root.launcherQuery = text
            Keys.onEscapePressed: root.launcherOpen = false
            Keys.onReturnPressed: root.launchFromLauncher(root.launcherFiltered[0])
            Keys.onEnterPressed: root.launchFromLauncher(root.launcherFiltered[0])
          }
        }

        // app grid
        Flickable {
          width: parent.width
          height: launcherCard.height - Style.space(16) - Style.space(42) - Style.space(12)
          clip: true
          contentWidth: width
          contentHeight: launcherGrid.implicitHeight + Style.space(20)
          boundsBehavior: Flickable.StopAtBounds

          Grid {
            id: launcherGrid
            width: parent.width
            columns: Math.max(3, Math.floor(width / Style.space(112)))
            spacing: Style.space(6)

            Repeater {
              model: root.launcherFiltered

              delegate: Item {
                id: appTile
                required property var modelData
                required property int index
                readonly property bool lastCol: (index + 1) % launcherGrid.columns === 0
                width: launcherGrid.width / launcherGrid.columns - launcherGrid.spacing
                  + (lastCol ? launcherGrid.spacing : 0)
                height: Style.space(96)

                Rectangle {
                  id: tileBg
                  anchors.fill: parent
                  radius: Style.space(10)
                  color: tileMa.containsMouse ? Util.alpha(Color.accent, 0.18) : "transparent"
                }

                // centered content block — explicit height so vertical centering
                // is exact math (a plain Column+anchors mis-centers here)
                Item {
                  id: tileContent
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width
                  height: Style.space(48) + Style.space(7) + tileLabel.implicitHeight

                  Item {
                    id: iconBox
                    width: Style.space(48)
                    height: Style.space(48)
                    anchors.top: parent.top
                    anchors.horizontalCenter: parent.horizontalCenter

                    Image {
                      id: tileIcon
                      anchors.fill: parent
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                      sourceSize.width: 128
                      sourceSize.height: 128
                      smooth: true
                      mipmap: true

                      readonly property string themedPath: {
                        var ic = String(appTile.modelData.icon || "")
                        if (!ic) return ""
                        if (ic.charAt(0) === "/") return "file://" + ic
                        try { var p = Quickshell.iconPath(ic, true); if (p) return p.charAt(0) === "/" ? "file://" + p : p } catch (e) {}
                        return root.appLibrary ? root.appLibrary.iconSource(ic) : ""
                      }
                      readonly property string genericPath: {
                        try { var p = Quickshell.iconPath("application-x-executable", true); if (p) return p.charAt(0) === "/" ? "file://" + p : p } catch (e) {}
                        return "file://" + (Quickshell.env("HOME") || "") + "/.local/share/icons/Papirus/64x64/apps/application-default-icon.svg"
                      }
                      readonly property var candidates: {
                        var ic = String(appTile.modelData.icon || "")
                        var out = []
                        if (themedPath) out.push(themedPath)
                        if (ic.length > 0) {
                          out.push("file://" + (Quickshell.env("HOME") || "") + "/.local/share/icons/Papirus/64x64/apps/" + ic + ".svg")
                          out.push("file://" + (Quickshell.env("HOME") || "") + "/.local/share/icons/Papirus/64x64/apps/" + ic + ".png")
                          out.push("file://" + (Quickshell.env("HOME") || "") + "/.local/share/icons/hicolor/512x512/apps/" + ic + ".png")
                        }
                        out.push(genericPath)
                        return out
                      }
                      property int stage: 0
                      onCandidatesChanged: stage = 0
                      source: candidates[Math.min(stage, candidates.length - 1)]
                      onStatusChanged: { if (status === Image.Error && stage < candidates.length - 1) stage += 1 }
                    }
                  }

                  Text {
                    id: tileLabel
                    width: appTile.width - Style.space(8)
                    anchors.top: iconBox.bottom
                    anchors.topMargin: Style.space(7)
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: appTile.modelData.name
                    color: Color.popups.text
                    font.family: Style.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter
                  }
                }

                MouseArea {
                  id: tileMa
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.launchFromLauncher(appTile.modelData)
                }
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ autohide reveal strip
  // Thin input-only strip at the dock edge; touching it reveals the dock.

  PanelWindow {
    id: revealStrip
    visible: root.autohide
    screen: root.targetScreen
    anchors.bottom: root.position === "bottom" || root.isSide
    anchors.top: root.position === "top" || root.isSide
    anchors.left: root.position === "left" || root.isHorizontal
    anchors.right: root.position === "right" || root.isHorizontal
    implicitWidth: root.isHorizontal ? 0 : Style.space(4)
    implicitHeight: root.isHorizontal ? Style.space(4) : 0
    color: "transparent"
    WlrLayershell.namespace: "omarchy-dock-reveal"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region { x: 0; y: 0; width: 4096; height: 4096 }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      cursorShape: Qt.ArrowCursor
      onContainsMouseChanged: {
        if (containsMouse) {
          root.revealed = true
          revealTimer.stop()
        } else {
          revealTimer.restart()
        }
      }
    }
  }

  property bool revealed: false

  onRevealedChanged: {
    if (!revealed) {
      dockCard.hoverSlotData = null
      dockCard.menuData = null
      dockCard.pillHover = false
      dockCard.slotHoverCount = 0
    }
  }

  Timer {
    id: revealTimer
    interval: 800
    onTriggered: {
      if (dockCard.slotHoverCount <= 0 && !dockCard.pillHover && dockCard.menuData === null)
        root.revealed = false
    }
  }

  Connections {
    target: dockCard
    function onMenuDataChanged() {
      if (dockCard.menuData !== null) root.revealed = true
    }
    function onHoverSlotDataChanged() {
      if (dockCard.hoverSlotData !== null) root.revealed = true
    }
  }
}