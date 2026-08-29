# Floating Dock

An Apple-style floating dock for [Omarchy](https://omarchy.org): pinned
launchers along the bottom of the screen, every running app shown to the
right of a divider (click any of them to jump to that window, across
workspaces), hover magnification, a launch bounce, running-app
indicators, and a glassy capsule look. Built as a
native `omarchy-shell` plugin (same tech as the bar/OSD), so it's themed
automatically and survives theme switches.

![Floating Dock](screenshot.jpg)

## Install

```bash
omarchy plugin add https://github.com/randomchaos7800-hub/omarchy-apple-dock.git --enable
```

Or manually:

```bash
git clone https://github.com/randomchaos7800-hub/omarchy-apple-dock.git ~/.config/omarchy/plugins/dino.dock
omarchy plugin enable dino.dock
```

> Plugins run as arbitrary, unsandboxed code inside your long-lived
> `omarchy-shell` process. Read `Dock.qml` before enabling anything you
> didn't write yourself — this one included.

## Configuring pinned apps

**Right-click any dock icon.** A pinned app offers *Unpin from Dock*; a
running app in the section right of the divider offers *Pin to Dock*.
Changes apply instantly and persist.

Pin state is stored in `~/.config/omarchy/dino.dock.pinned.json` —
deliberately *outside* the plugin directory, because the shell reloads
the whole plugin whenever anything inside its directory changes (writing
there from the menu would tear the dock down mid-click). A legacy
`pinned.json` inside the plugin directory is still read as a fallback
seed until the first pin/unpin writes the new file, so pre-1.2 setups
keep their pins with no migration step.

You can also hand-edit the file — a plain JSON array of desktop-entry
IDs, left to right:

```json
["foot", "org.gnome.Nautilus", "chromium", "..."]
```

The ID is the `.desktop` filename without the extension. List what's
installed with:

```bash
ls /usr/share/applications/*.desktop | xargs -n1 basename | sed 's/\.desktop$//'
```

Saving the file hot-reloads the dock immediately — no restart needed.
(Editing the *legacy* in-plugin `pinned.json` instead triggers a full
plugin reload — it works, but the new location is gentler.)

- **10–12 is the sweet spot** for icon size at full magnification.
- **20 is the hard cap** — entries past 20 are dropped (a warning is
  logged to the shell's console output).
- Past ~12–14 pinned apps, icons start shrinking to keep the dock under
  ~86% of screen width, the same way the real macOS dock does.

## Configuring which monitor it shows on

On a single-monitor setup you don't need to do anything — the dock uses
whichever screen Quickshell enumerates first.

On a multi-monitor setup, create `monitor.json` in the plugin directory
with a substring of the target screen's manufacturer, model, or connector
name (case-insensitive):

```json
"Odyssey G50F"
```

or just:

```json
"DP-2"
```

Matching by manufacturer/model survives a docking station renumbering
connectors across reboots; matching by connector name alone doesn't. No
`monitor.json`monitor file, or an empty one, means no preference. This file also
hot-reloads on save. (A legacy  inside the plugin
directory is still read as a fallback, but the new location is
preferred — files inside the plugin directory trigger a full plugin
reload when edited and dirty the checkout Changes for dino.dock:
diff --git a/Dock.qml b/Dock.qml
index 0526d77..9f0a18e 100644
--- a/Dock.qml
+++ b/Dock.qml
@@ -26,7 +26,15 @@ Item {
 
   // ------------------------------------------------------------ pinned apps
 
-  readonly property string pinnedPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/dino.dock/pinned.json"
+  // Pin state lives OUTSIDE the plugin directory on purpose: the shell's
+  // plugin registry watches ~/.config/omarchy/plugins/<id>/ and reloads the
+  // whole plugin when anything in it changes — writing pinned.json in there
+  // from the right-click menu would tear the dock down mid-click. The
+  // legacy in-plugin pinned.json is still read as a fallback seed, so
+  // existing setups keep their pins; the first pin/unpin from the dock
+  // writes the new file and it takes over from then on.
+  readonly property string pinnedPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/dino.dock.pinned.json"
+  readonly property string legacyPinnedPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/dino.dock/pinned.json"
   readonly property int maxPinned: 20
 
   property var pinnedIds: []    // ordered list of desktop-entry ids
@@ -55,16 +63,98 @@ Item {
     root.pinnedIds = ids
   }
 
+  // New file wins whenever it has content; the legacy file only seeds an
+  // installation that has never written the new one.
+  property string pinnedRaw: ""
+  property string legacyPinnedRaw: ""
+  function applyPinned() {
+    root.loadPinned(root.pinnedRaw.trim().length > 0 ? root.pinnedRaw : root.legacyPinnedRaw)
+  }
+
   FileView {
     id: pinnedFile
     path: root.pinnedPath
     watchChanges: true
+    atomicWrites: true
     printErrors: false
-    onLoaded: root.loadPinned(text())
+    onLoaded: { root.pinnedRaw = text(); root.applyPinned() }
     onFileChanged: reload()
-    onLoadFailed: root.loadPinned("")
+    onLoadFailed: { root.pinnedRaw = ""; root.applyPinned() }
   }
 
+  FileView {
+    id: legacyPinnedFile
+    path: root.legacyPinnedPath
+    watchChanges: true
+    printErrors: false
+    onLoaded: { root.legacyPinnedRaw = text(); root.applyPinned() }
+    onFileChanged: reload()
+    onLoadFailed: { root.legacyPinnedRaw = ""; root.applyPinned() }
+  }
+
+  // Pin management from the dock itself (right-click menu). Writes go to
+  // the same pinned.json a user could hand-edit — the FileView watch then
+  // reloads it, so the dock, the file, and any open editor all agree.
+  function writePinned(ids) {
+    root.pinnedIds = ids // optimistic; the file watch confirms it
+    var text = JSON.stringify(ids, null, 2) + "
"
+    root.pinnedRaw = text // the new file now owns the state
+    try {
+      pinnedFile.setText(text)
+    } catch (e) {
+      console.warn("dino.dock: pinned.json write failed:", e)
+    }
+  }
+
+  function pinApp(entryId) {
+    var id = String(entryId || "").trim()
+    if (id.length === 0 || root.pinnedIds.indexOf(id) !== -1) return
+    if (root.pinnedIds.length >= root.maxPinned) {
+      console.warn("dino.dock: pin cap (" + root.maxPinned + ") reached, not pinning " + id)
+      return
+    }
+    root.writePinned(root.pinnedIds.concat([id]))
+  }
+
+  function unpinApp(id) {
+    var ids = root.pinnedIds.filter(function(x) { return x !== id })
+    if (ids.length !== root.pinnedIds.length) root.writePinned(ids)
+  }
+
+  // ------------------------------------------------------------ settings
+
+  // Same out-of-plugin-dir rule as the pin file (the registry reload
+  // problem). Currently one knob: {"autohide": false} to keep the dock
+  // always visible.
+  readonly property string settingsPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/dino.dock.settings.json"
+  property bool autohide: true
+
+  function loadSettings(rawText) {
+    var v = true
+    try {
+      var parsed = JSON.parse(String(rawText || ""))
+      if (parsed && typeof parsed.autohide === "boolean") v = parsed.autohide
+    } catch (e) {}
+    root.autohide = v
+  }
+
+  FileView {
+    id: settingsFile
+    path: root.settingsPath
+    watchChanges: true
+    printErrors: false
+    onLoaded: root.loadSettings(text())
+    onFileChanged: reload()
+    onLoadFailed: root.loadSettings("")
+  }
+
+  // Auto-hide state. The dock slides below the screen edge when nothing
+  // needs it; a 4px reveal strip (separate tiny layer surface, only
+  // mapped while hidden) brings it back when the pointer hits the bottom
+  // of the screen — the macOS/taskbar autohide contract.
+  property bool dockHidden: false
+  onAutohideChanged: if (!autohide) dockHidden = false
+
   function rebuildEntryIndex() {
     var idx = {}
     var values = (typeof DesktopEntries !== "undefined" && DesktopEntries.applications) ? DesktopEntries.applications.values : []
@@ -101,9 +191,9 @@ Item {
 
   // ------------------------------------------------------------ running apps
 
-  // Lowercased Wayland app_id -> toplevel. Heuristic matching (see README):
-  // Wayland gives no reliable app_id <-> .desktop-id mapping, so this is a
-  // best-effort dot, not a guarantee.
+  // Lowercased Wayland app_id -> [toplevels]. Heuristic matching (see
+  // README): Wayland gives no reliable app_id <-> .desktop-id mapping, so
+  // this is a best-effort match, not a guarantee.
   property var runningAppIds: ({})
 
   function rebuildRunning() {
@@ -113,7 +203,9 @@ Item {
       for (var i = 0; i < values.length; i++) {
         var t = values[i]
         var key = String((t && t.appId) || "").toLowerCase()
-        if (key.length > 0 && !map[key]) map[key] = t
+        if (key.length === 0) continue
+        if (!map[key]) map[key] = []
+        map[key].push(t)
       }
     } catch (e) {}
     root.runningAppIds = map
@@ -124,23 +216,101 @@ Item {
     function onValuesChanged() { root.rebuildRunning() }
   }
 
-  function toplevelFor(pin) {
+  // The app_id key a pin's running windows live under, or "" if none.
+  function runningKeyFor(pin) {
     var needle1 = String(pin.id || "").toLowerCase()
     var needle2 = pin.name ? String(pin.name).toLowerCase() : ""
     for (var key in root.runningAppIds) {
-      if (key === needle1) return root.runningAppIds[key]
-      if (needle1.length > 0 && (key.indexOf(needle1) !== -1 || needle1.indexOf(key) !== -1)) return root.runningAppIds[key]
-      if (needle2.length > 0 && key.indexOf(needle2) !== -1) return root.runningAppIds[key]
+      if (key === needle1) return key
+      if (needle1.length > 0 && (key.indexOf(needle1) !== -1 || needle1.indexOf(key) !== -1)) return key
+      if (needle2.length > 0 && key.indexOf(needle2) !== -1) return key
+    }
+    return ""
+  }
+
+  function toplevelsFor(pin) {
+    var key = root.runningKeyFor(pin)
+    return key.length > 0 ? root.runningAppIds[key] : null
+  }
+
+  // Click on a running app: focus its window. Clicked again while one of
+  // its windows is already focused: cycle to its next window — that plus
+  // activate() switching workspaces is what makes the dock a mouse-only
+  // way to move between open programs, macOS style.
+  function focusNext(toplevels) {
+    if (!toplevels || toplevels.length === 0) return
+    var active = -1
+    for (var i = 0; i < toplevels.length; i++) {
+      if (toplevels[i] && toplevels[i].activated === true) { active = i; break }
+    }
+    var next = toplevels[(active + 1) % toplevels.length]
+    if (next && typeof next.activate === "function") next.activate()
+  }
+
+  function launchOrFocus(pin, toplevels) {
+    if (toplevels && toplevels.length > 0) {
+      root.focusNext(toplevels)
+    } else if (!pin.isExtra && root.appLibrary) {
+      root.appLibrary.launch(pin.id, pin.name)
+    }
+  }
+
+  // Best-effort desktop entry for a bare Wayland app_id (exact id first,
+  // then case-insensitive, then substring either way) — same spirit as
+  // runningKeyFor, in the other direction.
+  function entryForAppId(appId) {
+    var idx = root.entryIndex
+    if (idx[appId]) return idx[appId]
+    var lower = String(appId).toLowerCase()
+    var keys = Object.keys(idx)
+    for (var i = 0; i < keys.length; i++) {
+      if (keys[i].toLowerCase() === lower) return idx[keys[i]]
+    }
+    for (i = 0; i < keys.length; i++) {
+      var k = keys[i].toLowerCase()
+      if (k.indexOf(lower) !== -1 || lower.indexOf(k) !== -1) return idx[keys[i]]
     }
     return null
   }
 
-  function launchOrFocus(pin, toplevel) {
-    if (toplevel && typeof toplevel.activate === "function") {
-      toplevel.activate()
-    } else if (root.appLibrary) {
-      root.appLibrary.launch(pin.id, pin.name)
+  // Running apps that resolve to no pinned slot. They render to the right
+  // of a divider, macOS style, so every open program is clickable from the
+  // dock even when it was launched elsewhere. Sorted by app_id so the row
+  // doesn't reshuffle every time focus moves.
+  readonly property var runningExtras: {
+    var claimed = {}
+    for (var i = 0; i < root.resolvedPins.length; i++) {
+      var key = root.runningKeyFor(root.resolvedPins[i])
+      if (key.length > 0) claimed[key] = true
     }
+    var out = []
+    var keys = Object.keys(root.runningAppIds).sort()
+    for (i = 0; i < keys.length; i++) {
+      if (claimed[keys[i]]) continue
+      var tls = root.runningAppIds[keys[i]]
+      var appId = tls[0] ? String(tls[0].appId || keys[i]) : keys[i]
+      var entry = root.entryForAppId(appId)
+      out.push({
+        isExtra: true,
+        key: keys[i],
+        id: appId,
+        entry: entry,
+        name: entry ? String(entry.name || appId) : ((tls[0] && tls[0].title) ? String(tls[0].title) : appId),
+        icon: (entry && entry.icon) ? entry.icon : appId
+      })
+    }
+    return out
+  }
+
+  // Pinned apps, then a separator, then running unpinned apps — the whole
+  // row the dock renders.
+  readonly property var dockModel: {
+    var out = root.resolvedPins.slice()
+    if (root.runningExtras.length > 0) {
+      out.push({ isSeparator: true })
+      out = out.concat(root.runningExtras)
+    }
+    return out
   }
 
   Component.onCompleted: {
@@ -214,10 +384,47 @@ Item {
     WlrLayershell.layer: WlrLayer.Top
     WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
     exclusionMode: ExclusionMode.Ignore
-    // Only the dock card (see below) accepts input; the rest of this
-    // full-screen surface stays click-through so it never blocks the
-    // desktop underneath, exactly like the notifications/OSD overlays.
-    mask: Region { item: dockCard }
+    // Only the dock card (plus the context menu when open) accepts input;
+    // the rest of this full-screen surface stays click-through so it never
+    // blocks the desktop underneath, exactly like the notifications/OSD
+    // overlays. A long window-list menu can extend above dockCard's
+    // bounds, so the mask is a computed rect that grows upward with it —
+    // one flat region, no nested-Region semantics to trip over.
+    readonly property int maskTopOverflow: contextMenu.visible ? Math.max(0, -contextMenu.y) : 0
+    // Extends from the (possibly menu-raised) top of the dock down to the
+    // physical screen edge, so a pointer parked at the very bottom still
+    // counts as "at the dock" and autohide doesn't oscillate. Collapses to
+    // nothing while hidden — a hidden dock must not eat clicks.
+    mask: Region {
+      x: dockCard.x
+      y: root.dockHidden ? 0 : dockCard.y - panel.maskTopOverflow
+      width: root.dockHidden ? 0 : dockCard.width
+      height: root.dockHidden ? 0 : panel.height - dockCard.y + panel.maskTopOverflow
+    }
+
+    // What keeps the dock on screen: pointer anywhere over/under the card
+    // (nearMa spans to the screen edge), the menu, or an in-flight drag —
+    // or autohide being off. Losing all of them starts the hide timer.
+    readonly property bool dockWanted: !root.autohide
+      || nearMa.containsMouse || menuHover.containsMouse || edgeMa.containsMouse
+      || dockCard.menuData !== null || dockCard.dragIndex >= 0
+    onDockWantedChanged: if (dockWanted) root.dockHidden = false
+
+    Timer {
+      interval: 700
+      running: root.autohide && !panel.dockWanted && !root.dockHidden
+      onTriggered: root.dockHidden = true
+    }
+
+    MouseArea {
+      id: nearMa
+      x: dockCard.x
+      y: dockCard.y
+      width: dockCard.width
+      height: Math.max(0, panel.height - dockCard.y)
+      hoverEnabled: true
+      acceptedButtons: Qt.NoButton
+    }
 
     readonly property real screenWidth: panel.screen ? panel.screen.width : 1920
 
@@ -225,7 +432,13 @@ Item {
       id: dockCard
       anchors.horizontalCenter: parent.horizontalCenter
       anchors.bottom: parent.bottom
-      anchors.bottomMargin: Math.max(Style.space(10), Style.gapsOut)
+      readonly property int restMargin: Math.max(Style.space(10), Style.gapsOut)
+      anchors.bottomMargin: root.dockHidden
+        ? -(cardHeight + restMargin + Style.space(6))
+        : restMargin
+      Behavior on anchors.bottomMargin {
+        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
+      }
       width: cardWidth
       height: cardHeight + headroom
 
@@ -235,18 +448,24 @@ Item {
       // Wide enough that the endmost icons clear the capsule's curved ends.
       readonly property int padX: Style.space(24)
       readonly property int padY: Style.space(8)
-      readonly property int count: Math.max(1, root.resolvedPins.length)
+      readonly property bool hasSeparator: root.runningExtras.length > 0
+      readonly property int sepWidth: Style.space(2)
+      // Icon slots (pins + running extras); the separator is its own thin
+      // slot that takes sepWidth instead of iconSize.
+      readonly property int iconCount: Math.max(1, root.dockModel.length - (hasSeparator ? 1 : 0))
+      readonly property int slotCount: iconCount + (hasSeparator ? 1 : 0)
       readonly property real availableWidth: panel.screenWidth * 0.86
 
       // Grow wider up to ~86% of screen width; past that, shrink icons to
       // fit — the same trade-off the real macOS dock makes.
-      readonly property int naturalWidth: count * maxIconSize + (count - 1) * iconGap + padX * 2
+      readonly property int fixedWidth: (slotCount - 1) * iconGap + (hasSeparator ? sepWidth : 0) + padX * 2
+      readonly property int naturalWidth: iconCount * maxIconSize + fixedWidth
       readonly property int iconSize: naturalWidth <= availableWidth
         ? maxIconSize
-        : Math.max(minIconSize, Math.floor((availableWidth - padX * 2 - (count - 1) * iconGap) / count))
+        : Math.max(minIconSize, Math.floor((availableWidth - fixedWidth) / iconCount))
 
-      readonly property int cardWidth: root.resolvedPins.length > 0
-        ? (iconSize * count + iconGap * (count - 1) + padX * 2)
+      readonly property int cardWidth: root.dockModel.length > 0
+        ? (iconSize * iconCount + fixedWidth)
         : (maxIconSize + padX * 2)
       readonly property int cardHeight: iconSize + padY * 2
       // Extra vertical room above the pill so magnified/bouncing icons have
@@ -254,6 +473,34 @@ Item {
       // item) still covers them while they're up there.
       readonly property int headroom: Math.round(iconSize * (magStrength + 0.35))
 
+      // ---- right-click pin menu ----
+      property var menuData: null // modelData of the icon the menu is open for
+      property real menuX: 0
+
+      // ---- drag-to-reorder (pins only) ----
+      property int dragIndex: -1       // dockModel index of the pin being dragged
+      property int dragTargetIndex: -1 // insertion point among pins [0..pinCount]
+
+      function insertionIndexAt(xInCard) {
+        var rel = xInCard - iconRow.x
+        var idx = Math.round(rel / (iconSize + iconGap))
+        return Math.max(0, Math.min(root.resolvedPins.length, idx))
+      }
+
+      function finishDrag() {
+        var from = dragIndex
+        var to = dragTargetIndex
+        dragIndex = -1
+        dragTargetIndex = -1
+        if (from < 0 || to < 0 || from >= root.pinnedIds.length) return
+        var insertAt = to > from ? to - 1 : to
+        if (insertAt === from) return
+        var ids = root.pinnedIds.slice()
+        var moved = ids.splice(from, 1)[0]
+        ids.splice(insertAt, 0, moved)
+        root.writePinned(ids)
+      }
+
       // ---- hover magnification ----
       property real hoverX: -100000
       readonly property real magRadius: iconSize * 2.1
@@ -310,7 +557,10 @@ Item {
         hoverEnabled: true
         acceptedButtons: Qt.NoButton
         onPositionChanged: dockCard.hoverX = mouseX
-        onExited: dockCard.hoverX = -100000
+        onExited: {
+          dockCard.hoverX = -100000
+          menuCloseTimer.restart()
+        }
       }
 
       Row {
@@ -320,20 +570,36 @@ Item {
         spacing: dockCard.iconGap
 
         Repeater {
-          model: root.resolvedPins
+          model: root.dockModel
 
           delegate: Item {
             id: slot
             required property var modelData
             required property int index
-            width: dockCard.iconSize
+            readonly property bool isSep: slot.modelData.isSeparator === true
+            width: slot.isSep ? dockCard.sepWidth : dockCard.iconSize
             height: dockCard.height
 
             readonly property real slotCenterX: iconRow.x + slot.x + width / 2
-            readonly property real targetScale: dockCard.scaleFor(slotCenterX)
+            readonly property real targetScale: slot.isSep ? 1.0 : dockCard.scaleFor(slotCenterX)
             property bool hovered: false
-            readonly property var runningToplevel: root.toplevelFor(slot.modelData)
-            readonly property bool isRunning: slot.runningToplevel !== null
+            readonly property var runningToplevels: slot.isSep ? null
+              : (slot.modelData.isExtra === true
+                  ? (root.runningAppIds[slot.modelData.key] || null)
+                  : root.toplevelsFor(slot.modelData))
+            readonly property bool isRunning: slot.runningToplevels !== null && slot.runningToplevels.length > 0
+
+            // The pins/running divider — a soft hairline like macOS's.
+            Rectangle {
+              visible: slot.isSep
+              width: dockCard.sepWidth
+              height: dockCard.iconSize * 0.72
+              radius: width / 2
+              color: Util.alpha(Color.popups.border, 0.45)
+              anchors.horizontalCenter: parent.horizontalCenter
+              anchors.bottom: parent.bottom
+              anchors.bottomMargin: dockCard.padY + (dockCard.iconSize - height) / 2
+            }
 
             Rectangle {
               id: dot
@@ -349,7 +615,8 @@ Item {
 
             Rectangle {
               id: tile
-              width: dockCard.iconSize
+              visible: !slot.isSep
+              width: slot.isSep ? 0 : dockCard.iconSize
               height: dockCard.iconSize
               radius: Style.space(12)
               color: slot.hovered ? Style.hoverFill : "transparent"
@@ -364,6 +631,7 @@ Item {
               anchors.bottomMargin: dockCard.padY + tile.bounceOffset
               transformOrigin: Item.Bottom
               scale: slot.targetScale
+              opacity: dockCard.dragIndex === slot.index ? 0.35 : 1.0
 
               property real bounceOffset: 0
 
@@ -408,13 +676,33 @@ Item {
                 // almost everything here, so prefer it explicitly and only
                 // fall back to the normal themed lookup for the rare pin it
                 // doesn't cover (e.g. omacalc, an Omarchy-only app).
-                readonly property string papirusPath: "file:///usr/share/icons/Papirus/64x64/apps/" + slot.modelData.icon + ".svg"
-                readonly property string themedPath: root.appLibrary ? root.appLibrary.iconSource(slot.modelData.icon) : ""
+                readonly property string papirusPath: "file:///usr/share/icons/Papirus/64x64/apps/" + (slot.modelData.icon || "") + ".svg"
+                // Resolve through Qt's icon theme engine (Quickshell.iconPath
+                // is synchronous — no appLibrary refresh race), with
+                // appLibrary as a further fallback for anything exotic.
+                readonly property string themedPath: {
+                  var ic = String(slot.modelData.icon || "")
+                  if (ic.length === 0) return ""
+                  if (ic.charAt(0) === "/") return "file://" + ic
+                  try {
+                    var p = Quickshell.iconPath(ic, true)
+                    if (p && p.length > 0) return p.charAt(0) === "/" ? "file://" + p : p
+                  } catch (e) {}
+                  return root.appLibrary ? root.appLibrary.iconSource(ic) : ""
+                }
+                // Last resort for running apps whose app_id resolves to no
+                // usable icon anywhere (e.g. bare agent/terminal wrappers):
+                // a generic app tile beats an invisible one.
+                readonly property string genericPath: "file:///usr/share/icons/Papirus/64x64/apps/application-default-icon.svg"
 
                 source: icon.papirusPath
                 onStatusChanged: {
-                  if (status === Image.Error && source.toString() !== icon.themedPath) {
+                  if (status !== Image.Error) return
+                  var s = source.toString()
+                  if (s === icon.papirusPath && icon.themedPath.length > 0 && icon.themedPath !== s) {
                     source = icon.themedPath
+                  } else if (s !== icon.genericPath) {
+                    source = icon.genericPath
                   }
                 }
               }
@@ -438,21 +726,73 @@ Item {
             }
 
             MouseArea {
+              id: slotMa
               anchors.fill: tile
+              visible: !slot.isSep
+              enabled: !slot.isSep
               hoverEnabled: true
+              acceptedButtons: Qt.LeftButton | Qt.RightButton
               cursorShape: Qt.PointingHandCursor
               onEntered: slot.hovered = true
               onExited: slot.hovered = false
-              onClicked: {
-                bounceAnim.start()
-                root.launchOrFocus(slot.modelData, slot.runningToplevel)
+
+              // Drag-to-reorder: pins only. A left-press that travels more
+              // than half an icon horizontally becomes a drag; release
+              // commits the new order through the same writePinned path the
+              // menu uses.
+              readonly property bool draggable: !slot.isSep && slot.modelData.isExtra !== true
+              property real pressX: 0
+              property bool didDrag: false
+
+              onPressed: mouse => {
+                if (mouse.button === Qt.LeftButton) {
+                  pressX = mouse.x
+                  didDrag = false
+                }
+              }
+              onPositionChanged: mouse => {
+                if (!pressed || !draggable) return
+                if (!didDrag && Math.abs(mouse.x - pressX) > dockCard.iconSize * 0.5) {
+                  didDrag = true
+                  dockCard.menuData = null
+                  dockCard.dragIndex = slot.index
+                }
+                if (didDrag) {
+                  dockCard.dragTargetIndex = dockCard.insertionIndexAt(iconRow.x + slot.x + mouse.x)
+                }
+              }
+              onReleased: {
+                if (didDrag) dockCard.finishDrag()
+              }
+              onClicked: mouse => {
+                if (didDrag) {
+                  didDrag = false
+                  return
+                }
+                if (mouse.button === Qt.RightButton) {
+                  // Toggle the menu for this icon.
+                  if (dockCard.menuData === slot.modelData) {
+                    dockCard.menuData = null
+                  } else {
+                    dockCard.menuX = slot.slotCenterX
+                    dockCard.menuData = slot.modelData
+                  }
+                  return
+                }
+                dockCard.menuData = null
+                // Bounce is a "launching" cue — focusing an already-running
+                // window just switches to it, no theatrics (macOS again).
+                if (!slot.isRunning) bounceAnim.start()
+                root.launchOrFocus(slot.modelData, slot.runningToplevels)
               }
             }
 
             Rectangle {
               id: tooltip
               visible: opacity > 0
-              opacity: slot.hovered ? 1 : 0
+              // Suppressed while the pin menu is up — they occupy the same
+              // spot above the icon.
+              opacity: (slot.hovered && dockCard.menuData === null) ? 1 : 0
               Behavior on opacity { NumberAnimation { duration: 120 } }
               radius: Style.space(6)
               color: Util.alpha(Color.tooltip.background, 0.95)
@@ -465,7 +805,7 @@ Item {
               Text {
                 id: tooltipLabel
                 anchors.centerIn: parent
-                text: slot.modelData.name
+                text: slot.modelData.name || ""
                 color: Color.tooltip.text
                 font.family: Style.fontFamily
                 font.pixelSize: Style.font.bodySmall
@@ -474,6 +814,215 @@ Item {
           }
         }
       }
+
+      // ---- right-click menu ----
+      //
+      // Per-icon context menu: New Window, a jump list of the app's open
+      // windows (click one to focus it, wherever it lives), Quit (closes
+      // every window via the same foreign-toplevel protocol activate()
+      // uses), and Pin/Unpin. Can extend above dockCard's bounds, so the
+      // panel's input mask unions it in explicitly. Closes on action, on
+      // left-click of any icon, on right-click toggle, or shortly after
+      // the pointer leaves both the dock and the menu.
+      Rectangle {
+        id: contextMenu
+
+        readonly property var menuRows: {
+          var d = dockCard.menuData
+          if (d === null) return []
+          var rows = []
+          var tls = (d.isExtra === true)
+            ? (root.runningAppIds[d.key] || [])
+            : (root.toplevelsFor(d) || [])
+          var canLaunch = d.isExtra !== true || (d.entry !== null && d.entry !== undefined)
+          if (canLaunch) rows.push({ kind: "launch", label: "New Window" })
+          if (tls.length > 0) {
+            if (rows.length > 0) rows.push({ kind: "sep" })
+            for (var i = 0; i < tls.length && i < 8; i++) {
+              var title = String((tls[i] && tls[i].title) || "(untitled)")
+              if (title.length > 42) title = title.slice(0, 41) + "…"
+              rows.push({ kind: "window", label: title, tl: tls[i] })
+            }
+            rows.push({ kind: "sep" })
+            rows.push({ kind: "quit",
+                        label: tls.length > 1 ? "Quit (" + tls.length + " windows)" : "Quit" })
+          }
+          if (d.isExtra === true) {
+            if (d.entry && d.entry.id) rows.push({ kind: "pin", label: "Pin to Dock" })
+          } else {
+            rows.push({ kind: "unpin", label: "Unpin from Dock" })
+          }
+          return rows
+        }
+
+        function doAction(row) {
+          var d = dockCard.menuData
+          dockCard.menuData = null
+          if (d === null || !row) return
+          if (row.kind === "window") {
+            if (row.tl && typeof row.tl.activate === "function") row.tl.activate()
+          } else if (row.kind === "launch") {
+            var id = d.isExtra === true ? (d.entry ? d.entry.id : "") : d.id
+            if (id && root.appLibrary) root.appLibrary.launch(String(id), String(d.name || ""))
+          } else if (row.kind === "quit") {
+            var tls = (d.isExtra === true)
+              ? (root.runningAppIds[d.key] || [])
+              : (root.toplevelsFor(d) || [])
+            for (var i = 0; i < tls.length; i++) {
+              if (tls[i] && typeof tls[i].close === "function") tls[i].close()
+            }
+          } else if (row.kind === "pin") {
+            root.pinApp(d.entry ? d.entry.id : "")
+          } else if (row.kind === "unpin") {
+            root.unpinApp(String(d.id || ""))
+          }
+        }
+
+        // Row sizing comes from measuring the longest label, NOT from the
+        // Column's implicit size: rows binding their width to the column
+        // while the column derives its size from the rows is a stable
+        // 0x0 deadlock (both start at zero and agree forever).
+        readonly property string longestLabel: {
+          var best = ""
+          for (var i = 0; i < menuRows.length; i++) {
+            var l = String(menuRows[i].label || "")
+            if (l.length > best.length) best = l
+          }
+          return best
+        }
+        readonly property real rowWidth: menuMetrics.width + Style.space(28)
+        readonly property real rowHeight: menuMetrics.height + Style.space(12)
+
+        TextMetrics {
+          id: menuMetrics
+          font.family: Style.fontFamily
+          font.pixelSize: Style.font.bodySmall
+          text: contextMenu.longestLabel
+        }
+
+        visible: dockCard.menuData !== null && menuRows.length > 0
+        z: 100
+        radius: Style.space(8)
+        color: Util.alpha(Color.popups.background, 0.98)
+        border.color: Util.alpha(Color.popups.border, 0.5)
+        border.width: 1
+        width: rowWidth + Style.space(8)
+        height: menuCol.implicitHeight + Style.space(8)
+        x: Math.max(0, Math.min(dockCard.menuX - width / 2, dockCard.width - width))
+        y: dockCard.height - dockCard.cardHeight - height - Style.space(8)
+
+        MouseArea {
+          id: menuHover
+          anchors.fill: parent
+          hoverEnabled: true
+          acceptedButtons: Qt.NoButton
+          onExited: menuCloseTimer.restart()
+        }
+
+        Column {
+          id: menuCol
+          x: Style.space(4)
+          y: Style.space(4)
+
+          Repeater {
+            model: contextMenu.menuRows
+
+            delegate: Item {
+              id: menuRow
+              required property var modelData
+              readonly property bool isSep: modelData.kind === "sep"
+              width: contextMenu.rowWidth
+              height: isSep ? Style.space(7) : contextMenu.rowHeight
+
+              Rectangle {
+                visible: menuRow.isSep
+                anchors.centerIn: parent
+                width: parent.width - Style.space(8)
+                height: 1
+                color: Util.alpha(Color.popups.border, 0.4)
+              }
+
+              Rectangle {
+                visible: !menuRow.isSep
+                anchors.fill: parent
+                radius: Style.space(6)
+                color: rowMa.containsMouse ? Style.hoverFill : "transparent"
+              }
+
+              Text {
+                id: rowText
+                visible: !menuRow.isSep
+                anchors.verticalCenter: parent.verticalCenter
+                x: Style.space(14)
+                text: menuRow.isSep ? "" : menuRow.modelData.label
+                color: Color.popups.text
+                font.family: Style.fontFamily
+                font.pixelSize: Style.font.bodySmall
+              }
+
+              MouseArea {
+                id: rowMa
+                anchors.fill: parent
+                visible: !menuRow.isSep
+                enabled: !menuRow.isSep
+                hoverEnabled: true
+                cursorShape: Qt.PointingHandCursor
+                onClicked: contextMenu.doAction(menuRow.modelData)
+              }
+            }
+          }
+        }
+      }
+
+      // Insertion indicator while dragging a pin.
+      Rectangle {
+        visible: dockCard.dragTargetIndex >= 0
+        width: Style.space(3)
+        height: dockCard.iconSize
+        radius: width / 2
+        color: Color.accent
+        z: 50
+        x: iconRow.x + dockCard.dragTargetIndex * (dockCard.iconSize + dockCard.iconGap)
+           - dockCard.iconGap / 2 - width / 2
+        y: dockCard.height - dockCard.cardHeight + dockCard.padY
+      }
+
+      // Grace period so the pointer can travel dock -> menu without the
+      // menu vanishing mid-flight.
+      Timer {
+        id: menuCloseTimer
+        interval: 300
+        onTriggered: {
+          if (!hoverArea.containsMouse && !menuHover.containsMouse) dockCard.menuData = null
+        }
+      }
+    }
+  }
+
+  // 2px reveal strip along the bottom screen edge, its own tiny layer
+  // surface (whole-surface input by default) — unioning a full-width
+  // strip into the main panel's single rectangular mask would swallow
+  // clicks beside the dock. Kept mapped the whole time autohide is on,
+  // NOT just while hidden: unmapping it under the pointer freezes its
+  // MouseArea's containsMouse at true (no exit event ever arrives), which
+  // pinned the dock open on the first live test.
+  PanelWindow {
+    id: revealWindow
+    visible: root.autohide
+    screen: root.targetScreen
+    anchors { bottom: true; left: true; right: true }
+    implicitHeight: 2
+    color: "transparent"
+    WlrLayershell.namespace: "omarchy-dock-reveal"
+    WlrLayershell.layer: WlrLayer.Top
+    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
+    exclusionMode: ExclusionMode.Ignore
+
+    MouseArea {
+      id: edgeMa
+      anchors.fill: parent
+      hoverEnabled: true
+      acceptedButtons: Qt.NoButton
     }
   }
 }
diff --git a/README.md b/README.md
index dffef97..7a10e06 100644
--- a/README.md
+++ b/README.md
@@ -1,11 +1,15 @@
 # Floating Dock
 
 An Apple-style floating dock for [Omarchy](https://omarchy.org): pinned
-launchers along the bottom of the screen, hover magnification, a launch
-bounce, running-app indicators, and a glassy capsule look. Built as a
+launchers along the bottom of the screen, every running app shown to the
+right of a divider (click any of them to jump to that window, across
+workspaces), hover magnification, a launch bounce, running-app
+indicators, and a glassy capsule look. Built as a
 native `omarchy-shell` plugin (same tech as the bar/OSD), so it's themed
 automatically and survives theme switches.
 
+![Floating Dock](screenshot.jpg)
+
 ## Install
 
 ```bash
@@ -25,9 +29,20 @@ omarchy plugin enable dino.dock
 
 ## Configuring pinned apps
 
-Edit `pinned.json` in the plugin directory
-(`~/.config/omarchy/plugins/dino.dock/pinned.json`) — a plain JSON array
-of desktop-entry IDs, left to right:
+**Right-click any dock icon.** A pinned app offers *Unpin from Dock*; a
+running app in the section right of the divider offers *Pin to Dock*.
+Changes apply instantly and persist.
+
+Pin state is stored in `~/.config/omarchy/dino.dock.pinned.json` —
+deliberately *outside* the plugin directory, because the shell reloads
+the whole plugin whenever anything inside its directory changes (writing
+there from the menu would tear the dock down mid-click). A legacy
+`pinned.json` inside the plugin directory is still read as a fallback
+seed until the first pin/unpin writes the new file, so pre-1.2 setups
+keep their pins with no migration step.
+
+You can also hand-edit the file — a plain JSON array of desktop-entry
+IDs, left to right:
 
 ```json
 ["foot", "org.gnome.Nautilus", "chromium", "..."]
@@ -41,6 +56,8 @@ ls /usr/share/applications/*.desktop | xargs -n1 basename | sed 's/\.desktop$//'
 ```
 
 Saving the file hot-reloads the dock immediately — no restart needed.
+(Editing the *legacy* in-plugin `pinned.json` instead triggers a full
+plugin reload — it works, but the new location is gentler.)
 
 - **10–12 is the sweet spot** for icon size at full magnification.
 - **20 is the hard cap** — entries past 20 are dropped (a warning is
@@ -53,7 +70,7 @@ Saving the file hot-reloads the dock immediately — no restart needed.
 On a single-monitor setup you don't need to do anything — the dock uses
 whichever screen Quickshell enumerates first.
 
-On a multi-monitor setup, create `monitor.json` next to `pinned.json`
+On a multi-monitor setup, create `monitor.json` in the plugin directory
 with a substring of the target screen's manufacturer, model, or connector
 name (case-insensitive):
 
@@ -76,17 +93,73 @@ hot-reloads on save.
 
 - **Click** a pinned icon: focuses its window if one is already open,
   otherwise launches it (via the shared `AppLibrary` service — same
-  launch path as the Omarchy menu).
+  launch path as the Omarchy menu). Focusing follows the window to
+  whatever workspace it lives on — the compositor switches for you.
+- **Click again** while an app's window is already focused: cycles to
+  that app's next window, so a browser with three windows is three
+  clicks to tour, no keyboard involved.
+- **Running apps you didn't pin** appear to the right of a thin divider,
+  macOS style — every open program is clickable from the dock no matter
+  how it was launched. Icons resolve desktop-entry art where the
+  `app_id` can be matched (webapps included), falling back to a generic
+  tile for windows that ship no icon at all. This section appears and
+  disappears with the windows themselves.
+- **Right-click** any icon for its menu: *New Window*, a jump list of
+  the app's open windows (click one to focus it, wherever it lives),
+  *Quit* (closes every window of the app), and *Pin to Dock* / *Unpin
+  from Dock*. An unpinned app with open windows simply slides over to
+  the running section — nothing quits.
+- **Drag a pinned icon** left or right to reorder it — an accent bar
+  shows where it will land, and the new order persists.
+- **Auto-hide (default on)**: the dock slides off-screen when the
+  pointer leaves it, so it never sits on top of your tiled windows. Push
+  the pointer to the bottom edge of the screen and it slides back —
+  same contract as the macOS Dock or a hidden taskbar. A 2px strip
+  along the bottom edge catches the reveal (that sliver is reserved
+  while auto-hide is on). To keep the dock always visible, create
+   containing
+   — hot-reloads on save, same out-of-plugin-dir
+  location as the pin file.
 - **Hover**: icons magnify with distance-based falloff, like the macOS
   dock.
 - **Running indicator**: a small accent-colored dot appears under any
-  pinned app with an open window. Matching is done by comparing the
+  app with an open window, pinned or not. Matching is done by comparing the
   window's Wayland `app_id` against the desktop entry's ID/name — this is
   a heuristic (Wayland has no fully reliable "this app_id came from this
   .desktop file" mapping), so if a running dot doesn't light up for a
   particular app, its `app_id` doesn't match closely enough; nothing to
   fix on the launch side, it just won't show the dot.
 
+## Why there's no Minimize (yet)
+
+Minimize is designed and proven, but deliberately not shipped. Hyprland
+has no native minimize; the working equivalent is parking a window in a
+hidden special workspace — the same mechanism as Omarchy's scratchpad
+(SUPER + S):
+
+```lua
+-- park (minimize), no focus change:
+hl.dispatch(hl.dsp.window.move({ workspace = "special:minimized",
+                                 follow = false, window = w }))
+-- restore to whatever workspace you're on now:
+hl.dispatch(hl.dsp.window.move({ workspace = tostring(hl.get_active_workspace().id),
+                                 follow = false, window = w }))
+```
+
+The dock version would be a *Minimize* item in the right-click menu
+(macOS "Hide" semantics — all of an app's windows park, its icon dims,
+clicking restores to your current workspace).
+
+The reason it's not implemented: everything else in this dock rides on
+**stable Wayland protocols** (foreign-toplevel management) and survives
+compositor upgrades untouched. Minimize would be the one feature bound
+to **Hyprland's embedded Lua API** — a young, fork-specific surface that
+already broke the classic `hyprctl dispatch` syntax and can shift again
+with any Omarchy Hyprland bump. One feature silently breaking on
+upgrade would cost more trust than minimize is worth. If that API
+settles (or a portable minimize lands in a Wayland protocol), the recipe
+above is the whole implementation — PRs welcome.
+
 ## Updating
 
 ```bash
@@ -108,7 +181,10 @@ or manually: delete the plugin directory and remove the `{"id":
 - `manifest.json` — plugin manifest (kind: `panel`, `keepLoaded: true` so
   it's mounted at shell startup and stays up, like the OSD).
 - `Dock.qml` — the implementation.
-- `pinned.json` — your pinned-app list (edit this, not `Dock.qml`).
+- `~/.config/omarchy/dino.dock.pinned.json` — your pinned-app list
+  (managed by right-click; hand-editable). The in-repo `pinned.json` is
+  the legacy fallback seed for pre-1.2 installs and the defaults a fresh
+  install starts from.
 - `monitor.json` — optional, only needed on multi-monitor setups.
 
 ## License
diff --git a/manifest.json b/manifest.json
index 073438f..87c2c92 100644
--- a/manifest.json
+++ b/manifest.json
@@ -2,9 +2,9 @@
   "schemaVersion": 1,
   "id": "dino.dock",
   "name": "Floating Dock",
-  "version": "1.0.0",
+  "version": "1.4.0",
   "author": "dino",
-  "description": "Apple-style floating dock: pinned launchers, hover magnification, launch bounce, running-app indicators.",
+  "description": "Apple-style floating dock: pinned launchers, running apps with click-to-focus and window cycling, right-click menu (new window, window jump list, quit, pin/unpin), drag-to-reorder, auto-hide, hover magnification, launch bounce, running-app indicators.",
   "kinds": ["panel"],
   "keepLoaded": true,
   "entryPoints": { "panel": "Dock.qml" }
diff --git a/screenshot.jpg b/screenshot.jpg
new file mode 100644
index 0000000..113a31b
Binary files /dev/null and b/screenshot.jpg differ
pulls into.)

## How it behaves

- **Click** a pinned icon: focuses its window if one is already open,
  otherwise launches it (via the shared `AppLibrary` service — same
  launch path as the Omarchy menu). Focusing follows the window to
  whatever workspace it lives on — the compositor switches for you.
- **Click again** while an app's window is already focused: cycles to
  that app's next window, so a browser with three windows is three
  clicks to tour, no keyboard involved.
- **Running apps you didn't pin** appear to the right of a thin divider,
  macOS style — every open program is clickable from the dock no matter
  how it was launched. Icons resolve desktop-entry art where the
  `app_id` can be matched (webapps included), falling back to a generic
  tile for windows that ship no icon at all. This section appears and
  disappears with the windows themselves.
- **Right-click** any icon for its menu: *New Window*, a jump list of
  the app's open windows (click one to focus it, wherever it lives),
  *Quit* (closes every window of the app), and *Pin to Dock* / *Unpin
  from Dock*. An unpinned app with open windows simply slides over to
  the running section — nothing quits.
- **Drag a pinned icon** left or right to reorder it — an accent bar
  shows where it will land, and the new order persists.
- **Auto-hide (default on)**: the dock slides off-screen when the
  pointer leaves it, so it never sits on top of your tiled windows. Push
  the pointer to the bottom edge of the screen and it slides back —
  same contract as the macOS Dock or a hidden taskbar. A 2px strip
  along the bottom edge catches the reveal (that sliver is reserved
  while auto-hide is on). To keep the dock always visible, create
   containing
   — hot-reloads on save, same out-of-plugin-dir
  location as the pin file.
- **Hover**: icons magnify with distance-based falloff, like the macOS
  dock.
- **Running indicator**: a small accent-colored dot appears under any
  app with an open window, pinned or not. Matching is done by comparing the
  window's Wayland `app_id` against the desktop entry's ID/name — this is
  a heuristic (Wayland has no fully reliable "this app_id came from this
  .desktop file" mapping), so if a running dot doesn't light up for a
  particular app, its `app_id` doesn't match closely enough; nothing to
  fix on the launch side, it just won't show the dot.

## Why there's no Minimize (yet)

Minimize is designed and proven, but deliberately not shipped. Hyprland
has no native minimize; the working equivalent is parking a window in a
hidden special workspace — the same mechanism as Omarchy's scratchpad
(SUPER + S):

```lua
-- park (minimize), no focus change:
hl.dispatch(hl.dsp.window.move({ workspace = "special:minimized",
                                 follow = false, window = w }))
-- restore to whatever workspace you're on now:
hl.dispatch(hl.dsp.window.move({ workspace = tostring(hl.get_active_workspace().id),
                                 follow = false, window = w }))
```

The dock version would be a *Minimize* item in the right-click menu
(macOS "Hide" semantics — all of an app's windows park, its icon dims,
clicking restores to your current workspace).

The reason it's not implemented: everything else in this dock rides on
**stable Wayland protocols** (foreign-toplevel management) and survives
compositor upgrades untouched. Minimize would be the one feature bound
to **Hyprland's embedded Lua API** — a young, fork-specific surface that
already broke the classic `hyprctl dispatch` syntax and can shift again
with any Omarchy Hyprland bump. One feature silently breaking on
upgrade would cost more trust than minimize is worth. If that API
settles (or a portable minimize lands in a Wayland protocol), the recipe
above is the whole implementation — PRs welcome.

## Updating

```bash
omarchy plugin update dino.dock
```

## Removing / disabling

```bash
omarchy plugin remove dino.dock
```

or manually: delete the plugin directory and remove the `{"id":
"dino.dock"}` entry from the `plugins` array in
`~/.config/omarchy/shell.json`.

## Files

- `manifest.json` — plugin manifest (kind: `panel`, `keepLoaded: true` so
  it's mounted at shell startup and stays up, like the OSD).
- `Dock.qml` — the implementation.
- `~/.config/omarchy/dino.dock.pinned.json` — your pinned-app list
  (managed by right-click; hand-editable). The in-repo `pinned.json` is
  the legacy fallback seed for pre-1.2 installs and the defaults a fresh
  install starts from.
- `monitor.json` — optional, only needed on multi-monitor setups.

## License

MIT — see `LICENSE`.
