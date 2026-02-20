--- @class MultibufRegion
--- @field start_row integer 0-indexed start row
--- @field end_row integer 0-indexed end row (inclusive)

--- @alias MultibufTitleRenderFunction fun(bufnr: integer): any[]

--- @class MultibufAddBufOptions
--- @field buf integer Buffer handle
--- @field regions MultibufRegion[] List of regions to include
--- @field title any[]|nil|MultibufTitleRenderFunction
--- @field id string|nil

--- @class MultibufBufInfo
--- @field buf integer Buffer handle
--- @field source_extmark_ids integer[] IDs of extmarks tracking source regions
--- @field region_extmark_ids integer[] IDs of extmarks tracking regions in multibuffer
--- @field virt_expand_extmark_ids integer[] IDs of extmarks for expander UI
--- @field pending_regions MultibufRegion[]? List of regions to be set up once loaded
--- @field loading boolean? Whether this buffer is currently being loaded/processed
--- @field title any[]|nil|MultibufTitleRenderFunction
--- @field id string|nil

--- @class MultibufInfo
--- @field bufs MultibufBufInfo[] Info about included buffers
--- @field header string[]? Custom header lines

--- @class MultibufBufListener
--- @field multibufs integer[] List of multibuffers listening to this source
--- @field change_autocmd_id integer ID of the TextChanged autocmd

--- @class MultibufSetupOptions
--- @field render_multibuf_title MultibufTitleRenderFunction|nil Custom title renderer
--- @field render_expand_lines (fun(opts: multibuffer.RenderExpandLinesOptions): any[])? Custom expander renderer
--- @field expander_max_lines integer? Max lines to show as dimmed text in expander
--- @field expander_signs { above: string, below: string, both: string }|nil
--- @field expander_sign_hl string|nil

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
	user_opts = {
		expander_signs = {
			above = "↑",
			below = "↓",
			both = "↕",
		},
		expander_sign_hl = "Folded",
	},
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
			title = opts.title,
			id = opts.id,
		})
	end

	pending_adds[mb] = nil
	M.multibuf_reload(mb)
end

--- @param buf integer
--- @return integer|nil
local function get_buf_win(buf)
	local cur_win = vim.api.nvim_get_current_win()
	if vim.api.nvim_win_get_buf(cur_win) == buf then
		return cur_win
	end
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
			return win
		end
	end
	return nil
end

--- @param win integer|nil
--- @return integer
local function get_signcolumn_width(win)
	local sc
	if win and vim.api.nvim_win_is_valid(win) then
		sc = vim.api.nvim_get_option_value("signcolumn", { win = win })
	else
		sc = vim.api.nvim_get_option_value("signcolumn", { scope = "global" })
	end

	if sc == "no" then
		return 0
	end

	local width_str = sc:match(":(%d+)$")
	if width_str then
		return tonumber(width_str)
	end

	return 1
end

--- Generates 2-digit sign strings for line numbers
--- @param line_num integer
--- @param width_columns integer
--- @return string[]
local function get_line_number_signs(line_num, width_columns)
	local str = tostring(line_num)
	local width_cells = width_columns * 2
	if #str < width_cells then
		str = str .. " "
	end

	local result = {}
	for i = #str, 1, -2 do
		local start = math.max(1, i - 1)
		local chunk = str:sub(start, i)
		if #chunk == 1 then
			chunk = " " .. chunk
		end
		table.insert(result, 1, chunk)
	end
	return result
end

--- @param buf integer
--- @param extmark integer
--- @return integer|nil, integer|nil
local function get_extmark_range(buf, extmark)
	local result = vim.api.nvim_buf_get_extmark_by_id(buf, M.multibuf__ns, extmark, { details = true })
	if not result or not result[1] then
		return nil, nil
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
		local m_id, m_row, _, m_details = unpack(m)
		local m_end_row = m_details.end_row
		if m_end_row and line >= m_row and line < m_end_row then
			for b_idx, b in ipairs(info.bufs) do
				for s_idx, rid in ipairs(b.region_extmark_ids) do
					if m_id == rid then
						return b_idx, s_idx
					end
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

--- @param buf_info MultibufBufInfo
--- @return any[]
local function render_multibuf_title(buf_info)
	if buf_info.title then
		local buf_title = buf_info.title
		if type(buf_title) == "table" then
			return buf_title
		elseif type(buf_title) == "function" then
			local success, lines_or_error = pcall(buf_title, buf_info.buf)
			if success then
				return lines_or_error
			end
			vim.notify(lines_or_error, vim.log.levels.ERROR)
		else
			vim.notify("bad opt title type " .. type(buf_title), vim.log.levels.ERROR)
		end
	end

	if M.user_opts.render_multibuf_title then
		local success, lines_or_error = pcall(M.user_opts.render_multibuf_title, buf_info.buf)
		if success then
			return lines_or_error
		end
		vim.notify(lines_or_error, vim.log.levels.ERROR)
	end

	return M.default_render_multibuf_title(buf_info.buf)
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
--- @param width integer?
--- @param special_sign string?
local function place_line_number_signs(multibuf, target_row, source_row, width, special_sign)
	local signs = get_line_number_signs(source_row + 1, width or 1)
	if width then
		while #signs < width do
			table.insert(signs, 1, "  ")
		end
	end

	local start_idx = 1
	if special_sign and width and width > 0 then
		vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, target_row, 0, {
			sign_text = special_sign,
			sign_hl_group = M.user_opts.expander_sign_hl or "Folded",
			priority = 1000,
		})
		start_idx = 2
	end

	for i = start_idx, #signs do
		vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, target_row, 0, {
			sign_text = signs[i],
			sign_hl_group = "LineNr",
			priority = 100 - i,
		})
	end
end

--- @param multibuf integer
--- @param target_row integer
--- @param opts multibuffer.RenderExpandLinesOptions
local function place_expander(multibuf, target_row, opts)
	if opts.count <= 0 then
		return
	end

	vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, target_row, 0, {
		virt_lines = render_expand_lines(opts),
		virt_lines_above = opts.expand_direction ~= "below",
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
	if not vim.api.nvim_buf_is_valid(source_buf) or not vim.api.nvim_buf_is_valid(multibuf) then
		return
	end

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

			local line_count = vim.api.nvim_buf_line_count(source_buf)
			local safe_s_start = math.max(0, math.min(s_start, line_count - 1))
			local safe_s_end = math.max(safe_s_start, math.min(s_end, line_count))

			parser:parse({ safe_s_start, safe_s_end })
			parser:for_each_tree(function(tstree, tree)
				local tlang = tree:lang()
				local query = vim.treesitter.query.get(tlang, "highlights")
				if not query then
					return
				end

				-- Cache multibuffer lines for column clamping (performance)
				local mb_lines =
					vim.api.nvim_buf_get_lines(multibuf, target_start, target_start + (s_end - s_start), false)

				for id, node, metadata in query:iter_captures(tstree:root(), source_buf, safe_s_start, safe_s_end) do
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
--- @param force_source_buf integer?
--- @param force_source_line integer?
function M.multibuf_reload(multibuf, force_source_buf, force_source_line)
	local info = multibufs[multibuf]
	if not info then
		return
	end
	local win = get_buf_win(multibuf)
	local sc_width = get_signcolumn_width(win)
	local cursor_pos = win and vim.api.nvim_win_get_cursor(win)
	local source_buf, source_line
	if win then
		if force_source_buf then
			source_buf, source_line = force_source_buf, force_source_line
		else
			source_buf, source_line = M.multibuf_get_buf_at_line(multibuf, cursor_pos[1] - 1)
		end
	end

	vim.api.nvim_buf_clear_namespace(multibuf, M.multibuf__ns, 0, -1)

	local header = info.header or create_multibuf_header()
	local all_lines = { unpack(header) }
	local virt_name_indices = {}
	local virt_expand_lnums = {}

	-- 1. Build Text Content
	for _, buf_info in ipairs(info.bufs) do
		local has_content = false
		if buf_info.pending_regions and #buf_info.pending_regions > 0 then
			has_content = true
		elseif #buf_info.source_extmark_ids > 0 then
			has_content = true
		end

		if has_content then
			table.insert(virt_name_indices, #all_lines)
			if buf_info.pending_regions then
				for _, region in ipairs(buf_info.pending_regions) do
					table.insert(virt_expand_lnums, #all_lines)
					local count = (region.end_row - region.start_row) + 1
					if count > 0 then
						for _ = 1, count do
							table.insert(all_lines, "") -- empty line while temporarily loading
						end
					end
				end
			else
				for _, source_extmark_id in ipairs(buf_info.source_extmark_ids) do
					local s_start, s_end = get_extmark_range(buf_info.buf, source_extmark_id)
					if s_start and s_end then
						table.insert(virt_expand_lnums, #all_lines)
						vim.list_extend(all_lines, vim.api.nvim_buf_get_lines(buf_info.buf, s_start, s_end, true))
					end
				end
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
	local name_idx_cursor = 1

	local function get_expander_sign(direction)
		local signs = M.user_opts.expander_signs or {}
		local text = signs[direction]
		if text and text ~= "" then
			return text
		end
		return nil
	end

	for b_idx, buf_info in ipairs(info.bufs) do
		local has_content = false
		if buf_info.pending_regions and #buf_info.pending_regions > 0 then
			has_content = true
		elseif #buf_info.source_extmark_ids > 0 then
			has_content = true
		end

		if has_content then
			buf_info.region_extmark_ids = {}
			vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, virt_name_indices[name_idx_cursor], 0, {
				virt_lines = render_multibuf_title(buf_info),
				virt_lines_above = true,
				virt_lines_leftcol = true,
				priority = 20001,
			})
			name_idx_cursor = name_idx_cursor + 1

			local last_s_end = 0
			local source_line_count = vim.api.nvim_buf_line_count(buf_info.buf)
			local num_slices = buf_info.pending_regions and #buf_info.pending_regions or #buf_info.source_extmark_ids
			for s_idx = 1, num_slices do
				local s_start, s_end
				if buf_info.pending_regions then
					local region = buf_info.pending_regions[s_idx]
					s_start, s_end = region.start_row, region.end_row + 1
				else
					s_start, s_end = get_extmark_range(buf_info.buf, buf_info.source_extmark_ids[s_idx])
				end

				if s_start and s_end then
					local slice_len = s_end - s_start

					-- Signs on visible lines
					for i = 0, slice_len - 1 do
						local special_sign = nil
						if sc_width > 0 then
							local is_first = (i == 0)
							local is_last = (i == slice_len - 1)
							local needs_above = is_first and (s_start > 0)
							local needs_below = is_last and (s_end < source_line_count)

							if needs_above and needs_below then
								special_sign = get_expander_sign("both")
							elseif needs_above then
								special_sign = get_expander_sign("above")
							elseif needs_below then
								special_sign = get_expander_sign("below")
							end
						end
						place_line_number_signs(multibuf, current_lnum + i, s_start + i, sc_width, special_sign)
					end

					-- Gap renderer above
					if s_start > last_s_end then
						place_expander(multibuf, current_lnum, {
							expand_direction = (s_idx == 1) and "above" or "both",
							count = s_start - last_s_end,
							window = win or 0,
							bufnr = buf_info.buf,
							start_row = last_s_end,
						})
					end

					-- Gap renderer below (only for last slice of buffer)
					if (s_idx == num_slices) and (s_end < source_line_count) then
						place_expander(multibuf, current_lnum + slice_len - 1, {
							expand_direction = "below",
							count = source_line_count - s_end,
							window = win or 0,
							bufnr = buf_info.buf,
							start_row = s_end,
						})
					end

					buf_info.region_extmark_ids[s_idx] =
						vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, current_lnum, 0, {
							end_row = current_lnum + slice_len,
							end_right_gravity = true,
						})

					current_lnum, last_s_end, virt_expand_idx = current_lnum + slice_len, s_end, virt_expand_idx + 1
				end
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

		local slice_lookup = {}
		for _, b_info in ipairs(info.bufs) do
			for i, reg_id in ipairs(b_info.region_extmark_ids) do
				slice_lookup[reg_id] = { b_info = b_info, slice_idx = i }
			end
		end

		local slices = vim.api.nvim_buf_get_extmarks(
			multibuf,
			M.multibuf__ns,
			{ top, 0 },
			{ bot, -1 },
			{ details = true, overlap = true }
		)
		for _, extmark in ipairs(slices) do
			local lookup = slice_lookup[extmark[1]]
			if lookup then
				local b_info = lookup.b_info
				local i = lookup.slice_idx

				if b_info.pending_regions then
					if not b_info.loading then
						b_info.loading = true
						table.insert(need_loadbufs, b_info)
					end
					goto next_extmark
				end

				local r_start, r_end = get_extmark_range(multibuf, extmark[1])
				if not r_start then
					goto next_extmark
				end

				local s_ext_id = b_info.source_extmark_ids[i]
				if not s_ext_id then
					goto next_extmark
				end
				local s_start, _ = get_extmark_range(b_info.buf, s_ext_id)
				if not s_start then
					goto next_extmark
				end

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
end

--- @class CreateMultibufOptions
--- @field header string[]|nil

--- @param opts CreateMultibufOptions|nil
--- @return integer mbufnr
function M.create_multibuf(opts)
	opts = opts or {}
	vim.validate("opts.header", opts.header, { "table", "nil" })

	local id = vim.api.nvim_create_buf(true, true)
	local header = opts.header or create_multibuf_header()
	local info = { bufs = {}, header = header }
	vim.api.nvim_set_option_value("buftype", "acwrite", { buf = id })
	vim.api.nvim_set_option_value("filetype", "multibuffer", { buf = id })
	vim.api.nvim_set_option_value("modifiable", false, { buf = id })
	multibufs[id] = info

	vim.api.nvim_create_autocmd({ "BufReadCmd", "BufWriteCmd" }, {
		buffer = id,
		callback = function(args)
			pcall(vim.treesitter.stop, args.buf)
			M.multibuf_reload(args.buf)
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = id,
		callback = function(args)
			M.multibuf__wipeout(args.buf)
		end,
	})

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
	if multibufs[buf] then
		multibufs[buf] = nil
		pending_adds[buf] = nil
	end

	if buf_listeners[buf] then
		pcall(vim.api.nvim_del_autocmd, buf_listeners[buf].change_autocmd_id)
		buf_listeners[buf] = nil
	end

	-- Remove this buffer from any multibuffer that contains it
	for mb, info in pairs(multibufs) do
		local changed = false
		for i = #info.bufs, 1, -1 do
			if info.bufs[i].buf == buf then
				table.remove(info.bufs, i)
				changed = true
			end
		end
		if changed then
			vim.schedule(function()
				if M.multibuf_is_valid(mb) then
					M.multibuf_reload(mb)
				end
			end)
		end
	end
end

--- @param mb integer
--- @param line integer 0-indexed line in multibuffer
--- @return integer|nil bufnr, integer|nil source_line
function M.multibuf_get_buf_at_line(mb, line)
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
		for _, b in ipairs(info.bufs) do
			for i, rid in ipairs(b.region_extmark_ids) do
				if m[1] == rid then
					local rs, _ = get_extmark_range(mb, rid)
					if not rs then
						goto next_mark
					end
					local sid = b.source_extmark_ids and b.source_extmark_ids[i]
					if sid then
						local ss, _ = get_extmark_range(b.buf, sid)
						if ss then
							return b.buf, ss + (line - rs)
						end
					elseif b.pending_regions and b.pending_regions[i] then
						return b.buf, b.pending_regions[i].start_row + (line - rs)
					end
					return b.buf, nil
				end
			end
		end
		::next_mark::
	end
	return nil, nil
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

					local ts, _ = get_extmark_range(mb, region_id)
					if not ts then
						goto continue
					end

					if lnum == nil then
						return ts
					elseif lnum >= region.start_row and lnum <= region.end_row then
						return ts + (lnum - region.start_row)
					end
					::continue::
				end
			else
				for i, source_id in ipairs(b.source_extmark_ids) do
					local region_id = b.region_extmark_ids[i]
					if not region_id then
						goto continue
					end

					local ts, _ = get_extmark_range(mb, region_id)
					if not ts then
						goto continue
					end

					if lnum == nil then
						return ts
					end

					local ss, se = get_extmark_range(bufnr, source_id)
					if ss and se and lnum >= ss and lnum < se then
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
	vim.validate("mb", mb, function(v)
		return M.multibuf_is_valid(v), "valid multibuffer handle"
	end)
	vim.validate("delta_top", delta_top, "number")
	vim.validate("delta_bot", delta_bot, "number")
	vim.validate("line", line, { "number", "nil" })

	if delta_top == 0 and delta_bot == 0 then
		return
	end

	local win = get_buf_win(mb)
	local source_buf, source_line
	if win then
		local cursor = vim.api.nvim_win_get_cursor(win)
		source_buf, source_line = M.multibuf_get_buf_at_line(mb, cursor[1] - 1)
	end

	if line == nil then
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
			if source_buf == b_info.buf and source_line then
				source_line = math.max(region.start_row, math.min(region.end_row, source_line))
			end
		end
	else
		local sid = b_info.source_extmark_ids[s_idx]
		local s, e = get_extmark_range(b_info.buf, sid)
		if not s then
			return
		end
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
			if source_buf == b_info.buf and source_line then
				source_line = math.max(ns, math.min(ne - 1, source_line))
			end
		end
	end

	merge_buffer_regions(b_info)
	M.multibuf_reload(mb, source_buf, source_line)
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

	local signs = M.user_opts.expander_signs or { above = "↑", below = "↓", both = "↕" }
	local text = string.format(" --- [ %s %i ] ", signs[opts.expand_direction], opts.count)
	local width = vim.api.nvim_win_get_width(opts.window)
	return { { { text, "Folded" }, { string.rep("-", width - #text) .. " ", "Folded" } } }
end

return M
