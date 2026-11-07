-- Window half: renders the background CSS from tern.kv "config" (written by host.luau),
-- applies requested window settings, and mirrors Tern's current ones for the settings page.

local media = require("./media")

local DEFAULTS = { mode = "gradient", fit = "cover", dim = 30, speed = 18, intensity = 55, bar = 60, status = 60 }
local WINDOW_KEYS = { "opacity", "blur", "material" }

local function cfg()
	local c = tern.kv.get("config") or {}
	for k, v in DEFAULTS do
		if c[k] == nil then
			c[k] = v
		end
	end
	return c
end

-- Media files live in the plugin's data folder (host.luau), which a sheet's url() can't
-- name, so they're inlined as data: URLs. Encoding megabytes isn't free, so each file's URL
-- is cached until a different file is asked for (a dim change reuses it).
local MIME = { jpg = "image/jpeg", jpeg = "image/jpeg", png = "image/png", gif = "image/gif",
	webp = "image/webp", svg = "image/svg+xml", bmp = "image/bmp" }
local url_cache: { [string]: string } = {}
local cached_for: string? = nil
local function data_url(path: string): string
	local hit = url_cache[path]
	if hit then
		return hit
	end
	local mime = MIME[media.ext(path)] or "image/jpeg"
	local url = string.format("url(data:%s;base64,%s)", mime, tern.base64.encode(tern.fs.read(path)))
	url_cache[path] = url
	return url
end

-- An animation is a few sprite sheets (host.luau): cols × rows cells each, in order, every
-- cell a w × h frame with a `bleed` px border of its own edge pixels. Tern only redraws an
-- idle window for CSS animations, so playback is pure @keyframes, one per frame, held with
-- step-end. Per-frame image files flickered: Tern drops images not in use, so each frame
-- was loaded again.
-- The sheets are stacked background layers, each data: URL written once; keyframes only
-- move them, parking every sheet but the playing one far off-screen.
-- Cover crop: the sheets are sized in window units so one frame covers the window, and each
-- keyframe places its cell's centre on the window's centre (lengths, not percentages,
-- which would only line up when the window has the frame's shape).
-- Keyframe values can't be !important, so position stays unimportant in the base rule;
-- animations override Tern's normal rules anyway.
local OFF = "-100000px -100000px"
local function anim_css(c): string
	local a = c.anim
	local dim = math.clamp(c.dim, 0, 90) / 100
	local per = a.cols * a.rows
	local pw, ph = a.w + 2 * a.bleed, a.h + 2 * a.bleed
	local ratio = a.w / a.h
	local fw = string.format("max(100vw, %.6f * 100vh)", ratio)
	local fh = string.format("max(calc(100vw / %.6f), 100vh)", ratio)
	local function positions(i: number): string
		local s, cell = i // per, i % per
		local col, row = cell % a.cols, cell // a.cols
		local list = table.create(a.sheets, OFF)
		list[s + 1] = string.format("calc(50vw - %.6f * %s) calc(50vh - %.6f * %s)",
			(col * pw + a.bleed) / a.w + 0.5, fw, (row * ph + a.bleed) / a.h + 0.5, fh)
		return table.concat(list, ", ")
	end
	local keys = table.create(a.frames)
	for i = 0, a.frames - 1 do
		table.insert(keys, string.format("%.3f%%{background-position:%s}", i / a.frames * 100, positions(i)))
	end
	local images = table.create(a.sheets)
	local sizes = table.create(a.sheets)
	local size = string.format("calc(%.6f * %s) calc(%.6f * %s)", a.cols * pw / a.w, fw, a.rows * ph / a.h, fh)
	for s = 1, a.sheets do
		table.insert(images, data_url(string.format("%s/s%02d.jpg", a.dir, s)))
		table.insert(sizes, size)
	end
	-- The keyframes name is unique per import. With a fixed name, Tern kept running the old
	-- keyframes when the sheet was replaced (the new clip never showed).
	local name = "backdrop-play-" .. (string.match(a.dir, "(%d+)$") or "0")
	return string.format(
		[[
main#panel { background: transparent !important; }
body {
  box-shadow: inset 0 0 0 4000px rgb(0 0 0 / %.2f) !important;
  background-color: transparent !important;
  background-image: %s !important;
  background-size: %s !important;
  background-repeat: no-repeat !important;
  image-rendering: high-quality;
  background-position: %s;
  animation: %s %.3fs step-end infinite;
}
@keyframes %s {
%s
}
@media (prefers-reduced-motion: reduce) {
  body { animation: none; }
}
]],
		dim, table.concat(images, ", "), table.concat(sizes, ", "),
		positions(0), name, a.frames / a.fps, name, table.concat(keys, "\n")
	)
end

-- The background goes on body, the whole window. main#panel only spans the full window in
-- Studio and Float: Rail puts the tab rail beside it and Tiles insets it under the tab bar,
-- which left Tern's plain glass showing there. #panel itself is made transparent.
-- Tern's own background rules need !important to lose.
-- radial-gradient doesn't render in Tern 0.9.5; linear-gradient and url() do.
local PANEL_CLEAR = "main#panel { background: transparent !important; }\n"
local function css_for(c): string
	local legacy = c.image ~= nil and string.sub(c.image, 1, #tern.plugin.data) ~= tern.plugin.data
	if c.mode == "image" and c.image and (legacy or not tern.fs.exists(c.image)) then
		-- Older imports (assets/ in the plugin folder) show nothing until host.luau re-imports.
		return PANEL_CLEAR
	elseif c.mode == "image" and c.anim then
		return if c.anim.w then anim_css(c) else PANEL_CLEAR
	elseif c.mode == "image" and c.image then
		local dim = math.clamp(c.dim, 0, 90) / 100
		local size, repeat_ = "cover", "no-repeat"
		if c.fit == "contain" then
			size = "contain"
		elseif c.fit == "tile" then
			size, repeat_ = "auto", "repeat"
		end
		return PANEL_CLEAR .. string.format(
			[[
body {
  background-color: transparent !important;
  background-image: linear-gradient(rgb(0 0 0 / %.2f), rgb(0 0 0 / %.2f)), %s !important;
  background-size: 100%% 100%%, %s !important;
  background-repeat: no-repeat, %s !important;
  background-position: center, center !important;
  image-rendering: high-quality;
}
]],
			dim, dim, data_url(c.image), size, repeat_
		)
	elseif c.mode == "gradient" then
		local a = math.clamp(c.intensity, 5, 100) / 100
		return PANEL_CLEAR .. string.format(
			[[
body {
  background: linear-gradient(120deg,
      rgb(124 58 237 / %.2f), rgb(14 165 233 / %.2f),
      rgb(236 72 153 / %.2f), rgb(124 58 237 / %.2f)) !important;
  background-size: 300%% 300%% !important;
  animation: backdrop-drift %ds ease-in-out infinite alternate;
}
@keyframes backdrop-drift {
  0%%   { background-position: 0%% 50%%; }
  100%% { background-position: 100%% 50%%; }
}
]],
			a, a * 0.9, a * 0.8, a, math.clamp(c.speed, 4, 60)
		)
	end
	return "/* backdrop: off */"
end

-- The tab bar and status bar have no background of their own, so a busy wallpaper shows
-- straight through. Each gets a tint that fades toward the panels (no hard edge where the
-- strip meets the rounded panels and the gaps between them), with rounded inner corners.
local function bar_css(c): string
	local css = {
		-- Our settings page: Tern sizes the prefs element itself (inline, so CSS can't
		-- stretch it) and shrinks it while a menu (Recent) is open, so its dark backing
		-- stopped short. Paint the same backing on the full-height region behind it.
		".sf-main[data-surface='plugin.backdrop.settings'] { background: rgb(15 15 20) !important; position: relative; }",
		-- A layer behind the page covering the whole pane: clicks below the shrunken page land
		-- on it and close the menu (host.luau's "dismiss"), as clicks elsewhere on the page do.
		".sf-main[data-surface='plugin.backdrop.settings'] > .sf-prefs { position: relative; z-index: 1; }",
		".sf-main[data-surface='plugin.backdrop.settings'] > [data-role='backdrop.dismiss'] { position: absolute !important; top: 0; left: 0; right: 0; bottom: 0; z-index: 0; }",
		-- The settings page's brand mark is Tern's (omp's) by default and has no prop; draw ours.
		".sf-main[data-surface='plugin.backdrop.settings'] .pf-mark { background: url(icon.svg) center / contain no-repeat !important; box-shadow: none !important; border-radius: 6px !important; }",
		".sf-main[data-surface='plugin.backdrop.settings'] .pf-mark > svg { display: none !important; }",
		-- Tern's settings page shows a search field once it's wide enough, but searching is left
		-- to the plugin. Two short pages don't need it, so hide it instead of a dead field.
		".sf-main[data-surface='plugin.backdrop.settings'] .pf-search { display: none !important; }",
		-- Tern 0.9.10's changed-row dot sits a fixed 20 px from the row top, which misses the
		-- title in rows Tern centres vertically. Draw it beside the title line instead.
		".sf-main[data-surface='plugin.backdrop.settings'] .pf-dot { display: none !important; }",
		".sf-main[data-surface='plugin.backdrop.settings'] .pf-row.changed .pf-lbl .t { position: relative; }",
		".sf-main[data-surface='plugin.backdrop.settings'] .pf-row.changed .pf-lbl .t::before { content: ''; position: absolute; left: -11px; top: 0; bottom: 0; margin: auto 0; width: 6px; height: 6px; border-radius: 50%; background: var(--accent); }",
	}
	-- The file row's second line (video details): Tern's row hints are a single line, so it's
	-- drawn under the hint with ::after. Rebuilt with this sheet whenever the config changes.
	if c.mode == "image" and c.anim then
		table.insert(css, string.format(
			".sf-main[data-surface='plugin.backdrop.settings'] .pf-row[data-row='file'] .pf-lbl .h::after { content: '%d frames at %d fps'; display: block; }",
			c.anim.frames, c.anim.fps))
	end
	if c.mode ~= "off" then
		local a = math.clamp(c.bar, 0, 100) / 100
		table.insert(css, string.format(
			"nav#tabbar { background-color: transparent !important; background-image: linear-gradient(rgb(18 18 22 / %.2f) 60%%, rgb(18 18 22 / 0)) !important; border-radius: 0 0 12px 12px !important; }",
			a))
		-- Side tabs (⌘⇧S): the tabs move into aside#sidebar, a full-height left column. Tint
		-- the column instead, fading toward the panes; the nav inside it then stays clear.
		table.insert(css, string.format(
			"aside#sidebar { background-color: transparent !important; background-image: linear-gradient(90deg, rgb(18 18 22 / %.2f) 75%%, rgb(18 18 22 / 0)) !important; border-radius: 0 12px 12px 0 !important; }\naside#sidebar nav#tabbar { background-image: none !important; }",
			a))
		-- Rail: the tab bar itself is the full-height left column; tint it sideways like side tabs.
		table.insert(css, string.format(
			"html.lay-rail nav#tabbar { background-image: linear-gradient(90deg, rgb(18 18 22 / %.2f) 75%%, rgb(18 18 22 / 0)) !important; border-radius: 0 12px 12px 0 !important; }",
			a))
		table.insert(css, string.format(
			"footer#statusline { background-color: transparent !important; background-image: linear-gradient(rgb(18 18 22 / 0), rgb(18 18 22 / %.2f) 40%%) !important; border-radius: 12px 12px 0 0 !important; }",
			math.clamp(c.status, 0, 100) / 100))
	end
	return table.concat(css, "\n")
end

-- Publishes Tern's current window settings (and their ranges) for the settings page.
local function mirror(cx)
	local s = cx.settings
	local cur = { opacity = s:get("opacity"), blur = s:get("blur"), material = s:get("material") }
	local prev = tern.kv.get("tern")
	if prev and prev.opacity == cur.opacity and prev.blur == cur.blur and prev.material == cur.material then
		return
	end
	local ok_o, d_o = pcall(s.describe, s, "opacity")
	local ok_b, d_b = pcall(s.describe, s, "blur")
	local ok_m, d_m = pcall(s.describe, s, "material")
	cur.ranges = { opacity = ok_o and d_o.range or nil, blur = ok_b and d_b.range or nil }
	cur.materials = ok_m and d_m.enum or nil
	tern.kv.set("tern", cur)
end

local applied_rev = -1
local loop = 0
local last_mirror = -math.huge
local last_err: string? = nil

-- Tern pauses a plugin's timer hook for a few seconds after one callback runs past its
-- budget. Log anything slow so the cause shows up in tern.log.
local function warn_if_slow(what: string, t0: number)
	local ms = tern.now() - t0
	if ms > 25 then
		tern.log.warn(string.format("backdrop %s took %.1f ms (Tern's limit is 50)", what, ms))
	end
end

local function request_import(path: string)
	tern.kv.set("import_req", { id = tern.now() .. ":" .. path, path = path })
end

-- Tern's own text field (full editing, paste, selection), prefilled with the current file and
-- selected, so typing or pasting replaces it. A bad path reopens the field with what was typed
-- and the reason as a toast, so a typo costs one keystroke, not the whole path.
local function prompt_path(cx, value: string?)
	cx:prompt({
		value = value or cfg().source or "",
		placeholder = "Paste a path, e.g. ~/Pictures/wallpaper.jpg",
		icon = "image",
		action = "set background",
	}):next(function(text, _err, ncx)
		if text == nil then
			return
		end
		local path = media.normalize(text)
		local _, problem = media.check(path)
		if problem then
			local target = ncx or cx
			target:toast("error", problem, path ~= "" and path or nil)
			prompt_path(target, text)
			return
		end
		request_import(path)
	end)
end

local last_result = (tern.kv.get("import_result") or {}).id

local function tick(cx, token: number)
	if token ~= loop then
		return
	end
	local t0 = tern.now()
	local ok, err = pcall(function()
		local c = cfg()
		local rev = c.rev or 0
		if rev ~= applied_rev then
			applied_rev = rev
			-- Encoding each media file and installing the sheet each get their own callback and
			-- 50 ms budget: together, a large clip's sheets ran past it.
			local c1 = cfg()
			-- Only the current backdrop's encoded files stay cached.
			if c1.image ~= cached_for then
				url_cache, cached_for = {}, c1.image
			end
			local files = {}
			if c1.mode == "image" and c1.anim and c1.anim.w then
				for s = 1, c1.anim.sheets do
					table.insert(files, string.format("%s/s%02d.jpg", c1.anim.dir, s))
				end
			elseif c1.mode == "image" and c1.image then
				table.insert(files, c1.image)
			end
			local function install()
				local t1 = tern.now()
				local c2 = cfg()
				tern.css("bg", css_for(c2))
				-- Tells the host half this window now shows c2.image, so it can delete the old one.
				tern.kv.set("applied", c2.image or false)
				warn_if_slow("background sheet", t1)
			end
			local function warm(i: number)
				if i > #files then
					tern.timer(0, install)
					return
				end
				tern.timer(0, function()
					local t1 = tern.now()
					pcall(data_url, files[i])
					warn_if_slow("encoding " .. media.name(files[i]), t1)
					warm(i + 1)
				end)
			end
			warm(1)
			tern.timer(0, function()
				tern.css("bar", bar_css(cfg()))
			end)
		end
		local win_rev = c.win_rev or 0
		if cx and c.win and win_rev ~= (tern.kv.get("win_applied") or 0) then
			local patch = {}
			for _, k in WINDOW_KEYS do
				if c.win[k] ~= nil then
					patch[k] = c.win[k]
				end
			end
			cx.settings:set_many(patch)
			tern.kv.set("win_applied", win_rev)
		end
		-- Tern's own window settings change rarely; checking them every 2 s is plenty.
		if cx and t0 - last_mirror >= 2000 then
			last_mirror = t0
			mirror(cx)
		end
		-- "Change…" on the settings page (host half) asks for the path field here.
		local pick = tern.kv.get("pick_req")
		if cx and pick and pick.id ~= tern.kv.get("pick_done") then
			tern.kv.set("pick_done", pick.id)
			prompt_path(cx)
		end
		local res = tern.kv.get("import_result")
		if cx and res and res.id ~= last_result then
			last_result = res.id
			cx:toast(if res.ok then "success" else "error", res.msg)
		end
	end)
	if not ok then
		tern.log.warn("backdrop tick failed", err)
		-- Toast each distinct failure once; it repeats every tick otherwise.
		if cx and tostring(err) ~= last_err then
			last_err = tostring(err)
			pcall(cx.toast, cx, "error", "Backdrop hit an error", string.sub(tostring(err), 1, 160))
		end
	else
		last_err = nil
	end
	warn_if_slow("tick", t0)
	tern.timer(400, function(next_cx)
		tick(next_cx, token)
	end)
end

local function start()
	loop += 1
	local token = loop
	tern.timer(0, function(cx)
		tick(cx, token)
	end)
end

start()

tern.command({
	id = "settings",
	title = "Backdrop settings",
	icon = "image",
	keys = { "ctrl+alt+b" },
	run = function(cx)
		-- One settings pane: focus it if it's already open.
		for _, p in cx.session:panes() do
			if p.block == "backdrop.settings" then
				cx.layout:focus(p.pane)
				return
			end
		end
		if cx:new_block("backdrop.settings", nil, "beside") == nil then
			cx:toast("error", "Backdrop settings unavailable", "The plugin's host half isn't loaded. Try: tern plugin reload")
		end
	end,
})
