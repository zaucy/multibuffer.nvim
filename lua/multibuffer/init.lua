--- @class MultibufBufInfo
--- @field buf integer
--- @field virt_name_extmark_id integer|nil
--- @field source_extmark_ids integer[]
--- @field region_extmark_ids integer[] should be same length as source_extmark_ids
--- @field virt_expand_extmark_ids integer[] should be same length as source_extmark_ids

--- @class MultibufInfo
--- @field bufs MultibufBufInfo[]

--- @type table<integer, MultibufInfo>
local multibufs = {}

--- @class MultibufBufListener
--- @field multibufs integer[]
--- @field change_autocmd_id integer

--- @type table<integer, MultibufBufListener>
local buf_listeners = {}

local M = {
	user_opts = {
		keymaps = {}
	},
}

-- ──────── Helper Functions ────────

local function list_insert_unique(list, item)
	for _, v in ipairs(list) do
		if v == item then return end
	end
	table.insert(list, item)
end

local function clamp(num, min, max)
	if num < min then return min elseif num > max then return max end
	return num
end

local function get_buf_win(buf)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == buf then return win end
	end
	return nil
end

--- Generates 2-digit sign strings for line numbers
local function get_line_number_signs(line_num)
	local str = tostring(line_num)
	local result = {}
	for i = #str, 1, -2 do
		local start = math.max(1, i - 1)
		table.insert(result, 1, str:sub(start, i))
	end
	return result
end

local function get_extmark_range(buf, extmark)
	local result = vim.api.nvim_buf_get_extmark_by_id(buf, M.multibuf__ns, extmark, { details = true })
	if not result or not result[1] then return 0, 0 end
	return result[1], result[3].end_row
end

local function create_multibuf_header()
	return { " ─────── " }
end

local function render_multibuf_title(bufnr)
	if M.user_opts.render_multibuf_title then
		local success, lines_or_error = pcall(M.user_opts.render_multibuf_title, bufnr)
		if success then return lines_or_error end
		vim.notify(lines_or_error, vim.log.levels.ERROR)
	end
	return M.default_render_multibuf_title(bufnr)
end

local function render_expand_lines(opts)
	if M.user_opts.render_expand_lines then
		local success, lines_or_error = pcall(M.user_opts.render_expand_lines, opts)
		if success then return lines_or_error end
		vim.notify(lines_or_error, vim.log.levels.ERROR)
	end
	return M.default_render_expand_lines(opts)
end

local function multibuf_buf_changed(args)
	local listener_info = buf_listeners[args.buf]
	if listener_info then
		for _, multibuf in ipairs(listener_info.multibufs) do
			M.multibuf_reload(multibuf)
		end
	end
end

-- ──────── Structural Rendering ────────

local function place_line_number_signs(multibuf, target_row, source_row)
	local signs = get_line_number_signs(source_row + 1)
	for digit_idx, text in ipairs(signs) do
		if #text == 1 then text = " " .. text end -- Pad single digits
		vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, target_row, 0, {
			sign_text = text,
			sign_hl_group = "LineNr",
			priority = 100 - digit_idx,
		})
	end
	-- Spacer sign for gutter padding
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

-- ──────── Highlight Projection (Live UI Mirroring) ────────

--- Projects highlights from source to multibuffer using ephemeral extmarks.
--- This is called during the redraw cycle (on_win).
local function project_highlights(multibuf, source_buf, s_start, s_end, target_start)
	-- 1. Project Treesitter Highlights
	local ft = vim.api.nvim_get_option_value("filetype", { buf = source_buf })
	local lang = vim.treesitter.language.get_lang(ft)
	
	if lang and pcall(vim.treesitter.language.add, lang) then
		pcall(function()
			-- Use { error = false } to prevent hard crashes in recent Nvim versions
			local parser = vim.treesitter.get_parser(source_buf, lang, { error = false })
			if not parser then return end

			parser:parse({ s_start, s_end })
			parser:for_each_tree(function(tstree, tree)
				local tlang = tree:lang()
				local query = vim.treesitter.query.get(tlang, "highlights")
				if not query then return end
				for id, node, metadata in query:iter_captures(tstree:root(), source_buf, s_start, s_end) do
					local sr, sc, er, ec = node:range()
					local tr = target_start + (sr - s_start)
					local ter = target_start + (er - s_start)
					vim.api.nvim_buf_set_extmark(multibuf, M.multibuf_hl_ns, tr, sc, {
						end_row = ter, end_col = ec,
						hl_group = "@" .. query.captures[id] .. "." .. tlang,
						priority = tonumber(metadata.priority) or 100,
						ephemeral = true,
					})
				end
			end)
		end)
	end

	-- 2. Project Persistent Extmarks (LSP Diagnostics, Gitsigns, etc.)
	local persistent = vim.api.nvim_buf_get_extmarks(source_buf, -1, {s_start, 0}, {s_end, -1}, {details = true})
	for _, mark in ipairs(persistent) do
		local _, r, c, d = unpack(mark)
		if d.ns_id ~= M.multibuf__ns then
			local tr = target_start + (r - s_start)
			local ter = d.end_row and (target_start + (d.end_row - s_start))
			d.id, d.ns_id, d.end_row, d.ephemeral = nil, nil, ter, true
			pcall(vim.api.nvim_buf_set_extmark, multibuf, M.multibuf_hl_ns, tr, c, d)
		end
	end
end

-- ──────── Core Multibuffer Management ────────

function M.multibuf_reload(multibuf)
	local info = multibufs[multibuf]
	if not info then return end
	local win = get_buf_win(multibuf)
	local cursor_pos = win and vim.api.nvim_win_get_cursor(win)

	vim.api.nvim_buf_clear_namespace(multibuf, M.multibuf__ns, 0, -1)

	local header = create_multibuf_header()
	local all_lines = { unpack(header) }
	local virt_name_indices = {}
	local virt_expand_lnums = {}

	-- 1. Build Text Content
	for _, buf_info in ipairs(info.bufs) do
		table.insert(virt_name_indices, #all_lines)
		for _, source_extmark_id in ipairs(buf_info.source_extmark_ids) do
			local s_start, s_end = get_extmark_range(buf_info.buf, source_extmark_id)
			table.insert(virt_expand_lnums, #all_lines)
			vim.list_extend(all_lines, vim.api.nvim_buf_get_lines(buf_info.buf, s_start, s_end, true))
		end
	end
	table.insert(virt_expand_lnums, #all_lines)
	vim.api.nvim_buf_set_lines(multibuf, 0, -1, true, all_lines)

	-- 2. Render Structure (Titles, Signs, Expanders)
	local current_lnum = #header
	local virt_expand_idx = 1

	for b_idx, buf_info in ipairs(info.bufs) do
		vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, virt_name_indices[b_idx], 0, {
			virt_lines = render_multibuf_title(buf_info.buf),
			virt_lines_above = true, virt_lines_leftcol = true, priority = 20001,
		})

		local last_s_end = 0
		for s_idx, src_extmark_id in ipairs(buf_info.source_extmark_ids) do
			local s_start, s_end = get_extmark_range(buf_info.buf, src_extmark_id)
			local slice_len = s_end - s_start

			for i = 0, slice_len - 1 do
				place_line_number_signs(multibuf, current_lnum + i, s_start + i)
			end

			place_expander(multibuf, virt_expand_lnums[virt_expand_idx], {
				expand_direction = (s_idx == 1) and "above" or "both",
				count = s_start - last_s_end, window = win or 0,
			})

			buf_info.region_extmark_ids[s_idx] = vim.api.nvim_buf_set_extmark(multibuf, M.multibuf__ns, current_lnum, 0, {
				end_row = current_lnum + slice_len, end_right_gravity = true,
			})

			current_lnum, last_s_end, virt_expand_idx = current_lnum + slice_len, s_end, virt_expand_idx + 1
		end
	end

	vim.api.nvim_set_option_value("modified", false, { buf = multibuf })
	if win and cursor_pos then vim.api.nvim_win_set_cursor(win, cursor_pos) end
end

function M.setup(opts)
	M.user_opts = vim.tbl_deep_extend('force', M.user_opts, opts)
	M.multibuf__ns = vim.api.nvim_create_namespace("Multibuf")
	M.multibuf_hl_ns = vim.api.nvim_create_namespace("MultibufHighlights")

	-- Decoration provider mirrors source highlights into the multibuffer viewport
	vim.api.nvim_set_decoration_provider(M.multibuf_hl_ns, {
		on_win = function(_, _, multibuf, top, bot)
			-- Safety: skip if this isn't a known multibuffer
			if not M.multibuf_is_valid(multibuf) then return false end
			
			local info = multibufs[multibuf]
			if not info then return false end

			local slices = vim.api.nvim_buf_get_extmarks(multibuf, M.multibuf__ns, {top, 0}, {bot, -1}, {details = true, overlap = true})
			for _, extmark in ipairs(slices) do
				for _, b_info in ipairs(info.bufs) do
					for i, reg_id in ipairs(b_info.region_extmark_ids) do
						if extmark[1] == reg_id then
							local r_start, r_end = get_extmark_range(multibuf, reg_id)
							local s_start, _ = get_extmark_range(b_info.buf, b_info.source_extmark_ids[i])
							
							local v_start, v_end = math.max(top, r_start), math.min(bot, r_end)
							if v_start < v_end then
								local s_range_start = s_start + (v_start - r_start)
								local s_range_end = s_range_start + (v_end - v_start)
								
								-- Only project if source buffer has a valid Treesitter language
								local s_ft = vim.api.nvim_get_option_value("filetype", { buf = b_info.buf })
								local s_lang = vim.treesitter.language.get_lang(s_ft)
								if s_lang then
									project_highlights(multibuf, b_info.buf, s_range_start, s_range_end, v_start)
								end
							end
						end
					end
				end
			end
			return true
		end,
	})

	vim.api.nvim_create_autocmd({"BufReadCmd", "BufWriteCmd"}, {
		pattern = "multibuffer://*",
		callback = function(args) 
			-- Prevent automatic TS attachment which causes errors on these composite buffers
			pcall(vim.treesitter.stop, args.buf)
			M.multibuf_reload(args.buf) 
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		pattern = "*", callback = function(args) M.multibuf__wipeout(args.buf) end,
	})
end

-- ──────── Boilerplate / Legacy Mappings ────────

function M.create_multibuf()
	local id = vim.api.nvim_create_buf(true, false)
	local info = { bufs = {} }
	vim.api.nvim_buf_set_name(id, "multibuffer://" .. id)
	vim.api.nvim_set_option_value("buftype", "acwrite", { buf = id })
	local header = create_multibuf_header()
	vim.api.nvim_buf_set_lines(id, 0, #header, true, header)
	multibufs[id] = info
	return id
end

function M.multibuf_is_valid(buf) return multibufs[buf] ~= nil end

function M.multibuf_add_buf(mb, opts) M.multibuf_add_bufs(mb, { opts }) end

function M.multibuf_add_bufs(mb, opts_list)
	local info = multibufs[mb]
	for _, opts in ipairs(opts_list) do
		local buf = opts.buf
		local line_count = vim.api.nvim_buf_line_count(buf)
		local source_ids = {}
		for _, region in ipairs(opts.regions) do
			table.insert(source_ids, vim.api.nvim_buf_set_extmark(buf, M.multibuf__ns, 
				clamp(region.start_row, 0, line_count-1), 0, {
					end_row = clamp(region.end_row + 1, 0, line_count),
					end_right_gravity = true,
				}))
		end
		if not buf_listeners[buf] then
			local id = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
				buffer = buf, callback = multibuf_buf_changed,
			})
			buf_listeners[buf] = { change_autocmd_id = id, multibufs = { mb } }
		else
			list_insert_unique(buf_listeners[buf].multibufs, mb)
		end
		table.insert(info.bufs, {
			buf = buf, source_extmark_ids = source_ids, region_extmark_ids = {},
			virt_expand_extmark_ids = {},
		})
	end
	M.multibuf_reload(mb)
end

function M.win_set_multibuf(win, mb) vim.api.nvim_win_set_buf(win, mb) end

function M.multibuf__wipeout(buf)
	multibufs[buf] = nil
	if buf_listeners[buf] then
		vim.api.nvim_del_autocmd(buf_listeners[buf].change_autocmd_id)
		buf_listeners[buf] = nil
	end
end

function M.multibuf_get_buf_at_line(mb, line)
	local info = multibufs[mb]
	local marks = vim.api.nvim_buf_get_extmarks(mb, M.multibuf__ns, {line, 0}, {line, -1}, {details = true, overlap = true})
	for _, m in ipairs(marks) do
		for _, b in ipairs(info.bufs) do
			for i, rid in ipairs(b.region_extmark_ids) do
				if m[1] == rid then
					local rs, _ = get_extmark_range(mb, rid)
					local ss, _ = get_extmark_range(b.buf, b.source_extmark_ids[i])
					return b.buf, ss + (line - rs)
				end
			end
		end
	end
end

function M.default_render_multibuf_title(buf)
	return { {{""}}, {{ " " .. vim.api.nvim_buf_get_name(buf) .. "  ", "TabLine" }}, {{""}} }
end

function M.default_render_expand_lines(opts)
	if opts.count <= 0 then return {} end
	local icons = { above = "↑", below = "↓", both = "↕" }
	local text = string.format(" --- [ %s %i ] ", icons[opts.expand_direction], opts.count)
	local width = vim.api.nvim_win_get_width(opts.window)
	return { {{ text, "Folded" }, { string.rep("-", width - #text) .. " ", "Folded" }} }
end

return M
