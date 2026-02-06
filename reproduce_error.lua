-- Add current directory to runtimepath
vim.opt.rtp:append(".")

-- Fallback timeout
vim.defer_fn(function()
    print("TIMEOUT REACHED - Exiting")
    os.exit(1)
end, 5000)

local function test()
    local multibuffer = require("multibuffer")
    multibuffer.setup({})

    -- Define a custom highlight group
    vim.cmd('highlight TestHl guifg=#ff0000')

    local function create_dummy(name, lines)
        local f = io.open(name, "w")
        if f then
            for i = 1, lines do
                f:write("Line " .. i .. " in " .. name .. "\n")
            end
            f:close()
        end
    end

    create_dummy("test_a.txt", 10)

    local function open_file(file)
        local bufnr = vim.api.nvim_create_buf(true, false)
        local lines = vim.fn.readfile(file)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_buf_set_name(bufnr, file)
        vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
        return bufnr
    end

    local buf_a = open_file("test_a.txt")
    
    -- Set a manual highlight in source buffer A
    -- Line 2 (index 1), columns 0-10
    local ns = vim.api.nvim_create_namespace("TestHlNamespace")
    vim.api.nvim_buf_set_extmark(buf_a, ns, 1, 0, {
        end_col = 10,
        hl_group = "TestHl",
    })
    print("Set highlight in source buffer " .. buf_a)

    local mbuf = multibuffer.create_multibuf()
    multibuffer.multibuf_add_buf(mbuf, { 
        buf = buf_a, 
        regions = { { start_row = 0, end_row = 5 } } 
    })
    
    -- Check if the highlight was mirrored
    local mirrored = vim.api.nvim_buf_get_extmarks(mbuf, multibuffer.multibuf_hl_ns, 0, -1, { details = true })
    print("Found " .. #mirrored .. " mirrored extmarks in multibuffer " .. mbuf)
    
    local found = false
    for _, mark in ipairs(mirrored) do
        local details = mark[4]
        if details.hl_group == "TestHl" then
            print("Successfully found mirrored TestHl at row " .. mark[2])
            found = true
        end
    end

    if not found then
        print("FAILED: TestHl not found in multibuffer")
        -- Let's check ALL extmarks in the multibuffer just in case
        local all = vim.api.nvim_buf_get_extmarks(mbuf, -1, 0, -1, { details = true })
        print("Total extmarks in multibuffer: " .. #all)
        for i, mark in ipairs(all) do
            print(string.format("Mark %d: ns_id=%d, row=%d, details=%s", i, mark[4].ns_id or -1, mark[2], vim.inspect(mark[4])))
        end
    end

    vim.cmd('quitall!')
end

local status, err = pcall(test)
if not status then
    print("ERROR FOUND:")
    print(err)
    vim.cmd('quitall!')
end
