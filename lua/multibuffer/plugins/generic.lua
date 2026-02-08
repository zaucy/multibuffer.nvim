local M = {}

--- @class multibuf.plugins.GenericSearchOptions
--- @field default_input string|nil
--- @field prompt string|nil
--- @field expand_size number|nil
--- @field on_input_changed fun(input: string)

--- @param opts multibuf.plugins.GenericSearchOptions
function M.multibuf_generic_search(opts)
	vim.validate("opts", opts, "table")
	local default_input = opts.default_input or ""
	local prompt_string = opts.prompt or " "
	local expand_size = opts.expand_size or 0

	vim.validate("opts.on_input_changed", opts.on_input_changed, "function")

	local api = require("multibuffer")

	local search_mbuf = api.create_multibuf()
	local win = vim.api.nvim_get_current_win()
	local win_opts = vim.api.nvim_win_get_config(win)
	vim.api.nvim_win_set_buf(win, search_mbuf)

	api.multibuf_set_header(search_mbuf, { "", "", "", "" })

	local prompt_bufnr = vim.api.nvim_create_buf(false, false)
	vim.bo[prompt_bufnr].buftype = "prompt"
	vim.fn.prompt_setprompt(prompt_bufnr, prompt_string)

	local prompt_win = nil

	local function get_prompt_win_width()
		return win_opts.width - 14
	end

	local ensure_prompt_win = function()
		if prompt_win and vim.api.nvim_win_is_valid(prompt_win) then
			return
		end

		prompt_win = vim.api.nvim_open_win(prompt_bufnr, true, {
			relative = "win",
			anchor = "SW",
			row = 3,
			col = 6,
			height = 1,
			width = get_prompt_win_width(),
			border = "solid",
			win = win,
			fixed = true,
		})

		vim.api.nvim_create_autocmd({ "BufEnter" }, {
			callback = function()
				if not vim.api.nvim_win_is_valid(prompt_win) then
					return true
				end

				if vim.api.nvim_get_current_win() ~= prompt_win then
					return
				end

				local bufnr = vim.api.nvim_get_current_buf()
				if bufnr == prompt_bufnr then
					return
				end

				local config = vim.api.nvim_win_get_config(prompt_win)
				local attached_win = config.win
				if attached_win and vim.api.nvim_win_is_valid(attached_win) then
					vim.api.nvim_win_set_buf(attached_win, bufnr)
					vim.api.nvim_set_current_win(attached_win)
				end
				vim.api.nvim_win_set_buf(prompt_win, prompt_bufnr)
			end,
		})

		vim.wo[prompt_win].signcolumn = "no"
		vim.wo[prompt_win].number = false
		vim.wo[prompt_win].relativenumber = false
	end

	ensure_prompt_win()
	assert(prompt_win)

	local input = ""
	local input_change_defer_timer = nil

	local input_changed = vim.schedule_wrap(function()
		if input_change_defer_timer then
			vim.uv.timer_stop(input_change_defer_timer)
			input_change_defer_timer = nil
		end
		input_change_defer_timer = vim.defer_fn(function()
			opts.on_input_changed(input)
		end, 50)
	end)

	local function open_source_buf(mbuf, cursor_col)
		local winid = vim.api.nvim_get_current_win()
		local cursor = vim.api.nvim_win_get_cursor(winid)
		local winline = vim.fn.winline()

		local buf, line = api.multibuf_get_buf_at_line(mbuf, cursor[1])
		if buf then
			vim.api.nvim_set_current_buf(buf)
			vim.api.nvim_win_set_cursor(0, { line, cursor_col or cursor[2] })
			vim.fn.winrestview({ topline = line - winline + 1 })
		end
	end

	local function submit()
		local line_count = vim.api.nvim_buf_line_count(search_mbuf)
		local cursor = vim.api.nvim_win_get_cursor(win)
		if cursor[1] <= 3 then
			vim.api.nvim_win_set_cursor(win, { math.min(5 + expand_size, line_count), 0 })
		end
		vim.api.nvim_set_current_win(win)
		open_source_buf(search_mbuf)
	end

	local update_input = function()
		vim.api.nvim_set_option_value("modified", false, { buf = prompt_bufnr })
		local new_input = vim.trim(vim.fn.prompt_getinput(prompt_bufnr))
		if new_input ~= input then
			input = new_input
			input_changed()
		end
	end

	-- we intentionally don't use prompt_setcallback
	vim.keymap.set({ "i", "s", "n", "v" }, "<cr>", function()
		update_input()
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true), "n", true)
		submit()
	end, { noremap = true, buffer = prompt_bufnr })

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
		buffer = prompt_bufnr,
		callback = function()
			update_input()
		end,
	})

	local move_to_mbuf = function(key)
		return function()
			vim.api.nvim_set_current_win(win)
			local line_count = vim.api.nvim_buf_line_count(search_mbuf)
			local cursor = vim.api.nvim_win_get_cursor(win)
			if cursor[1] <= 3 then
				vim.api.nvim_win_set_cursor(win, { math.min(4, line_count), 0 })
			end
			if key then
				vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", true)
			end
		end
	end

	local motion_keys = {
		"j",
		-- "k",
		"<Down>",
		-- "<Up>",
		"<C-d>",
		"<C-u>",
		"<C-f>",
		"<C-b>",
		"<C-o>",
		"<PageDown>",
		"<PageUp>",
		"G",
		"gg",
	}

	for _, key in ipairs(motion_keys) do
		-- only map printable keys in normal mode to avoid blocking typing in insert mode
		local modes = (string.len(key) > 1 or key:match("%W")) and { "n", "i", "s" } or { "n", "s" }
		vim.keymap.set(modes, key, move_to_mbuf(key), { buffer = prompt_bufnr })
	end

	vim.keymap.set({ "n", "i", "s" }, "<C-w>", function()
		vim.api.nvim_set_current_win(win)
		local line_count = vim.api.nvim_buf_line_count(search_mbuf)
		local cursor = vim.api.nvim_win_get_cursor(win)
		if cursor[1] <= 3 then
			vim.api.nvim_win_set_cursor(win, { math.min(4, line_count), 0 })
		end
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-\\><C-n><C-w>", true, false, true), "n", true)
	end, { buffer = prompt_bufnr, nowait = true, noremap = true })

	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		buffer = search_mbuf,
		callback = function()
			if vim.api.nvim_get_current_win() ~= win then
				return
			end
			local cursor = vim.api.nvim_win_get_cursor(win)
			if cursor[1] <= 3 then
				ensure_prompt_win()
				vim.api.nvim_set_current_win(prompt_win)
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
		callback = function()
			local current_win = vim.api.nvim_get_current_win()
			if current_win == prompt_win then
				return
			end

			local current_win_buf = vim.api.nvim_win_get_buf(current_win)
			if current_win_buf == search_mbuf then
				ensure_prompt_win()
				win = current_win
				win_opts = vim.api.nvim_win_get_config(win)
				vim.api.nvim_win_set_width(prompt_win, get_prompt_win_width())

				local prompt_win_options = vim.api.nvim_win_get_config(prompt_win)
				prompt_win_options.win = win
				prompt_win_options.hide = false
				vim.api.nvim_win_set_config(prompt_win, prompt_win_options)
			elseif current_win == win then
				local prompt_win_options = vim.api.nvim_win_get_config(prompt_win)
				prompt_win_options.hide = true
				vim.api.nvim_win_set_config(prompt_win, prompt_win_options)
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "WinClosed" }, {
		buffer = search_mbuf,
		callback = function(args)
			assert(args.buf == search_mbuf)
			local prompt_win_options = vim.api.nvim_win_get_config(prompt_win)
			prompt_win_options.hide = true
			vim.api.nvim_win_set_config(prompt_win, prompt_win_options)
		end,
	})

	vim.api.nvim_create_autocmd({ "WinResized" }, {
		callback = function(args)
			if args.buf ~= search_mbuf then
				return
			end

			win = vim.api.nvim_get_current_win()

			ensure_prompt_win()
			assert(prompt_win)

			win_opts = vim.api.nvim_win_get_config(win)
			vim.api.nvim_win_set_width(prompt_win, get_prompt_win_width())
		end,
	})

	vim.cmd("startinsert")
	if default_input ~= "" then
		vim.api.nvim_feedkeys(default_input, "n", true)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>vT <C-g>", true, false, true), "n", true)
		vim.schedule(function()
			opts.on_input_changed(default_input)
		end)
	end

	return search_mbuf
end

return M
