local mbuf = require("multibuffer")

local M = {}

--- @class RipgrepCache
--- @field query string
--- @field results MultibufAddBufOptions[]

--- @type RipgrepCache|nil
local search_cache = nil

--- @type vim.SystemObj|nil
local current_proc = nil

--- @type integer|nil timer for debouncing
local debounce_timer = nil

--- @type string|nil tracks the query of the currently running process
local last_spawned_query = nil

-- ──────── Helper: Process Parsing ────────

--- Parses rg --vimgrep output into MultibufAddBufOptions
--- @param output string
--- @return MultibufAddBufOptions[]
local function parse_vimgrep(output)
	local results_by_buf = {}
	local bufs = {}

	for line in vim.gsplit(output, "\n", { plain = true }) do
		line = line:gsub("\r$", "")
		if line ~= "" then
			-- Format: file:line:col:text
			-- We use a more robust match that handles Windows drive letters
			local file, lnum = line:match("^(.+):(%d+):%d+:")
			if file and lnum then
				local row = tonumber(lnum) - 1
				local bufnr = vim.fn.bufadd(file)
				if not vim.api.nvim_buf_is_loaded(bufnr) then
					vim.fn.bufload(bufnr)
				end

				if not results_by_buf[bufnr] then
					results_by_buf[bufnr] = { buf = bufnr, regions = {} }
					table.insert(bufs, bufnr)
				end
				table.insert(results_by_buf[bufnr].regions, { start_row = row, end_row = row })
			end
		end
	end

	-- Sort buffers by name for consistent UI display
	table.sort(bufs, function(a, b)
		return vim.api.nvim_buf_get_name(a) < vim.api.nvim_buf_get_name(b)
	end)

	local final_list = {}
	for _, bufnr in ipairs(bufs) do
		table.insert(final_list, results_by_buf[bufnr])
	end
	return final_list
end

-- ──────── Core Search Logic ────────

--- @param query string
--- @param callback fun(results: MultibufAddBufOptions[])
local function run_rg(query, callback)
	if current_proc then
		current_proc:kill(15)
	end

	if query == "" then
		last_spawned_query = ""
		callback({})
		return
	end

	last_spawned_query = query
	current_proc = vim.system({ "rg", "--vimgrep", "--smart-case", "--sort", "path", query }, { text = true }, function(out)
		current_proc = nil
		-- Only process if ripgrep succeeded (code 0)
		if out.code == 0 then
			vim.schedule(function()
				-- Only apply if this is still the results we want
				if query == last_spawned_query then
					local results = parse_vimgrep(out.stdout or "")
					callback(results)
				end
			end)
		end
	end)
end

-- ──────── inccommand Handlers ────────

--- @param opts table
function M._search_preview(opts, ns, buf)
	local query = opts.args or ""
	local preview_buf = buf or vim.api.nvim_get_current_buf()

	-- Initialize the preview buffer
	mbuf._initialize_multibuffer(preview_buf)

	if debounce_timer then
		vim.fn.timer_stop(debounce_timer)
	end

	debounce_timer = vim.fn.timer_start(20, function() -- Lower debounce for snappier feel
		run_rg(query, function(results)
			search_cache = { query = query, results = results }
			
			if vim.api.nvim_buf_is_valid(preview_buf) then
				-- Properly clear old slices (prevents extmark leaks)
				mbuf.multibuf_clear_slices(preview_buf)
				mbuf.multibuf_add_bufs(preview_buf, results)
				
				-- Force a redraw so the inccommand window updates immediately
				vim.cmd("redraw")
			end
		end)
	end)

	return 1
end

--- @param opts table
function M._search_execute(opts)
	local query = opts.args
	local target_name = "mb-search://" .. query

	-- Find if a buffer with EXACTLY this name already exists
	local target_buf = -1
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_get_name(b) == target_name then
			target_buf = b
			break
		end
	end

	if target_buf ~= -1 then
		mbuf._initialize_multibuffer(target_buf)
		mbuf.multibuf_clear_slices(target_buf)
	else
		target_buf = vim.api.nvim_create_buf(true, false)
		pcall(vim.api.nvim_buf_set_name, target_buf, target_name)
		mbuf._initialize_multibuffer(target_buf)
	end

	local function apply(results)
		mbuf.multibuf_add_bufs(target_buf, results)
		vim.api.nvim_set_current_buf(target_buf)
	end

	if search_cache and search_cache.query == query then
		apply(search_cache.results)
	else
		run_rg(query, apply)
	end
end

-- ──────── Setup ────────

function M.setup()
	vim.api.nvim_create_user_command("Mgrep", M._search_execute, {
		nargs = 1,
		preview = function(opts, ns, buf)
			local ok, res = pcall(M._search_preview, opts, ns, buf)
			if not ok then
				vim.schedule(function()
					vim.notify("Mgrep Preview Error: " .. tostring(res), vim.log.levels.ERROR)
				end)
				return 0
			end
			return res
		end,
		desc = "Live Multibuffer Grep",
	})
end

return M
