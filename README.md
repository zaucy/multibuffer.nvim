# Multibuffers in Neovim

Experimental multibuffers API for neovim. Expect breaking changes and some instability. This repository aims to be strictly an API for creating and managing multibuffers. What is a multibuffer? A multibuffer is a single buffer that contains editable regions of other buffers.

Strategy:

* `multibuffer://` schema for buffer name
* `multibuffer` filetype assigned to all multibuffers
* reads and writes handled through `BufReadCmd` and `BufWriteCmd`
* customizable virtual text above each section in multibuffer
* line numbers of each region through signcolumn
* live highlight projection from source buffers (1:1 Treesitter/LSP parity)

## Get Started

This plugin comes with **no defaults**. You create multibuffers using the provided API and manage their appearance and behavior using standard Neovim features like autocommands and ftplugins.

### Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
	"zaucy/multibuffer.nvim",
	opts = {},
}
```

### Adding Keymaps (The "Neovim Way")

Since multibuffers are assigned the `multibuffer` filetype, you can add keymaps using a `FileType` autocommand. This ensures they are set only once per buffer.

```lua
vim.api.nvim_create_autocmd("FileType", {
	pattern = "multibuffer",
	callback = function(args)
		-- Navigation: <CR> to jump to source line
		vim.keymap.set("n", "<cr>", function()
			local mbuf = require('multibuffer')
			local cursor = vim.api.nvim_win_get_cursor(0)
			local buf, line = multibuffer.multibuf_get_buf_at_line(args.buf, cursor[1])
			if buf then
				vim.api.nvim_set_current_buf(buf)
				vim.api.nvim_win_set_cursor(0, { line, cursor[2] })
			end
		end, { buffer = args.buf, desc = "Jump to source" })
	end,
})
```

Alternatively, you can place your configuration in `after/ftplugin/multibuffer.lua`.

## Recommended Configuration

Disable standard line numbers to avoid confusion with the multibuffer's own line numbers in the signcolumn:

```lua
-- using BufWinEnter so that if the multibuf window changes to a different buffer it will reset
-- NOTE: this assumes you're setting your window options in another autocmd
vim.api.nvim_create_autocmd("BufWinEnter", {
	pattern = "multibuffer://*",
	callback = function(args)
		local winid = vim.api.nvim_get_current_win()
		vim.api.nvim_set_option_value("number", false, { scope = "local", win = winid })
		vim.api.nvim_set_option_value("relativenumber", false, { scope = "local", win = winid })
		-- Ensure enough room for multibuf line numbers (e.g. 4 digits)
		vim.api.nvim_set_option_value("signcolumn", "yes:3", { scope = "local", win = winid })
	end,
})

vim.api.nvim_create_autocmd({ "BufEnter", "BufNew", "BufWinEnter", "TermOpen" }, {
	callback = function()
		if vim.bo.buftype == "multibuffer" then return end

		-- restore your window options
	end,
})
```

## Examples

### Customize your multibuf title separators

In setup options you may pass a function called `render_multibuf_title` that returns a list to be rendered in the virtual text. Here is an example that uses nvim-web-devicons and a rounded border.

```lua
-- setup options
{
	render_multibuf_title = function(bufnr)
		local icons = require("nvim-web-devicons")
		local buf_name = vim.api.nvim_buf_get_name(bufnr)
		local icon, icon_hl_group = icons.get_icon(buf_name)
		local nice_buf_name = vim.fn.fnamemodify(buf_name, ":~:.")
		nice_buf_name = string.gsub(nice_buf_name, "\\", "/")

		icon = icon or ""
		icon_hl_group = icon_hl_group or "DevIconDefault"

		local title = { { " " }, { icon, icon_hl_group }, { " ", "" }, { nice_buf_name, "MultibufferTitleName" }, { " " } }
		local title_text_length = 0
		for _, part in ipairs(title) do
			title_text_length = title_text_length + string.len(part[1])
		end

		local top_text = "╭" .. string.rep("─", title_text_length - 2) .. "╮"
		local bottom_text = "╰" .. string.rep("─", title_text_length - 2) .. "╯"

		table.insert(title, 1, { "│", "MultibufferTitleBorder" })
		table.insert(title, { "│", "MultibufferTitleBorder" })

		return {
			{ { top_text, "MultibufferTitleBorder" } },
			title,
			{ { bottom_text, "MultibufferTitleBorder" } },
		}
	end,
}
```

### Telescope Integration

Create a multibuffer from all results in a [Telescope](https://github.com/nvim-telescope/telescope.nvim) picker:

```lua
-- Inside your telescope setup mappings
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
	},
},
```
