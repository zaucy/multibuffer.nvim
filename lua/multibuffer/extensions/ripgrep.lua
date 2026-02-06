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

-- ──────── Helper: Process Parsing ────────

--- Parses rg --vimgrep output into MultibufAddBufOptions
--- @param output string
--- @return MultibufAddBufOptions[]
local function parse_vimgrep(output)
	local results_by_buf = {}
	local sorted_bufs = {}

	-- Use gsplit for robust line handling across platforms
	for line in vim.gsplit(output, "\n", { plain = true }) do
		-- Strip trailing \r if present (Windows)
		line = line:gsub("\r$", "")

		if line ~= "" then
			-- Format: file:line:col:text
			-- We use greedy (.+) for the file to correctly handle C:\ drive letters on Windows.
			-- Treesitter/LUA patterns will backtrack to find the digits.
			local file, lnum, _, _ = line:match("^(.+):(%d+):(%d+):(.*)$")

			if file and lnum then
				local row = tonumber(lnum) - 1
				local bufnr = vim.fn.bufadd(file)
				if not vim.api.nvim_buf_is_loaded(bufnr) then
					vim.fn.bufload(bufnr)
				end

				if not results_by_buf[bufnr] then
					results_by_buf[bufnr] = { buf = bufnr, regions = {} }
					table.insert(sorted_bufs, bufnr)
				end

				table.insert(results_by_buf[bufnr].regions, { start_row = row, end_row = row })
			end
		end
	end

	local final_list = {}
	for _, bufnr in ipairs(sorted_bufs) do
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
		callback({})
		return
	end

	current_proc = vim.system({ "rg", "--vimgrep", "--smart-case", query }, { text = true }, function(out)
		current_proc = nil
		local results = parse_vimgrep(out.stdout or "")
		vim.schedule(function()
			callback(results)
		end)
	end)
end

-- ──────── inccommand Handlers ────────

--- @param opts table
function M._search_preview(opts, ns, buf)
	local query = opts.fargs[1]
	local preview_buf = buf or vim.api.nvim_get_current_buf()

	-- 1. Initialize the preview buffer as a multibuffer if needed
	mbuf._initialize_multibuffer(preview_buf)

	-- 2. Debounced search
	if debounce_timer then
		vim.fn.timer_stop(debounce_timer)
	end

	debounce_timer = vim.fn.timer_start(50, function()
		run_rg(query, function(results)
			-- Update Cache
			search_cache = { query = query, results = results }

			-- Only update if buffer is still valid (user hasn't closed cmdline)
			if vim.api.nvim_buf_is_valid(preview_buf) then
				-- Reset slices before adding new ones
				local info = mbuf._get_info(preview_buf)
				if info then
					info.bufs = {}
				end

				mbuf.multibuf_add_bufs(preview_buf, results)
			end
		end)
	end)

	return 1
end

--- @param opts table
function M._search_execute(opts)
	local query = opts.args
	local final_mbuf = mbuf.create_multibuf()
	vim.api.nvim_buf_set_name(final_mbuf, "multibuffer://search/" .. query)

	-- 1. Use Cache if available and matching
	if search_cache and search_cache.query == query then
		mbuf.multibuf_add_bufs(final_mbuf, search_cache.results)
		vim.api.nvim_set_current_buf(final_mbuf)
	else
		-- 2. Fallback to async search if cache is cold
		run_rg(query, function(results)
			mbuf.multibuf_add_bufs(final_mbuf, results)
			vim.api.nvim_set_current_buf(final_mbuf)
		end)
	end
end

-- ──────── Setup ────────

function M.setup()
	vim.api.nvim_create_user_command("Mgrep", M._search_execute, {
		nargs = 1,
		preview = function(opts, ns, buf)
			local success, result_or_error = pcall(M._search_preview, opts, ns, buf)
			if not success then
				vim.schedule(function()
					-- vim.notify(vim.inspect(buf))
					vim.notify(result_or_error)
				end)
				return 0
			end
			return result_or_error
		end,
		desc = "Live Multibuffer Grep",
	})
end

return M
