local M = {}

local function do_location_request(method, title_verb, extra_params)
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(win)

	local clients = vim.lsp.get_clients({
		bufnr = buf,
		method = method,
	})

	local api = require("multibuffer")
	local mbuf = api.create_multibuf()

	if #clients == 0 then
		api.multibuf_set_header(mbuf, {
			string.format("no lsp clients supporting %s attached to buffer", method),
		})
		return
	end

	local client = clients[1]

	api.multibuf_set_header(mbuf, {
		string.format(" %s waiting for %s ...", title_verb, client.name),
	})

	api.multibuf_add_buf(mbuf, {
		buf = buf,
		id = "search_origin",
		title = {
			{ { "", "" } },
			{ { string.format(" looking for %s from here ", title_verb), "" } },
			{ { "", "" } },
		},
		regions = {
			{
				start_row = cursor[1] - 1,
				end_row = cursor[1] - 1,
			},
		},
	})

	vim.api.nvim_win_set_buf(win, mbuf)
	vim.api.nvim_win_set_cursor(win, { 2, cursor[2] })

	--- @type lsp.TextDocumentPositionParams
	local params = {
		textDocument = { uri = vim.uri_from_bufnr(buf) },
		position = { line = cursor[1] - 1, character = cursor[2] },
	}

	if extra_params then
		params = vim.tbl_extend("force", params, extra_params)
	end

	--- @param err lsp.ResponseError
	--- @param result lsp.Location|lsp.Location[]|lsp.LocationLink[]|nil
	local function handler(err, result, context, config)
		if err then
			api.multibuf_set_header(mbuf, {
				string.format(" %s error: %s ", client.name, err.message),
				vim.inspect(err.data),
			})
			return
		end

		--- @type lsp.Location[]|lsp.LocationLink[]
		local locations = {}

		if result then
			if not vim.isarray(result) then
				table.insert(locations, result)
			else
				locations = result
			end
		end

		if #locations == 0 then
			api.multibuf_set_header(mbuf, {
				string.format(" %s gave no results ", client.name),
			})
			return
		end

		api.multibuf_set_header(mbuf, {
			string.format(" %s found %i location(s) ", client.name, #locations),
		})

		local grouped = {}
		for _, loc in ipairs(locations) do
			local uri = loc.uri or loc.targetUri
			local range = loc.range or loc.targetRange
			if not grouped[uri] then
				grouped[uri] = {}
			end
			table.insert(grouped[uri], {
				start_row = range.start.line,
				end_row = range["end"].line,
			})
		end

		local adds = {}
		for uri, regions in pairs(grouped) do
			table.insert(adds, {
				buf = vim.uri_to_bufnr(uri),
				regions = regions,
			})
		end

		api.multibuf_add_bufs(mbuf, adds)
	end

	local status, req_id = client:request(method, params, handler, buf)

	if not status then
		api.multibuf_set_header(mbuf, {
			string.format(" %s is not reponsive ", client.name),
		})
	end
end

function M.goto_definition()
	do_location_request("textDocument/definition", "goto definition")
end

function M.references()
	do_location_request("textDocument/references", "references", {
		context = { includeDeclaration = true },
	})
end

function M.implementation()
	do_location_request("textDocument/implementation", "implementation")
end

function M.type_definition()
	do_location_request("textDocument/typeDefinition", "type definition")
end

function M.declaration()
	do_location_request("textDocument/declaration", "declaration")
end

local function do_call_hierarchy(direction)
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(win)

	local method = "textDocument/prepareCallHierarchy"
	local clients = vim.lsp.get_clients({
		bufnr = buf,
		method = method,
	})

	local api = require("multibuffer")
	local mbuf = api.create_multibuf()

	if #clients == 0 then
		api.multibuf_set_header(mbuf, {
			string.format("no lsp clients supporting %s attached to buffer", method),
		})
		return
	end

	local client = clients[1]
	local title_verb = direction == "incomingCalls" and "incoming calls" or "outgoing calls"

	api.multibuf_set_header(mbuf, {
		string.format(" %s waiting for %s (prepare) ...", title_verb, client.name),
	})

	api.multibuf_add_buf(mbuf, {
		buf = buf,
		id = "search_origin",
		title = {
			{ { "", "" } },
			{ { string.format(" looking for %s from here ", title_verb), "" } },
			{ { "", "" } },
		},
		regions = {
			{
				start_row = cursor[1] - 1,
				end_row = cursor[1] - 1,
			},
		},
	})

	vim.api.nvim_win_set_buf(win, mbuf)
	vim.api.nvim_win_set_cursor(win, { 2, cursor[2] })

	local params = {
		textDocument = { uri = vim.uri_from_bufnr(buf) },
		position = { line = cursor[1] - 1, character = cursor[2] },
	}

	--- @param err lsp.ResponseError
	--- @param result lsp.CallHierarchyItem[]|nil
	local function prepare_handler(err, result)
		if err then
			api.multibuf_set_header(mbuf, {
				string.format(" %s prepare error: %s ", client.name, err.message),
				vim.inspect(err.data),
			})
			return
		end

		if not result or #result == 0 then
			api.multibuf_set_header(mbuf, {
				string.format(" %s found no call hierarchy item at cursor ", client.name),
			})
			return
		end

		local item = result[1]
		local call_method = "callHierarchy/" .. direction

		api.multibuf_set_header(mbuf, {
			string.format(" %s waiting for %s (%s) ...", title_verb, client.name, direction),
		})

		--- @param call_err lsp.ResponseError
		--- @param call_result lsp.CallHierarchyIncomingCall[]|lsp.CallHierarchyOutgoingCall[]|nil
		local function call_handler(call_err, call_result)
			if call_err then
				api.multibuf_set_header(mbuf, {
					string.format(" %s %s error: %s ", client.name, direction, call_err.message),
					vim.inspect(call_err.data),
				})
				return
			end

			if not call_result or #call_result == 0 then
				api.multibuf_set_header(mbuf, {
					string.format(" %s found no %s ", client.name, title_verb),
				})
				return
			end

			api.multibuf_set_header(mbuf, {
				string.format(" %s found %i result(s) ", client.name, #call_result),
			})

			local grouped = {}
			for _, call in ipairs(call_result) do
				local target_item = direction == "incomingCalls" and call.from or call.to
				local uri = target_item.uri

				if not grouped[uri] then
					grouped[uri] = {}
				end

				if direction == "incomingCalls" and call.fromRanges then
					for _, range in ipairs(call.fromRanges) do
						table.insert(grouped[uri], {
							start_row = range.start.line,
							end_row = range["end"].line,
						})
					end
				else
					table.insert(grouped[uri], {
						start_row = target_item.range.start.line,
						end_row = target_item.range["end"].line,
					})
				end
			end

			local adds = {}
			for uri, regions in pairs(grouped) do
				table.insert(adds, {
					buf = vim.uri_to_bufnr(uri),
					regions = regions,
				})
			end

			api.multibuf_add_bufs(mbuf, adds)
		end

		client:request(call_method, { item = item }, call_handler, buf)
	end

	client:request(method, params, prepare_handler, buf)
end

function M.incoming_calls()
	do_call_hierarchy("incomingCalls")
end

function M.outgoing_calls()
	do_call_hierarchy("outgoingCalls")
end

return M
