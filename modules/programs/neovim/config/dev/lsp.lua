local lspconfig = require('lspconfig')
local cmplsp = require('cmp_nvim_lsp')
local capabilities = cmplsp.default_capabilities()

vim.keymap.set('n', '<Backspace>', vim.lsp.buf.format)
vim.keymap.set('n', '<Leader><Leader>', function()
    for _ = 1, 2 do vim.lsp.buf.hover() end
end)

vim.keymap.set('n', '<Leader>e', function()
    for _ = 1, 2 do vim.diagnostic.open_float() end
end)
vim.diagnostic.config {
    virtual_text = false,
    update_in_insert = true,
    severity_sort = true,
    float = { source = 'if_many' }
}

local servers = {
    'rust_analyzer', 'jdtls',--'java_language_server',
    'svelte', 'nil_ls', 'clangd', 'bashls', 'eslint',
    'hls', 'html', 'cssls', 'taplo', 'vimls',
    'jsonls', 'yamlls', 'pyright', 'dockerls', 'prismals',
    'tsserver', 'lua_ls', 'tailwindcss'
}

local override = function(server)
    if server == 'jdtls' then
        lspconfig[server].setup {
            capabilities = capabilities,
            root_dir = function(_)
                return vim.fs.find({'.git'}, {upwards=true})[1]
                or vim.fn.getcwd()
            end,
            cmd = { 'jdt-language-server' },
        }
        return true
    end

    if server == 'java_language_server' then
        lspconfig[server].setup {
            capabilities = capabilities,
            single_file_support = true,
            root_dir = function(_)
                return vim.fs.find({'.git'}, {upwards=true})[1]
                or vim.fn.getcwd()
            end,
            cmd = { 'java-language-server' },
        }
        return true
    end

    return false
end

for _, server in ipairs(servers) do
    if (not override(server)) then
        lspconfig[server].setup { capabilities = capabilities }
    end
end
