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
`monitor.json`, or an empty one, means no preference. This file also
hot-reloads on save.

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
