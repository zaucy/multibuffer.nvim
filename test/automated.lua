local mb = require("multibuffer")

-- 1. Setup source buffer
local src_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(src_buf, 0, -1, false, { "A1", "A2", "A3" })

-- 2. Create multibuffer
local mbuf = mb.create()

-- 3. Add region
mb.add_buffer({
    multibuf = mbuf,
    source_buf = src_buf,
    regions = { { start_row = 0, end_row = 2 } } 
})

local function get_mbuf_lines()
    return vim.api.nvim_buf_get_lines(mbuf, 0, -1, false)
end

local function get_src_lines()
    return vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
end

print("=== Starting Sync Test (Explicit Write Model) ===")

-- TEST 1: Source -> Mbuf (Real-time via TextChanged)
print("Test 1: Updating Source Buffer...")
vim.api.nvim_buf_set_lines(src_buf, 1, 2, false, { "A2-NEW" })
vim.api.nvim_buf_call(src_buf, function() vim.cmd("doautocmd TextChanged") end)

local lines = get_mbuf_lines()
print("Mbuf Line 2 (A2):", lines[2])
assert(lines[2] == "A2-NEW", "Mbuf should have updated from source. Got: " .. tostring(lines[2]))

-- TEST 2: Mbuf -> Source (Explicit Write)
print("Test 2: Updating Multibuffer & Saving...")
vim.api.nvim_buf_set_lines(mbuf, 0, 1, false, { "A1-EDITED" })
-- No automatic sync here, must call write
mb.write(mbuf)

local src_lines = get_src_lines()
print("Source Line 1:", src_lines[1])
assert(src_lines[1] == "A1-EDITED", "Source should have updated from mbuf after write. Got: '" .. tostring(src_lines[1]) .. "'")

print("=== All Sync Tests Passed! ===")
vim.cmd("qall!")
