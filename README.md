# Multibuffers in Neovim

Experimental multibuffers API for neovim. Expect breaking changes and some instability. This repository aims to be strictly an API for creating and managing multibuffers. What is a multibuffer? A multibuffer is a single buffer that contains editable regions of other buffers.

Strategy:

* `multibuffer://` schema for buffer name
* reads and writes handled through `BufReadCmd` and `BufWriteCmd`
* customizable virtual text above each section in multibuffer to denote what buffer region is below
* line numbers of each region through signcolumn

API:

* creating a multibuffer
* adding regular buffer(s) to a multibuffer
* customizing virtual text above regions
* getting real buffer and real row/column from line number in multibuffer

## Get Started

This plugin comes with **no defaults** you will need to use another plugin or write your own integrations to use `multibuffer.nvim`.

Using lazy

```lua
{
	"zaucy/multibuffer.nvim",
	opts = {
		-- optional list of keymaps for all multibuffers
		keymaps = {},
	},
}
```

## Multibuffer Plugins

... TODO ...

## Some recommendations

`<cr>` to go to source line in multibuffer

```lua
keymaps = {
	-- ...
	{ "n", "<cr>", function()
		local multibuffer = require('multibuffer')
		local multibuf = vim.api.nvim_get_current_buf()
		local cursor = vim.api.nvim_win_get_cursor(0)
		local buf, line = multibuffer.multibuf_get_buf_at_line(multibuf, cursor[1])
		if buf then
			vim.api.nvim_set_current_buf(buf)
			vim.api.nvim_win_set_cursor(0, { line, cursor[2] })
		end
	end },
}
```

Turn off line numbers in multibufs. Mulibuffers use the signcolumn to show the source line numbers and showing both line numbers can look confusing.

```lua
vim.api.nvim_create_autocmd("BufWinEnter", {
	pattern = "multibuffer://*",
	callback = function(args)
		local winid = vim.api.nvim_get_current_win()
		-- no multibuffer line numbers
		vim.api.nvim_set_option_value("number", false, { scope = "local", win = winid })
		vim.api.nvim_set_option_value("relativenumber", false, { scope = "local", win = winid })

		-- leave some room for multibuf line number signcolumn
		vim.api.nvim_set_option_value("signcolumn", "yes:3", { scope = "local", win = winid })
	end,
})
```

`<C-a>` in [telescope](https://github.com/nvim-telescope/telescope.nvim) to open multibuf of results

```lua
mappings = {
	i = {
		["<C-a>"] = function(prompt_bufnr)
			local actions = require("telescope.actions")
			local action_state = require("telescope.actions.state")
			local multibuffer = require("multibuffer")
			local picker = action_state.get_current_picker(prompt_bufnr)
			local selections = {}
			for entry in picker.manager:iter() do
				local bufnr = entry.bufnr
				if bufnr == nil then
					bufnr = vim.fn.bufadd(entry.filename)
					vim.fn.bufload(bufnr)
				end
				table.insert(selections, {
					filename = entry.filename,
					bufnr = bufnr,
					start_row = (entry.lnum or 1) - 1,
				})
			end
			actions.close(prompt_bufnr)

			local multibuf = multibuffer.create_multibuf()
			--- @type table<number, MultibufAddBufOptions>
			local add_opts_by_buf = {}
			for _, selection in ipairs(selections) do
				if add_opts_by_buf[selection.bufnr] == nil then
					add_opts_by_buf[selection.bufnr] = {
						buf = selection.bufnr,
						regions = {},
					}
				end
				table.insert(add_opts_by_buf[selection.bufnr].regions, {
					start_row = selection.start_row - telescope_multibuffer_expand,
					end_row = selection.start_row + telescope_multibuffer_expand,
				})
			end
			--- @type MultibufAddBufOptions[]
			local add_buf_opts = {}
			for _, add_opts in pairs(add_opts_by_buf) do
				table.insert(add_buf_opts, add_opts)
			end
			multibuffer.multibuf_add_bufs(multibuf, add_buf_opts)
			multibuffer.win_set_multibuf(0, multibuf)
		end,
	}
}
```
