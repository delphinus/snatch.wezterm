-- snatch.wezterm: Capture terminal screen text in Neovim for navigation and copying
-- https://github.com/delphinus/snatch.wezterm

---@type Wezterm
local wezterm = require "wezterm"
local act = wezterm.action

local M = {}

-- Find this plugin's installation directory (lazy: not available during initial load)
local plugin_dir
local function get_plugin_dir()
  if plugin_dir then
    return plugin_dir
  end
  for _, item in ipairs(wezterm.plugin.list()) do
    if item.url and item.url:match "snatch" then
      plugin_dir = item.plugin_dir .. "/"
      return plugin_dir
    end
  end
  -- Fallback: try component field (older WezTerm versions use different structure)
  for _, item in ipairs(wezterm.plugin.list()) do
    if type(item) == "table" then
      local url = item[1] or ""
      local dir = item[2] or ""
      if url:match "snatch" then
        plugin_dir = dir .. "/"
        return plugin_dir
      end
    end
  end
  return nil
end

-- Detect platform
local is_macos = wezterm.target_triple:match "darwin"
local is_windows = wezterm.target_triple:match "windows"

-- Resolve Neovim config home
local function nvim_config_home()
  local xdg = os.getenv "XDG_CONFIG_HOME"
  if xdg then
    return xdg
  end
  if is_windows then
    return os.getenv "LOCALAPPDATA" or (wezterm.home_dir .. "/AppData/Local")
  end
  return wezterm.home_dir .. "/.config"
end

-- Ensure the Neovim init.lua is deployed
local function ensure_nvim_config(appname)
  local dir = get_plugin_dir()
  if not dir then
    wezterm.log_error "snatch.wezterm: cannot find plugin directory"
    return false
  end
  local src = dir .. "nvim/init.lua"
  local dst_dir = nvim_config_home() .. "/" .. appname
  local dst = dst_dir .. "/init.lua"

  -- Read source
  local sf = io.open(src, "r")
  if not sf then
    wezterm.log_error("snatch.wezterm: cannot read " .. src)
    return false
  end
  local src_content = sf:read "*a"
  sf:close()

  -- Check if destination needs updating
  local df = io.open(dst, "r")
  if df then
    local dst_content = df:read "*a"
    df:close()
    if dst_content == src_content then
      return true -- already up to date
    end
  end

  -- Create directory and write
  os.execute('mkdir -p "' .. dst_dir .. '"')
  local wf = io.open(dst, "w")
  if not wf then
    wezterm.log_error("snatch.wezterm: cannot write " .. dst)
    return false
  end
  wf:write(src_content)
  wf:close()
  wezterm.log_info("snatch.wezterm: deployed nvim config to " .. dst)
  return true
end

-- Default shell for spawning
local function default_shell()
  if is_macos then
    return "/bin/zsh"
  end
  return os.getenv "SHELL" or "/bin/sh"
end

-- Shell command to run nvim and return to original tab
local function build_shell_cmd(shell, layout_file, appname, labels, caller_tab_idx)
  if shell:match "fish$" then
    return {
      shell, "-c", ([=[
        set -x NVIM_APPNAME %s
        set -x SNATCH_LAYOUT %s
        set -x SNATCH_LABELS '%s'
        nvim
        wezterm cli activate-tab --tab-index %d
      ]=]):format(appname, layout_file, labels, caller_tab_idx),
    }
  end
  -- POSIX shell (bash, zsh, sh)
  return {
    shell, "-c", ([=[
      export NVIM_APPNAME='%s'
      export SNATCH_LAYOUT='%s'
      export SNATCH_LABELS='%s'
      nvim
      wezterm cli activate-tab --tab-index %d
    ]=]):format(appname, layout_file, labels, caller_tab_idx),
  }
end

-- Build the snatch action
function M.action(opts)
  opts = opts or {}
  local appname = opts.nvim_appname or "snatch.wezterm"
  local labels = opts.labels or "HJKLASDFGYUIOPQWERTNMZXCVB"
  local shell = opts.shell or default_shell()

  ensure_nvim_config(appname)

  return wezterm.action_callback(function(window, pane)
    local tab = pane:tab()
    local panes_info = tab:panes_with_info()
    local timestamp = tostring(os.time())

    -- If a pane is zoomed, capture only that pane
    for _, info in ipairs(panes_info) do
      if info.is_zoomed then
        panes_info = { info }
        break
      end
    end

    local layout = { panes = {} }
    for _, info in ipairs(panes_info) do
      local p = info.pane
      local dims = p:get_dimensions()
      local total_rows = dims.scrollback_rows + dims.viewport_rows
      local text = p:get_logical_lines_as_text(total_rows)

      -- get_logical_lines_as_text() prepends a newline; strip it
      if text:sub(1, 1) == "\n" then
        text = text:sub(2)
      end

      local tmpfile = "/tmp/snatch-" .. timestamp .. "-" .. tostring(p:pane_id())
      local f = io.open(tmpfile, "w")
      if not f then
        wezterm.log_error("snatch.wezterm: failed to create " .. tmpfile)
        return
      end
      f:write(text)
      f:close()

      table.insert(layout.panes, {
        file = tmpfile,
        left = info.left,
        top = info.top,
        width = info.width,
        height = info.height,
        is_active = info.is_active,
      })
    end

    local layout_file = "/tmp/snatch-layout-" .. timestamp .. ".json"
    local lf = io.open(layout_file, "w")
    if not lf then
      wezterm.log_error "snatch.wezterm: failed to create layout file"
      return
    end
    lf:write(wezterm.json_encode(layout))
    lf:close()

    local caller_tab_idx = 0
    for _, info in ipairs(window:mux_window():tabs_with_info()) do
      if info.is_active then
        caller_tab_idx = info.index
        break
      end
    end

    window:perform_action(
      act.SpawnCommandInNewTab {
        domain = "CurrentPaneDomain",
        args = build_shell_cmd(shell, layout_file, appname, labels, caller_tab_idx),
      },
      pane
    )
  end)
end

return M
