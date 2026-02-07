--- @class MultibufRegion
--- @field start_row integer 0-indexed start row
--- @field end_row integer 0-indexed end row (inclusive)

--- @class MultibufAddBufOptions
--- @field buf integer Buffer handle
--- @field regions MultibufRegion[] List of regions to include

--- @class MultibufBufInfo
--- @field buf integer Buffer handle
--- @field source_extmark_ids integer[] IDs of extmarks tracking source regions
--- @field region_extmark_ids integer[] IDs of extmarks tracking regions in multibuffer
--- @field virt_expand_extmark_ids integer[] IDs of extmarks for expander UI
--- @field pending_regions MultibufRegion[]? List of regions to be set up once loaded
--- @field loading boolean? Whether this buffer is currently being loaded/processed

--- @class MultibufInfo
--- @field bufs MultibufBufInfo[] Info about included buffers
--- @field header string[]? Custom header lines

--- @class MultibufBufListener
--- @field multibufs integer[] List of multibuffers listening to this source
--- @field change_autocmd_id integer ID of the TextChanged autocmd

--- @class MultibufSetupOptions
--- @field render_multibuf_title (fun(bufnr: integer): any[])? Custom title renderer
--- @field render_expand_lines (fun(opts: multibuffer.RenderExpandLinesOptions): any[])? Custom expander renderer
--- @field expander_max_lines integer? Max lines to show as dimmed text in expander

--- @class multibuffer.RenderExpandLinesOptions
--- @field expand_direction "above"|"below"|"both"
--- @field count integer Number of hidden lines
--- @field window integer Window handle
--- @field bufnr integer Buffer handle
--- @field start_row integer 0-indexed start row of hidden lines

--- @type table<integer, MultibufInfo>
local multibufs = {}

--- @type table<integer, MultibufBufListener>
local buf_listeners = {}

--- @type table<integer, MultibufAddBufOptions[]>
local pending_adds = {}

--- @param list any[]
--- @param item any
local function list_insert_unique(list, item)
	for _, v in ipairs(list) do
		if v == item then
			return
		end
	end
	table.insert(list, item)
end

--- @param num number
--- @param min number
--- @param max number
--- @return number
local function clamp(num, min, max)
	if num < min then
		return min
	elseif num > max then
		return max
	end
	return num
end

local M = {
	--- @type MultibufSetupOptions
	user_opts = {},
	--- @type integer Namespace for structural elements (signs, titles)
	multibuf__ns = nil,
	--- @type integer Namespace for live highlight projection
	multibuf_hl_ns = nil,
}

--- @param args table
local function multibuf_buf_changed(args)
	local listener_info = buf_listeners[args.buf]
	if listener_info then
		for _, multibuf in ipairs(listener_info.multibufs) do
			M.multibuf_reload(multibuf)
		end
	end
end

--- @param mb integer
--- @param buf_info MultibufBufInfo
local function load_source_buf(mb, buf_info)
	local buf = buf_info.buf
	if vim.api.nvim_buf_is_loaded(buf) and #buf_info.source_extmark_ids > 0 then
		buf_info.loading = false
		return false
	end

	vim.fn.bufload(buf)

	local line_count = vim.api.nvim_buf_line_count(buf)
	local regions = buf_info.pending_regions or {}
	buf_info.source_extmark_ids = {}

	for _, region in ipairs(regions) do
		table.insert(
			buf_info.source_extmark_ids,
			vim.api.nvim_buf_set_extmark(buf, M.multibuf__ns, clamp(region.start_row, 0, line_count - 1), 0, {
				end_row = clamp(region.end_row + 1, 0, line_count),
				end_right_gravity = true,
			})
		)
	end
	buf_info.pending_regions = nil
	buf_info.loading = false

	if not buf_listeners[buf] then
		local id = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
			buffer = buf,
			callback = multibuf_buf_changed,
		})
		buf_listeners[buf] = { change_autocmd_id = id, multibufs = { mb } }
	else
		list_insert_unique(buf_listeners[buf].multibufs, mb)
	end

	return true
end

--- @param mb integer
local function process_pending_adds(mb)
	local pending = pending_adds[mb]
	if not pending or #pending == 0 then
		pending_adds[mb] = nil
		return
	end

	local info = multibufs[mb]
	if not info then
		pending_adds[mb] = nil
		return
	end

	-- For visibility-based loading, we just add them as "unloaded" entries
	for _, opts in ipairs(pending) do
		table.insert(info.bufs, {
			buf = opts.buf,
			source_extmark_ids = {},
			region_extmark_ids = {},
			virt_expand_extmark_ids = {},
			pending_regions = opts.regions,
		})
	end

	pending_adds[mb] = nil
	M.multibuf_reload(mb)
end

--- @param buf integer
--- @return integer|nil
local function get_buf_win(buf)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == buf then
			return win
		end
	end
	return nil
end

--- Generates 2-digit sign strings for line numbers
--- @param line_num integer
--- @return string[]
local function get_line_number_signs(line_num)
	local str = tostring(line_num)
	local result = {}
	for i = #str, 1, -2 do
		local start = math.max(1, i - 1)
		table.insert(result, 1, str:sub(start, i))
	end
	return result
end

--- @param buf integer
--- @param extmark integer
--- @return integer, integer
local function get_extmark_range(buf, extmark)
	local result = vim.api.nvim_buf_get_extmark_by_id(buf, M.multibuf__ns, extmark, { details = true })
	if not result or not result[1] then
		return 0, 0
	end
	return result[1], result[3].end_row
end

--- @param b_info MultibufBufInfo
local function merge_buffer_regions(b_info)
	local buf = b_info.buf
	if b_info.pending_regions then
		local regions = b_info.pending_regions
		if #regions <= 1 then
			return
		end

		table.sort(regions, function(a, b)
			return a.start_row < b.start_row
		end)

		local merged = {}
		local current = regions[1]

		for i = 2, #regions do
			local next_r = regions[i]
			if next_r.start_row <= current.end_row + 1 then
				current.end_row = math.max(current.end_row, next_r.end_row)
			else
				table.insert(merged, current)
				current = next_r
			end
		end
		table.insert(merged, current)
		b_info.pending_regions = merged
		b_info.region_extmark_ids = {}
	else
		local ranges = {}
		for _, sid in ipairs(b_info.source_extmark_ids) do
			local s, e = get_extmark_range(buf, sid)
			table.insert(ranges, { s = s, e = e })
		end

		if #ranges <= 1 then
			return
		end

		table.sort(ranges, function(a, b)
			return a.s < b.s
		end)

		local merged = {}
		local current = ranges[1]

		for i = 2, #ranges do
			local next_r = ranges[i]
			if next_r.s <= current.e then
				current.e = math.max(current.e, next_r.e)
			else
				table.insert(merged, current)
				current = next_r
			end
		end
		table.insert(merged, current)

		-- Update extmarks
		for _, sid in ipairs(b_info.source_extmark_ids) do
			vim.api.nvim_buf_del_extmark(buf, M.multibuf__ns, sid)
		end
		b_info.source_extmark_ids = {}
		b_info.region_extmark_ids = {}
		for _, r in ipairs(merged) do
			table.insert(
				b_info.source_extmark_ids,
				vim.api.nvim_buf_set_extmark(buf, M.multibuf__ns, r.s, 0, {
					end_row = r.e,
					end_right_gravity = true,
				})
			)
		end
	end
end

--- @param mb integer
--- @param line integer
--- @return integer|nil b_idx, integer|nil s_idx
local function find_slice_index_at_line(mb, line)
	local info = multibufs[mb]
	if not info then
		return nil, nil
	end
	local marks = vim.api.nvim_buf_get_extmarks(
		mb,
		M.multibuf__ns,
		{ line, 0 },
		{ line, -1 },
		{ details = true, overlap = true }
	)
	for _, m in ipairs(marks) do
		for b_idx, b in ipairs(info.bufs) do
			for s_idx, rid in ipairs(b.region_extmark_ids) do
				if m[1] == rid then
					return b_idx, s_idx
				end
			end
		end
	end
	return nil, nil
end

--- @return string[]
local function create_multibuf_header()
	return { " ─────── " }
end

--- @param s string
--- @param tabstop integer
--- @return string
local function expand_tabs(s, tabstop)
	local result = ""
	local col = 0
	for i = 1, #s do
		local char = s:sub(i, i)
		if char == "\t" then
			local spaces = tabstop - (col % tabstop)
			result = result .. string.rep(" ", spaces)
			col = col + spaces
		else
			result = result .. char
			col = col + 1
		end
	end
	return result
end

--- @param bufnr integer
--- @return any[]
local function render_multibuf_title(bufnr)
	if M.user_opts.render_multibuf_title then
		local success, lines_or_error = pcall(M.user_opts.render_multibuf_title, bufnr)
		if success then
			return lines_or_error
		end
		vim.notify(lines_or_error, vim.log.levels.ERROR)
	end
	return M.default_render_multibuf_title(bufnr)
end

--- @param opts multibuffer.RenderExpandLinesOptions
--- @return any[]
local function render_expand_lines(opts)
	if M.user_opts.render_expand_lines then
		local success, lines_or_error = pcall(M.user_opts.render_expand_lines, opts)
		if success then
			return lines_or_error
		end
		vim.notify(lines_or_error, vim.log.levels.ERROR)
	end
	return M.default_render_expand_lines(opts)
end

-- ──────── Structural Rendering ────────

--- @param multibuf integer
--- @param target_row integer
--- @param source_row integer
local function place_line_number_signs(multibuf, target_row, source_row)
	local signs = get_line_number_signs(source_row + 1)
	for digit_idx, text in ipairs(signs) do
		if #text == 1 then
			text = " " .. text
		end -- Pad single digits
		vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, target_row, 0, {
			sign_text = text,
			sign_hl_group = "LineNr",
			priority = 100 - digit_idx,
		})
	end
end

--- @param multibuf integer
--- @param target_row integer
--- @param opts multibuffer.RenderExpandLinesOptions
local function place_expander(multibuf, target_row, opts)
	vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, target_row, 0, {
		virt_lines = render_expand_lines(opts),
		virt_lines_above = true,
		virt_lines_leftcol = true,
		priority = 20001,
	})
end

-- ──────── Highlight Projection (Live UI Mirroring) ────────

--- Projects highlights from source to multibuffer using ephemeral extmarks.
--- @param multibuf integer
--- @param source_buf integer
--- @param s_start integer 0-indexed start line in source
--- @param s_end integer 0-indexed end line in source
--- @param target_start integer 0-indexed start line in multibuffer
local function project_highlights(multibuf, source_buf, s_start, s_end, target_start)
	-- 1. Project Treesitter Highlights
	local ft = vim.api.nvim_get_option_value("filetype", { buf = source_buf })
	local lang = vim.treesitter.language.get_lang(ft)

	if lang and pcall(vim.treesitter.language.add, lang) then
		pcall(function()
			-- Use { error = false } to prevent hard crashes
			local parser = vim.treesitter.get_parser(source_buf, lang, { error = false })
			if not parser then
				return
			end

			parser:parse({ s_start, s_end })
			parser:for_each_tree(function(tstree, tree)
				local tlang = tree:lang()
				local query = vim.treesitter.query.get(tlang, "highlights")
				if not query then
					return
				end

				-- Cache multibuffer lines for column clamping (performance)
				local mb_lines =
					vim.api.nvim_buf_get_lines(multibuf, target_start, target_start + (s_end - s_start), false)

				for id, node, metadata in query:iter_captures(tstree:root(), source_buf, s_start, s_end) do
					local sr, sc, er, ec = node:range()

					-- Map coordinates to multibuffer
					local tr = target_start + (sr - s_start)
					local ter = target_start + (er - s_start)

					-- Safety: Ensure we don't project outside the target slice or buffer
					if tr >= target_start then
						-- Column Clamping: Neovim errors if end_col > line_length
						local line_idx = tr - target_start
						local target_line = mb_lines[line_idx + 1] or ""
						local max_col = #target_line

						local safe_sc = math.min(sc, max_col)
						local safe_ec = ec and math.min(ec, max_col)

						pcall(vim.api.nvim_buf_set_extmark, multibuf, M.multibuf_hl_ns, tr, safe_sc, {
							end_row = ter,
							end_col = safe_ec,
							hl_group = "@" .. query.captures[id] .. "." .. tlang,
							priority = tonumber(metadata.priority) or 100,
							ephemeral = true,
						})
					end
				end
			end)
		end)
	end

	-- 2. Project Persistent Extmarks (LSP Diagnostics, Gitsigns, etc.)
	local persistent = vim.api.nvim_buf_get_extmarks(source_buf, -1, { s_start, 0 }, { s_end, -1 }, { details = true })
	for _, mark in ipairs(persistent) do
		local _, r, c, d = unpack(mark)
		if d.ns_id ~= M.multibuf__ns then
			local tr = target_start + (r - s_start)
			local ter = d.end_row and (target_start + (d.end_row - s_start))

			-- Only project if it falls within our target range
			if tr >= target_start then
				d.id, d.ns_id, d.end_row, d.ephemeral = nil, nil, ter, true
				pcall(vim.api.nvim_buf_set_extmark, multibuf, M.multibuf_hl_ns, tr, c, d)
			end
		end
	end
end

-- ──────── Core Multibuffer Management ────────

--- @param multibuf integer
function M.multibuf_reload(multibuf)
	local info = multibufs[multibuf]
	if not info then
		return
	end
	local win = get_buf_win(multibuf)
	local cursor_pos = win and vim.api.nvim_win_get_cursor(win)
	local source_buf, source_line
	if win then
		source_buf, source_line = M.multibuf_get_buf_at_line(multibuf, cursor_pos[1] - 1)
	end

	vim.api.nvim_buf_clear_namespace(multibuf, M.multibuf__ns, 0, -1)

	local header = info.header or create_multibuf_header()
	local all_lines = { unpack(header) }
	local virt_name_indices = {}
	local virt_expand_lnums = {}

	-- 1. Build Text Content
	for _, buf_info in ipairs(info.bufs) do
		table.insert(virt_name_indices, #all_lines)
		if buf_info.pending_regions then
			for _, region in ipairs(buf_info.pending_regions) do
				table.insert(virt_expand_lnums, #all_lines)
				local count = (region.end_row - region.start_row) + 1
				for _ = 1, count do
					table.insert(all_lines, "") -- empty line while temporarily loading
				end
			end
		else
			for _, source_extmark_id in ipairs(buf_info.source_extmark_ids) do
				local s_start, s_end = get_extmark_range(buf_info.buf, source_extmark_id)
				table.insert(virt_expand_lnums, #all_lines)
				vim.list_extend(all_lines, vim.api.nvim_buf_get_lines(buf_info.buf, s_start, s_end, true))
			end
		end
	end
	table.insert(virt_expand_lnums, #all_lines)

	vim.api.nvim_set_option_value("modifiable", true, { buf = multibuf })
	vim.api.nvim_buf_set_lines(multibuf, 0, -1, true, all_lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = multibuf })

	-- 2. Render Structure (Titles, Signs, Expanders)
	local current_lnum = #header
	local virt_expand_idx = 1

	for b_idx, buf_info in ipairs(info.bufs) do
		vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, virt_name_indices[b_idx], 0, {
			virt_lines = render_multibuf_title(buf_info.buf),
			virt_lines_above = true,
			virt_lines_leftcol = true,
			priority = 20001,
		})

		local last_s_end = 0
		if buf_info.pending_regions then
			for s_idx, region in ipairs(buf_info.pending_regions) do
				local slice_len = (region.end_row - region.start_row) + 1
				for i = 0, slice_len - 1 do
					place_line_number_signs(multibuf, current_lnum + i, region.start_row + i)
				end

				place_expander(multibuf, virt_expand_lnums[virt_expand_idx], {
					expand_direction = (s_idx == 1) and "above" or "both",
					count = region.start_row - last_s_end,
					window = win or 0,
					bufnr = buf_info.buf,
					start_row = last_s_end,
				})

				buf_info.region_extmark_ids[s_idx] =
					vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, current_lnum, 0, {
						end_row = current_lnum + slice_len,
						end_right_gravity = true,
					})

				current_lnum, last_s_end, virt_expand_idx =
					current_lnum + slice_len, region.end_row + 1, virt_expand_idx + 1
			end
		else
			for s_idx, src_extmark_id in ipairs(buf_info.source_extmark_ids) do
				local s_start, s_end = get_extmark_range(buf_info.buf, src_extmark_id)
				local slice_len = s_end - s_start

				for i = 0, slice_len - 1 do
					place_line_number_signs(multibuf, current_lnum + i, s_start + i)
				end

				place_expander(multibuf, virt_expand_lnums[virt_expand_idx], {
					expand_direction = (s_idx == 1) and "above" or "both",
					count = s_start - last_s_end,
					window = win or 0,
					bufnr = buf_info.buf,
					start_row = last_s_end,
				})

				buf_info.region_extmark_ids[s_idx] =
					vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, current_lnum, 0, {
						end_row = current_lnum + slice_len,
						end_right_gravity = true,
					})

				current_lnum, last_s_end, virt_expand_idx = current_lnum + slice_len, s_end, virt_expand_idx + 1
			end
		end
	end

	vim.api.nvim_set_option_value("modified", false, { buf = multibuf })
	if win and cursor_pos then
		local new_line
		if source_buf and source_line then
			new_line = M.multibuf_buf_get_line(multibuf, source_buf, source_line)
		end

		if new_line then
			vim.api.nvim_win_set_cursor(win, { new_line + 1, cursor_pos[2] })
		else
			-- fallback to old absolute pos, clamped
			local line_count = vim.api.nvim_buf_line_count(multibuf)
			local target_line = math.min(cursor_pos[1], line_count)
			vim.api.nvim_win_set_cursor(win, { target_line, cursor_pos[2] })
		end
	end
end

--- @param opts MultibufSetupOptions
function M.setup(opts)
	M.user_opts = vim.tbl_deep_extend("force", M.user_opts, opts)
	M.multibuf__ns = vim.api.nvim_create_namespace("Multibuf")
	M.multibuf_hl_ns = vim.api.nvim_create_namespace("MultibufHighlights")

	-- Decoration provider mirrors source highlights into the multibuffer viewport
	local function incremental_load_source_and_update(multibuf, top, bot)
		if not M.multibuf_is_valid(multibuf) then
			return false
		end
		local info = multibufs[multibuf]
		if not info then
			return false
		end

		local need_loadbufs = {}

		local slices = vim.api.nvim_buf_get_extmarks(
			multibuf,
			M.multibuf__ns,
			{ top, 0 },
			{ bot, -1 },
			{ details = true, overlap = true }
		)
		for _, extmark in ipairs(slices) do
			for _, b_info in ipairs(info.bufs) do
				for i, reg_id in ipairs(b_info.region_extmark_ids) do
					if extmark[1] == reg_id then
						if b_info.pending_regions then
							if not b_info.loading then
								b_info.loading = true
								table.insert(need_loadbufs, b_info)
							end
							goto next_extmark
						end

						local r_start, r_end = get_extmark_range(multibuf, reg_id)
						local s_start, _ = get_extmark_range(b_info.buf, b_info.source_extmark_ids[i])

						local v_start, v_end = math.max(top, r_start), math.min(bot + 1, r_end)
						if v_start < v_end then
							local s_range_start = s_start + (v_start - r_start)
							local s_range_end = s_range_start + (v_end - v_start)

							local s_ft = vim.api.nvim_get_option_value("filetype", { buf = b_info.buf })
							local s_lang = vim.treesitter.language.get_lang(s_ft)
							if s_lang then
								project_highlights(multibuf, b_info.buf, s_range_start, s_range_end, v_start)
							end
						end
					end
				end
			end
			::next_extmark::
		end

		-- Reload to replace placeholders with real content
		if #need_loadbufs > 0 then
			vim.schedule(function()
				for _, b_info in ipairs(need_loadbufs) do
					load_source_buf(multibuf, b_info)
				end
				M.multibuf_reload(multibuf)
			end)
		end

		return true
	end

	vim.api.nvim_set_decoration_provider(M.multibuf_hl_ns, {
		on_win = function(_, _, multibuf, top, bot)
			return incremental_load_source_and_update(multibuf, top, bot)
		end,
	})

	vim.api.nvim_create_autocmd({ "BufReadCmd", "BufWriteCmd" }, {
		pattern = "multibuffer://*",
		callback = function(args)
			pcall(vim.treesitter.stop, args.buf)
			M.multibuf_reload(args.buf)
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		pattern = "*",
		callback = function(args)
			M.multibuf__wipeout(args.buf)
		end,
	})
end

-- ──────── Public API ────────

--- @return integer bufnr
function M.create_multibuf(opts)
	opts = opts or {}
	vim.validate("opts.header", opts.header, { "table", "nil" })

	local id = vim.api.nvim_create_buf(true, false)
	local header = opts.header or create_multibuf_header()
	local info = { bufs = {}, header = header }
	vim.api.nvim_buf_set_name(id, "multibuffer://" .. id)
	vim.api.nvim_set_option_value("buftype", "acwrite", { buf = id })
	vim.api.nvim_set_option_value("filetype", "multibuffer", { buf = id })
	vim.api.nvim_set_option_value("modifiable", false, { buf = id })
	multibufs[id] = info
	return id
end

--- @param mb integer
--- @param header string[]
function M.multibuf_set_header(mb, header)
	local info = multibufs[mb]
	if not info then
		return
	end
	info.header = header
	M.multibuf_reload(mb)
end

--- @param buf integer
--- @return boolean
function M.multibuf_is_valid(buf)
	return multibufs[buf] ~= nil
end

--- @param mb integer
--- @param opts MultibufAddBufOptions
function M.multibuf_add_buf(mb, opts)
	M.multibuf_add_bufs(mb, { opts })
end

--- @param mb integer
function M.multibuf_clear_bufs(mb)
	local info = multibufs[mb]
	if not info then
		return
	end
	info.bufs = {}
	pending_adds[mb] = nil
	M.multibuf_reload(mb)
end

--- @param mb integer
--- @param opts_list MultibufAddBufOptions[]
function M.multibuf_add_bufs(mb, opts_list)
	local info = multibufs[mb]
	if not info then
		return
	end

	if not pending_adds[mb] then
		pending_adds[mb] = {}
	end

	for _, opts in ipairs(opts_list) do
		table.insert(pending_adds[mb], opts)
	end

	process_pending_adds(mb)
end

--- @param win integer window handle
--- @param mb integer multibuffer handle
function M.win_set_multibuf(win, mb)
	vim.api.nvim_win_set_buf(win, mb)
end

--- @param mb integer
--- @return boolean
function M.multibuf_is_loading(mb)
	local info = multibufs[mb]
	if not info then
		return false
	end
	if pending_adds[mb] and #pending_adds[mb] > 0 then
		return true
	end
	for _, b in ipairs(info.bufs) do
		if b.pending_regions then
			return true
		end
	end
	return false
end

--- @param buf integer
function M.multibuf__wipeout(buf)
	multibufs[buf] = nil
	pending_adds[buf] = nil
	if buf_listeners[buf] then
		vim.api.nvim_del_autocmd(buf_listeners[buf].change_autocmd_id)
		buf_listeners[buf] = nil
	end
end

--- @param mb integer
--- @param line integer 0-indexed line in multibuffer
--- @return integer|nil bufnr, integer|nil source_line
function M.multibuf_get_buf_at_line(mb, line)
	local info = multibufs[mb]
	local marks = vim.api.nvim_buf_get_extmarks(
		mb,
		M.multibuf__ns,
		{ line, 0 },
		{ line, -1 },
		{ details = true, overlap = true }
	)
	for _, m in ipairs(marks) do
		for _, b in ipairs(info.bufs) do
			for i, rid in ipairs(b.region_extmark_ids) do
				if m[1] == rid then
					local rs, _ = get_extmark_range(mb, rid)
					local sid = b.source_extmark_ids[i]
					if sid then
						local ss, _ = get_extmark_range(b.buf, sid)
						return b.buf, ss + (line - rs)
					elseif b.pending_regions and b.pending_regions[i] then
						return b.buf, b.pending_regions[i].start_row + (line - rs)
					end
					return b.buf, nil
				end
			end
		end
	end
end

--- get the line number in the multibuf that points to bufnr optionally
--- specifically the lnum in the bufnr. if lnum is nil then the first bufnr in
--- the multibuf thats found is returned
--- @param mb integer multibuf id
--- @param bufnr integer the buffer to look for in the mutlibuffer
--- @param lnum integer|nil optional line number to look for in bufnr
--- @return integer|nil multibuf_lnum the line number of the multibuf or nil if
--- the bufnr is not in the multibuf
function M.multibuf_buf_get_line(mb, bufnr, lnum)
	vim.validate("mb", mb, "number")
	vim.validate("bufnr", bufnr, "number")
	vim.validate("lnum", lnum, { "number", "nil" })

	local info = multibufs[mb]
	if not info then
		return nil
	end
	for _, b in ipairs(info.bufs) do
		if b.buf == bufnr then
			if b.pending_regions then
				for i, region in ipairs(b.pending_regions) do
					local region_id = b.region_extmark_ids[i]
					if not region_id then
						goto continue
					end

					if lnum == nil then
						local ts, _ = get_extmark_range(mb, region_id)
						return ts
					elseif lnum >= region.start_row and lnum <= region.end_row then
						local ts, _ = get_extmark_range(mb, region_id)
						return ts + (lnum - region.start_row)
					end
					::continue::
				end
			else
				for i, source_id in ipairs(b.source_extmark_ids) do
					local ss, se = get_extmark_range(bufnr, source_id)
					local region_id = b.region_extmark_ids[i]
					if not region_id then
						goto continue
					end

					if lnum == nil then
						local ts, _ = get_extmark_range(mb, region_id)
						return ts
					elseif lnum >= ss and lnum < se then
						local ts, _ = get_extmark_range(mb, region_id)
						return ts + (lnum - ss)
					end
					::continue::
				end
			end
		end
	end

	return nil
end

--- Expand or shrink a slice in a multibuffer.
--- @param mb integer multibuf id
--- @param delta_top integer lines to expand upwards (negative to shrink)
--- @param delta_bot integer lines to expand downwards (negative to shrink)
--- @param line integer|nil optional 0-indexed line number in multibuffer, defaults to cursor line
function M.multibuf_slice_expand(mb, delta_top, delta_bot, line)
	vim.validate("mb", mb, "number")
	vim.validate("delta_top", delta_top, "number")
	vim.validate("delta_bot", delta_bot, "number")
	vim.validate("line", line, { "number", "nil" })

	if line == nil then
		local win = get_buf_win(mb)
		if not win then
			return
		end
		line = vim.api.nvim_win_get_cursor(win)[1] - 1
	end

	local b_idx, s_idx = find_slice_index_at_line(mb, line)
	if not b_idx or not s_idx then
		return
	end

	local info = multibufs[mb]
	local b_info = info.bufs[b_idx]

	if b_info.pending_regions then
		local region = b_info.pending_regions[s_idx]
		region.start_row = region.start_row - delta_top
		region.end_row = region.end_row + delta_bot

		if region.start_row > region.end_row then
			table.remove(b_info.pending_regions, s_idx)
			if #b_info.pending_regions == 0 then
				table.remove(info.bufs, b_idx)
			end
		else
			region.start_row = math.max(0, region.start_row)
		end
	else
		local sid = b_info.source_extmark_ids[s_idx]
		local s, e = get_extmark_range(b_info.buf, sid)
		local line_count = vim.api.nvim_buf_line_count(b_info.buf)

		local ns = math.max(0, s - delta_top)
		local ne = math.min(line_count, e + delta_bot)

		if ns >= ne then
			vim.api.nvim_buf_del_extmark(b_info.buf, M.multibuf__ns, sid)
			table.remove(b_info.source_extmark_ids, s_idx)
			if #b_info.source_extmark_ids == 0 then
				table.remove(info.bufs, b_idx)
			end
		else
			vim.api.nvim_buf_set_extmark(b_info.buf, M.multibuf__ns, ns, 0, {
				id = sid,
				end_row = ne,
				end_right_gravity = true,
			})
		end
	end

	merge_buffer_regions(b_info)
	M.multibuf_reload(mb)
end

--- @param mb integer
--- @param delta integer
--- @param line integer|nil
function M.multibuf_slice_expand_top(mb, delta, line)
	M.multibuf_slice_expand(mb, delta, 0, line)
end

--- @param mb integer
--- @param delta integer
--- @param line integer|nil
function M.multibuf_slice_expand_bottom(mb, delta, line)
	M.multibuf_slice_expand(mb, 0, delta, line)
end

--- @param bufnr integer
--- @return any[]
function M.default_render_multibuf_title(bufnr)
	return { { { "" } }, { { " " .. vim.api.nvim_buf_get_name(bufnr) .. "  ", "TabLine" } }, { { "" } } }
end

--- @param opts multibuffer.RenderExpandLinesOptions
--- @return any[]
function M.default_render_expand_lines(opts)
	if opts.count <= 0 then
		return {}
	end

	local multibuf = vim.api.nvim_win_get_buf(opts.window)
	local max_lines = vim.b[multibuf].multibuffer_expander_max_lines
		or M.user_opts.expander_max_lines
		or vim.g.multibuffer_expander_max_lines
		or 0

	if opts.count <= max_lines then
		local lines = vim.api.nvim_buf_get_lines(opts.bufnr, opts.start_row, opts.start_row + opts.count, false)
		local ts = vim.api.nvim_get_option_value("tabstop", { buf = multibuf })
		local win_info = vim.fn.getwininfo(opts.window)[1]
		local textoff = win_info and win_info.textoff or 0

		local all_virt_lines = {}
		for _, line in ipairs(lines) do
			local chunks = {}
			if textoff > 0 then
				table.insert(chunks, { string.rep(" ", textoff), "LineNr" })
			end
			table.insert(chunks, { expand_tabs(line, ts), "Comment" })
			table.insert(all_virt_lines, chunks)
		end
		return all_virt_lines
	end

	local icons = { above = "↑", below = "↓", both = "↕" }
	local text = string.format(" --- [ %s %i ] ", icons[opts.expand_direction], opts.count)
	local width = vim.api.nvim_win_get_width(opts.window)
	return { { { text, "Folded" }, { string.rep("-", width - #text) .. " ", "Folded" } } }
end

return M
