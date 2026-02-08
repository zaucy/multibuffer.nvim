local M = {}

local symbol_kinds = {
	"Function",
	"Method",
	"Namespace",
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

			--- @param entry vim.quickfix.entry
			local symbol_lines = vim.tbl_map(function(entry)
				return entry.lnum - 1
			end, filtered_entry)

			vim.fn.sort(symbol_lines)
			vim.list.unique(symbol_lines)

			api.multibuf_set_header(symbols_mbuf, {
				string.format(" found %i document symbols ", #symbol_lines),
			})

			api.multibuf_add_buf(symbols_mbuf, {
				buf = buf,
				regions = vim.tbl_map(function(lnum)
					return { start_row = lnum, end_row = lnum }
				end, symbol_lines),
			})
		end,
	})

	vim.api.nvim_win_set_buf(win, symbols_mbuf)
end

return M
