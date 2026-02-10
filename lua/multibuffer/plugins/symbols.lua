local M = {}

local symbol_kinds = {
	"Function",
	"Method",
	"Namespace",
}

local symbol_table = {
	["Array"] = { "", "Array" },
	["Boolean"] = { "", "@lsp.type.boolean" },
	["Class"] = { "", "@lsp.type.class" },
	["Constant"] = { "", "@constant" },
	["constructor"] = { "", "@constructor" },
	["Constructor"] = { "", "@lsp.type.enum" },
	["EnumMember"] = { "", "@lsp.type.enumMember" },
	["Event"] = { "", "@lsp.type.event" },
	["Field"] = { "", "@field" },
	["File"] = "",
	["Function"] = { "", "@function" },
	["Interface"] = { "", "@lsp.type.interface" },
	["Key"] = { "", "@lsp.type.keyword" },
	["Method"] = { "", "@method" },
	["Module"] = { "", "@module" },
	["Namespace"] = { "", "@namespace" },
	["Null"] = "󰟢",
	["Number"] = { "", "@number" },
	["Object"] = { "" },
	["Operator"] = { "", "@lsp.type.operator" },
	["Package"] = { "", "@namespace" },
	["Property"] = { "", "@property" },
	["String"] = { "", "@string" },
	["Struct"] = { "", "@lsp.type.struct" },
	["TypeParameter"] = { "", "@lsp.type.typeParameter" },
	["Variable"] = { "", "@variable" },
}

local function should_show_symbol(entry)
	return vim.tbl_contains(symbol_kinds, entry.kind)
end

function M.multibuf_document_symbols(buf)
	if buf == 0 then
		buf = vim.api.nvim_get_current_buf()
	end
	assert(buf ~= 0)
	local win = vim.api.nvim_get_current_win()

	local api = require("multibuffer")
	local symbols_mbuf = api.create_multibuf()

	vim.b[symbols_mbuf].multibuffer_expander_max_lines = 0

	api.multibuf_set_header(symbols_mbuf, {
		" loading document symbols ",
	})

	vim.lsp.buf.document_symbol({
		on_list = function(t)
			local filtered_entry = vim.tbl_filter(should_show_symbol, t.items)

			api.multibuf_set_header(symbols_mbuf, {
				string.format(" found %i document symbols ", #filtered_entry),
			})

			local entries_by_symbol_kind = {}
			for _, entry in ipairs(filtered_entry) do
				entries_by_symbol_kind[entry.kind] = entries_by_symbol_kind[entry.kind] or {}
				table.insert(entries_by_symbol_kind[entry.kind], entry)
			end

			local add_opts = {}

			for kind, entries in pairs(entries_by_symbol_kind) do
				--- @param entry vim.quickfix.entry
				local symbol_lines = vim.tbl_map(function(entry)
					return entry.lnum - 1
				end, entries)

				vim.fn.sort(symbol_lines)
				vim.list.unique(symbol_lines)

				table.insert(add_opts, {
					buf = buf,
					title = {
						{},
						{
							{ " " },
							symbol_table[kind],
							{ " " },
							{ kind },
							{ string.format(" (%i) ", #entries) },
						},
						{},
					},
					regions = vim.tbl_map(function(lnum)
						return { start_row = lnum, end_row = lnum }
					end, symbol_lines),
				})
			end

			api.multibuf_add_bufs(symbols_mbuf, add_opts)
		end,
	})

	vim.api.nvim_win_set_buf(win, symbols_mbuf)
end

function M.multibuf_workspace_symbols(default_query)
	vim.validate("default_query", default_query, "string")

	local buf = vim.api.nvim_get_current_buf()
	local clients = vim.lsp.get_clients({
		bufnr = buf,
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

	--- @param client vim.lsp.Client
	--- @param err lsp.ResponseError|nil
	--- @param result lsp.WorkspaceSymbol[]|nil
	local function workspace_symbol_handler(client, err, result, context, config)
		assert(mbuf)

		api.multibuf_clear_bufs(mbuf)

		if not result then
			assert(mbuf)
			local err_msg = "unknown"
			if err and err.message then
				err_msg = err.message
			end
			api.multibuf_set_header(mbuf, {
				"",
				"",
				"",
				string.format("ERROR: %s", err_msg),
			})
			return
		end

		--- @type table<number, MultibufRegion[]>
		local regions_by_bufnr = {}

		for _, symbol in ipairs(result) do
			local lnum = symbol.location.range.start.line
			local symbol_bufnr = vim.uri_to_bufnr(symbol.location.uri)

			regions_by_bufnr[symbol_bufnr] = regions_by_bufnr[symbol_bufnr] or {}
			table.insert(regions_by_bufnr[symbol_bufnr], { start_row = lnum, end_row = lnum })
		end

		local add_buf_opts = {}

		for regions_buf, regions in pairs(regions_by_bufnr) do
			table.insert(add_buf_opts, {
				buf = regions_buf,
				regions = regions,
			})
		end

		api.multibuf_add_bufs(mbuf, add_buf_opts)

		api.multibuf_set_header(mbuf, {
			"",
			"",
			"",
			string.format("found %i workspace symbols", #result),
		})
	end

	mbuf = require("multibuffer.plugins.generic").multibuf_generic_search({
		default_input = default_query,
		on_input_changed = function(query)
			assert(mbuf, "on_input_changed called before search buffer was created")

			for client_index, req_id in ipairs(last_client_request_ids) do
				if req_id ~= -1 then
					clients[client_index]:cancel_request(req_id)
				end
			end

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
