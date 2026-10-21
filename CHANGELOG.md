# Changelog

## 1.0.0 — release candidate

- Build 30: refresh the app icon with a light ivory background, soft blue windows and a mint focused window. Keep the three-workspace symbol and all standard macOS icon sizes.

- Build 29: hide the redundant menu-bar entry while docked or floating bars are present. Keep settings and quit actions in each bar's context menu, and restore the menu-bar entry when no bar can be shown.

- Build 28: add a divider between Spaces and Process, with adjustable symmetric side padding and theme accent colors. Keep None and Line styles, migrating old Dot settings to Line. Omit the section divider when either section is hidden.

- Build 27: align per-display menu-bar backgrounds with the native button's content insets. Add None, Line and Dot display dividers with adjustable gap, thickness and color, preserving the old divider preference.

- Build 26: vertically center visible Space labels with app icons, preserving focus underlines and clipping long labels to their buttons.

- Build 25: omit explicitly invisible sticky windows from Space and sticky icon groups, including 1Password's ordered-out auxiliary window. Preserve real sticky windows, other-Space app icons and the Process recovery list.

- Build 24: use one single-line presentation and remove the redundant Detailed/Compact selector and two-line title renderer. Add Mint and Sky accent presets with system text and backdrop colors. Existing presentation preferences are ignored; other settings and theme overrides remain compatible.

- Build 23: include the build number, process architecture, Accessibility permission, event subscription status and safe error categories in copied diagnostics. Reading diagnostics does not query yabai or request permission.

- Build 22: report native subscription failures and recover with bounded retries; preserve an explicitly unfocused desktop even when Finder has visible windows; build Space context menus on demand from the latest snapshot.

- Build 21: confirm failed focused-window queries with a full snapshot before reporting a disconnect, so clicking the desktop does not briefly disable Space labels. Full-query failures still report errors.

- Build 20: keep unchanged per-display labels, buttons and images intact; redraw only changed cells and group backgrounds. Modifier-key events now update Command mouse passthrough without refreshing both menu-bar views.
- Use the native slots' WindowServer onscreen state instead of occlusion as the visibility gate, and explicitly finish layout after requesting a new slot width.

- Build 19: keep the previous menu-bar content inside its native slot while resizing, reserve stable Space-label widths, and update existing buttons when their ordered targets stay the same.

- Build 18: keep per-display menu-bar content visible while Command is held; let mouse events pass through to the native slot for reordering.

- Build 17: remove exclamation badges from menu-bar and floating-bar surfaces; keep connection and action-error details in the menu and Settings.

- Build 16: route clicks from both native menu-bar replicas to their Space/window targets and stop automatically opening the full menu on left-click. Keep right-click/Control-click menu access and Command reordering.
- Remove the trailing ellipsis and its extra 20 pt reservation; explicitly accept first clicks on nonactivating bar buttons.

- Build 15: fit the appearance preview to its actual content height and make current-Space underlines solid 2 pt lines.
- Allow floating bars to move into the menu-bar area and persist there; preserve old positions until the user drags them. Add a checked Lock Floating Bar Position context-menu item synchronized with Settings.

- Build 14: mark every display's visible Space independently of background opacity, and add optional lines between display groups.
- Keep This display only in the menu bar: reserve a native slot and anchor separate per-screen content inside it, with an ellipsis menu entry and Command reordering support. Hide content when its native slot is hidden or ambiguous; follow window notifications without polling.

- Build 13: use recorded mouse-event coordinates for immediate handle dragging, apply the final mouse-up position, and protect the bar from refreshes throughout the drag gesture.
- Add rounded glass/solid/transparent backdrops with independent tint, radius, padding, border and shadow settings. Match material appearance to the selected palette and fall back to solid for Reduce Transparency.
- Improve default Latte Space-name contrast while retaining custom colors and unfocused-background settings.
- Build 12: enable native panel shadows.

- Build 11: reuse a-bar's native AX observer, title cache/reconciliation, targeted focus queries and 300 ms movement delay. Remove the separate mouse-monitor/pressed-button implementation.
- Retire the old title shell signal when native title mapping is available. Add an explicit Accessibility setup button and port the original observer/JSON regression suites.

- Build 10: defer all event-driven queries while a mouse button is held, including title/focus updates; refresh once after release. Use the same field-projection mechanism as a-bar for snapshot reads.
- Settle missing mouse-up events after 300 ms of drag inactivity; retain the query gate while the button remains held.
- Build 9: add per-display top/floating bars, independent current-Space highlights, display-group spacing and saved floating positions.
- Add separate Space-name colors, transparent unfocused backgrounds, and Catppuccin/Tokyo Night presets.
- Refresh after mouse dragging ends instead of registering per-movement shell notifications; cache display metadata and reuse buttons for geometry-only changes.
- Stop rendering hidden settings previews; cover multi-display projection, drag persistence, signal migration and color migration in regression tests.

- Make Compact icons independently clickable; remove the fixed chevron and focus dot, with full-menu/settings access on every item's context menu.
- Show per-window layouts inside Spaces and hide Process by default; keep a switch to re-enable it.
- Reduce Space icon padding, separate icon/group gaps, enlarge layout icons and extend width/icon/font/corner ranges.
- Add focused/visible/inactive Space colors, a system-color reset and adjustable unfocused-window brightness.
- Preserve focused app representatives during deduplication and keep native-height icons clickable at narrow widths.

- Continue Space creation and deletion when yabai reports that the target display is already focused; preserve all other command failures.

- Add a-bar-style Spaces and Process groups inside the native menu bar, with direct per-item clicks and Space context menus.
- Add rename, adjacent swap, create and delete actions with serialized execution, stable Space IDs and visible errors.
- Add empty-Space / app / title filters, regex matching, app deduplication, a separate sticky group, all-Space Process scope, app/title modes, stack numbers and independent layout badges.
- Add font, monochrome icon, group opacity, corner and border controls; verify light/dark and high-font-size rendering.
- Keep button targets stable across an update during mouse tracking; cache text measurements before reducing a large display list.

- Add Space label formats, focus markers, window icon scope, icon size, spacing and a custom width, with saved settings and an immediate preview.
- Separate appearance from connection/startup settings. Mark retained preview data after disconnection or display sleep.
- Bound title measurement to items that can fit, and request only visible icons. Keep focus and accurate overflow counts with long labels and large window lists.
- Recover from display topology changes without requiring a screen-wake notification. Send Space selections even when a cached snapshot claims they are already focused.
- Keep menu structure changes in AppKit's update callback. Validate uncommitted executable paths before checking the connection.
- Stage and verify app/ZIP/checksum outputs before replacement; restore previous outputs if publication within `dist/` fails.

This candidate uses ad-hoc signing. [v1.0.0-rc.30](https://github.com/GladioFeng/yabai-menu/releases/tag/v1.0.0-rc.30) includes the universal build 30 archive and checksum; hosted CI has passed on Intel and Apple Silicon. Developer ID signing, notarization and macOS 13 runtime verification remain pending.

## 0.2.0 — preview

- Replace fixed polling with yabai, system, daemon-exit and socket-replacement events. Add bounded recovery and external command hooks.
- Keep the latest selection during an in-flight switch. Cancel outdated work across restarts and preserve action errors independently of successful reads.
- Display connection status and update age; pause queries while displays are asleep.
- Fit menu-bar content to compact/standard width budgets while retaining the focused Space and window.
- Add persistent display settings, executable selection, native login-item control, About, setup help and privacy-conscious diagnostic copying.
- Improve the menu's current-Space section, long-title handling and accessibility descriptions.
- Add a generated application icon, regression tests and a read-only CI workflow.

## 0.1.0 — local prototype

- Native menu-bar Space numbers, window icons, layout/sticky state and a switching menu.
- Independent yabai signal registration and universal local builds.
