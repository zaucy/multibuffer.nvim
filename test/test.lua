-- make the sign column big enough to show our multibuffer line numbers
vim.opt.signcolumn = "auto:4"

local multibuffer = require("multibuffer")
multibuffer.setup({})

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
multibuffer.multibuf_add_buf(mbuf, { buf = open_file('a.txt'), regions = { { start_row = 119, end_row = 119 } } })
multibuffer.multibuf_add_buf(mbuf, { buf = open_file('b.txt'), regions = { { start_row = 0, end_row = 0 } } })
multibuffer.win_set_multibuf(0, mbuf)
