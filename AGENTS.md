# AGENTS.md

Backdrop is a [Tern](https://stencil.so/tern) plugin written in Luau: an animated gradient, still image or video behind the whole window, bar tints, window look controls and a settings page. There is no build step; Tern loads the `.luau` files directly.

## Layout

| File | Runs in | Owns |
| --- | --- | --- |
| `plugin.toml` | manifest | id `backdrop`, blocks `settings` (the page), `switch` (the palette's Recent picker) and `apply` (Open with, "Set as Tern background") |
| `host.luau` | host half (daemon worker) | imports (ffprobe/ffmpeg), sprite-sheet planning, media files, Recent, the settings block's view and events |
| `window.luau` | window half (one VM per window) | turning the config into CSS (`tern.css("bg"…)`, `"bar"`), applying window settings, mirroring Tern's settings, the path prompt, toasts |
| `switch.css` | manifest `styles` | the Switch background picker's card grid |
| `media.luau` | both | path normalizing and checks, per-OS home folder, display helpers |
| `tern.d.luau` | tooling | generated types, committed so CI can type-check; regenerate with `tern plugin types .` after a Tern update |

The halves share nothing but `tern.kv` (`kv.json` in the plugin's data folder). Keys: `config` (bumps `rev` on every save), `recent`, `import_req` / `import_result`, `pick_req` / `pick_done`, `tern` (mirrored settings), `win_applied`, `applied`, `pruned`.

## Develop

```sh
tern plugin link .          # use this checkout in place
tern plugin reload backdrop # after editing (or let the watcher do it)
tern plugin types .         # refresh tern.d.luau
```

Logs: macOS `~/Library/Logs/Tern/tern.log` (window half) and `tern-daemon.log` (host half). Inspect the live window with `tern ctl dump SEL`, `tern ctl css`, `tern ctl stats`, `tern ctl shot NAME` (PNG under `~/target/shots/tern/live/`). Open the page with `tern ctl plugins run plugin.backdrop.settings`.

## Invariants (each one was learned from a bug)

- **Never write files inside the plugin folder at runtime.** Tern watches it recursively and reloads the plugin on any change, which drops and reinstalls the sheets (a visible flash). Imports go to `tern.plugin.data .. "/media"` (picker thumbnails to `/thumbs`); the window half inlines them as `data:` URLs because a sheet's `url()` can only name files in the plugin folder.
- **Every window callback has a 50 ms budget.** Tern pauses the plugin's timers for a few seconds when one runs over. Heavy work (encoding a sheet, installing the CSS) gets its own `tern.timer(0, …)`. ffmpeg work stays in the host half.
- **Video is sprite sheets played by CSS `@keyframes`**, never Lua-driven frame swaps (Tern only redraws an idle window for CSS animations) and never one file per frame (Tern drops images not in use, which flickered). At most `MAX_SHEETS` sheets of at most 4096 px a side; each cell carries a `BLEED` px edge border.
- **The keyframes name is unique per import** (`backdrop-play-<rev>`); a fixed name kept the old clip playing.
- **The background goes on `body`**, with `main#panel` made transparent; `#panel` doesn't cover the window in Rail and Tiles layouts.
- **Delete old media only after a window reports it applied the new one** (`applied == config.image`), or windows flash Tern's own background.
- Paths and tools must work on macOS, Linux and Windows: use `media.home()`, `find_tool()`, and never assume `/` or Homebrew.
- Every error reaches the user as a toast and is logged.

## Style

- Comments only for a non-obvious why, one short line where possible, about 80 columns.
- No em dashes anywhere (code, comments, docs, commit messages).
- Conventional Commits: `type(scope): summary` with a bullet body.

## Verify

There is no test suite. After a change, reload, then exercise the path in a real window: import an image and a video, switch Source, change Dim, open both settings pages, and check the logs for `backdrop … took` warnings or errors. `tern ctl css NAME FILE` parse-checks generated CSS without touching the window if you scope selectors to a class that matches nothing.
