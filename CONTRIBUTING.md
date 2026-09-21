# Contributing

Thanks for wanting to improve the dock. The code is small on purpose —
about 2,000 lines of QML (`Dock.qml`) and one Python helper
(`dock_helper.py`) — and every file should stay auditable before you
enable it.

## Ground rules

1. **Protocols over hacks.** Window tracking, focusing, cycling and
   closing must ride on the Wayland foreign-toplevel protocol. Don't add
   a Hyprland-specific call unless the protocol genuinely can't do it —
   and if it can't, put the compositor-specific piece in
   `dock_helper.py`, not in the QML.
2. **No lies in the README.** Only document behavior that you actually
   ran. If a feature is partial, say so.
3. **Theme through Omarchy.** Colors come from `Style`/`Color` singletons
   so the dock follows theme switches. No hardcoded palettes.
4. **Config stays out of the plugin directory.** Runtime settings live in
   `~/.config/omarchy/dino.dock.*.json` because the shell reloads a
   plugin whenever its own directory changes.

## Testing checklist before opening a PR

- [ ] `pkill -x quickshell; omarchy restart shell` — no QML errors in the
      journal (`journalctl --user | grep Dock.qml`).
- [ ] All four placements load: `position` = bottom / top / left / right.
- [ ] Hover preview opens for a running app and closes on pointer-leave
      and at the 30 s cap.
- [ ] Right-click menu rows work (minimize, maximize, new window, quit,
      pin/unpin).
- [ ] Launcher opens, filters, launches with Enter, closes with ESC and
      with an outside click.
- [ ] Minimize → restore cycle leaves the window on your active
      workspace (`hyprctl clients -j | grep -i workspace`).

## Style

Match the existing QML: explicit heights for exact centering, one
comment for every non-obvious decision, no magic numbers without a
`Style.space`/token equivalent.
