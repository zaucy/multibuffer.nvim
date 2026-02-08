local M = {
	all_rg_matches = {},
	search_hl_ns = vim.api.nvim_create_namespace("multibuffer_ripgrep_search"),
	max_ripgrep_search_buf_count = 100,
	multibuffer_expand = 1,
}

vim.api.nvim_set_decoration_provider(M.search_hl_ns, {
	on_win = function(_, _, mbuf, top, bot)
		local api = require("multibuffer")
		local rg_matches = M.all_rg_matches[mbuf]
		if not rg_matches then
			return
		end
		for line = top, bot do
			local bufnr, s_lnum = api.multibuf_get_buf_at_line(mbuf, line)
			if bufnr and s_lnum then
				local matches = rg_matches[bufnr] and rg_matches[bufnr][s_lnum]
				if matches then
					for _, m in ipairs(matches) do
						vim.api.nvim_buf_set_extmark(mbuf, M.search_hl_ns, line, m.start, {
							end_col = m["end"],
							hl_group = "Search",
							ephemeral = true,
						})
					end
				end
			end
		end
	end,
})

function M.multibuf_ripgrep(opts)
	local default_input = opts.default_input or ""
	local api = require("multibuffer")

	local search_mbuf = api.create_multibuf()
	M.all_rg_matches[search_mbuf] = {}
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = search_mbuf,
		callback = function()
			M.all_rg_matches[search_mbuf] = nil
		end,
	})
	local win = vim.api.nvim_get_current_win()
	local win_opts = vim.api.nvim_win_get_config(win)
	vim.api.nvim_win_set_buf(win, search_mbuf)

	api.multibuf_set_header(search_mbuf, { "", "", "", "" })

	local prompt_bufnr = vim.api.nvim_create_buf(false, false)
	vim.bo[prompt_bufnr].buftype = "prompt"
	vim.fn.prompt_setprompt(prompt_bufnr, " ")

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

	--- @type uv.uv_process_t|nil
	local last_proc = nil
	--- @type uv.uv_pipe_t|nil
	local last_proc_stdout = nil
	--- @type uv.uv_pipe_t|nil
	local last_proc_stderr = nil

	local function stop_proc()
		if last_proc_stderr and not last_proc_stderr:is_closing() then
			last_proc_stderr:close(function() end)
			last_proc_stderr = nil
		end
		if last_proc_stdout and not last_proc_stdout:is_closing() then
			last_proc_stdout:close(function() end)
			last_proc_stdout = nil
		end
		if last_proc and not last_proc:is_closing() then
			-- last_proc:close(function() end)
			last_proc:kill("sigint")
			last_proc = nil
		end
	end

	--- @param query string
	local function spawn_proc(query)
		stop_proc()

		if not query then
			return
		end

		local new_proc_stdout, new_proc_stdout_err = vim.uv.new_pipe(false)
		assert(new_proc_stdout, new_proc_stdout_err)
		last_proc_stdout = new_proc_stdout

		local new_proc_stderr, new_proc_stderr_err = vim.uv.new_pipe(false)
		assert(new_proc_stderr, new_proc_stderr_err)
		last_proc_stderr = new_proc_stderr

		local spawn_args = {
			"--json",
			-- "--vimgrep",
			query,
		}

		local err_from_stderr = ""
		local new_proc
		local new_proc_err

		local cwd = vim.uv.cwd()
		assert(cwd)

		local on_proc_exit_safe = vim.schedule_wrap(function(code, _)
			if last_proc_stdout ~= new_proc_stdout then
				return
			end

			if code ~= 0 then
				local search_stats_text = string.format("ripgrep exited with code %i", code)
				if code == 1 then
					local pretty_cwd = cwd:gsub("\\", "/")
					local homedir = vim.fn.substitute(vim.fn.expand("~"), "\\\\", "/", "g")
					if vim.startswith(pretty_cwd, homedir) then
						pretty_cwd = "~" .. pretty_cwd:sub(#homedir + 1)
					end
					search_stats_text = string.format("ripgrep found 0 matches in %s", pretty_cwd)
				end
				local header = { "", "", "", search_stats_text }
				local error_lines = vim.split(err_from_stderr, "\n", {})
				for _, error_line in ipairs(error_lines) do
					table.insert(header, error_line)
				end
				api.multibuf_set_header(search_mbuf, header)
			end
		end)

		local function on_proc_exit(code, signal)
			if last_proc_stdout ~= new_proc_stdout then
				return
			end

			on_proc_exit_safe(code, signal)
		end

		new_proc, new_proc_err = vim.uv.spawn("rg", {
			stdio = { nil, new_proc_stdout, new_proc_stderr },
			hide = true,
			cwd = cwd,
			verbatim = false,
			args = spawn_args,
		}, on_proc_exit)

		assert(new_proc, new_proc_err)

		--- @type table<string, MultibufRegion[]>
		local regions_by_filename = {}
		--- @type table<string, table<integer, any>>
		local matches_by_filename = {}
		--- @type string[]
		local done_searching_paths = {}
		local done_schedule_active = false
		local total_searched_paths = 0
		local found_files = 0
		local stats = nil

		local process_done_searching_paths

		process_done_searching_paths = vim.schedule_wrap(function(batched_searching_paths)
			local add_opts = {}

			for _, path in ipairs(batched_searching_paths) do
				local path_bufnr = vim.fn.bufadd(path)
				local regions = regions_by_filename[path]

				M.all_rg_matches[search_mbuf][path_bufnr] = matches_by_filename[path]

				table.sort(regions, function(a, b)
					return a.start_row < b.start_row
				end)

				local merged_regions = {}
				for _, region in ipairs(regions) do
					if #merged_regions == 0 then
						table.insert(merged_regions, region)
					else
						local last = merged_regions[#merged_regions]
						if region.start_row <= last.end_row then
							last.end_row = math.max(last.end_row, region.end_row)
						else
							table.insert(merged_regions, region)
						end
					end
				end

				table.insert(add_opts, {
					buf = path_bufnr,
					regions = merged_regions,
				})
			end

			total_searched_paths = total_searched_paths + #batched_searching_paths

			if stats then
				local search_stats_text = string.format(
					"ripgrep found %i matches in %i files in %s; showing %i files",
					stats.matches,
					found_files,
					stats.elapsed.human,
					total_searched_paths
				)
				api.multibuf_set_header(search_mbuf, { "", "", "", search_stats_text })
			else
				local search_stats_text = string.format("ripgrep %i files", found_files)
				api.multibuf_set_header(search_mbuf, { "", "", "", search_stats_text })
			end

			api.multibuf_add_bufs(search_mbuf, add_opts)

			if #done_searching_paths > 0 and total_searched_paths < M.max_ripgrep_search_buf_count then
				vim.defer_fn(function()
					local next_batch = { table.remove(done_searching_paths, 1) }
					process_done_searching_paths(next_batch)
				end, 10)
				return
			end

			done_schedule_active = false
		end)

		local try_schedule_done_searching_paths = function()
			if done_schedule_active then
				return
			end

			if total_searched_paths >= M.max_ripgrep_search_buf_count then
				return
			end

			done_schedule_active = true
			local batch = { table.remove(done_searching_paths, 1) }
			process_done_searching_paths(batch)
		end

		vim.uv.read_start(new_proc_stderr, function(err, data)
			-- should have been closed, but ignore just incase
			if last_proc_stdout ~= new_proc_stdout then
				return
			end

			if err or not data then
				return
			end
			err_from_stderr = err_from_stderr .. data
		end)

		local stdout_leftovers = ""
		vim.uv.read_start(new_proc_stdout, function(err, data)
			-- should have been closed, but ignore just incase
			if last_proc_stdout ~= new_proc_stdout then
				return
			end

			if err or not data then
				if err then
					vim.schedule(function()
						vim.notify(err, vim.log.levels.ERROR)
					end)
				end
				return
			end

			local lines = vim.split(stdout_leftovers .. data, "\n", { plain = true })
			stdout_leftovers = table.remove(lines)

			for _, line in ipairs(lines) do
				if line ~= "" then
					local success, msg = pcall(vim.json.decode, line)

					if not success then
						vim.schedule(function()
							vim.notify("json decode fail: " .. vim.inspect(msg), vim.log.levels.ERROR)
						end)
						return
					end

					-- if msg.data.stats then
					-- 	stats = msg.data.stats
					-- end

					if msg.type == "begin" then
						local path = msg.data.path.text
						regions_by_filename[path] = {}
					elseif msg.type == "end" then
						local path = msg.data.path.text
						table.insert(done_searching_paths, path)
						found_files = found_files + 1
						try_schedule_done_searching_paths()
					elseif msg.type == "match" then
						local path = msg.data.path.text
						local match_lnum = msg.data.line_number
						--- @type MultibufRegion
						local region = {
							start_row = match_lnum - 1 - M.multibuffer_expand,
							end_row = match_lnum - 1 + M.multibuffer_expand,
						}
						assert(regions_by_filename[path])
						table.insert(regions_by_filename[path], region)

						if not matches_by_filename[path] then
							matches_by_filename[path] = {}
						end
						matches_by_filename[path][match_lnum - 1] = msg.data.submatches
					elseif msg.type == "summary" then
						stats = msg.data.stats
						try_schedule_done_searching_paths()
					end
				end
			end
		end)
	end

	local input = ""
	local spawn_defer_timer = nil

	local clear_header = function()
		api.multibuf_set_header(search_mbuf, { "", "", "", "" })
	end

	local input_changed = vim.schedule_wrap(function()
		api.multibuf_clear_bufs(search_mbuf)
		M.all_rg_matches[search_mbuf] = {}
		clear_header()
		if #input < 3 then
			stop_proc()
		else
			if spawn_defer_timer then
				vim.uv.timer_stop(spawn_defer_timer)
				spawn_defer_timer = nil
			end
			spawn_defer_timer = vim.defer_fn(function()
				spawn_proc(input)
			end, 50)
		end
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
			vim.api.nvim_win_set_cursor(win, { math.min(5 + M.multibuffer_expand, line_count), 0 })
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
				vim.cmd("startinsert")
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
	end
end

return M
