local M = {}

local symbol_kinds = {
	"function",
	"method",
	"class",
	"type",
	"interface",
	"struct",
	"enum",
	"module",
	"namespace",
	"constructor",
	"field",
	"property",
}

local function is_symbol(capture_name)
	if capture_name:find("%.builtin") then
		return false
	end
	for _, kind in ipairs(symbol_kinds) do
		if capture_name:find("^" .. kind) or capture_name:find("%." .. kind) then
			return true
		end
	end
	if capture_name:find("^definition%.") then
		return true
	end
	return false
end

function M.multibuf_document_symbols(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()

	--- @type MultibufRegion[]
	local symbol_regions = {}

	local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
	local lang = vim.treesitter.language.get_lang(ft) or ft
	local ok, parser = pcall(vim.treesitter.get_parser, buf, lang)

	if ok and parser then
		parser:parse(true)
		local seen_nodes = {}
		parser:for_each_tree(function(tstree, tree)
			local tlang = tree:lang()
			local queries = {
				vim.treesitter.query.get(tlang, "locals"),
				vim.treesitter.query.get(tlang, "highlights"),
			}
			for _, query in ipairs(queries) do
				if query then
					for id, node, _ in query:iter_captures(tstree:root(), buf) do
						local name = query.captures[id]
						if is_symbol(name) then
							local node_id = node:id()
							if not seen_nodes[node_id] then
								seen_nodes[node_id] = true
								local sr, _, er, _ = node:range()
								table.insert(symbol_regions, {
									start_row = sr,
									end_row = er,
								})
							end
						end
					end
				end
			end
		end)
	end

	if #symbol_regions == 0 then
		vim.notify("no symbols found in document", vim.log.levels.ERROR)
		return
	end

	local api = require("multibuffer")
	local symbols_mbuf = api.create_multibuf()

	api.multibuf_add_buf(symbols_mbuf, {
		buf = buf,
		regions = symbol_regions,
	})

	vim.api.nvim_win_set_buf(win, symbols_mbuf)
end

return M
