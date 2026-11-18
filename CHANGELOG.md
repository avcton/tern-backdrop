# Changelog

All notable changes to Backdrop are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [1.3.0] - 2026-11-18

### Changed

- **Switch Background** stays open after you pick a file: a glass ring with a rolling accent comet runs round that card's border and the step and percentage show under its name. Once the new background is showing and the window has settled, the ring lights up, holds for a moment, and the picker fades out. Esc hides it and the switch carries on. If the switch fails, the reason shows under the cards so you can pick another.
- On the picker, each picture shows what the file is with an icon in its bottom-right corner (a play mark for videos, a picture for images), the current file's card included; the **Video** pill is gone, and **Current** is the only mark on top. The marks are frosted white in light mode instead of always dark.

### Fixed

- A switch from the picker no longer waits for you to move the mouse or type before the new background shows, when the window was sitting idle.

## [1.2.0] - 2026-11-17

### Changed

- `ctrl+alt+b` now opens **Backdrop: Switch Background**; **Backdrop: Settings** moves to `ctrl+alt+shift+b`.
- The switcher's action is now `plugin.backdrop.switcher` (was `plugin.backdrop.switch`); rename it in any `keybinds` you added.
- **Backdrop: Switch Background** always shows in the palette. With nothing in Recent yet, it (and `ctrl+alt+b`) shows a toast pointing to Backdrop: Settings instead of doing nothing.

### Fixed

- The settings page no longer scrolls on into an empty second screen, and its left nav rail runs the full height of the pane again, also while the Recent menu is open.

## [1.1.1] - 2026-11-16

### Fixed

- A window whose Backdrop callback ran past Tern's 500 ms wall-time cap (often the computer sleeping mid-call) stopped picking up new settings until a plugin reload; it now resumes on its own.
- On the Background page, Source's Gradient / Media / Off buttons sit beside the label again instead of dropping to a line of their own, flush left (Tern 0.9.23 reserves room for the hidden Reset button).

## [1.1.0] - 2026-11-13

### Added

- **Backdrop: Switch Background** in the palette: a small floating grid of your Recent files with thumbnails (made with ffmpeg). Arrow keys and Enter (or a click) switch the background; Esc or clicking elsewhere closes it.

### Changed

- The settings command is now **Backdrop: Settings**, next to **Backdrop: Switch Background** in the palette.

## [1.0.1] - 2026-11-12

### Changed

- Needs Tern 0.9.17 or later. "Status bar tint" is now "Widget bar tint", after the bar Tern renamed.

### Fixed

- The widget bar tint shows again; it styled Tern's old status line, gone since 0.9.17.
- A plugin reload during an import no longer has the retry write over files from the previous ffmpeg run, which Tern 0.9.16 keeps running.

## [1.0.0] - 2026-11-07

First public release.

### Added

- Three sources behind the whole window: an animated gradient, a still image, or a video or GIF (up to 30 seconds).
- Videos play from sprite sheets with a cover crop at any window shape, loop-seam smoothing for clips that don't loop cleanly, and an edge border on every frame so nothing bleeds in at the window edges.
- Settings page (`ctrl+alt+b`) with a Background page (source, file, Recent, fit, dim, gradient strength and loop length) and a Window page (material, panel opacity, desktop blur, top and status bar tints).
- "Set as Tern background" in Open with for image and video files.
- Recent list of the last six files, and automatic re-import when the saved copy goes missing.
- macOS, Linux and Windows support: ffmpeg is found on `PATH` or in each system's usual install folders, and paths in each system's style are accepted.
- Honours the system's reduce motion setting by holding a video on its first frame.
