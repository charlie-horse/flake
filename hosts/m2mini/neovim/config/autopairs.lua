local cmp = require('cmp')
local autotag = require('nvim-ts-autotag')
local autopairs = require('nvim-autopairs')
local cmp_autopairs = require('nvim-autopairs.completion.cmp')

autopairs.setup({
    check_ts = true,
})

autotag.setup()

cmp.event:on(
    'confirm_done',
    cmp_autopairs.on_confirm_done()
)
