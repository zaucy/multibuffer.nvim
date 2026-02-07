-- Set a timeout for the test
vim.defer_fn(function()
    print("Test timed out!")
    vim.cmd("qa!")
end, 5000)

local status, multibuffer = pcall(require, "multibuffer")
if not status then
    print("Failed to require multibuffer: " .. tostring(multibuffer))
    vim.cmd("qa!")
    return
end

local function open_file(file)
	local bufnr = vim.api.nvim_create_buf(true, false)
	local lines = vim.fn.readfile(file)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_buf_set_name(bufnr, file)
	vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
	return bufnr
end

multibuffer.setup({})

local bufnr_a = open_file("test/a.txt")
local mbuf = multibuffer.create_multibuf()
multibuffer.multibuf_add_buf(mbuf, { buf = bufnr_a, regions = { { start_row = 119, end_row = 119 } } })

local function check(msg)
    local line_count = vim.api.nvim_buf_line_count(mbuf)
    print(string.format("%s: Multibuf line count = %d", msg, line_count))
end

check("Initial") -- Header (1) + 1 line = 2

print("Expanding top by 10...")
multibuffer.multibuf_slice_expand_top(mbuf, 10, 1)
check("After expand top 10") -- 2 + 10 = 12

print("Expanding bottom by 5...")
multibuffer.multibuf_slice_expand_bottom(mbuf, 5, 1)
check("After expand bottom 5") -- 12 + 5 = 17

print("Shrinking top by 5...")
multibuffer.multibuf_slice_expand_top(mbuf, -5, 1)
check("After shrink top 5") -- 17 - 5 = 12

print("Shrinking bottom by 20 (removing slice)...")
multibuffer.multibuf_slice_expand_bottom(mbuf, -20, 1)
check("After shrink bottom 20") -- Should be 1 (header only)

-- Test merging
print("\nTesting merging...")
local mbuf2 = multibuffer.create_multibuf()
multibuffer.multibuf_add_buf(mbuf2, { buf = bufnr_a, regions = { 
    { start_row = 10, end_row = 20 },
    { start_row = 30, end_row = 40 }
} })

local line_count = vim.api.nvim_buf_line_count(mbuf2)
print("Initial mbuf2 lines: " .. line_count) -- 1 (header) + 11 + 11 = 23

print("Expanding first slice bottom to overlap second slice...")
-- First slice ends at 20. Second starts at 30.
-- First slice is at line 1 to 11.
multibuffer.multibuf_slice_expand_bottom(mbuf2, 10, 1)

local final_count = vim.api.nvim_buf_line_count(mbuf2)
print("Final mbuf2 lines: " .. final_count)
-- [10, 20] expanded by 10 at bottom becomes [10, 30].
-- Next slice is [30, 40].
-- Merged should be [10, 40], which is 31 lines.
-- Total lines: 1 (header) + 31 = 32.

if final_count == 32 then
    print("SUCCESS: Merged correctly!")
else
    print("FAILURE: Expected 32 lines, got " .. final_count)
end

vim.cmd("qa!")
