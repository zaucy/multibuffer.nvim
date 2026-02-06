--- @class MultibufBufInfo
--- @field buf integer
--- @field virt_name_extmark_id integer|nil
--- @field source_extmark_ids integer[]
--- @field region_extmark_ids integer[] should be same length as source_extmark_ids and extmark line count should be same
--- @field virt_expand_extmark_ids integer[] should be same length as source_extmark_ids + 1 (one for the bottom)

--- @class MultibufInfo
--- @field bufs MultibufBufInfo[]
--- @field line_map table<integer, integer>

--- @type MultibufInfo[]
local multibufs = {}

--- @class MultibufBufListener
--- @field multibufs integer[]
--- @field change_autocmd_id integer

--- @type table<integer, MultibufBufListener>
local buf_listeners = {}

--- @class MultibufSetupKeymap
--- @field [1] string|string[]  Mode "short-name" (see |nvim_set_keymap()|), or a list thereof.
--- @field [2] string           Left-hand side |{lhs}| of the mapping.
--- @field [3] string|function  Right-hand side |{rhs}| of the mapping, can be a Lua function.

--- @class MultibufSetupOptions
--- @field keymaps MultibufSetupKeymap[]?
--- @field render_multibuf_title any?
--- @field render_expand_lines any?

local M = {
	--- @type MultibufSetupOptions
	user_opts = {
		keymaps = {}
	},
}

local function list_insert_unique(list, item)
	for _, v in ipairs(list) do
		if v == item then return end
	end
	table.insert(list, item)
end

local function clamp(num, min, max)
	assert(type(num) == "number")
	assert(type(max) == "number")
	assert(type(min) == "number")
	assert(min <= max)
	if num < min then
		return min
	elseif num > max then
		return max
	end
	return num
end

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

--- @return string[]
local function create_multibuf_header()
	return { " ─────── " }
end

local function get_buf_win(buf)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == buf then
			return win
		end
	end
	return nil
end

--- @return string[]
local function get_line_number_signs(line_num)
	local str = tostring(line_num)
	local result = {}
	-- Split into 2-character chunks from the right
	for i = #str, 1, -2 do
		local start = math.max(1, i - 1)
		table.insert(result, 1, str:sub(start, i))
	end
	return result
end

local function multibuf_buf_changed(args)
	local buf = args.buf
	local listener_info = buf_listeners[buf]
	if listener_info == nil then
		return
	end

	for _, multibuf in ipairs(listener_info.multibufs) do
		-- TODO: don't reload whole multibuf just related buffers/extmarks
		M.multibuf_reload(multibuf)
	end
end

--- @param multibuf_buf_info MultibufBufInfo
local function merge_and_sort_source_extmarks(multibuf_buf_info)
	local ids_and_rows = {}
	for _, source_extmark_id in ipairs(multibuf_buf_info.source_extmark_ids) do
		local result    = vim.api.nvim_buf_get_extmark_by_id(
			multibuf_buf_info.buf,
			M.multibuf__ns,
			source_extmark_id,
			{ details = true }
		)

		local start_row = result[1]
		local details   = result[3]
		assert(details ~= nil, "no extmark details")
		local end_row = details.end_row

		table.insert(ids_and_rows, { source_extmark_id, start_row, end_row })
	end

	table.sort(ids_and_rows, function(a, b) return a[2] < b[2] end)


	local merged_indices = {}
	local i = 1
	while true do
		local item = ids_and_rows[i]
		if not item then break end
		local next_item = ids_and_rows[i + 1]
		if not next_item then
			table.insert(merged_indices, i)
			break
		end

		table.insert(merged_indices, i)
		if next_item[2] <= item[3] - 1 then
			item[3] = next_item[3]
			i = i + 2
			vim.api.nvim_buf_del_extmark(multibuf_buf_info.buf, M.multibuf__ns, next_item[1])
		else
			i = i + 1
		end
	end

	multibuf_buf_info.source_extmark_ids = {}
	for _, index in ipairs(merged_indices) do
		local extmark = ids_and_rows[index][1]
		table.insert(multibuf_buf_info.source_extmark_ids, extmark)
	end
end

--- @param multibuf integer
--- @param info MultibufInfo
local function setup_multibuf_keymaps(multibuf, info)
	if not M.user_opts.keymaps then
		return
	end

	for index, keymap in ipairs(M.user_opts.keymaps) do
		local success, err = pcall(vim.keymap.set, keymap[1], keymap[2], keymap[3], { buffer = multibuf })
		if not success and err then
			vim.notify(string.format("error keymap[%i]: %s", index, err), vim.log.levels.ERROR)
		end
	end
end

--- @param buf integer
--- @param extmark integer
--- @return number,number
local function get_extmark_range(buf, extmark)
	assert(type(buf) == "number")
	assert(type(extmark) == "number")

	local result    = vim.api.nvim_buf_get_extmark_by_id(buf, M.multibuf__ns, extmark, { details = true })
	local start_row = result[1]
	local end_row   = result[3].end_row
	assert(type(end_row) == "number")

	return start_row, end_row
end

--- @return integer
function M.create_multibuf()
	local new_multibuf_id = vim.api.nvim_create_buf(true, false)

	--- @type MultibufInfo
	local multibuf_info = {
		bufs = {},
		line_map = {},
	}
	assert(new_multibuf_id ~= 0, "failed to create multibuf")
	vim.api.nvim_buf_set_name(new_multibuf_id, "multibuffer://" .. new_multibuf_id)
	vim.api.nvim_set_option_value("buftype", "acwrite", { buf = new_multibuf_id })
	-- always have header line because we can't put virtual text above the first line in a buffer
	local header = create_multibuf_header()
	vim.api.nvim_buf_set_lines(new_multibuf_id, 0, #header, true, header)
	vim.api.nvim_set_option_value("modified", false, { buf = new_multibuf_id })
	multibufs[new_multibuf_id] = multibuf_info

	local success, err = pcall(setup_multibuf_keymaps, new_multibuf_id, multibuf_info)
	if not success and err then
		vim.notify(err, vim.log.levels.ERROR)
	end

	return new_multibuf_id
end

--- @param multibuf integer
--- @return boolean
function M.multibuf_is_valid(multibuf)
	local multibuf_info = multibufs[multibuf]
	return multibuf_info ~= nil
end

--- @class MultibufRegion
--- @field start_row integer
--- @field end_row integer

--- @class MultibufAddBufOptions
--- @field buf integer
--- @field regions MultibufRegion[]

--- @param multibuf integer
--- @param opts MultibufAddBufOptions
function M.multibuf_add_buf(multibuf, opts)
	M.multibuf_add_bufs(multibuf, { opts })
end

--- @param multibuf integer
--- @param opts_list MultibufAddBufOptions[]
function M.multibuf_add_bufs(multibuf, opts_list)
	assert(M.multibuf_is_valid(multibuf), "invalid multibuf")

	local multibuf_info = multibufs[multibuf]
	assert(
		not vim.api.nvim_get_option_value("modified", { buf = multibuf }),
		"cannot add buf to modified multibuf"
	)

	for index, opts in ipairs(opts_list) do
		assert(opts ~= nil, string.format("invalid opts at index %i", index))
		assert(vim.api.nvim_buf_is_valid(opts.buf), string.format("invalid buf at index %i", index))
		for region_idx, region in ipairs(opts.regions) do
			assert(region.end_row >= region.start_row,
				string.format("end_row must be >= start_row at index opts[%i].regions[%i]", index, region_idx))
		end
	end


	for _, opts in ipairs(opts_list) do
		local buf = opts.buf
		local source_line_count = vim.api.nvim_buf_line_count(buf)
		local source_extmark_ids = {}

		for _, region in ipairs(opts.regions) do
			local start_row = clamp(region.start_row, 0, source_line_count - 1)
			local end_row = clamp(region.end_row + 1, 0, source_line_count)

			local source_extmark_id = vim.api.nvim_buf_set_extmark(buf, M.multibuf__ns, start_row, 0, {
				strict = true,
				end_row = end_row,
				end_right_gravity = true,
				priority = 20000, -- ya i dunno
			})
			table.insert(source_extmark_ids, source_extmark_id)
		end

		if buf_listeners[buf] == nil then
			local autocmd_id = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
				buffer = buf,
				callback = multibuf_buf_changed,
			})
			buf_listeners[buf] = {
				change_autocmd_id = autocmd_id,
				multibufs = { multibuf }
			}
		else
			list_insert_unique(buf_listeners[buf].multibufs, multibuf)
		end

		--- @type MultibufBufInfo
		local multibuf_buf_info = {
			buf = buf,
			source_extmark_ids = source_extmark_ids,
			region_extmark_ids = {},
			virt_name_extmark_id = nil,
			virt_expand_extmark_ids = {},
		}
		merge_and_sort_source_extmarks(multibuf_buf_info)
		table.insert(multibuf_info.bufs, multibuf_buf_info)
	end

	-- TODO: reload here is inefficient we should do an incremental update instead
	M.multibuf_reload(multibuf)
end

--- @param window integer
--- @param multibuf integer
function M.win_set_multibuf(window, multibuf)
	assert(vim.api.nvim_win_is_valid(window), "invalid window")
	assert(M.multibuf_is_valid(multibuf), "invalid multibuf")
	vim.api.nvim_win_set_buf(window, multibuf)
end

--- @param buf integer
function M.multibuf__wipeout(buf)
	if M.multibuf_is_valid(buf) then
		multibufs[buf] = nil
	end

	local listener_info = buf_listeners[buf]
	if listener_info ~= nil then
		vim.api.nvim_del_autocmd(listener_info.change_autocmd_id)
		buf_listeners[buf] = nil
	end
end

local function place_line_number_signs(multibuf, target_row, source_row)
	local abs_lnum = source_row + 1
	local signs = get_line_number_signs(abs_lnum)

	for digit_idx, sign_text in ipairs(signs) do
		-- Clean up sign text (handles legacy format if still present in get_line_number_signs)
		local text = sign_text:match("Digit(%d+)") or (sign_text == "MutlibufferDigitSpacer" and " " or sign_text)
		if text:match("^%d$") then text = " " .. text end -- Pad single digits

		vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, target_row, 0, {
			sign_text = text,
			sign_hl_group = "LineNr",
			priority = 100 - digit_idx,
		})
	end
	-- Spacer sign
	vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, target_row, 0, {
		sign_text = " ",
		sign_hl_group = "LineNr",
		priority = 10,
	})
end

local function place_expander(multibuf, target_row, opts)
	vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, target_row, 0, {
		virt_lines = render_expand_lines(opts),
		virt_lines_above = true,
		virt_lines_leftcol = true,
		priority = 20001,
	})
end

--- Clones highlighting and other extmarks from source to multibuffer
local function mirror_highlights(multibuf, buf_info, source_start, source_end, target_start)
	-- Use ns_id = -1 to get extmarks from ALL namespaces in one go
	local extmarks = vim.api.nvim_buf_get_extmarks(
		buf_info.buf,
		-1,
		{ source_start, 0 },
		{ source_end, -1 },
		{ details = true }
	)

	for _, mark in ipairs(extmarks) do
		local _, row, col, details = unpack(mark)
		
		-- Skip our own structural extmarks
		if details.ns_id ~= M.multibuf__ns then
			local target_srow = target_start + (row - source_start)
			
			-- Get line length for safety clamping
			local line = vim.api.nvim_buf_get_lines(multibuf, target_srow, target_srow + 1, false)[1] or ""
			local max_col = #line

			-- Only copy valid extmark options
			local opts = {
				end_row = details.end_row and (target_start + (details.end_row - source_start)),
				end_col = details.end_col and math.min(details.end_col, max_col),
				hl_group = details.hl_group,
				virt_text = details.virt_text,
				virt_text_pos = details.virt_text_pos,
				virt_text_win_col = details.virt_text_win_col,
				virt_text_hide = details.virt_text_hide,
				virt_lines = details.virt_lines,
				virt_lines_above = details.virt_lines_above,
				virt_lines_leftcol = details.virt_lines_leftcol,
				hl_mode = details.hl_mode,
				priority = details.priority,
				right_gravity = details.right_gravity,
				end_right_gravity = details.end_right_gravity,
				sign_text = details.sign_text,
				sign_hl_group = details.sign_hl_group,
				number_hl_group = details.number_hl_group,
				line_hl_group = details.line_hl_group,
				cursorline_hl_group = details.cursorline_hl_group,
				conceal = details.conceal,
				spell = details.spell,
				ui_watched = details.ui_watched,
				url = details.url,
			}
			
			-- Ensure start col is also within range (especially for empty lines)
			local safe_col = math.min(col, max_col)

			-- Map to our dedicated highlight namespace
			pcall(vim.api.nvim_buf_set_extmark, multibuf, M.multibuf_hl_ns, target_srow, safe_col, opts)
		end
	end
end

function M.multibuf_reload(multibuf)
	assert(M.multibuf_is_valid(multibuf), "invalid multibuf")
	local multibuf_info = multibufs[multibuf]
	local win = get_buf_win(multibuf)
	local cursor_pos
	if win ~= nil then
		cursor_pos = vim.api.nvim_win_get_cursor(win)
	end

	-- Efficiently clear our structural namespace
	vim.api.nvim_buf_clear_namespace(multibuf, M.multibuf__ns, 0, -1)

	local all_lines = create_multibuf_header()
	local header_length = #all_lines
	local virt_name_indices = {}
	local virt_expand_lnums = {}

	-- Build the buffer content and track where slices start
	for _, buf_info in ipairs(multibuf_info.bufs) do
		table.insert(virt_name_indices, #all_lines)
		for _, source_extmark_id in ipairs(buf_info.source_extmark_ids) do
			local start_row, end_row = get_extmark_range(buf_info.buf, source_extmark_id)
			local lines = vim.api.nvim_buf_get_lines(buf_info.buf, start_row, end_row, true)
			table.insert(virt_expand_lnums, #all_lines)
			vim.list_extend(all_lines, lines)
		end
	end
	table.insert(virt_expand_lnums, #all_lines)

	-- Update buffer content in a single call
	vim.api.nvim_buf_set_lines(multibuf, 0, -1, true, all_lines)

	-- Place titles, signs, and expanders
	local current_lnum = header_length
	local virt_expand_index = 1

	for buf_idx, buf_info in ipairs(multibuf_info.bufs) do
		-- Set Buffer Title
		vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, virt_name_indices[buf_idx], 0, {
			virt_lines = render_multibuf_title(buf_info.buf),
			virt_lines_above = true,
			virt_lines_leftcol = true,
			priority = 20001,
		})

		local last_end_row = 0
		for slice_idx, source_extmark_id in ipairs(buf_info.source_extmark_ids) do
			local start_row, end_row = get_extmark_range(buf_info.buf, source_extmark_id)
			local slice_len = end_row - start_row

			-- Place Line Number Signs
			for i = 0, slice_len - 1 do
				place_line_number_signs(multibuf, current_lnum + i, start_row + i)
			end

			-- Set Expander
			place_expander(multibuf, virt_expand_lnums[virt_expand_index], {
				expand_direction = (slice_idx == 1) and "above" or "both",
				count = start_row - last_end_row,
				window = win or 0,
			})

			-- Track regions for mapping
			buf_info.region_extmark_ids[slice_idx] = vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, current_lnum, 0, {
				end_row = current_lnum + slice_len,
				end_right_gravity = true,
			})

			current_lnum = current_lnum + slice_len
			last_end_row = end_row
			virt_expand_index = virt_expand_index + 1
		end
	end

	vim.api.nvim_set_option_value("modified", false, { buf = multibuf })
	if win ~= nil and cursor_pos then
		vim.api.nvim_win_set_cursor(win, cursor_pos)
	end
end

function M.mutlibuf__write(multibuf)
	assert(M.multibuf_is_valid(multibuf), "invalid multibuf")
	vim.notify("TODO: write multibuf", vim.log.levels.ERROR)
	M.multibuf_reload(multibuf)
end

--- Get the buffer in a multibuffer at the line in a multibuffer
--- @param multibuf integer
--- @param line integer zero-index line
--- @return integer|nil,integer|nil bufnr at line or nil if invalid
function M.multibuf_get_buf_at_line(multibuf, line)
	assert(M.multibuf_is_valid(multibuf), "invalid multibuf")
	local multibuf_info = multibufs[multibuf]
	local extmarks = vim.api.nvim_buf_get_extmarks(multibuf, M.multibuf__ns, { line, 0 }, { line, -1 }, {
		details = true,
		overlap = true,
	})

	if #extmarks == 0 then
		error(string.format("no extmarks for multibuf %i", multibuf), vim.log.levels.WARN)
		return nil, nil
	end

	for _, extmark in ipairs(extmarks) do
		local id = extmark[1]

		for _, buf_info in ipairs(multibuf_info.bufs) do
			for i, region_extmark_id in ipairs(buf_info.region_extmark_ids) do
				if id == region_extmark_id then
					local source_extmark_id = buf_info.source_extmark_ids[i]
					local region_row_start, region_row_end = get_extmark_range(multibuf, region_extmark_id)
					local source_row_start, source_row_end = get_extmark_range(buf_info.buf, source_extmark_id)
					local diff = line - region_row_start

					return buf_info.buf, (source_row_start + diff)
				end
			end
		end
	end

	return nil, nil
end

--- @return any[]
function M.default_render_multibuf_title(bufnr)
	return {
		{ { "" } },
		{ { " " .. vim.api.nvim_buf_get_name(bufnr) .. "  " } },
		{ { "" } },
	}
end

--- @class multibuffer.RenderExpandLinesOptions
--- @field expand_direction "above"|"below"|"both"
--- @field count number
--- @field window number

--- @param opts multibuffer.RenderExpandLinesOptions
--- @return any[]
function M.default_render_expand_lines(opts)
	if opts.count <= 0 then
		return {}
	end

	local line = {}

	local win_width = vim.api.nvim_win_get_width(opts.window)
	local prefix_len = 0

	local expand_direction_prefix = {
		above = "↑",
		below = "↓",
		both = "↕",
	}

	local text = string.format(" --- [ %s %i ] ", expand_direction_prefix[opts.expand_direction], opts.count)
	table.insert(line, { text, "Folded" })
	prefix_len = prefix_len + #text

	table.insert(line, { string.rep("-", win_width - prefix_len + 1) .. " ", "Folded" })

	return { line }
end

--- Mirror highlights from a source buffer range to a target multibuffer range
local function mirror_treesitter_highlights(multibuf, source_buf, source_start, source_end, target_start)
	local success, parser = pcall(vim.treesitter.get_parser, source_buf)
	if not (success and parser) then return end

	-- Ensure the source parser is up to date for the range we need
	parser:parse({ source_start, source_end })

	parser:for_each_tree(function(tstree, tree)
		local lang = tree:lang()
		local query = vim.treesitter.query.get(lang, "highlights")
		if not query then return end

		local root = tstree:root()
		-- Query only the relevant range in the source tree
		for id, node, metadata in query:iter_captures(root, source_buf, source_start, source_end) do
			local srow, scol, erow, ecol = node:range()
			
			-- Map to multibuffer coordinates
			local target_srow = target_start + (srow - source_start)
			local target_erow = target_start + (erow - source_start)

			-- Determine the highlight group name
			local capture_name = query.captures[id]
			local hl_group = "@" .. capture_name .. "." .. lang

			-- Apply as an ephemeral highlight during the redraw cycle
			vim.api.nvim_buf_set_extmark(multibuf, M.multibuf_hl_ns, target_srow, scol, {
				end_row = target_erow,
				end_col = ecol,
				hl_group = hl_group,
				priority = tonumber(metadata.priority) or 100,
				ephemeral = true,
			})
		end
	end)
end

--- @param opts MultibufSetupOptions
function M.setup(opts)
	M.user_opts = vim.tbl_deep_extend('force', M.user_opts, opts)
	M.multibuf__ns = vim.api.nvim_create_namespace("Multibuf")
	M.multibuf_hl_ns = vim.api.nvim_create_namespace("MultibufHighlights")

	-- Decoration provider to mirror ALL highlights dynamically during redraw
	vim.api.nvim_set_decoration_provider(M.multibuf_hl_ns, {
		on_win = function(_, winid, multibuf, toprow, botrow)
			local multibuf_info = multibufs[multibuf]
			if not multibuf_info then return false end

			-- Scan visible range in multibuffer for slices
			local slices = vim.api.nvim_buf_get_extmarks(multibuf, M.multibuf__ns, { toprow, 0 }, { botrow, -1 }, {
				details = true,
				overlap = true,
			})

			for _, extmark in ipairs(slices) do
				local id = extmark[1]
				for _, buf_info in ipairs(multibuf_info.bufs) do
					for i, region_extmark_id in ipairs(buf_info.region_extmark_ids) do
						if id == region_extmark_id then
							local region_row_start, region_row_end = get_extmark_range(multibuf, region_extmark_id)
							local source_extmark_id = buf_info.source_extmark_ids[i]
							local source_row_start, source_row_end = get_extmark_range(buf_info.buf, source_extmark_id)
							
							-- Intersect visible range with slice range
							local visible_start = math.max(toprow, region_row_start)
							local visible_end = math.min(botrow, region_row_end)

							if visible_start < visible_end then
								local slice_offset = visible_start - region_row_start
								local s_start = source_row_start + slice_offset
								local s_end = s_start + (visible_end - visible_start)

								-- 1. Mirror Treesitter Highlights for this visible segment
								mirror_treesitter_highlights(multibuf, buf_info.buf, s_start, s_end, visible_start)
								
								-- 2. Mirror Persistent Extmarks (Diagnostics, etc.)
								-- (Optional: could be moved to mirror_treesitter_highlights for unified logic)
								local persistent = vim.api.nvim_buf_get_extmarks(buf_info.buf, -1, {s_start, 0}, {s_end, -1}, {details = true})
								for _, mark in ipairs(persistent) do
									local _, r, c, d = unpack(mark)
									if d.ns_id ~= M.multibuf__ns then
										local t_srow = visible_start + (r - s_start)
										local t_erow = d.end_row and (visible_start + (d.end_row - s_start))
										d.id = nil
										d.ns_id = nil
										d.end_row = t_erow
										d.ephemeral = true
										pcall(vim.api.nvim_buf_set_extmark, multibuf, M.multibuf_hl_ns, t_srow, c, d)
									end
								end
							end
						end
					end
				end
			end
			return true
		end,
	})

	vim.api.nvim_create_autocmd("BufWriteCmd", {
		pattern = "multibuffer://*",
		callback = function(args)
			local buf = args.buf
			M.mutlibuf__write(buf)
		end,
	})

	vim.api.nvim_create_autocmd("BufReadCmd", {
		pattern = "multibuffer://*",
		callback = function(args)
			local buf = args.buf
			M.multibuf_reload(buf)
		end,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		pattern = "*",
		callback = function(args)
			local buf = args.buf
			M.multibuf__wipeout(buf)
		end,
	})
end

return M
