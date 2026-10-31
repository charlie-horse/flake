local telescope = require('telescope')
local actions = require('telescope.actions')
local builtins = require('telescope.builtin')
local extensions = telescope.extensions
local fb = telescope.extensions.file_browser

vim.keymap.set('n', '<Leader>b', builtins.buffers)

vim.keymap.set('n', '<Leader>F', builtins.find_files)
vim.keymap.set('n', '<Leader>rg', builtins.live_grep)
vim.keymap.set('n', '<Leader>f', function()
    extensions.file_browser.file_browser({path = "%:p:h"})
end)

vim.keymap.set('n', '<Leader>r', builtins.lsp_references)
vim.keymap.set('n', '<Leader>d', builtins.lsp_definitions)

vim.keymap.set('n', '<Leader>gh', builtins.git_stash)
vim.keymap.set('n', '<Leader>gs', builtins.git_status)
vim.keymap.set('n', '<Leader>gc', builtins.git_commits)
vim.keymap.set('n', '<Leader>gb', builtins.git_branches)

local defaults = {}
defaults.sorting_strategy = 'ascending'
defaults.mappings = {
    ['i'] = {
        ['<C-c>'] = false,
        ['<CR>'] = function() vim.cmd('stopinsert') end
    },
    ['n'] = {
        ['q'] = actions.close,
        ['<C-c>'] = actions.close,
        ['s'] = actions.toggle_selection,
    }
}

local pickers = {buffers = {}, git_status = {}}
pickers.buffers.mappings = {
    n = { ["x"] = actions.delete_buffer }
}
pickers.git_status.mappings = {
    n = {
        ['<CR>'] = actions.git_staging_toggle,
        ['o'] = actions.select_default
    }
}

local cfg_extensions = {
    fzf = {
        fuzzy = true,
        override_generic_sorter = true,
        override_file_sorter = true,
        case_mode = 'smart_case'
    },
    file_browser = {
        grouped = true,
        respect_gitignore = false,
        hijack_netrw = true,
        display_stat = {size = true},
        mappings = {
            ['n'] = {
                ['c'] = fb.actions.create,
                ['d'] = fb.actions.copy,
                ['m'] = fb.actions.move,
                ['r'] = fb.actions.rename,
                ['x'] = fb.actions.remove,
                ['h'] = fb.actions.toggle_hidden,
                ['e'] = fb.actions.change_cwd
            }
        }
    }
}
defaults.initial_mode = 'normal'
telescope.setup({
    defaults = defaults,
    pickers = pickers,
    extensions = cfg_extensions
})

telescope.load_extension 'fzf'
telescope.load_extension 'file_browser'
