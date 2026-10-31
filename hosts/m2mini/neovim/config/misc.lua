require('nvim-highlight-colors').setup({
    render = 'background',
    enable_tailwind = true
})


require('gitsigns').setup({
    signcolumn = true
})


require('deadcolumn').setup({
    scope = 'buffer',
    modes = { 'n', 'i', 'ic', 'ix', 'R', 'Rx', 'Rv', 'Rvc', 'Rvx' },
    blending = {
        threshold = 0.90,
        hlgroup = {
            'Normal',
            'background'
        }
    },
    warning = {
        alpha = 0.4,
        hlgroup = {
            'vimWarn',
            'background'
        }
    },
    extra = {
        follow_tw = '+1'
    }
})


require('trouble').setup({})


require('alpha').setup({
    opts = { margin = 44 },
    layout = {
        { type = 'padding', val = 5 },
        {
            type = 'text',
            val = {
                "███╗   ██╗ ███████╗ ██████╗  ██╗   ██╗ ██╗ ███╗   ███╗",
                "████╗  ██║ ██╔════╝██╔═══██╗ ██║   ██║ ██║ ████╗ ████║",
                "██╔██╗ ██║ █████╗  ██║   ██║ ██║   ██║ ██║ ██╔████╔██║",
                "██║╚██╗██║ ██╔══╝  ██║   ██║ ╚██╗ ██╔╝ ██║ ██║╚██╔╝██║",
                "██║ ╚████║ ███████╗╚██████╔╝  ╚████╔╝  ██║ ██║ ╚═╝ ██║",
                "╚═╝  ╚═══╝ ╚══════╝ ╚═════╝    ╚═══╝   ╚═╝ ╚═╝     ╚═╝"
            },
            opts = { position = 'center' }
        }
    }
})
