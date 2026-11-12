# Changelog

All notable changes to Backdrop are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

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
