-- Host half: the Background Settings page and the "Set as Tern background" file action.
-- Both write the shared config to tern.kv; window.luau applies it (CSS needs the window half).

local ui = tern.ui

local DEFAULTS = { mode = "gradient", fit = "cover", dim = 30, speed = 18, intensity = 55, bar = 60, status = 60 }
local media = require("./media")
local MAX_BYTES = 25 * 1024 * 1024
-- Tern paints no background image over 4096 px a side; bigger stills are shrunk on import.
-- Video frames are cropped to roughly a Mac window's shape.
local SHEET_MAX = 4096
local FRAME_ASPECT = 1.55
-- Backdrops loop the whole clip within MAX_FRAMES frames, so long videos (a downloaded
-- YouTube video, say) would play at 1 fps from their first two minutes. Refuse them clearly.
local MAX_SECONDS = 30
local MAX_VIDEO_BYTES = 2 * 1024 * 1024 * 1024

local WINDOWS = tern.runtime.os == "windows"

-- Finds a tool on PATH, then in the usual install places: a daemon started by launchd or
-- systemd often has a shorter PATH than the user's shell.
local function find_tool(name: string): string?
	local file = if WINDOWS then name .. ".exe" else name
	local dirs = {}
	local path = tern.getenv("PATH") or tern.getenv("Path") or ""
	for dir in string.gmatch(path, if WINDOWS then "[^;]+" else "[^:]+") do
		table.insert(dirs, (string.gsub(dir, '^"(.*)"$', "%1")))
	end
	local home = media.home()
	if WINDOWS then
		local local_app = tern.getenv("LOCALAPPDATA") or (home .. "\\AppData\\Local")
		for _, d in {
			local_app .. "\\Microsoft\\WinGet\\Links", -- winget
			home .. "\\scoop\\shims", -- Scoop
			(tern.getenv("ProgramData") or "C:\\ProgramData") .. "\\chocolatey\\bin", -- Chocolatey
			(tern.getenv("ProgramFiles") or "C:\\Program Files") .. "\\ffmpeg\\bin",
			"C:\\ffmpeg\\bin",
		} do
			table.insert(dirs, d)
		end
	else
		for _, d in {
			"/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin", "/snap/bin",
			"/home/linuxbrew/.linuxbrew/bin", home .. "/.linuxbrew/bin", home .. "/.local/bin",
			home .. "/.nix-profile/bin", "/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin",
		} do
			table.insert(dirs, d)
		end
	end
	local sep = if WINDOWS then "\\" else "/"
	for _, dir in dirs do
		if dir ~= "" then
			local p = (string.gsub(dir, "[/\\]+$", "")) .. sep .. file
			if tern.fs.exists(p) then
				return p
			end
		end
	end
	return nil
end

local function install_hint(): string
	local os = tern.runtime.os
	if os == "macos" then
		return "Install it with: brew install ffmpeg"
	elseif os == "windows" then
		return "Install it with: winget install ffmpeg"
	end
	for _, pm in {
		{ "apt", "sudo apt install ffmpeg" }, { "dnf", "sudo dnf install ffmpeg" },
		{ "pacman", "sudo pacman -S ffmpeg" }, { "zypper", "sudo zypper install ffmpeg" },
		{ "apk", "sudo apk add ffmpeg" }, { "brew", "brew install ffmpeg" },
	} do
		if find_tool(pm[1]) then
			return "Install it with: " .. pm[2]
		end
	end
	return "Install ffmpeg with your package manager."
end

-- A process callback that errors (disk full, file vanished) would never report back and
-- leave the import stuck at "Importing…". This reports the error through `done` instead.
local function guard(done: (boolean, string) -> (), fn: (...any) -> ())
	return function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			done(false, "Import failed: " .. tostring(err))
		end
	end
end

-- "Converting the video took too long" / "… failed: <ffmpeg's first error line>".
local function proc_failed(what: string, r): string
	if r.timed_out then
		return what .. " took too long and was stopped."
	end
	local line = string.match(r.stderr or "", "[^\r\n]+")
	return what .. " failed" .. (if line then ": " .. string.sub(line, 1, 140) else ".")
end

local function human_time(s: number): string
	if s >= 3600 then
		return string.format("%.1f h", s / 3600)
	elseif s >= 60 then
		return string.format("%d min", math.floor(s / 60 + 0.5))
	end
	return string.format("%d s", math.floor(s + 0.5))
end

local function config()
	local c = tern.kv.get("config") or {}
	for k, v in DEFAULTS do
		if c[k] == nil then
			c[k] = v
		end
	end
	return c
end

local function save(c)
	c.rev = (c.rev or 0) + 1
	tern.kv.set("config", c)
end

-- Imported media lives in the plugin's data folder: Tern reloads the whole plugin on any
-- file change inside the plugin folder, and each reload drops and reinstalls the sheets,
-- so imports there flashed the backdrop. window.luau inlines these files as data: URLs,
-- since a sheet's url() can't name a file outside the plugin folder.
local MEDIA = tern.plugin.data .. "/media"

-- Removes old backgrounds' files, but keeps `keep` (the new one) and the one still showing:
-- each window swaps its sheet a moment after the config changes, and deleting the showing
-- frames first made windows flash Tern's own background between missing frames.
local function clear_assets(keep: string?)
	tern.fs.mkdir(MEDIA)
	local showing = config().image
	for _, name in tern.fs.list(MEDIA) do
		local p = MEDIA .. "/" .. name
		if p ~= keep and p ~= showing then
			pcall(tern.fs.remove, p)
		end
	end
end

-- Unique per attempt: since Tern 0.9.16 a reload leaves a running ffmpeg alive, and the
-- import's retry must not write over the orphan's files.
local function media_path(c, kind: string, ext: string?): string
	local p = string.format("%s/%s-%d-%d", MEDIA, kind, (c.rev or 0) + 1, math.floor(tern.now()))
	return if ext then p .. "." .. ext else p
end

-- Frames are packed into a few sprite sheets (ffmpeg's tile filter) and played by stepping
-- background-position. Tern 0.9.10 keeps only the images currently in use, so one file
-- per frame meant a load and decode on every frame, which flickered under load. A handful of
-- sheets stay loaded the whole time. Each sheet is at most SHEET_MAX a side; frames shrink
-- below FRAME_W when that's what it takes to stay within MAX_SHEETS.
local MAX_FRAMES = 120
local FRAME_W = 960
local MAX_SHEETS = 3
local BLEED = 2
local function plan_frames(duration: number, native_fps: number, src_w: number, src_h: number)
	local crop_w = math.min(src_w, math.floor(src_h * FRAME_ASPECT))
	local fps = math.min(15, math.max(1, math.floor(native_fps)))
	while fps > 1 and duration * fps > MAX_FRAMES do
		fps -= 1
	end
	-- One frame short of the estimate: if ffmpeg yields one fewer than duration × fps, the
	-- last sheet would end on a padded black cell and flash once per loop.
	local frames = math.max(1, math.min(MAX_FRAMES, math.floor(duration * fps) - 1))
	-- Each cell carries a BLEED px copy of its own edge pixels, so smoothing at the
	-- window edges blends in the same frame instead of the neighbouring cell.
	-- Tries 1 to MAX_SHEETS sheets and every column count, keeping the layout with the widest
	-- frames; fewer sheets win ties, since each decoded sheet costs memory.
	local cap = math.min(crop_w, FRAME_W)
	local best = { w = 0 }
	for sheets = 1, MAX_SHEETS do
		local per = math.ceil(frames / sheets)
		for cols = 1, per do
			local rows = math.ceil(per / cols)
			local by_w = math.floor(SHEET_MAX / cols) - 2 * BLEED
			local by_h = math.floor((math.floor(SHEET_MAX / rows) - 2 * BLEED) * FRAME_ASPECT)
			local w = math.min(cap, by_w, by_h)
			w -= w % 2
			if w > best.w then
				best = { w = w, cols = cols, rows = rows, sheets = math.ceil(frames / (cols * rows)) }
			end
		end
		if best.w >= cap then
			break
		end
	end
	local w = math.max(2, best.w)
	local h = math.max(2, math.floor(w / FRAME_ASPECT / 2) * 2)
	return { fps = fps, frames = frames, w = w, h = h, cols = best.cols, rows = best.rows, sheets = best.sheets }
end

local function parse_rate(r: string): number
	local n, d = tonumber(string.match(r, "^(%d+)/") or ""), tonumber(string.match(r, "/(%d+)$") or "")
	if n and d and d ~= 0 then
		return n / d
	end
	return tonumber(r) or 24
end

-- Video or GIF -> sprite sheets in MEDIA/anim-<rev>-<ms>/, played by window.luau as a
-- CSS background-image animation (the only kind of animation Tern keeps drawing when idle).
local function import_animation(path: string, done: (boolean, string) -> ())
	local ffmpeg = find_tool("ffmpeg")
	-- The ffprobe shipped beside this ffmpeg, so the two always match.
	local sibling = ffmpeg and (string.gsub(ffmpeg, "ffmpeg(%.?[EXexe]*)$", "ffprobe%1"))
	local ffprobe = if sibling and tern.fs.exists(sibling) then sibling else find_tool("ffprobe")
	if not ffprobe or not ffmpeg then
		done(false, "Videos and GIFs need ffmpeg, which isn't installed. " .. install_hint())
		return
	end
	tern.process.run({ ffprobe, "-v", "error", "-select_streams", "v:0",
		"-show_entries", "stream=width,height,r_frame_rate,nb_frames,duration:format=duration,size",
		"-of", "json", path },
		{ timeout_ms = 15000 }, guard(done, function(probe)
			if probe.status ~= 0 then
				done(false, if probe.timed_out then "Reading the video took too long."
					else "Couldn't read that file as a video. It may be damaged or an unsupported format.")
				return
			end
			local info = tern.json.decode(probe.stdout)
			local st = info.streams and info.streams[1]
			if not st or not st.width then
				done(false, "That file has no video in it (audio only?).")
				return
			end
			local rate = parse_rate(st.r_frame_rate or "24/1")
			local count = tonumber(st.nb_frames or "")
			local duration = tonumber(st.duration or "") or tonumber(info.format and info.format.duration or "")
				or (count and count / rate) or 0
			if duration <= 0 then
				duration = 1 / rate -- a one-frame GIF
			end
			if duration > MAX_SECONDS then
				done(false, string.format("That video is %s long. Backdrops loop the whole clip, so use one under %d s (trim it first).",
					human_time(duration), MAX_SECONDS))
				return
			end
			local size = tonumber(info.format and info.format.size or "")
			if size and size > MAX_VIDEO_BYTES then
				done(false, string.format("That file is %.1f GB. Use a smaller export of the clip.", size / 1024 ^ 3))
				return
			end
			-- Loop seam: clips whose last frame doesn't match the first snap back every loop. When
			-- the jump is clearly bigger than normal motion, the tail is crossfaded into the head
			-- (the loop then starts K seconds in and ends where it began), which hides the seam.
			local sample = "scale=160:-2,format=gray"
			tern.process.run({ ffmpeg, "-v", "error", "-i", path, "-sseof", "-0.1", "-i", path, "-lavfi",
				string.format("[0:v]trim=end_frame=1,%s[a];[1:v]trim=end_frame=1,%s[b];[a][b]blend=all_mode=difference,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-", sample, sample),
				"-f", "null", "-" }, { timeout_ms = 30000 }, guard(done, function(seam_r)
				local seam = tonumber(string.match(seam_r.stdout or "", "YAVG=([%d.]+)") or "") or 0
				local fade = 0
				if seam > 1.5 and duration >= 1.5 then
					fade = math.clamp(duration * 0.2, 0.3, 1.0)
				end
				local length = duration - fade
				local p = plan_frames(length, rate, st.width, st.height)
				local c = config()
				local dir = media_path(c, "anim")
				local finish = string.format("fps=%d,crop='min(iw,ih*%.4f)':'min(ih,iw/%.4f)',scale=%d:%d:flags=lanczos,pad=iw+%d:ih+%d:%d:%d,fillborders=left=%d:right=%d:top=%d:bottom=%d:mode=smear,trim=end_frame=%d,tile=%dx%d",
					p.fps, FRAME_ASPECT, FRAME_ASPECT, p.w, p.h, 2 * BLEED, 2 * BLEED, BLEED, BLEED,
					BLEED, BLEED, BLEED, BLEED, p.frames, p.cols, p.rows)
				local graph = if fade > 0
					then string.format("[0:v]split[a][b];[a]trim=start=%.3f,setpts=PTS-STARTPTS[m];[b]trim=end=%.3f,setpts=PTS-STARTPTS[h];[m][h]xfade=transition=fade:duration=%.3f:offset=%.3f,%s",
						fade, fade, fade, duration - 2 * fade, finish)
					else "[0:v]" .. finish
				tern.fs.mkdir(dir)
				tern.process.run({ ffmpeg, "-y", "-v", "error", "-i", path, "-filter_complex", graph,
					"-frames:v", tostring(p.sheets), "-q:v", "3", dir .. "/s%02d.jpg" },
					{ cwd = tern.plugin.dir, timeout_ms = 120000 }, guard(done, function(r)
						local made = if tern.fs.exists(dir) then #tern.fs.list(dir) else 0
						if r.status ~= 0 or made ~= p.sheets then
							pcall(tern.fs.remove, dir)
							done(false, proc_failed("Converting the video", r))
							return
						end
						clear_assets(dir)
						local cc = config()
						cc.image, cc.source, cc.mode = dir, path, "image"
						cc.anim = { dir = dir, frames = p.frames, fps = p.fps, cols = p.cols, rows = p.rows, sheets = p.sheets,
							w = p.w, h = p.h, bleed = BLEED }
						save(cc)
						done(true, string.format("Animated backdrop: %d frames at %d fps%s%s", p.frames, p.fps,
							if fade > 0 then ", loop smoothed" else "",
							if p.fps < 10 then " (long clip, so it's choppier; shorter loops look smoother)" else ""))
					end))
			end))
		end))
end

-- Up to six files used before, newest first, for the Recent menu.
local function remember(path: string)
	local list = { path }
	for _, p in tern.kv.get("recent") or {} do
		if p ~= path and #list < 6 then
			table.insert(list, p)
		end
	end
	tern.kv.set("recent", list)
end

-- Drops Recent entries whose file is gone (renamed, moved, deleted). The current file stays
-- even when missing: the file row reports it instead.
local function prune_recent(current: string?)
	local list, kept = tern.kv.get("recent") or {}, {}
	for _, p in list do
		if p == current or tern.fs.exists(p) then
			table.insert(kept, p)
		end
	end
	if #kept ~= #list then
		tern.kv.set("recent", kept)
	end
end

-- Whether the saved copy of the current backdrop exists. Imports from before the media
-- moved to the data folder name assets/ paths, which load removes, so they count as gone.
local function copy_present(c): boolean
	return c.image ~= nil and tern.fs.exists(c.image)
end

-- Imports an image (copied into MEDIA, so window.luau can inline it) or a
-- video (converted to frames). `finished` runs once, possibly later.
local function import_image(raw: string, finished: (boolean, string) -> ())
	local path = media.normalize(raw)
	local kind, problem = media.check(path)
	if not kind then
		finished(false, problem or "Can't use that file.")
		return
	end
	local function done(ok: boolean, msg: string)
		if ok then
			remember(path)
			prune_recent(path)
		end
		finished(ok, msg)
	end
	local ext = media.ext(path)
	if kind == "video" then
		local ok, err = pcall(import_animation, path, done)
		if not ok then
			done(false, tostring(err))
		end
		return
	end
	local c = config()
	local function finish(rel: string, msg: string)
		local cc = config()
		cc.image, cc.source, cc.mode, cc.anim = rel, path, "image", nil
		save(cc)
		done(true, msg)
	end
	-- Tern paints nothing for an image over SHEET_MAX px a side, so rasters go through ffmpeg,
	-- which shrinks them to fit (smaller ones keep their size). SVG scales by itself.
	local ffmpeg = if ext ~= "svg" then find_tool("ffmpeg") else nil
	if ffmpeg then
		-- ffmpeg writes the final file itself: no read-back through Lua memory, no temp copy.
		local rel = media_path(c, "bg", if ext == "png" then "png" else "jpg")
		tern.fs.mkdir(MEDIA)
		local fit = string.format("scale=w='min(iw,%d)':h='min(ih,%d)':force_original_aspect_ratio=decrease", SHEET_MAX, SHEET_MAX)
		tern.process.run({ ffmpeg, "-y", "-v", "error", "-i", path, "-vf", fit, "-frames:v", "1", "-q:v", "2", rel },
			{ cwd = tern.plugin.dir, timeout_ms = 60000 }, guard(done, function(r)
				if r.status ~= 0 or not tern.fs.exists(rel) then
					pcall(tern.fs.remove, rel)
					done(false, proc_failed("Preparing the image", r))
					return
				end
				clear_assets(rel)
				finish(rel, "Backdrop set")
			end))
		return
	end
	local ok, bytes = pcall(tern.fs.read, path, MAX_BYTES)
	if not ok then
		done(false, "Couldn't read that image, or it's over 25 MB. " .. install_hint() .. " to use large images.")
		return
	end
	clear_assets(nil)
	local rel = media_path(c, "bg", ext)
	tern.fs.write(rel, bytes)
	finish(rel, if ext == "svg" then "Backdrop set"
		else "Backdrop set. Without ffmpeg, images over 4096 px won't show. " .. install_hint())
end

local function window_value(c, key: string)
	local w = c.win or {}
	if w[key] ~= nil then
		return w[key]
	end
	return (tern.kv.get("tern") or {})[key]
end

-- Change… asks the window half (which owns cx:prompt) to open the path field. Its 0.4 s check
-- can sleep while a still-image window sits idle, which left the click doing nothing until
-- other input arrived. Two follow-up renders shortly after deliver frames that wake it.
local function request_pick(s, cx)
	tern.kv.set("pick_req", { id = tern.now() })
	for _, ms in { 450, 900 } do
		tern.timer(ms, function()
			s.wake = (s.wake or 0) + 1
			pcall(cx.render, cx)
		end)
	end
end

local function view(s)
	local c = config()
	local t = tern.kv.get("tern") or {}
	local ranges = t.ranges or {}
	local op_r = ranges.opacity or { min = 0, max = 100 }
	local bl_r = ranges.blur or { min = 0, max = 100 }
	local materials = {}
	for _, m in (t.materials or { "Glass" }) do
		table.insert(materials, { value = m, label = m })
	end

	local importing = (tern.kv.get("import_req") or {}).id ~= nil
		and (tern.kv.get("import_req") or {}).id ~= (tern.kv.get("import_result") or {}).id
	local is_anim = c.anim ~= nil
	-- Two sections per page, each named for what's in it, so the page label ("Background"),
	-- section titles and row labels don't repeat each other.
	local content = {
		{ id = "mode", label = "Source", changed = c.mode ~= DEFAULTS.mode, defaultLabel = "Gradient",
			control = { k = "choice", style = "segmented", value = c.mode, options = {
				{ value = "gradient", label = "Gradient" },
				{ value = "image", label = "Media" },
				{ value = "off", label = "Off" },
			} } },
	}
	local look = {}
	local function add(row)
		table.insert(content, row)
	end
	local function add_look(row)
		table.insert(look, row)
	end
	if c.mode == "image" then
		local res = tern.kv.get("import_result") or {}
		local hint
		if importing then
			hint = "Importing…"
		elseif c.source and not tern.fs.exists(c.source) and copy_present(c) then
			hint = "Original moved or renamed. Still showing the saved copy."
		elseif c.source and not copy_present(c) then
			hint = "The saved copy is gone and the original can't be found. Choose the file again."
		elseif c.source then
			-- Line 1 is the hint: folder · type. Tern's hints are one line (it drops newlines),
			-- so window.luau draws the video details as a second line under it.
			hint = media.folder(c.source) .. " · " .. (if c.anim then "Video" else "Image")
		elseif tern.runtime.os == "macos" then
			hint = "Paste a file's path. In Finder, ⌥⌘C copies it."
		elseif tern.runtime.os == "windows" then
			hint = "Paste a file's path. In Explorer, Ctrl+Shift+C copies it."
		else
			hint = "Paste a file's path. Most file managers copy it with Ctrl+C."
		end
		add({ id = "file", label = if c.source then media.name(c.source) else "No file chosen", hint = hint,
			-- When the saved copy is gone the hint already says so; don't repeat it as a warning.
			warning = if not importing and res.ok == false and copy_present(c) then res.msg else nil,
			control = { k = "action", act = "choose",
				label = if importing then "Importing…" elseif c.source then "Change…" else "Choose…" } })
		local recent = {}
		for _, p in tern.kv.get("recent") or {} do
			if p ~= c.source and tern.fs.exists(p) then
				table.insert(recent, { value = p, label = media.name(p), detail = media.folder(p) })
			end
		end
		if #recent > 0 and c.source then
			table.insert(recent, 1, { value = c.source, label = media.name(c.source),
				detail = if tern.fs.exists(c.source) then "Current" else "Current · original missing" })
			add({ id = "recent", label = "Recent", hint = "Switch back to a file you used before.",
				control = { k = "choice", style = "menu", value = c.source, options = recent } })
		end
		if not is_anim then
			add_look({ id = "fit", label = "Fit", changed = c.fit ~= DEFAULTS.fit, defaultLabel = "Cover",
				control = { k = "choice", style = "segmented", value = c.fit, options = {
					{ value = "cover", label = "Cover" },
					{ value = "contain", label = "Contain" },
					{ value = "tile", label = "Tile" },
				} } })
		end
		add_look({ id = "dim", label = "Dim", hint = "Fades the image so text stays readable.",
			changed = c.dim ~= DEFAULTS.dim, defaultLabel = tostring(DEFAULTS.dim) .. "%",
			control = { k = "number", value = c.dim, min = 0, max = 90, step = 5, unit = "%" } })
	elseif c.mode == "gradient" then
		add_look({ id = "intensity", label = "Strength", changed = c.intensity ~= DEFAULTS.intensity,
			defaultLabel = tostring(DEFAULTS.intensity) .. "%",
			control = { k = "number", value = c.intensity, min = 5, max = 100, step = 5, unit = "%" } })
		add_look({ id = "speed", label = "Loop length", hint = "Seconds per sweep. Lower is faster.",
			changed = c.speed ~= DEFAULTS.speed, defaultLabel = tostring(DEFAULTS.speed) .. "s",
			control = { k = "number", value = c.speed, min = 4, max = 60, step = 2, unit = "s" } })
	end

	-- From Tern's own setting docs: opacity is the panels' alpha; blur only applies to the
	-- Clear material and blurs the desktop, which an image or video background covers.
	local material = window_value(c, "material") or materials[1].value
	local panels = {
		{ id = "material", label = "Material", hint = "Solid: opaque panels. Glass and Clear: see-through panels.",
			control = { k = "choice", value = material, options = materials } },
	}
	if material ~= "Solid" then
		table.insert(panels, { id = "opacity", label = "Panel opacity",
			hint = "How solid Tern's panels are. Lower shows more of the background through them.",
			control = { k = "number", value = window_value(c, "opacity") or 100, min = op_r.min, max = op_r.max, step = 5, unit = "%" } })
	end
	if material == "Clear" then
		table.insert(panels, { id = "blur", label = "Desktop blur", hint = "Blurs your desktop behind the window.",
			disabled = if c.mode == "image" then "Your image covers the desktop, so there's nothing to blur. Set Source to Off to see it." else nil,
			control = { k = "number", value = window_value(c, "blur") or 0, min = bl_r.min, max = bl_r.max, step = 4 } })
	end
	-- Bar tints are window chrome: grouped here, disabled (not hidden) while the background
	-- is off, since there's nothing behind the bars to tint against.
	local no_bg = if c.mode == "off" then "No backdrop to tint against. Set a Source on the Background page." else nil
	local bars = {
		{ id = "bar", label = "Top bar tint", hint = "Darkens the tab bar so tabs stay readable.",
			disabled = no_bg, changed = c.bar ~= DEFAULTS.bar, defaultLabel = tostring(DEFAULTS.bar) .. "%",
			control = { k = "number", value = c.bar, min = 0, max = 100, step = 5, unit = "%" } },
		{ id = "status", label = "Widget bar tint", hint = "Same for the widget bar along the window's foot, when it's shown.",
			disabled = no_bg, changed = c.status ~= DEFAULTS.status, defaultLabel = tostring(DEFAULTS.status) .. "%",
			control = { k = "number", value = c.status, min = 0, max = 100, step = 5, unit = "%" } },
	}

	local sections
	if s.page == "window" then
		sections = { { id = "panels", title = "Panels", rows = panels }, { id = "bars", title = "Bars", rows = bars } }
	else
		sections = { { id = "content", title = "Content", rows = content } }
		if #look > 0 then
			table.insert(sections, { id = "look", title = "Look", rows = look })
		end
	end

	return {
		main = ui.col({
			ui.node("prefs", {
				title = "Backdrop",
				pages = {
					{ id = "background", label = "Background", icon = "image" },
					{ id = "window", label = "Window", icon = "sliders" },
				},
				page = s.page,
				editing = s.editing,
				lead = if s.page == "window"
					then "How Tern's panels and bars sit over the backdrop. Applies to every Tern window."
					else "What shows behind Tern: an animated gradient or your own media.",
				sections = sections,
			}),
			-- Fills the pane below the settings element (Tern shrinks it while a menu is
			-- open): a click there closes the menu, as a click anywhere else on the page does.
			-- `title` carries s.wake, so request_pick's follow-up renders differ and reach the window.
			ui.el("div", { role = "backdrop.dismiss", grow = 1, title = tostring(s.wake or 0), actions = { click = "dismiss" } }),
		}),
	}
end

local function set_window(c, key: string, value)
	c.win = c.win or {}
	c.win[key] = value
	c.win_rev = (c.win_rev or 0) + 1
end

-- One import at a time. A request that arrives mid-import waits, and only the newest one
-- waiting runs: two concurrent imports could delete each other's files in MEDIA.
local busy = false
local waiting: { id: string, path: string, cb: ((boolean, string) -> ())? }? = nil

local function run_import(job: { id: string, path: string, cb: ((boolean, string) -> ())? })
	if busy then
		waiting = job
		return
	end
	busy = true
	local settled = false
	local function finish(ok: boolean, msg: string)
		if settled then
			return
		end
		settled = true
		-- Every window toasts results it hasn't seen (window.luau).
		tern.kv.set("import_result", { id = job.id, ok = ok, msg = msg })
		if job.cb then
			pcall(job.cb, ok, msg)
		end
		busy = false
		local nxt = waiting
		waiting = nil
		if nxt then
			run_import(nxt)
		end
	end
	local ok, err = pcall(import_image, job.path, finish)
	if not ok then
		finish(false, tostring(err))
	end
end

-- Imports requested by the window half's path field (it can't run ffmpeg-heavy work in its
-- 50 ms budget). Polled here on the host worker, so it works with or without the settings
-- page open. `started` lives in memory: after a reload, an unfinished request runs again
-- instead of showing "Importing…" forever.
local started: string? = nil
local function poll_imports()
	local req = tern.kv.get("import_req")
	local res = tern.kv.get("import_result") or {}
	if req and req.id and req.id ~= res.id and req.id ~= started then
		started = req.id
		run_import({ id = req.id, path = req.path })
	end
	-- Once a window reports it switched to the current background, the previous one's files
	-- can go. Not mid-import: the new frames being written aren't in the config yet.
	local current = config().image
	if not busy and current and tern.kv.get("applied") == current and tern.kv.get("pruned") ~= current then
		tern.kv.set("pruned", current)
		clear_assets(current)
	end
	tern.timer(500, poll_imports)
end
tern.timer(500, poll_imports)

-- An orphaned ffmpeg (see media_path) has finished writing files nothing uses: prune again.
tern.on("process_exit", function()
	tern.kv.set("pruned", false)
end)

-- On load: tidy Recent, and if the saved copy is gone (fresh install or update), import the
-- original again so the backdrop comes back by itself. If the original is gone too, the file
-- row asks to choose it again, and the windows toast why.
tern.timer(1000, function()
	local c = config()
	prune_recent(c.source)
	-- Older imports (files in the plugin folder's assets/, or sheets without the frame size
	-- the cover crop needs) are re-imported. Once the current one lives in MEDIA, the old
	-- folder goes; deleting it reloads the plugin once more, a one-time cost.
	local legacy = c.image ~= nil and string.sub(c.image, 1, #MEDIA) ~= MEDIA
	if not (legacy and c.mode == "image") and tern.fs.exists("assets") then
		pcall(tern.fs.remove, "assets")
	end
	local outdated = legacy or (c.anim ~= nil and c.anim.w == nil)
	if c.mode ~= "image" or not c.source or (copy_present(c) and not outdated) then
		return
	end
	if tern.fs.exists(c.source) then
		tern.kv.set("import_req", { id = string.format("restore:%.3f", tern.now()), path = c.source })
	else
		-- Request and result share an id, so the import poller sees nothing pending; a result
		-- alone made it re-run the previous request.
		local id = string.format("restore:%.3f", tern.now())
		tern.kv.set("import_req", { id = id, path = c.source })
		tern.kv.set("import_result", { id = id, ok = false,
			msg = "Backdrop's saved copy is gone and " .. media.name(c.source) .. " can't be found. Choose it again." })
	end
end)

-- What the settings page shows that can change behind its back (imports, other windows,
-- Tern's own settings). The page re-renders only when this changes, not every second.
local function signature(): string
	local c = tern.kv.get("config") or {}
	return tern.json.encode({
		c.rev, c.win_rev,
		(tern.kv.get("import_req") or {}).id, (tern.kv.get("import_result") or {}).id,
		tern.kv.get("tern"), tern.kv.get("recent"),
		-- Renames happen outside Tern: include whether the original still exists.
		c.source and tern.fs.exists(c.source),
	})
end

tern.block.define("settings", {
	init = function(cx, _args, saved)
		local s: { [string]: any } = { page = (saved and saved.page) or "background", cx = cx }
		local last = signature()
		local function poll()
			if s.closed then
				return
			end
			local now = signature()
			if now ~= last then
				last = now
				-- A pane closed with Tern's own x has no close hook; rendering it fails, ending the chain.
				if not pcall(cx.render, cx) then
					return
				end
			end
			tern.timer(1000, poll)
		end
		tern.timer(1000, poll)
		return s
	end,
	title = function()
		return "Backdrop"
	end,
	view = view,
	save = function(s)
		return { page = s.page }
	end,
	event = function(s, ev, cx)
		local c = config()
		if ev.ev == "action" then
			if ev.act == "page" then
				s.page = ev.value
			elseif ev.act == "close" and ev.value == nil then
				s.closed = true
				cx:exit(0)
			elseif ev.act == "choose" then
				-- cx:prompt only exists in the window half; it watches this request.
				request_pick(s, cx)
			elseif ev.act == "close" or ev.act == "dismiss" then
				s.editing = nil
			end
			return
		end
		-- The Recent menu: open on click, close on pick or click-away.
		if ev.ev == "activate" and ev.item == "recent" then
			s.editing = { row = "recent", option = c.source }
			return
		end
		if ev.ev == "change" and ev.item == "recent" then
			s.editing = nil
			if ev.value and ev.value ~= c.source then
				tern.kv.set("import_req", { id = tern.now() .. ":" .. ev.value, path = ev.value })
			end
			return
		end
		if ev.ev ~= "change" then
			return
		end
		local item, value = ev.item, ev.value
		if item == "opacity" or item == "blur" or item == "material" then
			if value == nil then
				return
			end
			set_window(c, item, value)
		elseif value == nil then
			c[item] = DEFAULTS[item]
		else
			c[item] = value
		end
		if item == "mode" and value == "image" and not c.image then
			request_pick(s, cx)
		end
		save(c)
	end,
	key = function(s, k, cx)
		if k.name == "escape" then
			-- An open menu (Recent) closes first; Esc again closes the page.
			if s.editing then
				s.editing = nil
				return true
			end
			s.closed = true
			cx:exit(0)
			return true
		end
		return false
	end,
})

-- Files › Open with › Set as Tern background: import, report, close.
tern.block.define("apply", {
	init = function(cx, args)
		local path = args[1]
		local s = { msg = "Importing " .. (path or "nothing") .. "…" }
		local function finish(ok: boolean, msg: string)
			s.msg = msg
			pcall(cx.render, cx)
			tern.timer(50, function()
				pcall(cx.exit, cx, if ok then 0 else 1)
			end)
		end
		-- After init returns, so `s` is the block's state before any render. Goes through the
		-- same one-at-a-time queue as the settings page; the windows toast the result.
		tern.timer(0, function()
			if path then
				run_import({ id = string.format("apply:%.3f", tern.now()), path = path, cb = finish })
			else
				finish(false, "No file given")
			end
		end)
		return s
	end,
	view = function(s)
		return { main = ui.col({ ui.text(s.msg) }) }
	end,
})
