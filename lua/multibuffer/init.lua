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
	local digits = {}
	local result = {}

	for digit in tostring(line_num):gmatch("%d") do
		table.insert(digits, tonumber(digit))
	end

	for i = #digits, 2, -2 do
		local two_digit = digits[i - 1] .. digits[i]
		table.insert(result, 1, "MutlibufferDigit" .. two_digit)
	end

	if #digits % 2 == 1 then
		table.insert(result, 1, "MutlibufferDigit" .. digits[1])
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
	table.insert(multibufs, new_multibuf_id, multibuf_info)

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
		listener_info[buf] = nil
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

	vim.fn.sign_unplace("", { buffer = multibuf })

	local all_lines = create_multibuf_header()
	local header_length = #all_lines
	local virt_name_indices = {}
	local virt_expand_lnums = {}

	for _, buf_info in ipairs(multibuf_info.bufs) do
		table.insert(virt_name_indices, #all_lines)
		for _, source_extmark_id in ipairs(buf_info.source_extmark_ids) do
			local result    = vim.api.nvim_buf_get_extmark_by_id(
				buf_info.buf,
				M.multibuf__ns,
				source_extmark_id,
				{ details = true }
			)

			local start_row = result[1]
			local details   = result[3]
			assert(details ~= nil, "no extmark details")
			local end_row = details.end_row
			assert(end_row ~= nil, "bad end_row")
			assert(start_row >= 0, string.format("bad start row %i", start_row))
			assert(end_row > start_row, string.format("bad end row %i (start row is %i)", end_row, start_row))
			local lines = vim.api.nvim_buf_get_lines(buf_info.buf, start_row, end_row, true)
			assert(#lines > 0)

			table.insert(virt_expand_lnums, #all_lines)
			vim.list_extend(all_lines, lines)
		end
	end

	table.insert(virt_expand_lnums, #all_lines)
	vim.api.nvim_buf_set_lines(multibuf, 0, vim.api.nvim_buf_line_count(multibuf), true, all_lines)

	assert(#multibuf_info.bufs == #virt_name_indices)

	for index, buf_info in ipairs(multibuf_info.bufs) do
		local virt_name_index = virt_name_indices[index]
		buf_info.virt_name_extmark_id = vim.api.nvim_buf_set_extmark(
			multibuf,
			M.multibuf__ns,
			virt_name_index,
			0,
			{
				id = buf_info.virt_name_extmark_id,
				virt_lines = render_multibuf_title(buf_info.buf),
				virt_lines_above = true,
				virt_lines_leftcol = true,
				strict = true,
				priority = 20001,
			}
		)
	end

	local lnum = header_length
	local virt_expand_index = 1
	for _, buf_info in ipairs(multibuf_info.bufs) do
		local last_end_row = 0
		for source_extmark_id_index, source_extmark_id in ipairs(buf_info.source_extmark_ids) do
			local start_row, end_row = get_extmark_range(buf_info.buf, source_extmark_id)

			for line_index = start_row, end_row - 1 do
				local signs = get_line_number_signs(line_index + 1)
				lnum = lnum + 1
				for digit_index, sign in ipairs(signs) do
					local group = "___MultibufferDigitGroup" .. digit_index
					local priority = 11 + ((digit_index - 10) * -1)
					vim.fn.sign_place(0, group, sign, multibuf, { lnum = lnum, priority = priority })
				end

				vim.fn.sign_place(0, "___MultibufferDigitGroup100Space", "MutlibufferDigitSpacer", multibuf,
					{ lnum = lnum, priority = 9 })
			end

			--- @type "above"|"below"|"both"
			local expand_direction = "both"
			if source_extmark_id_index == 1 then
				expand_direction = "above"
			end

			local virt_expand_lnum = virt_expand_lnums[virt_expand_index]
			local expand_render_lines = render_expand_lines({
				expand_direction = expand_direction,
				count = start_row - last_end_row,
				window = win or 0,
			})
			buf_info.virt_expand_extmark_ids[source_extmark_id_index] = vim.api.nvim_buf_set_extmark(
				multibuf,
				M.multibuf__ns,
				virt_expand_lnum,
				0,
				{
					id = buf_info.virt_expand_extmark_ids[source_extmark_id_index],
					virt_lines = expand_render_lines,
					virt_lines_above = true,
					virt_lines_leftcol = true,
					strict = true,
					priority = 20001,
				}
			)

			last_end_row = end_row
			virt_expand_index = virt_expand_index + 1
		end

		-- TODO: need to add below expander
		-- local virt_expand_lnum = virt_expand_lnums[virt_expand_index]
		-- local expand_render_lines = render_expand_lines({
		-- 	expand_direction = "below",
		-- 	count = 1,
		-- 	window = win or 0,
		-- })
		-- buf_info.virt_expand_extmark_ids[#buf_info.source_extmark_ids] = vim.api.nvim_buf_set_extmark(
		-- 	multibuf,
		-- 	M.multibuf__ns,
		-- 	virt_expand_lnum,
		-- 	0,
		-- 	{
		-- 		id = buf_info.virt_expand_extmark_ids[#buf_info.source_extmark_ids],
		-- 		virt_lines = expand_render_lines,
		-- 		virt_lines_above = true,
		-- 		virt_lines_leftcol = true,
		-- 		strict = true,
		-- 		priority = 20001,
		-- 	}
		-- )
	end


	local current_multibuf_line_index = header_length
	for _, buf_info in ipairs(multibuf_info.bufs) do
		for i, source_extmark in ipairs(buf_info.source_extmark_ids) do
			local source_start_row, source_end_row = get_extmark_range(buf_info.buf, source_extmark)
			local source_length = source_end_row - source_start_row

			buf_info.region_extmark_ids[i] = vim.api.nvim_buf_set_extmark(
				multibuf,
				M.multibuf__ns,
				current_multibuf_line_index,
				0,
				{
					id = buf_info.region_extmark_ids[i],
					end_row = current_multibuf_line_index + source_length,
					end_right_gravity = true,
				}
			)

			current_multibuf_line_index = current_multibuf_line_index + source_length
		end
	end


	for _, buf_info in ipairs(multibuf_info.bufs) do
		while #buf_info.region_extmark_ids > #buf_info.source_extmark_ids do
			local old_extmark = table.remove(buf_info.region_extmark_ids, #buf_info.region_extmark_ids)
			vim.api.nvim_buf_del_extmark(multibuf, M.multibuf__ns, old_extmark)
		end
	end

	vim.api.nvim_set_option_value("modified", false, { buf = multibuf })

	if win ~= nil then
		assert(cursor_pos ~= nil)
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

--- @param opts MultibufSetupOptions
function M.setup(opts)
	M.user_opts = vim.tbl_deep_extend('force', M.user_opts, opts)
	M.multibuf__ns = vim.api.nvim_create_namespace("Multibuf")

	for i = 0, 9 do
		vim.fn.sign_define("MutlibufferDigit" .. tostring(i), { text = " " .. tostring(i), texthl = "LineNr" })
		vim.fn.sign_define("MutlibufferDigit0" .. tostring(i), { text = "0" .. tostring(i), texthl = "LineNr" })
	end

	for i = 10, 99 do
		vim.fn.sign_define("MutlibufferDigit" .. tostring(i), { text = tostring(i), texthl = "LineNr" })
	end

	-- NOTE: in the future this spacer should be reserved for some plugin like gitsigns or others that want to show their signs in the multibuf
	vim.fn.sign_define("MutlibufferDigitSpacer", { text = " ", texthl = "LineNr" })

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
