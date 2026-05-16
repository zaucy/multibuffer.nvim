-- test/verify_symbol_cursor.lua
local api = require("multibuffer")
api.setup({})
local symbols = require("multibuffer.plugins.symbols")

-- Mock LSP client
local mock_client = {
    name = "mock_lsp",
    request = function(self, method, params, handler, bufnr)
        if method == "textDocument/documentSymbol" then
            local items = {
                { name = "func1", kind = 12, range = { start = { line = 9, character = 0 }, ["end"] = { line = 9, character = 5 } } },
                { name = "func2", kind = 12, range = { start = { line = 19, character = 0 }, ["end"] = { line = 19, character = 5 } } },
                { name = "func3", kind = 12, range = { start = { line = 29, character = 0 }, ["end"] = { line = 29, character = 5 } } },
                { name = "var1", kind = 13, range = { start = { line = 34, character = 0 }, ["end"] = { line = 34, character = 5 } } },
            }
            handler(nil, items)
            return true, 1
        end
        return false, -1
    end
}

-- Inject mock client
vim.lsp.get_clients = function(opts)
    return { mock_client }
end

-- Create a dummy buffer
local buf = vim.api.nvim_create_buf(false, true)
local lines = {}
for i = 1, 40 do
    table.insert(lines, "line " .. i)
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.api.nvim_win_set_buf(0, buf)

-- Test case: Cursor at line 15 (between func1 and func2)
vim.api.nvim_win_set_buf(0, buf)
vim.api.nvim_win_set_cursor(0, { 15, 0 })
symbols.multibuf_document_symbols({ buf = buf })
local mbuf = vim.api.nvim_get_current_buf()

-- Test the new helper
local source_buf, source_line = api.multibuf_get_origin_at_cursor(0)
print(string.format("Origin at cursor: buf %d, line %s", source_buf, tostring(source_line)))
assert(source_line == 10, "Expected 1-indexed source line 10 for cursor near lnum 10")
assert(source_buf == buf, "Expected correct source buffer")

-- Test direct call with 0-index (legacy/internal)
local _, s_line_0 = api.multibuf_get_buf_at_line(mbuf, 1) -- line 2 (0-indexed)
print(string.format("Direct 0-indexed call: line %s", tostring(s_line_0)))
assert(s_line_0 == 9, "Expected 0-indexed source line 9 for 0-indexed MB line 1")

print("All tests passed!")
vim.cmd("qa!")
