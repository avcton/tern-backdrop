--!strict
-- Shared by both halves: turns whatever was pasted into a path, and says what's wrong with it.

local M = {}

M.IMAGE_EXT = { png = true, jpg = true, jpeg = true, webp = true, svg = true, bmp = true }
M.ANIM_EXT = { gif = true, mp4 = true, mov = true, m4v = true, webm = true, mkv = true }

function M.ext(path: string): string
	return string.lower(string.match(path, "%.(%w+)$") or "")
end

-- Accepts what people actually paste: Finder's "Copy as Pathname", a quoted path, a path
-- dragged into a shell (spaces escaped with \), a file:// URL, or ~/….
function M.normalize(raw: string): string
	local p = string.match(raw, "^%s*(.-)%s*$") or ""
	local quoted = string.match(p, "^'(.*)'$") or string.match(p, '^"(.*)"$')
	if quoted then
		p = quoted
	elseif string.sub(p, 1, 7) == "file://" then
		p = string.gsub(string.sub(p, 8), "^localhost", "")
		p = string.gsub(p, "%%(%x%x)", function(h)
			return string.char(tonumber(h, 16) :: number)
		end)
		-- file:///C:/Users/... names a Windows drive path.
		p = string.gsub(p, "^/(%a:[/\\])", "%1")
	elseif tern.runtime.os ~= "windows" and string.find(p, "\\", 1, true) then
		-- Shell escapes ("My\ Pictures") from a Unix terminal; on Windows "\" is the separator.
		p = string.gsub(p, "\\(.)", "%1")
	end
	if p == "~" or string.match(p, "^~[/\\]") then
		p = M.home() .. string.sub(p, 2)
	end
	return p
end

-- "image" or "video" for a usable file, else nil and a short reason.
function M.check(path: string): (string?, string?)
	if path == "" then
		return nil, "Enter a path to an image or video."
	end
	-- A pasted web link (YouTube and the like) is the most common non-path paste.
	if string.match(path, "^%a[%w+.-]*://") then
		return nil, "Web links aren't supported. Download the file first, then paste its path."
	end
	local absolute = string.sub(path, 1, 1) == "/" or string.match(path, "^%a:[\\/]") ~= nil
		or string.sub(path, 1, 2) == "\\\\"
	if not absolute then
		return nil, if tern.runtime.os == "windows"
			then "Use a full path, like C:\\Users\\you\\Pictures\\wallpaper.jpg or ~\\Pictures\\..."
			else "Use a full path, starting with / or ~."
	end
	if not tern.fs.exists(path) then
		return nil, "Nothing at that path."
	end
	if pcall(tern.fs.list, path) then
		return nil, "That's a folder. Add the file name."
	end
	local ext = M.ext(path)
	if M.IMAGE_EXT[ext] then
		return "image", nil
	elseif M.ANIM_EXT[ext] then
		return "video", nil
	end
	return nil, "Not an image or video (png, jpg, webp, svg, bmp, gif, mp4, mov, webm)."
end

-- HOME on macOS/Linux, USERPROFILE on Windows (where HOME, if set at all, may be a Git Bash
-- style /c/Users/... path).
function M.home(): string
	if tern.runtime.os == "windows" then
		return tern.getenv("USERPROFILE") or tern.getenv("HOME") or ""
	end
	return tern.getenv("HOME") or tern.getenv("USERPROFILE") or ""
end

-- "~/Pictures/Wallpapers" for a file's folder.
function M.folder(path: string): string
	local dir = string.match(path, "^(.*)[/\\][^/\\]*$") or path
	local home = M.home()
	local head = string.sub(dir, 1, #home)
	-- Windows paths are case-insensitive: c:\users\you is the same folder.
	if tern.runtime.os == "windows" then
		head, home = string.lower(head), string.lower(home)
	end
	if home ~= "" and head == home then
		return "~" .. string.sub(dir, #home + 1)
	end
	return dir
end

function M.name(path: string): string
	return string.match(path, "[^/\\]+$") or path
end

return M
