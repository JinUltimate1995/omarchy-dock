import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Apple-style floating dock. Mounted at startup (kind: "panel",
// keepLoaded: true) and stays visible permanently — there is no
// open/close cycle like OSD or the menu, it just sits at the bottom of
// the screen.
//
// Pinned apps live in pinned.json next to this file (hand-edited, see
// README.md), not in shell.json — a list of up to 20 desktop-entry IDs is
// awkward to carry as bar-style inline settings, and a dedicated file is
// easier to hand-edit / diff / back up.
Item {
  id: root

  // Injected by omarchy-shell when this panel plugin is mounted.
  property var shell: null
  property string omarchyPath: ""

  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

  // ------------------------------------------------------------ pinned apps

  // Pin state lives OUTSIDE the plugin directory on purpose: the shell's
  // plugin registry watches ~/.config/omarchy/plugins/<id>/ and reloads the
  // whole plugin when anything in it changes — writing pinned.json in there
  // from the right-click menu would tear the dock down mid-click. The
  // legacy in-plugin pinned.json is still read as a fallback seed, so
  // existing setups keep their pins; the first pin/unpin from the dock
  // writes the new file and it takes over from then on.
  readonly property string pinnedPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/dino.dock.pinned.json"
  readonly property string legacyPinnedPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/dino.dock/pinned.json"
  readonly property int maxPinned: 20

  property var pinnedIds: []    // ordered list of desktop-entry ids
  property var entryIndex: ({}) // desktop-entry id -> DesktopEntries entry object

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
      } catch (e) {
        console.warn("dino.dock: pinned.json parse failed:", e)
      }
    }
    if (ids.length > root.maxPinned) {
      console.warn("dino.dock: " + ids.length + " pinned apps configured, showing the first " + root.maxPinned)
      ids = ids.slice(0, root.maxPinned)
    }
    root.pinnedIds = ids
  }

  // New file wins whenever it has content; the legacy file only seeds an
  // installation that has never written the new one.
  property string pinnedRaw: ""
  property string legacyPinnedRaw: ""
  function applyPinned() {
    root.loadPinned(root.pinnedRaw.trim().length > 0 ? root.pinnedRaw : root.legacyPinnedRaw)
  }

  FileView {
    id: pinnedFile
    path: root.pinnedPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: { root.pinnedRaw = text(); root.applyPinned() }
    onFileChanged: reload()
    onLoadFailed: { root.pinnedRaw = ""; root.applyPinned() }
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

  // Pin management from the dock itself (right-click menu). Writes go to
  // the same pinned.json a user could hand-edit — the FileView watch then
  // reloads it, so the dock, the file, and any open editor all agree.
  function writePinned(ids) {
    root.pinnedIds = ids // optimistic; the file watch confirms it
    var text = JSON.stringify(ids, null, 2) + "\n"
    root.pinnedRaw = text // the new file now owns the state
    try {
      pinnedFile.setText(text)
    } catch (e) {
      console.warn("dino.dock: pinned.json write failed:", e)
    }
  }

  function pinApp(entryId) {
    var id = String(entryId || "").trim()
    if (id.length === 0 || root.pinnedIds.indexOf(id) !== -1) return
    if (root.pinnedIds.length >= root.maxPinned) {
      console.warn("dino.dock: pin cap (" + root.maxPinned + ") reached, not pinning " + id)
      return
    }
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
      var e = values[i]
      if (e && e.id) idx[String(e.id)] = e
    }
    root.entryIndex = idx
  }

  Connections {
    target: (typeof DesktopEntries !== "undefined") ? DesktopEntries.applications : null
    function onValuesChanged() { root.rebuildEntryIndex() }
  }

  // {id, entry, name, icon} per pinned slot, resolved against whatever
  // desktop entries currently exist. An id with no matching entry still
  // renders (fallback icon, id as its label) rather than silently vanishing,
  // so a typo in pinned.json is visible instead of just missing.
  readonly property var resolvedPins: {
    var out = []
    for (var i = 0; i < root.pinnedIds.length; i++) {
      var id = root.pinnedIds[i]
      var entry = root.entryIndex[id] || null
      out.push({
        id: id,
        entry: entry,
        name: entry ? String(entry.name || id) : id,
        icon: entry ? entry.icon : id
      })
    }
    return out
  }

  // ------------------------------------------------------------ running apps

  // Lowercased Wayland app_id -> [toplevels]. Heuristic matching (see
  // README): Wayland gives no reliable app_id <-> .desktop-id mapping, so
  // this is a best-effort match, not a guarantee.
  property var runningAppIds: ({})

  function rebuildRunning() {
    var map = {}
    try {
      var values = ToplevelManager.toplevels.values
      for (var i = 0; i < values.length; i++) {
        var t = values[i]
        var key = String((t && t.appId) || "").toLowerCase()
        if (key.length === 0) continue
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

  // The app_id key a pin's running windows live under, or "" if none.
  function runningKeyFor(pin) {
    var needle1 = String(pin.id || "").toLowerCase()
    var needle2 = pin.name ? String(pin.name).toLowerCase() : ""
    for (var key in root.runningAppIds) {
      if (key === needle1) return key
      if (needle1.length > 0 && (key.indexOf(needle1) !== -1 || needle1.indexOf(key) !== -1)) return key
      if (needle2.length > 0 && key.indexOf(needle2) !== -1) return key
    }
    return ""
  }

  function toplevelsFor(pin) {
    var key = root.runningKeyFor(pin)
    return key.length > 0 ? root.runningAppIds[key] : null
  }

  // Click on a running app: focus its window. Clicked again while one of
  // its windows is already focused: cycle to its next window — that plus
  // activate() switching workspaces is what makes the dock a mouse-only
  // way to move between open programs, macOS style.
  function focusNext(toplevels) {
    if (!toplevels || toplevels.length === 0) return
    var active = -1
    for (var i = 0; i < toplevels.length; i++) {
      if (toplevels[i] && toplevels[i].activated === true) { active = i; break }
    }
    var next = toplevels[(active + 1) % toplevels.length]
    if (next && typeof next.activate === "function") next.activate()
  }

  function launchOrFocus(pin, toplevels) {
    if (toplevels && toplevels.length > 0) {
      root.focusNext(toplevels)
    } else if (!pin.isExtra && root.appLibrary) {
      root.appLibrary.launch(pin.id, pin.name)
    }
  }

  // Best-effort desktop entry for a bare Wayland app_id (exact id first,
  // then case-insensitive, then substring either way) — same spirit as
  // runningKeyFor, in the other direction.
  function entryForAppId(appId) {
    var idx = root.entryIndex
    if (idx[appId]) return idx[appId]
    var lower = String(appId).toLowerCase()
    var keys = Object.keys(idx)
    for (var i = 0; i < keys.length; i++) {
      if (keys[i].toLowerCase() === lower) return idx[keys[i]]
    }
    for (i = 0; i < keys.length; i++) {
      var k = keys[i].toLowerCase()
      if (k.indexOf(lower) !== -1 || lower.indexOf(k) !== -1) return idx[keys[i]]
    }
    return null
  }

  // Running apps that resolve to no pinned slot. They render to the right
  // of a divider, macOS style, so every open program is clickable from the
  // dock even when it was launched elsewhere. Sorted by app_id so the row
  // doesn't reshuffle every time focus moves.
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
        isExtra: true,
        key: keys[i],
        id: appId,
        entry: entry,
        name: entry ? String(entry.name || appId) : ((tls[0] && tls[0].title) ? String(tls[0].title) : appId),
        icon: (entry && entry.icon) ? entry.icon : appId
      })
    }
    return out
  }

  // Pinned apps, then a separator, then running unpinned apps — the whole
  // row the dock renders.
  readonly property var dockModel: {
    var out = root.resolvedPins.slice()
    if (root.runningExtras.length > 0) {
      out.push({ isSeparator: true })
      out = out.concat(root.runningExtras)
    }
    return out
  }

  Component.onCompleted: {
    root.rebuildEntryIndex()
    root.rebuildRunning()
    if (root.appLibrary) root.appLibrary.refreshIcons()
  }

  // ------------------------------------------------------------ target monitor

  // Optional: pin the dock to one specific monitor instead of whichever
  // screen Quickshell enumerates first. Useful on multi-monitor rigs where
  // a docking station renumbers connector names (DP-5 vs DP-6) across
  // reboots — matching by manufacturer/model substring survives that,
  // matching by connector name alone doesn't.
  //
  // Config in monitor.json next to this file, a single JSON string with
  // any substring of the target's manufacturer/model/connector name,
  // case-insensitive (e.g. "Odyssey G50F", or just "DP-2"). Absent or
  // empty file = no preference, use the first enumerated screen.
  readonly property string monitorPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/dino.dock/monitor.json"
  property string monitorMatch: ""

  function loadMonitorMatch(rawText) {
    var text = String(rawText || "").trim()
    if (text.length === 0) { root.monitorMatch = ""; return }
    try {
      var parsed = JSON.parse(text)
      root.monitorMatch = String(parsed || "").trim().toLowerCase()
    } catch (e) {
      // Forgive a plain unquoted string too — less to get wrong by hand.
      root.monitorMatch = text.toLowerCase()
    }
  }

  FileView {
    id: monitorFile
    path: root.monitorPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadMonitorMatch(text())
    onFileChanged: reload()
    onLoadFailed: root.loadMonitorMatch("")
  }

  function screenMatches(screen) {
    if (!screen || root.monitorMatch.length === 0) return false
    var haystack = (String(screen.manufacturer || "") + " " + String(screen.model || "") + " " + String(screen.name || "")).toLowerCase()
    return haystack.indexOf(root.monitorMatch) !== -1
  }

  readonly property var targetScreen: {
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++) {
      if (root.screenMatches(screens[i])) return screens[i]
    }
    // No match configured, or the configured monitor isn't plugged in
    // right now — fall back to something rather than rendering nowhere.
    return screens.length > 0 ? screens[0] : null
  }

  // ------------------------------------------------------------ the dock UI

  PanelWindow {
    id: panel
    visible: true
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-dock"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Only the dock card (plus the context menu when open) accepts input;
    // the rest of this full-screen surface stays click-through so it never
    // blocks the desktop underneath, exactly like the notifications/OSD
    // overlays. A long window-list menu can extend above dockCard's
    // bounds, so the mask is a computed rect that grows upward with it —
    // one flat region, no nested-Region semantics to trip over.
    readonly property int maskTopOverflow: contextMenu.visible ? Math.max(0, -contextMenu.y) : 0
    mask: Region {
      x: dockCard.x
      y: dockCard.y - panel.maskTopOverflow
      width: dockCard.width
      height: dockCard.height + panel.maskTopOverflow
    }

    readonly property real screenWidth: panel.screen ? panel.screen.width : 1920

    Item {
      id: dockCard
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Math.max(Style.space(10), Style.gapsOut)
      width: cardWidth
      height: cardHeight + headroom

      readonly property int maxIconSize: Style.space(50)
      readonly property int minIconSize: Style.space(32)
      readonly property int iconGap: Style.space(10)
      // Wide enough that the endmost icons clear the capsule's curved ends.
      readonly property int padX: Style.space(24)
      readonly property int padY: Style.space(8)
      readonly property bool hasSeparator: root.runningExtras.length > 0
      readonly property int sepWidth: Style.space(2)
      // Icon slots (pins + running extras); the separator is its own thin
      // slot that takes sepWidth instead of iconSize.
      readonly property int iconCount: Math.max(1, root.dockModel.length - (hasSeparator ? 1 : 0))
      readonly property int slotCount: iconCount + (hasSeparator ? 1 : 0)
      readonly property real availableWidth: panel.screenWidth * 0.86

      // Grow wider up to ~86% of screen width; past that, shrink icons to
      // fit — the same trade-off the real macOS dock makes.
      readonly property int fixedWidth: (slotCount - 1) * iconGap + (hasSeparator ? sepWidth : 0) + padX * 2
      readonly property int naturalWidth: iconCount * maxIconSize + fixedWidth
      readonly property int iconSize: naturalWidth <= availableWidth
        ? maxIconSize
        : Math.max(minIconSize, Math.floor((availableWidth - fixedWidth) / iconCount))

      readonly property int cardWidth: root.dockModel.length > 0
        ? (iconSize * iconCount + fixedWidth)
        : (maxIconSize + padX * 2)
      readonly property int cardHeight: iconSize + padY * 2
      // Extra vertical room above the pill so magnified/bouncing icons have
      // somewhere to rise into — and so the click-mask (sized to this whole
      // item) still covers them while they're up there.
      readonly property int headroom: Math.round(iconSize * (magStrength + 0.35))

      // ---- right-click pin menu ----
      property var menuData: null // modelData of the icon the menu is open for
      property real menuX: 0

      // ---- drag-to-reorder (pins only) ----
      property int dragIndex: -1       // dockModel index of the pin being dragged
      property int dragTargetIndex: -1 // insertion point among pins [0..pinCount]

      function insertionIndexAt(xInCard) {
        var rel = xInCard - iconRow.x
        var idx = Math.round(rel / (iconSize + iconGap))
        return Math.max(0, Math.min(root.resolvedPins.length, idx))
      }

      function finishDrag() {
        var from = dragIndex
        var to = dragTargetIndex
        dragIndex = -1
        dragTargetIndex = -1
        if (from < 0 || to < 0 || from >= root.pinnedIds.length) return
        var insertAt = to > from ? to - 1 : to
        if (insertAt === from) return
        var ids = root.pinnedIds.slice()
        var moved = ids.splice(from, 1)[0]
        ids.splice(insertAt, 0, moved)
        root.writePinned(ids)
      }

      // ---- hover magnification ----
      property real hoverX: -100000
      readonly property real magRadius: iconSize * 2.1
      readonly property real magStrength: 0.85

      function scaleFor(centerX) {
        if (dockCard.hoverX < -99999) return 1.0
        var d = Math.abs(centerX - dockCard.hoverX)
        if (d >= dockCard.magRadius) return 1.0
        var t = 1 - d / dockCard.magRadius
        return 1.0 + dockCard.magStrength * t * t
      }

      BorderSurface {
        id: cardBg
        width: dockCard.cardWidth
        height: dockCard.cardHeight
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        // Full capsule + near-opaque fill + 1px low-alpha hairline. The old
        // theme-driven look (small radius, 2px accent border, 0.92 alpha)
        // read as a boxy web panel: window edges behind bled through the
        // translucency as seams, and the bright border boxed it in. macOS
        // docks are a soft capsule with a border you barely register.
        radius: Math.round(height / 2)
        borderSpec: Border.flat(Util.alpha(Color.popups.border, 0.35), 1)
        // Vertical glass sheen: catches light at the top, settles darker at
        // the base. Derived from the theme background so it follows theme
        // switches instead of hardcoding a palette.
        gradient: Gradient {
          GradientStop { position: 0.0; color: Util.alpha(Qt.lighter(Color.popups.background, 2.1), 0.97) }
          GradientStop { position: 0.45; color: Util.alpha(Color.popups.background, 0.97) }
          GradientStop { position: 1.0; color: Util.alpha(Qt.darker(Color.popups.background, 1.5), 0.98) }
        }

        // Additive white sheen over the top half — the base color is dark
        // enough that lightening it multiplicatively (above) barely reads,
        // so the actual "glass" cue comes from this overlay, same as the
        // aqua-era gloss trick.
        Rectangle {
          anchors.fill: parent
          radius: parent.radius
          gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.16) }
            GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.02) }
            GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.0) }
          }
        }
      }

      MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onPositionChanged: dockCard.hoverX = mouseX
        onExited: {
          dockCard.hoverX = -100000
          menuCloseTimer.restart()
        }
      }

      Row {
        id: iconRow
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        spacing: dockCard.iconGap

        Repeater {
          model: root.dockModel

          delegate: Item {
            id: slot
            required property var modelData
            required property int index
            readonly property bool isSep: slot.modelData.isSeparator === true
            width: slot.isSep ? dockCard.sepWidth : dockCard.iconSize
            height: dockCard.height

            readonly property real slotCenterX: iconRow.x + slot.x + width / 2
            readonly property real targetScale: slot.isSep ? 1.0 : dockCard.scaleFor(slotCenterX)
            property bool hovered: false
            readonly property var runningToplevels: slot.isSep ? null
              : (slot.modelData.isExtra === true
                  ? (root.runningAppIds[slot.modelData.key] || null)
                  : root.toplevelsFor(slot.modelData))
            readonly property bool isRunning: slot.runningToplevels !== null && slot.runningToplevels.length > 0

            // The pins/running divider — a soft hairline like macOS's.
            Rectangle {
              visible: slot.isSep
              width: dockCard.sepWidth
              height: dockCard.iconSize * 0.72
              radius: width / 2
              color: Util.alpha(Color.popups.border, 0.45)
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              anchors.bottomMargin: dockCard.padY + (dockCard.iconSize - height) / 2
            }

            Rectangle {
              id: dot
              visible: slot.isRunning
              width: Style.space(5)
              height: Style.space(5)
              radius: width / 2
              color: Color.accent
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(3)
            }

            Rectangle {
              id: tile
              visible: !slot.isSep
              width: slot.isSep ? 0 : dockCard.iconSize
              height: dockCard.iconSize
              radius: Style.space(12)
              color: slot.hovered ? Style.hoverFill : "transparent"
              anchors.horizontalCenter: parent.horizontalCenter
              // Anchored to the pill's own bottom (padY in from the edge),
              // not to the running-indicator dot below it — dot is a
              // separate overlay, and anchoring the icon to it always
              // reserved dot-height + extra padding beneath the icon with
              // nothing matching above it, pushing every icon off-center
              // upward regardless of whether that pin was even running.
              anchors.bottom: parent.bottom
              anchors.bottomMargin: dockCard.padY + tile.bounceOffset
              transformOrigin: Item.Bottom
              scale: slot.targetScale
              opacity: dockCard.dragIndex === slot.index ? 0.35 : 1.0

              property real bounceOffset: 0

              Behavior on scale {
                SpringAnimation { spring: 3.2; damping: 0.28 }
              }

              SequentialAnimation {
                id: bounceAnim
                NumberAnimation { target: tile; property: "bounceOffset"; to: dockCard.iconSize * 0.45; duration: 160; easing.type: Easing.OutQuad }
                NumberAnimation { target: tile; property: "bounceOffset"; to: 0; duration: 260; easing.type: Easing.OutBounce }
                NumberAnimation { target: tile; property: "bounceOffset"; to: dockCard.iconSize * 0.22; duration: 130; easing.type: Easing.OutQuad }
                NumberAnimation { target: tile; property: "bounceOffset"; to: 0; duration: 220; easing.type: Easing.OutBounce }
              }

              // Icons come from a mix of icon themes: some ship as
              // transparent art (Chromium, Neovim, Obsidian) that sits
              // cleanly on the dock, others bake in an opaque square
              // background (foot, btop, OBS, generic fallbacks) that reads
              // as a mismatched tile next to the rest. Clipping every icon
              // to one consistent rounded silhouette (same family as the
              // tile's own radius) makes the row read as one shape
              // language instead of a patchwork grid — a no-op for icons
              // that are already transparent, a real fix for the ones that
              // aren't.
              Image {
                id: icon
                anchors.fill: parent
                anchors.margins: Style.space(4)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                visible: false
                layer.enabled: true

                // Whatever icon theme resolves an app's default icon varies
                // wildly in polish — some ship clean art (Chromium, Neovim),
                // others fall back to a plain glyph on a flat square (foot,
                // the old btop/localsend renders). Papirus is a curated,
                // near-universal pack with consistently-styled art for
                // almost everything here, so prefer it explicitly and only
                // fall back to the normal themed lookup for the rare pin it
                // doesn't cover (e.g. omacalc, an Omarchy-only app).
                readonly property string papirusPath: "file:///usr/share/icons/Papirus/64x64/apps/" + (slot.modelData.icon || "") + ".svg"
                // Resolve through Qt's icon theme engine (Quickshell.iconPath
                // is synchronous — no appLibrary refresh race), with
                // appLibrary as a further fallback for anything exotic.
                readonly property string themedPath: {
                  var ic = String(slot.modelData.icon || "")
                  if (ic.length === 0) return ""
                  if (ic.charAt(0) === "/") return "file://" + ic
                  try {
                    var p = Quickshell.iconPath(ic, true)
                    if (p && p.length > 0) return p.charAt(0) === "/" ? "file://" + p : p
                  } catch (e) {}
                  return root.appLibrary ? root.appLibrary.iconSource(ic) : ""
                }
                // Last resort for running apps whose app_id resolves to no
                // usable icon anywhere (e.g. bare agent/terminal wrappers):
                // a generic app tile beats an invisible one.
                readonly property string genericPath: "file:///usr/share/icons/Papirus/64x64/apps/application-default-icon.svg"

                source: icon.papirusPath
                onStatusChanged: {
                  if (status !== Image.Error) return
                  var s = source.toString()
                  if (s === icon.papirusPath && icon.themedPath.length > 0 && icon.themedPath !== s) {
                    source = icon.themedPath
                  } else if (s !== icon.genericPath) {
                    source = icon.genericPath
                  }
                }
              }

              Rectangle {
                id: iconMask
                anchors.fill: icon
                radius: Style.space(9)
                visible: false
                layer.enabled: true
              }

              MultiEffect {
                anchors.fill: icon
                source: icon
                maskEnabled: true
                maskSource: iconMask
                maskThresholdMin: 0.5
                maskSpreadAtMin: 0.05
              }
            }

            MouseArea {
              id: slotMa
              anchors.fill: tile
              visible: !slot.isSep
              enabled: !slot.isSep
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              cursorShape: Qt.PointingHandCursor
              onEntered: slot.hovered = true
              onExited: slot.hovered = false

              // Drag-to-reorder: pins only. A left-press that travels more
              // than half an icon horizontally becomes a drag; release
              // commits the new order through the same writePinned path the
              // menu uses.
              readonly property bool draggable: !slot.isSep && slot.modelData.isExtra !== true
              property real pressX: 0
              property bool didDrag: false

              onPressed: mouse => {
                if (mouse.button === Qt.LeftButton) {
                  pressX = mouse.x
                  didDrag = false
                }
              }
              onPositionChanged: mouse => {
                if (!pressed || !draggable) return
                if (!didDrag && Math.abs(mouse.x - pressX) > dockCard.iconSize * 0.5) {
                  didDrag = true
                  dockCard.menuData = null
                  dockCard.dragIndex = slot.index
                }
                if (didDrag) {
                  dockCard.dragTargetIndex = dockCard.insertionIndexAt(iconRow.x + slot.x + mouse.x)
                }
              }
              onReleased: {
                if (didDrag) dockCard.finishDrag()
              }
              onClicked: mouse => {
                if (didDrag) {
                  didDrag = false
                  return
                }
                if (mouse.button === Qt.RightButton) {
                  // Toggle the menu for this icon.
                  if (dockCard.menuData === slot.modelData) {
                    dockCard.menuData = null
                  } else {
                    dockCard.menuX = slot.slotCenterX
                    dockCard.menuData = slot.modelData
                  }
                  return
                }
                dockCard.menuData = null
                // Bounce is a "launching" cue — focusing an already-running
                // window just switches to it, no theatrics (macOS again).
                if (!slot.isRunning) bounceAnim.start()
                root.launchOrFocus(slot.modelData, slot.runningToplevels)
              }
            }

            Rectangle {
              id: tooltip
              visible: opacity > 0
              // Suppressed while the pin menu is up — they occupy the same
              // spot above the icon.
              opacity: (slot.hovered && dockCard.menuData === null) ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: 120 } }
              radius: Style.space(6)
              color: Util.alpha(Color.tooltip.background, 0.95)
              width: tooltipLabel.implicitWidth + Style.space(16)
              height: tooltipLabel.implicitHeight + Style.space(8)
              anchors.horizontalCenter: tile.horizontalCenter
              anchors.bottom: tile.top
              anchors.bottomMargin: Style.space(10) + dockCard.iconSize * (slot.targetScale - 1)

              Text {
                id: tooltipLabel
                anchors.centerIn: parent
                text: slot.modelData.name || ""
                color: Color.tooltip.text
                font.family: Style.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }
      }

      // ---- right-click menu ----
      //
      // Per-icon context menu: New Window, a jump list of the app's open
      // windows (click one to focus it, wherever it lives), Quit (closes
      // every window via the same foreign-toplevel protocol activate()
      // uses), and Pin/Unpin. Can extend above dockCard's bounds, so the
      // panel's input mask unions it in explicitly. Closes on action, on
      // left-click of any icon, on right-click toggle, or shortly after
      // the pointer leaves both the dock and the menu.
      Rectangle {
        id: contextMenu

        readonly property var menuRows: {
          var d = dockCard.menuData
          if (d === null) return []
          var rows = []
          var tls = (d.isExtra === true)
            ? (root.runningAppIds[d.key] || [])
            : (root.toplevelsFor(d) || [])
          var canLaunch = d.isExtra !== true || (d.entry !== null && d.entry !== undefined)
          if (canLaunch) rows.push({ kind: "launch", label: "New Window" })
          if (tls.length > 0) {
            if (rows.length > 0) rows.push({ kind: "sep" })
            for (var i = 0; i < tls.length && i < 8; i++) {
              var title = String((tls[i] && tls[i].title) || "(untitled)")
              if (title.length > 42) title = title.slice(0, 41) + "…"
              rows.push({ kind: "window", label: title, tl: tls[i] })
            }
            rows.push({ kind: "sep" })
            rows.push({ kind: "quit",
                        label: tls.length > 1 ? "Quit (" + tls.length + " windows)" : "Quit" })
          }
          if (d.isExtra === true) {
            if (d.entry && d.entry.id) rows.push({ kind: "pin", label: "Pin to Dock" })
          } else {
            rows.push({ kind: "unpin", label: "Unpin from Dock" })
          }
          return rows
        }

        function doAction(row) {
          var d = dockCard.menuData
          dockCard.menuData = null
          if (d === null || !row) return
          if (row.kind === "window") {
            if (row.tl && typeof row.tl.activate === "function") row.tl.activate()
          } else if (row.kind === "launch") {
            var id = d.isExtra === true ? (d.entry ? d.entry.id : "") : d.id
            if (id && root.appLibrary) root.appLibrary.launch(String(id), String(d.name || ""))
          } else if (row.kind === "quit") {
            var tls = (d.isExtra === true)
              ? (root.runningAppIds[d.key] || [])
              : (root.toplevelsFor(d) || [])
            for (var i = 0; i < tls.length; i++) {
              if (tls[i] && typeof tls[i].close === "function") tls[i].close()
            }
          } else if (row.kind === "pin") {
            root.pinApp(d.entry ? d.entry.id : "")
          } else if (row.kind === "unpin") {
            root.unpinApp(String(d.id || ""))
          }
        }

        // Row sizing comes from measuring the longest label, NOT from the
        // Column's implicit size: rows binding their width to the column
        // while the column derives its size from the rows is a stable
        // 0x0 deadlock (both start at zero and agree forever).
        readonly property string longestLabel: {
          var best = ""
          for (var i = 0; i < menuRows.length; i++) {
            var l = String(menuRows[i].label || "")
            if (l.length > best.length) best = l
          }
          return best
        }
        readonly property real rowWidth: menuMetrics.width + Style.space(28)
        readonly property real rowHeight: menuMetrics.height + Style.space(12)

        TextMetrics {
          id: menuMetrics
          font.family: Style.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: contextMenu.longestLabel
        }

        visible: dockCard.menuData !== null && menuRows.length > 0
        z: 100
        radius: Style.space(8)
        color: Util.alpha(Color.popups.background, 0.98)
        border.color: Util.alpha(Color.popups.border, 0.5)
        border.width: 1
        width: rowWidth + Style.space(8)
        height: menuCol.implicitHeight + Style.space(8)
        x: Math.max(0, Math.min(dockCard.menuX - width / 2, dockCard.width - width))
        y: dockCard.height - dockCard.cardHeight - height - Style.space(8)

        MouseArea {
          id: menuHover
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
          onExited: menuCloseTimer.restart()
        }

        Column {
          id: menuCol
          x: Style.space(4)
          y: Style.space(4)

          Repeater {
            model: contextMenu.menuRows

            delegate: Item {
              id: menuRow
              required property var modelData
              readonly property bool isSep: modelData.kind === "sep"
              width: contextMenu.rowWidth
              height: isSep ? Style.space(7) : contextMenu.rowHeight

              Rectangle {
                visible: menuRow.isSep
                anchors.centerIn: parent
                width: parent.width - Style.space(8)
                height: 1
                color: Util.alpha(Color.popups.border, 0.4)
              }

              Rectangle {
                visible: !menuRow.isSep
                anchors.fill: parent
                radius: Style.space(6)
                color: rowMa.containsMouse ? Style.hoverFill : "transparent"
              }

              Text {
                id: rowText
                visible: !menuRow.isSep
                anchors.verticalCenter: parent.verticalCenter
                x: Style.space(14)
                text: menuRow.isSep ? "" : menuRow.modelData.label
                color: Color.popups.text
                font.family: Style.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                id: rowMa
                anchors.fill: parent
                visible: !menuRow.isSep
                enabled: !menuRow.isSep
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: contextMenu.doAction(menuRow.modelData)
              }
            }
          }
        }
      }

      // Insertion indicator while dragging a pin.
      Rectangle {
        visible: dockCard.dragTargetIndex >= 0
        width: Style.space(3)
        height: dockCard.iconSize
        radius: width / 2
        color: Color.accent
        z: 50
        x: iconRow.x + dockCard.dragTargetIndex * (dockCard.iconSize + dockCard.iconGap)
           - dockCard.iconGap / 2 - width / 2
        y: dockCard.height - dockCard.cardHeight + dockCard.padY
      }

      // Grace period so the pointer can travel dock -> menu without the
      // menu vanishing mid-flight.
      Timer {
        id: menuCloseTimer
        interval: 300
        onTriggered: {
          if (!hoverArea.containsMouse && !menuHover.containsMouse) dockCard.menuData = null
        }
      }
    }
  }
}
