-- Add current directory to runtimepath
vim.opt.rtp:append(".")

-- Fallback timeout to prevent hanging
vim.defer_fn(function()
    print("TIMEOUT REACHED - Exiting")
    os.exit(1)
end, 5000)

local function test()
    local multibuffer = require("multibuffer")
    multibuffer.setup({})

    -- Create dummy files for testing
    local function create_dummy(name, lines)
        local f = io.open(name, "w")
        if f then
            for i = 1, lines do
                f:write("Line " .. i .. " in " .. name .. "\n")
            end
            f:close()
        end
    end

    create_dummy("test_a.txt", 200)
    create_dummy("test_b.txt", 10)

    local function open_file(file)
        local bufnr = vim.api.nvim_create_buf(true, false)
        local lines = vim.fn.readfile(file)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_buf_set_name(bufnr, file)
        vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
        return bufnr
    end

    print("Creating multibuffer...")
    local mbuf = multibuffer.create_multibuf()
    
    print("Adding buffer A...")
    multibuffer.multibuf_add_buf(mbuf, { 
        buf = open_file("test_a.txt"), 
        regions = { { start_row = 119, end_row = 119 } } 
    })
    
    print("Adding buffer B...")
    multibuffer.multibuf_add_buf(mbuf, { 
        buf = open_file("test_b.txt"), 
        regions = { { start_row = 0, end_row = 2 } } 
    })
    
    print("Multibuffer created successfully!")
    vim.cmd('quitall!')
end

local status, err = pcall(test)

if not status then
    print("ERROR FOUND:")
    print(err)
    -- We can't use os.exit safely here if we want to see the output in some environments
    -- but for headless nvim it should be okay.
    vim.cmd('quitall!')
end
