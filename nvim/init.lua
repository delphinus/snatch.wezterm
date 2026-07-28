-- snatch.wezterm: Neovim configuration for screen copy mode
-- This file is auto-deployed by the snatch.wezterm WezTerm plugin.
-- Do not edit directly; changes will be overwritten on plugin update.

-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath "data" .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system {
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  }
end
vim.opt.rtp:prepend(lazypath)

-- Labels from environment (set by WezTerm plugin)
local labels = vim.env.SNATCH_LABELS or "HJKLASDFGYUIOPQWERTNMZXCVB"

require("lazy").setup({
  {
    "delphinus/luamigemo",
    version = "*",
  },
  {
    -- flash.nvim からの移行。jab は migemo (luamigemo) を直接使うので mode
    -- 関数は不要。multi_window 対応 (タブ内の全ペインにラベルを付けて
    -- またいでジャンプ) の PR が atusy/jab.nvim へマージされるまでは、その
    -- 対応を入れた自分の fork のブランチを使う。マージ後は "atusy/jab.nvim"
    -- (branch 無し) に戻す。snatch のペインは focusable なフロートなので、
    -- jab は multi_window でそれらすべてにラベルを付けられる。
    "delphinus/jab.nvim",
    branch = "feat/multi-window",
    lazy = false,
  },
}, {
  change_detection = { enabled = false },
  checker = { enabled = false },
  rocks = { enabled = false },
  performance = {
    rtp = {
      disabled_plugins = {
        "gzip", "matchit", "matchparen", "netrwPlugin",
        "tarPlugin", "tohtml", "tutor", "zipPlugin",
      },
    },
  },
})

-- Global options
vim.opt.laststatus = 0
vim.opt.cmdheight = 0
vim.opt.swapfile = false
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.clipboard = "unnamedplus"
-- The capture holds one buffer line per terminal row, so 'zb' must be able to
-- put the last line flush against the bottom of the window.
vim.opt.scrolloff = 0
vim.opt.sidescrolloff = 0

-- Read layout file
local layout_file = vim.env.SNATCH_LAYOUT
local layout = nil

if layout_file then
  local f = io.open(layout_file, "r")
  if f then
    layout = vim.json.decode(f:read "*a")
    f:close()
  end
end

-- Create floating windows for each pane
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    vim.schedule(function()
      if not layout or not layout.panes or #layout.panes == 0 then
        return
      end

      -- Background window: dark empty buffer for gaps between panes
      local bg_buf = vim.api.nvim_get_current_buf()
      vim.bo[bg_buf].buftype = "nofile"
      vim.wo.winhighlight = "Normal:WinSeparator"

      local active_win = nil
      for _, p in ipairs(layout.panes) do
        local buf = vim.fn.bufadd(p.file)
        vim.fn.bufload(buf)
        vim.bo[buf].modifiable = false
        vim.bo[buf].readonly = true
        vim.bo[buf].swapfile = false

        local win = vim.api.nvim_open_win(buf, false, {
          relative = "editor",
          row = p.top,
          col = p.left,
          width = p.width,
          height = p.height,
          style = "minimal",
          border = "none",
          focusable = true,
        })

        -- The capture is physical (already wrapped) lines, so re-wrapping here
        -- would double up. 'nowrap' keeps the buffer a 1:1 copy of the grid.
        vim.wo[win].wrap = false
        vim.wo[win].cursorline = true

        vim.api.nvim_set_current_win(win)
        vim.cmd "normal! Gzb"

        p.win_id = win
        if p.is_active then
          active_win = win
        end
      end

      if active_win then
        vim.api.nvim_set_current_win(active_win)
      end

      -- Fidelity harness: grab the reproduced screen so it can be compared
      -- against the "before" image the WezTerm plugin took. The delay lets
      -- WezTerm paint the new tab before screencapture reads the framebuffer.
      local shot_prefix = vim.env.SNATCH_SCREENSHOT
      local fidelity = vim.env.SNATCH_FIDELITY
      if shot_prefix and fidelity then
        vim.defer_fn(function()
          vim.cmd "redraw"
          vim.system({ fidelity, "capture", shot_prefix .. "-after.png" }):wait()
        end, 500)
      end
    end)
  end,
})

-- jab: s でインクリメンタル検索してジャンプ (migemo 対応)。multi_window で
-- タブ内の全ペイン (focusable なフロート) にラベルを付けてまたいで飛べる。
-- jab_win は式を返すので expr マッピングにする。
vim.keymap.set({ "n", "x" }, "s", function()
  return require("jab").jab_win {
    labels = vim.split(labels, ""),
    multi_window = true,
  }
end, { expr = true, desc = "jab (migemo, multi-window)" })

-- Quit
vim.keymap.set("n", "q", "<Cmd>qa!<CR>")

-- Auto-close after yank
vim.api.nvim_create_autocmd("TextYankPost", {
  callback = function()
    vim.defer_fn(function()
      vim.cmd "qa!"
    end, 50)
  end,
})

-- Cleanup all temp files on exit
vim.api.nvim_create_autocmd("VimLeave", {
  callback = function()
    if layout and layout.panes then
      for _, p in ipairs(layout.panes) do
        os.remove(p.file)
      end
    end
    if layout_file then
      os.remove(layout_file)
    end
  end,
})
