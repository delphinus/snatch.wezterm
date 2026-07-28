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

-- Screenshot the WezTerm window (macOS only) for the fidelity harness.
local function take_screenshot(path)
  if not is_macos then
    wezterm.log_warn "snatch.wezterm: screenshots are only supported on macOS"
    return
  end
  local dir = get_plugin_dir()
  if not dir then
    return
  end
  local ok, _, stderr = wezterm.run_child_process { dir .. "scripts/fidelity.sh", "capture", path }
  if not ok then
    wezterm.log_error("snatch.wezterm: screenshot failed: " .. (stderr or ""))
  end
end

-- Default shell for spawning
local function default_shell()
  if is_macos then
    return "/bin/zsh"
  end
  return os.getenv "SHELL" or "/bin/sh"
end

-- Environment passed to the spawned Neovim, in a fixed order.
local ENV_KEYS = { "NVIM_APPNAME", "SNATCH_LAYOUT", "SNATCH_LABELS", "SNATCH_SCREENSHOT", "SNATCH_FIDELITY" }

-- Shell command to run nvim and return to original tab.
-- Runs `Lazy! sync` first when ensure_nvim_config() left a marker, and only
-- removes the marker on success so a failed sync is retried next time.
-- In screenshot mode it also builds the before/after comparison once nvim exits.
local function build_shell_cmd(shell, env, caller_tab_idx)
  local marker = sync_marker_path(env.NVIM_APPNAME)
  local is_fish = shell:match "fish$" ~= nil

  -- `indent` keeps the generated script readable: the template already indents
  -- the first line, so only the continuations need padding.
  local function join_exports(indent)
    local lines = {}
    for _, key in ipairs(ENV_KEYS) do
      local value = env[key]
      if value then
        local fmt = is_fish and "set -x %s '%s'" or "export %s='%s'"
        table.insert(lines, fmt:format(key, value))
      end
    end
    return table.concat(lines, "\n" .. indent)
  end

  if is_fish then
    return {
      shell, "-c", ([=[
        %s
        if test -f '%s'
          echo 'snatch.wezterm: config updated, syncing Neovim plugins...'
          nvim --headless '+Lazy! sync' +qa; and rm -f '%s'
        end
        nvim
        if set -q SNATCH_SCREENSHOT
          "$SNATCH_FIDELITY" compare "$SNATCH_SCREENSHOT"
        end
        wezterm cli activate-tab --tab-index %d
      ]=]):format(join_exports "        ", marker, marker, caller_tab_idx),
    }
  end
  -- POSIX shell (bash, zsh, sh)
  return {
    shell, "-c", ([=[
      %s
      if [ -f '%s' ]; then
        echo 'snatch.wezterm: config updated, syncing Neovim plugins...'
        nvim --headless '+Lazy! sync' +qa && rm -f '%s'
      fi
      nvim
      if [ -n "${SNATCH_SCREENSHOT:-}" ]; then
        "$SNATCH_FIDELITY" compare "$SNATCH_SCREENSHOT"
      fi
      wezterm cli activate-tab --tab-index %d
    ]=]):format(join_exports "      ", marker, marker, caller_tab_idx),
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
    local shot_prefix = opts.screenshot and ("/tmp/snatch-" .. timestamp) or nil

    -- Grab the "before" image first so it shows the screen as it looked when
    -- the key was pressed, not after the captures below.
    if shot_prefix then
      take_screenshot(shot_prefix .. "-before.png")
    end

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

    local env = {
      NVIM_APPNAME = appname,
      SNATCH_LAYOUT = layout_file,
      SNATCH_LABELS = labels,
    }
    if shot_prefix then
      local dir = get_plugin_dir()
      if dir then
        env.SNATCH_SCREENSHOT = shot_prefix
        env.SNATCH_FIDELITY = dir .. "scripts/fidelity.sh"
      end
    end

    window:perform_action(
      act.SpawnCommandInNewTab {
        domain = "CurrentPaneDomain",
        args = build_shell_cmd(shell, env, caller_tab_idx),
      },
      pane
    )
  end)
end

return M
