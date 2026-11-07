# How Backdrop works

Tern plugins have two halves that share only a small key-value store. Backdrop's host half (`host.luau`) runs in Tern's session daemon and does the slow work: probing and converting files with ffmpeg. The window half (`window.luau`) runs once per window and turns the settings into a style sheet. Everything on screen is CSS; no Luau code runs per frame.

## The background is one style sheet on the window

The picture goes on `body`, the whole window, and Tern's main panel is made transparent so it shows through. Painting `main#panel` instead fails in the Rail and Tiles layouts, where the panel doesn't reach the window edges. The dim is an inset shadow over `body`, and the bar tints are separate gradients on the tab bar, side tabs and status line.

## Videos are sprite sheets

Tern's CSS can't play a video file, and `background-image` shows only the first frame of an animated GIF or WebP. What it does animate reliably is `@keyframes`, and only CSS animations keep an idle window redrawing; a background swapped from Luau froze until the next keypress.

The first version used one JPEG per frame and animated `background-image` through them. It flickered more the more you used Tern: Tern keeps only the images in use loaded, so each frame was loaded and decoded again, and a frame that wasn't ready in time painted nothing.

So an import packs the frames into at most three sheets with ffmpeg's `tile` filter, each at most 4096 px a side (Tern's limit). Every frame gets a 2 px border copied from its own edge pixels, so smoothing at the window edges never blends in the neighbouring frame. The plan tries every column count for one to three sheets and keeps the layout with the widest frames, preferring fewer sheets on a tie. The sheets are stacked background layers on `body`; each keyframe parks all sheets but one far off-screen and moves that one so the right cell shows, held with `step-end` until the next frame.

## A real cover crop

Positioning cells by percentage only lines up when the window has the frame's shape, so a split pane or a portrait monitor would stretch the picture. Instead the sheets are sized in window units, `calc(cols × max(100vw, ratio × 100vh))`, so one frame covers the window, and each keyframe places its cell's centre on the window's centre with `calc()` lengths. This is the approach [tern-custom-background](https://github.com/naraaalt/tern-custom-background) uses, adapted to several sheets and edge borders.

## Loop seams

Many clips don't end where they start. Before converting, Backdrop compares the last frame with the first (mean brightness difference). When the jump is clearly bigger than normal motion, the tail is crossfaded into the head with ffmpeg's `xfade`, so the loop starts a little into the clip and ends where it began.

## Media never goes in the plugin folder

Tern watches the plugin folder and reloads the whole plugin on any change inside it, which removes and reinstalls its style sheets: a visible flash. Imports therefore go to the plugin's data folder. A style sheet's `url()` can only name files inside the plugin folder, so the window half reads each sheet and inlines it as a `data:` URL. Encoding a sheet and installing the style sheet each run in their own callback, because Tern pauses a plugin whose callback runs past 50 ms; the encoded text is cached, so changing Dim doesn't encode again.

Old media is deleted only after a window reports that it switched to the new backdrop, or windows would flash Tern's own background between the two.

## Limits

- **Tern's selectors.** Backdrop styles `body`, `main#panel`, `nav#tabbar`, `aside#sidebar`, `footer#statusline` and the settings page's `.pf-*` classes. A Tern update that renames them needs a Backdrop update.
- **GPU memory.** Each decoded 4096 px sheet is about 64 MB.
- **Frame timing.** Videos play at an even rate of up to 15 fps; a GIF's per-frame delays aren't kept.
- **Style sheet size.** Inlined sheets make the style sheet a few megabytes; it's parsed once per import.
