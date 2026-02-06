-- make the sign column big enough to show our multibuffer line numbers
vim.opt.signcolumn = "auto:4"

local multibuffer = require("multibuffer")
multibuffer.setup({
	keymaps = {
		{
			"n",
			"<cr>",
			function()
				local multibuf = vim.api.nvim_get_current_buf()
				local cursor = vim.api.nvim_win_get_cursor(0)
				local buf, line = multibuffer.multibuf_get_buf_at_line(multibuf, cursor[1])
				if buf then
					vim.api.nvim_set_current_buf(buf)
					vim.api.nvim_win_set_cursor(0, { line, cursor[2] })
				end
			end,
		},
	},
})

--- @return integer
local function open_file(file)
	local bufnr = vim.api.nvim_create_buf(true, false)
	local lines = vim.fn.readfile(file)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_buf_set_name(bufnr, file)
	-- i dunno how to open a buffer properly
	vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
	return bufnr
end

local mbuf = multibuffer.create_multibuf()
multibuffer.multibuf_add_buf(mbuf, { buf = open_file("a.txt"), regions = { { start_row = 119, end_row = 119 } } })
multibuffer.multibuf_add_buf(mbuf, { buf = open_file("b.txt"), regions = { { start_row = 0, end_row = 0 } } })
multibuffer.multibuf_set_header(mbuf, { " CUSTOM HEADER ", " ============== " })
multibuffer.win_set_multibuf(0, mbuf)
