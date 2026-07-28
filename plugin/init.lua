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

-- Marker telling the next Neovim launch to sync its plugins.
--
-- The deployed init.lua pins the plugin specs (repo, branch) lazy.nvim installs.
-- When an update changes those specs, lazy.nvim keeps using the already cloned
-- directory: it only auto-installs plugins that are missing, and this config
-- disables `checker`/`change_detection`. The old clone then silently lacks the
-- features the new init.lua expects. Dropping a marker whenever init.lua
-- actually changes lets the next launch run `Lazy! sync` once, which re-clones
-- plugins whose origin moved.
local function sync_marker_path(appname)
  return nvim_config_home() .. "/" .. appname .. "/.snatch-sync-needed"
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

  -- The specs may have moved; ask the next launch to sync.
  local mf = io.open(sync_marker_path(appname), "w")
  if mf then
    mf:write ""
    mf:close()
  else
    wezterm.log_error("snatch.wezterm: cannot write " .. sync_marker_path(appname))
  end

  wezterm.log_info("snatch.wezterm: deployed nvim config to " .. dst)
  return true
end

-- Remove the escape sequences emitted by pane:get_lines_as_escapes().
--
-- We capture with the escapes variant rather than get_lines_as_text() because
-- the latter drops empty lines: it trims trailing whitespace off the whole
-- accumulated buffer after every line, and since "\n" is whitespace, a line
-- that contributes no characters also eats the newline before it. (Same bug in
-- get_logical_lines_as_text().) lines_to_escapes() writes "\r\n" per line
-- unconditionally, so the grid survives intact.
--
-- Lua patterns have no alternation, so run one gsub per sequence shape. Order
-- matters: OSC before CSI before the generic ESC form, or the generic form
-- would swallow the introducer of the longer ones.
local function strip_escapes(s)
  s = s:gsub("\27%][^\7\27]*\7", "") -- OSC ... BEL (hyperlinks)
  s = s:gsub("\27%][^\27]*\27\\", "") -- OSC ... ST
  s = s:gsub("\27%[[0-9;:?<=>]*[ -/]*[@-~]", "") -- CSI (SGR, EL, ...)
  s = s:gsub("\27[ -/]*[0-~]", "") -- ESC intermediates final (e.g. ESC ( B)
  return s
end

-- Capture a pane as plain text, one line per terminal row.
local function capture_pane(pane)
  local dims = pane:get_dimensions()
  -- scrollback_rows already counts the viewport rows, so it is the full
  -- history on its own.
  local text = strip_escapes(pane:get_lines_as_escapes(dims.scrollback_rows))
  return (text:gsub("\r\n", "\n"):gsub("\r", "\n"))
end

-- Default shell for spawning
local function default_shell()
  if is_macos then
    return "/bin/zsh"
  end
  return os.getenv "SHELL" or "/bin/sh"
end

-- Shell command to run nvim and return to original tab.
-- Runs `Lazy! sync` first when ensure_nvim_config() left a marker, and only
-- removes the marker on success so a failed sync is retried next time.
local function build_shell_cmd(shell, layout_file, appname, labels, caller_tab_idx)
  local marker = sync_marker_path(appname)
  if shell:match "fish$" then
    return {
      shell, "-c", ([=[
        set -x NVIM_APPNAME %s
        set -x SNATCH_LAYOUT %s
        set -x SNATCH_LABELS '%s'
        if test -f '%s'
          echo 'snatch.wezterm: config updated, syncing Neovim plugins...'
          nvim --headless '+Lazy! sync' +qa; and rm -f '%s'
        end
        nvim
        wezterm cli activate-tab --tab-index %d
      ]=]):format(appname, layout_file, labels, marker, marker, caller_tab_idx),
    }
  end
  -- POSIX shell (bash, zsh, sh)
  return {
    shell, "-c", ([=[
      export NVIM_APPNAME='%s'
      export SNATCH_LAYOUT='%s'
      export SNATCH_LABELS='%s'
      if [ -f '%s' ]; then
        echo 'snatch.wezterm: config updated, syncing Neovim plugins...'
        nvim --headless '+Lazy! sync' +qa && rm -f '%s'
      fi
      nvim
      wezterm cli activate-tab --tab-index %d
    ]=]):format(appname, layout_file, labels, marker, marker, caller_tab_idx),
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
      local text = capture_pane(p)

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
