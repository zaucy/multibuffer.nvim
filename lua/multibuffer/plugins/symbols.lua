local M = {}

function M.multibuf_document_symbols(opts)
	opts = opts or {}
	local buf = opts.buf or vim.api.nvim_get_current_buf()
	local kinds = opts.kinds
	if buf == 0 then
		buf = vim.api.nvim_get_current_buf()
	end

	local clients = vim.lsp.get_clients({
		bufnr = buf,
		method = "textDocument/documentSymbol",
	})

	local api = require("multibuffer")
	local mbuf = api.create_multibuf()

	if #clients == 0 then
		api.multibuf_set_header(mbuf, {
			"no lsp clients supporting document symbols attached to buffer",
		})
		return
	end

	local client = clients[1]

	-- Helper to recursively flatten DocumentSymbol into a list of simplified items
	local function flatten_symbols(symbols, result)
		result = result or {}
		for _, s in ipairs(symbols) do
			local lnum = s.range and s.range.start.line or (s.location and s.location.range.start.line)
			-- SymbolInformation uses kind as an integer, DocumentSymbol uses kind as an integer too.
			-- We need to convert it to a string name for our filtering logic.
			local kind_name = vim.lsp.protocol.SymbolKind[s.kind] or "Unknown"
			table.insert(result, { lnum = lnum + 1, kind = kind_name })
			if s.children then
				flatten_symbols(s.children, result)
			end
		end
		return result
	end

	assert(buf ~= 0)
	local win = vim.api.nvim_get_current_win()
	-- get cursor position to set it in the multibuffer later
	local cursor_pos = vim.api.nvim_win_get_cursor(win)

	vim.b[mbuf].multibuffer_expander_max_lines = 0

	api.multibuf_set_header(mbuf, {
		string.format(" loading document symbols from %s ...", client.name),
	})

	vim.api.nvim_win_set_buf(win, mbuf)

	local params = { textDocument = vim.lsp.util.make_text_document_params(buf) }
	client:request("textDocument/documentSymbol", params, function(err, result)
		if err then
			api.multibuf_set_header(mbuf, {
				string.format(" error: %s ", err.message),
			})
			return
		end

		local items = flatten_symbols(result or {})

		local filtered_entry = vim.tbl_filter(function(entry)
			if not kinds then
				return true
			end
			return vim.tbl_contains(kinds, entry.kind)
		end, items)

		-- Find the closest symbol to the cursor
		local closest_lnum = -1
		if #filtered_entry > 0 then
			local cursor_lnum = cursor_pos[1]
			local best_lnum = -1
			for _, entry in ipairs(filtered_entry) do
				if entry.lnum <= cursor_lnum and entry.lnum > best_lnum then
					best_lnum = entry.lnum
				end
			end
			closest_lnum = best_lnum
			-- if no symbol is found, default to the first symbol
			if closest_lnum == -1 then
				table.sort(filtered_entry, function(a, b)
					return a.lnum < b.lnum
				end)
				closest_lnum = filtered_entry[1].lnum
			end
		end

		api.multibuf_set_header(mbuf, {
			string.format(" found %i document symbols ", #filtered_entry),
		})

		local add_opts = {}

		if #filtered_entry > 0 then
			local symbol_lines = vim.tbl_map(function(entry)
				return entry.lnum - 1
			end, filtered_entry)

			vim.fn.sort(symbol_lines)
			vim.list.unique(symbol_lines)

			table.insert(add_opts, {
				buf = buf,
				title = {
					{},
					{
						{ " " },
						{ "" },
						{ " " },
						{ "Document Symbols" },
						{ string.format(" (%i) ", #filtered_entry) },
					},
					{},
				},
				regions = vim.tbl_map(function(lnum)
					return { start_row = lnum, end_row = lnum }
				end, symbol_lines),
			})
		end

		api.multibuf_add_bufs(mbuf, add_opts)

		-- Set the cursor to the closest symbol
		if closest_lnum > 0 then
			local target_mb_line = api.multibuf_buf_get_line(mbuf, buf, closest_lnum - 1)
			if target_mb_line then
				vim.api.nvim_win_set_cursor(win, { target_mb_line + 1, 0 })
			end
		end
	end, buf)
end

function M.multibuf_workspace_symbols(default_query)
	vim.validate("default_query", default_query, "string")

	local buf = vim.api.nvim_get_current_buf()
	local clients = vim.lsp.get_clients({
		-- bufnr = buf,
		method = "workspace/symbol",
	})

	--- index is client index in `clients`
	--- element is lsp request id
	--- @type number[]
	local last_client_request_ids = {}

	for _, _ in ipairs(clients) do
		table.insert(last_client_request_ids, -1)
	end

	local api = require("multibuffer")

	--- @type number|nil
	local mbuf = nil
	local done_requests = 0
	local found_count = 0
	local skipped_count = 0

	--- @type table<number, MultibufRegion[]>
	local regions_by_bufnr = {}

	--- @param client vim.lsp.Client
	--- @param err lsp.ResponseError|nil
	--- @param result lsp.WorkspaceSymbol[]|nil
	local function workspace_symbol_handler(client, err, result, context, config)
		assert(mbuf)

		if err then
			local err_msg = err.message or "unknown"
			api.multibuf_set_header(mbuf, {
				"",
				"",
				"",
				string.format("ERROR from %s: %s", client.name, err_msg),
			})
			return
		end

		if not result then
			return
		end

		for _, symbol in ipairs(result) do
			local lnum = symbol.location.range.start.line
			local path = vim.uri_to_fname(symbol.location.uri)
			local lsp_util = require("multibuffer.lsp_util")
			path = lsp_util.resolve_local_path(path)

			if vim.uv.fs_stat(path) then
				local symbol_bufnr = vim.fn.bufadd(path)
				regions_by_bufnr[symbol_bufnr] = regions_by_bufnr[symbol_bufnr] or {}
				table.insert(regions_by_bufnr[symbol_bufnr], { start_row = lnum, end_row = lnum })
			else
				skipped_count = skipped_count + 1
			end
		end

		api.multibuf_clear_bufs(mbuf)

		local add_buf_opts = {}
		local cwd = vim.fn.getcwd()
		local lsp_util = require("multibuffer.lsp_util")

		for regions_buf, regions in pairs(regions_by_bufnr) do
			table.sort(regions, function(a, b)
				return a.start_row < b.start_row
			end)

			-- Deduplicate regions on the same line
			local unique_regions = {}
			if #regions > 0 then
				table.insert(unique_regions, regions[1])
				for i = 2, #regions do
					if regions[i].start_row ~= regions[i - 1].start_row then
						table.insert(unique_regions, regions[i])
					end
				end
			end
			regions = unique_regions

			local original_path = vim.api.nvim_buf_get_name(regions_buf)
			local resolved_path = lsp_util.resolve_local_path(original_path)

			-- Check if the resolved path is within the logical workspace.
			-- resolve_local_path already maps things back to junctions in CWD if possible.
			local normalized_resolved = resolved_path:gsub("\\", "/"):lower()
			local normalized_cwd = cwd:gsub("\\", "/"):lower()
			local is_local = normalized_resolved:sub(1, #normalized_cwd) == normalized_cwd

			table.insert(add_buf_opts, {
				buf = regions_buf,
				regions = regions,
				is_local = is_local,
				path = resolved_path,
			})
		end

		table.sort(add_buf_opts, function(a, b)
			if a.is_local ~= b.is_local then
				return a.is_local
			end
			return a.path < b.path
		end)

		api.multibuf_add_bufs(mbuf, add_buf_opts)

		found_count = found_count + #result

		if done_requests == #clients then
			local header = {
				"",
				"",
				"",
				string.format("found %i workspace symbols (duplicates merged)", found_count),
			}
			if skipped_count > 0 then
				table.insert(header, string.format("(skipped %i non-existent file(s))", skipped_count))
			end
			api.multibuf_set_header(mbuf, header)
		end
	end

	mbuf = require("multibuffer.plugins.generic").multibuf_generic_search({
		default_input = default_query,
		on_input_changed = function(query)
			assert(mbuf, "on_input_changed called before search buffer was created")
			api.multibuf_clear_bufs(mbuf)

			for client_index, req_id in ipairs(last_client_request_ids) do
				if req_id ~= -1 then
					clients[client_index]:cancel_request(req_id)
				end
			end

			done_requests = 0
			found_count = 0
			regions_by_bufnr = {}

			api.multibuf_set_header(mbuf, {
				"",
				"",
				"",
				string.format("looking for workspace symbols '%s'", query),
			})

			for client_index, client in ipairs(clients) do
				--- @type lsp.WorkspaceSymbolParams
				local params = {
					query = query,
				}
				local success, req_id = client:request(
					"workspace/symbol",
					params,
					function(err, result, context, config)
						done_requests = done_requests + 1
						if context.request_id then
							-- don't leave lingering request id so we don't send
							-- cancel rquest for requests that are already
							-- fulfilled
							last_client_request_ids[client_index] = -1
						end
						workspace_symbol_handler(client, err, result, context, config)
					end,
					buf
				)

				if success then
					last_client_request_ids[client_index] = req_id
				else
					done_requests = done_requests + 1
				end
			end
		end,
	})

	if #clients == 0 then
		api.multibuf_set_header(mbuf, {
			"",
			"",
			"",
			"no lsp clients attached to buffer",
		})
	end
end

return M
