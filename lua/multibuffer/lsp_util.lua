local M = {}

local root_links = nil
local last_cwd = nil

--- Recursively scans a directory for symlinks and junctions.
--- @param dir string The directory to scan.
--- @param depth integer Maximum recursion depth.
--- @param results { logical: string, real: string }[] Accumulator for results.
--- @param seen_reals table<string, boolean> Tracker to avoid cycles and redundant work.
local function scan_links(dir, depth, results, seen_reals)
	if depth <= 0 then
		return
	end

	local handle = vim.uv.fs_scandir(dir)
	if not handle then
		return
	end

	local sep = package.config:sub(1, 1)

	while true do
		local name, type = vim.uv.fs_scandir_next(handle)
		if not name then
			break
		end

		if name == "." or name == ".." or name == ".git" or name == "node_modules" then
			goto continue
		end

		local full_path = dir:gsub("[/\\]$", "") .. sep .. name
		local lstat = vim.uv.fs_lstat(full_path)

		-- Ignore broken links or unreadable paths
		if not lstat then
			goto continue
		end

		if lstat.type == "link" then
			local real = vim.uv.fs_realpath(full_path)
			if real then
				-- Normalize real path for comparison
				local real_norm = real:gsub("[/\\]$", "") .. sep
				if not seen_reals[real_norm] then
					table.insert(results, {
						logical = full_path,
						real = real_norm,
					})
					seen_reals[real_norm] = true

					-- If the symlink points to a directory, scan inside it for more links.
					-- This is common in Bazel's 'external' or 'execroot' structures.
					local stat = vim.uv.fs_stat(real)
					if stat and stat.type == "directory" then
						scan_links(full_path, depth - 1, results, seen_reals)
					end
				end
			end
		elseif lstat.type == "directory" then
			scan_links(full_path, depth - 1, results, seen_reals)
		end
		::continue::
	end
end

--- Scans the current working directory for symlinks and junctions,
--- caching their logical-to-real path mappings.
--- @return { logical: string, real: string }[]
local function get_root_links()
	local cwd = vim.fn.getcwd()
	if root_links and last_cwd == cwd then
		return root_links
	end

	root_links = {}
	last_cwd = cwd

	local seen_reals = {}
	-- Scan up to 3 levels deep to catch common monorepo/bazel structures.
	scan_links(cwd, 3, root_links, seen_reals)

	-- Sort by real path length descending so we match the most specific (longest) paths first.
	table.sort(root_links, function(a, b)
		return #a.real > #b.real
	end)

	return root_links
end

--- Resolves a path via realpath only if the result is within the current working directory.
---
--- It also handles the "reverse" case for build systems like Bazel: if a file is returned
--- as a real path in a cache but is reachable via a symlink/junction in the project root,
--- it will be mapped back to that logical root path.
--- @param path string
--- @return string
function M.resolve_local_path(path)
	-- Normalize path separators to avoid mixed slashes on Windows
	path = path:gsub("\\", "/")

	local realpath = vim.uv.fs_realpath(path)
	if not realpath then
		return path
	end
	realpath = realpath:gsub("\\", "/")

	local cwd = vim.fn.getcwd():gsub("\\", "/")
	local sep = "/"

	-- 1. Standard resolution: Is the real path already under the CWD?
	local real_cwd = vim.uv.fs_realpath(cwd)
	if real_cwd then
		real_cwd = real_cwd:gsub("\\", "/")
		local real_cwd_prefix = real_cwd:gsub("/$", "") .. sep
		if realpath:sub(1, #real_cwd_prefix) == real_cwd_prefix or realpath == real_cwd then
			return realpath
		end
	end

	-- 2. Reverse mapping: Does the real path point into a target of a local root symlink?
	local links = get_root_links()
	for _, link in ipairs(links) do
		local link_real = link.real:gsub("\\", "/")
		if realpath:sub(1, #link_real) == link_real then
			local remainder = realpath:sub(#link_real + 1)
			local logical = link.logical:gsub("\\", "/")
			return logical .. sep .. remainder
		end
	end

	return path
end

return M
