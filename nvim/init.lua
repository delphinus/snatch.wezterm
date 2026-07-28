-- snatch.wezterm: Neovim configuration for screen copy mode
-- This file is auto-deployed by the snatch.wezterm WezTerm plugin.
-- Do not edit directly; changes will be overwritten on plugin update.
--
-- Bump when the lazy.nvim specs below change. The WezTerm plugin compares this
-- line and only then asks the next launch to run `Lazy! sync`, so edits to the
-- rest of this file (or to lua/snatch/) do not cost a network round trip before
-- the capture appears.
-- spec-version: 1

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
-- Be explicit: if detection ever fails, every truecolor cell quantises to 16
-- colours and the capture looks broken rather than merely uncoloured.
vim.opt.termguicolors = true

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

local palette = (layout and layout.palette) or {}
local use_color = not (layout and layout.color == false)

-- Match WezTerm's own colours.
--
-- These have to be settled before any window exists: 'background' selects which
-- variant of the default scheme the groups below inherit from, and jab.nvim
-- draws its labels with those groups.
local function setup_colors()
  local fg, bg = palette.foreground, palette.background
  if bg then
    local r, g, b = tonumber(bg:sub(2, 3), 16), tonumber(bg:sub(4, 5), 16), tonumber(bg:sub(6, 7), 16)
    vim.o.background = (0.299 * r + 0.587 * g + 0.114 * b) > 127 and "light" or "dark"
  end
  if fg or bg then
    -- Floats read NormalFloat, but jab.nvim pads wide-character labels with a
    -- chunk highlighted as Normal, so both have to agree.
    for _, group in ipairs { "Normal", "NormalFloat" } do
      vim.api.nvim_set_hl(0, group, { fg = fg, bg = bg })
    end
  end

  if not use_color then
    return
  end

  -- jab.nvim dims the screen during a search with a single foreground-only
  -- `Comment` extmark. Neovim combines highlights attribute-wise, so a group
  -- that sets no background lets ours through untouched: the text greys out
  -- while the cell colours stay at full strength, which is unreadable. Giving
  -- Comment a background turns it into a real backdrop, so colour flattens
  -- while searching and comes back on the jump.
  local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
  vim.api.nvim_set_hl(0, "Comment", vim.tbl_extend("force", comment, { bg = bg }))

  -- CursorLine is background-only by default, and ":h hl-CursorLine" makes such
  -- a definition low priority, so it vanishes under any coloured cell. Giving
  -- it a foreground would win but destroy the text colours on that row, so
  -- underline it instead.
  vim.api.nvim_set_hl(0, "CursorLine", { underline = true })

  -- Visual is background-only too, and dark text on its pale grey is illegible.
  -- Inverting is what a terminal does for a selection and is always readable.
  -- Unlike an extmark attribute, this is applied above the decorations, so it
  -- cannot leak into neighbouring highlights.
  vim.api.nvim_set_hl(0, "Visual", { reverse = true })
end

-- Load a captured pane into a scratch buffer, colouring it from the escape
-- sequences WezTerm recorded.
local ansi = require "snatch.ansi"
local hl_ns = vim.api.nvim_create_namespace "snatch-color"
local hl_groups = {}

local function highlight_group(attrs)
  local key = ansi.key(attrs)
  local group = hl_groups[key]
  if not group then
    group = "SnatchAnsi" .. vim.tbl_count(hl_groups)
    vim.api.nvim_set_hl(0, group, attrs)
    hl_groups[key] = group
  end
  return group
end

local function load_pane(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local raw = f:read "*a"
  f:close()

  local lines, runs = ansi.parse(raw, palette)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  if use_color then
    for lnum, lruns in pairs(runs) do
      local width = #(lines[lnum] or "")
      for _, run in ipairs(lruns) do
        local start_col = math.min(run[1], width)
        local end_col = math.min(run[2], width)
        local attrs, url = run[3], run[4]
        local opts = { priority = 10, url = url }
        if attrs then
          opts.hl_group = highlight_group(attrs)
        end
        if run.eol then
          -- Erase-to-end-of-line with a background set: paint the rest of the
          -- screen line. This is the form the API documents for hl_eol.
          opts.end_row, opts.end_col, opts.hl_eol = lnum, 0, true
        else
          opts.end_col = end_col
        end
        if opts.hl_group or url then
          pcall(vim.api.nvim_buf_set_extmark, buf, hl_ns, lnum - 1, start_col, opts)
        end
      end
    end
  end

  -- Set after the lines: a nomodifiable buffer rejects them.
  vim.bo[buf].modifiable = false
  return buf
end

-- Create floating windows for each pane
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    vim.schedule(function()
      if not layout or not layout.panes or #layout.panes == 0 then
        return
      end

      setup_colors()

      -- Background window: dark empty buffer for gaps between panes.
      -- WinSeparator links to Normal, so this follows the WezTerm background.
      local bg_buf = vim.api.nvim_get_current_buf()
      vim.bo[bg_buf].buftype = "nofile"
      vim.wo.winhighlight = "Normal:WinSeparator"

      local active_win = nil
      for _, p in ipairs(layout.panes) do
        local buf = load_pane(p.file)
        if not buf then
          goto continue
        end

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
        ::continue::
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
        end, 800)
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
