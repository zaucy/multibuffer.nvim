-- make the sign column big enough to show our multibuffer line numbers
vim.opt.signcolumn = "auto:4"

local api = require("multibuffer")
api.setup({})

vim.api.nvim_create_autocmd("FileType", {
	pattern = "multibuffer",
	callback = function(args)
		-- expand/shrink keys
		local keys = {
			{ "<C-up>", 1, 0 },
			{ "<C-k>", 1, 0 },
			{ "<C-down>", 0, 1 },
			{ "<C-j>", 0, 1 },

			{ "<C-S-up>", 0, -1 },
			{ "<C-S-k>", 0, -1 },
			{ "<C-S-down>", -1, 0 },
			{ "<C-S-j>", -1, 0 },
		}

		for _, entry in ipairs(keys) do
			vim.keymap.set("n", entry[1], function()
				api.multibuf_slice_expand(args.buf, entry[2], entry[3])
			end)
		end
	end,
})

local mbuf = api.create_multibuf()
api.multibuf_add_buf(mbuf, { buf = vim.fn.bufadd("a.txt"), regions = { { start_row = 119, end_row = 119 } } })
api.multibuf_add_buf(mbuf, { buf = vim.fn.bufadd("b.txt"), regions = { { start_row = 0, end_row = 0 } } })

api.multibuf_add_buf(mbuf, {
	buf = vim.fn.bufadd("b.txt"),
	regions = { { start_row = 0, end_row = 0 } },
	title = { { { " [[ Custom Title ]] ", "TabLine" } } },
})

local header_msg = "clean environment for testing multibuffer.nvim"

api.multibuf_set_header(mbuf, {
	string.rep("▔", #header_msg + 4),
	"  " .. header_msg .. "  ",
	string.rep("▁", #header_msg + 4),
})
api.win_set_multibuf(0, mbuf)

vim.api.nvim_win_set_cursor(0, { 4, 0 })

-- keys to test the example plugins
vim.keymap.set({ "n", "v" }, "<C-w>/", function()
	require("multibuffer.plugins.ripgrep").multibuf_ripgrep({})
end)
vim.keymap.set({ "n", "v" }, "<C-w>s", function()
	require("multibuffer.plugins.symbols").multibuf_document_symbols()
end)
