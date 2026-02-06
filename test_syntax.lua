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

    -- 1. Create Source A (Lua)
    local buf_lua = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf_lua, 0, -1, false, {"local x = 1"})
    vim.api.nvim_set_option_value("filetype", "lua", { buf = buf_lua })

    -- 2. Create Source B (C) - Using C as it's built-in
    local buf_c = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf_c, 0, -1, false, {"int x = 1;"})
    vim.api.nvim_set_option_value("filetype", "c", { buf = buf_c })

    -- 3. Create multibuffer
    local mbuf = multibuffer.create_multibuf()
    multibuffer.multibuf_add_buf(mbuf, { buf = buf_lua, regions = { { start_row = 0, end_row = 0 } } })
    multibuffer.multibuf_add_buf(mbuf, { buf = buf_c, regions = { { start_row = 0, end_row = 0 } } })

    print("Multibuffer created with Lua and C.")

    -- 4. Check LanguageTree
    local root_parser = vim.treesitter.get_parser(mbuf)
    if root_parser then
        print("SUCCESS: Root parser found: " .. root_parser:lang())
        
        local children = root_parser:children()
        local child_langs = {}
        for lang, _ in pairs(children) do
            table.insert(child_langs, lang)
        end
        print("Child languages found: " .. table.concat(child_langs, ", "))
        
        -- Verify regions
        root_parser:for_each_tree(function(tree, ltree)
            local regions = ltree:included_regions()
            print(string.format("  Lang %s has %d regions", ltree:lang(), #regions))
        end)
    else
        print("FAILED: No parser found")
    end

    vim.cmd('quitall!')
end

local status, err = pcall(test)
if not status then
    print("ERROR FOUND:")
    print(err)
    vim.cmd('quitall!')
end
