-- Set some global options for better visibility
vim.opt.signcolumn = "yes:4"
vim.opt.number = false
vim.opt.relativenumber = false

local function setup()
    local ok, mb = pcall(require, "multibuffer")
    if not ok then
        error("Could not load multibuffer plugin! Make sure lua/multibuffer.dll exists. Error: " .. tostring(mb))
    end

    -- Helper to load a file into a buffer properly
    local function load_file(path)
        if vim.fn.filereadable(path) == 0 then
            print("Warning: File not readable: " .. path)
            return vim.api.nvim_create_buf(true, false)
        end
        
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, path)
        
        local lines = {}
        for line in io.lines(path) do
            table.insert(lines, line)
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_set_option_value("modified", false, { buf = buf })
        return buf
    end

    local src_a = load_file("test/a.txt")
    local src_b = load_file("test/b.txt")

    -- Create multibuffer
    local mbuf = mb.create()

    -- Add regions from A (near line 120)
    mb.add_buffer({
        multibuf = mbuf,
        source_buf = src_a,
        regions = { { start_row = 118, end_row = 122 } }
    })

    -- Add regions from B
    mb.add_buffer({
        multibuf = mbuf,
        source_buf = src_b,
        regions = { { start_row = 0, end_row = 3 } }
    })

    -- Display
    vim.api.nvim_set_current_buf(mbuf)
    
    print("Multibuffer ready! Edit and use :w to save back to source buffers.")
end

local ok, err = pcall(setup)
if not ok then
    print("Setup Error: " .. tostring(err))
end
