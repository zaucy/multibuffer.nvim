local M = {}

function M.goto_definition()
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(win)

	local clients = vim.lsp.get_clients({
		bufnr = buf,
		method = "textDocument/definition",
	})

	--- index is client index in `clients`
	--- element is lsp request id
	--- @type number[]
	local last_client_request_ids = {}

	for _, _ in ipairs(clients) do
		table.insert(last_client_request_ids, -1)
	end

	local api = require("multibuffer")
	local mbuf = api.create_multibuf()

	if #clients == 0 then
		api.multibuf_set_header(mbuf, {
			"no lsp clients attached to buffer",
		})
		return
	end

	local client = clients[1]

	api.multibuf_set_header(mbuf, {
		string.format(" goto definition waiting for %s ...", client.name),
	})

	api.multibuf_add_buf(mbuf, {
		buf = buf,
		id = "definition_search",
		title = {
			{ { "", "" } },
			{ { " looking for definition from here ", "" } },
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

	--- @type lsp.DefinitionParams
	local params = {
		textDocument = { uri = vim.uri_from_bufnr(buf) },
		position = { line = cursor[1] - 1, character = cursor[2] },
	}

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
				table.insert(result)
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

		for _, loc in ipairs(locations) do
			local uri = loc.uri or loc.targetUri
			local range = loc.range or loc.targetRange

			api.multibuf_add_buf(mbuf, {
				buf = vim.uri_to_bufnr(uri),
				regions = {
					{
						start_row = range.start.line,
						end_row = range["end"].line,
					},
				},
			})
		end
	end

	local status, req_id = client:request("textDocument/definition", params, handler, buf)

	if not status then
		api.multibuf_set_header(mbuf, {
			string.format(" %s is not reponsive ", client.name),
		})
	end
end

return M
