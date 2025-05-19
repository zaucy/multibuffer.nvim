--- @class MultibufBufInfo
--- @field buf integer
--- @field source_extmark_id integer
--- @field virt_name_extmark_id integer|nil
--- @field source_change_autocmd_id integer

--- @class MultibufInfo
--- @field internal_buf integer
--- @field bufs MultibufBufInfo[]

--- @type MultibufInfo[]
local multibufs = {}

--- @type integer
local last_multibuf_id = 0

local M = {
	user_opts = {
	},
}

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

--- @return string[]
local function create_multibuf_header()
	return { "───────" }
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

--- @param multibuf integer
local function multibuf_buf_changed(multibuf, opts)
	local buf = opts.buf
	local extmark_id = opts.extmark_id

	-- TODO: don't reload whole multibuf just related buffers/extmarks
	M.multibuf_reload(multibuf)
end

--- @return integer
function M.create_multibuf()
	local new_multibuf_id = last_multibuf_id + 1
	last_multibuf_id = new_multibuf_id

	--- @type MultibufInfo
	local multibuf_info = {
		internal_buf = vim.api.nvim_create_buf(true, false),
		bufs = {},
	}
	assert(multibuf_info.internal_buf ~= 0, "failed to create internal buf for multibuf")
	vim.api.nvim_buf_set_name(multibuf_info.internal_buf, "multibuffer://" .. new_multibuf_id)
	-- vim.api.nvim_set_option_value("filetype", "multibuffer", { buf = multibuf_info.internal_buf })
	vim.api.nvim_set_option_value("buftype", "acwrite", { buf = multibuf_info.internal_buf })
	-- always have header line because we can't put virtual text above the first line in a buffer
	local header = create_multibuf_header()
	vim.api.nvim_buf_set_lines(multibuf_info.internal_buf, 0, #header, true, header)
	vim.api.nvim_set_option_value("modified", false, { buf = multibuf_info.internal_buf })
	table.insert(multibufs, new_multibuf_id, multibuf_info)

	return new_multibuf_id
end

--- @param multibuf integer
--- @return boolean
function M.multibuf_is_valid(multibuf)
	local multibuf_info = multibufs[multibuf]
	return multibuf_info ~= nil
end

--- @class MultibufAddBufOptions
--- @field buf integer
--- @field start_row integer
--- @field end_row integer

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
		not vim.api.nvim_get_option_value("modified", { buf = multibuf_info.internal_buf }),
		"cannot add buf to modified multibuf"
	)

	for index, opts in ipairs(opts_list) do
		assert(opts ~= nil, string.format("invalid opts at index %i", index))
		assert(vim.api.nvim_buf_is_valid(opts.buf), string.format("invalid buf at index %i", index))
		assert(opts.end_row >= opts.start_row, string.format("end_row must be >= start_row at index %i", index))
	end

	for _, opts in ipairs(opts_list) do
		local buf = opts.buf
		local source_line_count = vim.api.nvim_buf_line_count(buf)
		local start_row = clamp(opts.start_row, 0, source_line_count - 1)
		local end_row = clamp(opts.end_row + 1, 0, source_line_count)

		local source_extmark_id = vim.api.nvim_buf_set_extmark(buf, M.multibuf__ns, start_row, 0, {
			strict = true,
			end_row = end_row,
			priority = 20000, -- ya i dunno
		})

		local autocmd_id = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
			buffer = buf,
			callback = function(args)
				multibuf_buf_changed(multibuf, { extmark_id = source_extmark_id, buf = args.buf })
			end,
		})

		--- @type MultibufBufInfo
		local multibuf_buf_info = {
			buf = buf,
			source_extmark_id = source_extmark_id,
			virt_name_extmark_id = nil,
			source_change_autocmd_id = autocmd_id,
		}
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
	local multibuf_info = multibufs[multibuf]
	vim.api.nvim_win_set_buf(window, multibuf_info.internal_buf)
end

--- @param multibuf integer
--- @param opts vim.api.keyset.buf_delete
function M.multibuf_delete(multibuf, opts)
	assert(M.multibuf_is_valid(multibuf), "invalid multibuf")
	local multibuf_info = multibufs[multibuf]
	vim.api.nvim_buf_delete(multibuf_info.internal_buf, opts)
	multibufs[multibuf] = nil
end

function M.multibuf__internal_buf(multibuf)
	assert(M.multibuf_is_valid(multibuf), "invalid multibuf")
	local multibuf_info = multibufs[multibuf]
	return multibuf_info.internal_buf
end

function M.multibuf__from_internal_buf(bufnr)
	for multibuf, info in ipairs(multibufs) do
		if info.internal_buf == bufnr then
			return multibuf
		end
	end

	return nil
end

function M.multibuf_reload(multibuf)
	assert(M.multibuf_is_valid(multibuf), "invalid multibuf")
	local multibuf_info = multibufs[multibuf]
	local win = get_buf_win(multibuf_info.internal_buf)
	local cursor_pos
	if win ~= nil then
		cursor_pos = vim.api.nvim_win_get_cursor(win)
	end

	-- clearing whole buffer, not sure if this is necessary in all situations
	vim.api.nvim_buf_set_lines(multibuf_info.internal_buf, 0, -1, true, {})
	vim.fn.sign_unplace("", { buffer = multibuf_info.internal_buf })

	local all_lines = create_multibuf_header()
	local header_length = #all_lines
	local virt_name_indices = {}

	for _, buf_info in ipairs(multibuf_info.bufs) do
		local result    = vim.api.nvim_buf_get_extmark_by_id(
			buf_info.buf,
			M.multibuf__ns,
			buf_info.source_extmark_id,
			{ details = true }
		)

		local start_row = result[1]
		local end_row   = result[3].end_row
		local lines     = vim.api.nvim_buf_get_lines(buf_info.buf, start_row, end_row, true)

		table.insert(virt_name_indices, #all_lines)
		vim.list_extend(all_lines, lines)
		vim.api.nvim_buf_set_lines(multibuf_info.internal_buf, -2, -2, true, lines)
	end

	vim.api.nvim_buf_set_lines(multibuf_info.internal_buf, 0, #all_lines, true, all_lines)

	assert(#multibuf_info.bufs == #virt_name_indices)

	for index, buf_info in ipairs(multibuf_info.bufs) do
		local virt_name_index = virt_name_indices[index]
		buf_info.virt_name_extmark_id = vim.api.nvim_buf_set_extmark(
			multibuf_info.internal_buf,
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
	for _, buf_info in ipairs(multibuf_info.bufs) do
		local result    = vim.api.nvim_buf_get_extmark_by_id(
			buf_info.buf,
			M.multibuf__ns,
			buf_info.source_extmark_id,
			{ details = true }
		)

		local start_row = result[1]
		local end_row   = result[3].end_row

		for line_index = start_row, end_row - 1 do
			local signs = get_line_number_signs(line_index + 1)
			lnum = lnum + 1
			for digit_index, sign in ipairs(signs) do
				local group = "___MultibufferDigitGroup" .. digit_index
				local priority = 11 + ((digit_index - 10) * -1)
				vim.fn.sign_place(0, group, sign, multibuf_info.internal_buf, { lnum = lnum, priority = priority })
			end

			vim.fn.sign_place(0, "___MultibufferDigitGroup100Space", "MutlibufferDigitSpacer", multibuf_info
				.internal_buf, { lnum = lnum, priority = 9 })
		end
	end

	vim.api.nvim_set_option_value("modified", false, { buf = multibuf_info.internal_buf })

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

--- @return any[]
function M.default_render_multibuf_title(bufnr)
	return {
		{ { "" } },
		{ { " " .. vim.api.nvim_buf_get_name(bufnr) .. "  " } },
		{ { "" } },
	}
end

function M.setup(opts)
	M.user_opts = opts
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
			local multibuf = M.multibuf__from_internal_buf(buf)
			M.mutlibuf__write(multibuf)
		end,
	})

	vim.api.nvim_create_autocmd("BufReadCmd", {
		pattern = "multibuffer://*",
		callback = function(args)
			local buf = args.buf
			local multibuf = M.multibuf__from_internal_buf(buf)
			M.multibuf_reload(multibuf)
		end,
	})
end

return M
