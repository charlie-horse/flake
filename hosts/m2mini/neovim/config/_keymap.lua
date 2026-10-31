vim.g.mapleader = ' '

vim.keymap.set('v', '<Leader>c', '"+y')
vim.keymap.set('n', '<Leader>v', '"+p')

vim.keymap.set({'n', 'v'}, '<Leader>s', ':w<CR>')
vim.keymap.set({'n', 'v'}, '<Leader><Esc>', ':noh<CR>')

vim.keymap.set('t', '<C-t>', '<C-\\><C-n>')
vim.keymap.set('n', '<Leader>t', ':new<CR>:terminal<CR><C-w>J:res 10<CR>')

vim.keymap.set('n', '<Leader>h', '<C-w>h')
vim.keymap.set('n', '<Leader>j', '<C-w>j')
vim.keymap.set('n', '<Leader>k', '<C-w>k')
vim.keymap.set('n', '<Leader>l', '<C-w>l')

vim.keymap.set('n', '<Leader>wh', '<C-w>H')
vim.keymap.set('n', '<Leader>wj', '<C-w>J')
vim.keymap.set('n', '<Leader>wk', '<C-w>K')
vim.keymap.set('n', '<Leader>wl', '<C-w>L')

vim.keymap.set('n', '<Leader>q', ':q<CR>')
vim.keymap.set('n', '<Leader>Q', ':qa<CR>')
vim.keymap.set('n', '<Leader>n', function()
    local count = 0
    for _, win in pairs(vim.api.nvim_tabpage_list_wins(0)) do
        local cfg = vim.api.nvim_win_get_config(win)
        if cfg.relative == "" and cfg.external == false
            then count = count + 1
        end
    end

    if count % 2 == 1
        then vim.cmd.vnew()
        else vim.cmd.new()
    end
end)

vim.keymap.set({'n','i', 'v'}, '<C-c>', '<ESC>')
vim.keymap.set({'n', 'v'}, '<Space>', '<NOP>')
vim.keymap.set({'n', 'v'}, '<Backspace>', '<NOP>')
