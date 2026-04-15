# snatch.wezterm

Capture terminal screen text in [Neovim](https://neovim.io/) for navigation and copying.
A [WezTerm](https://wezterm.org/) plugin inspired by [tmux-fuzzy-motion](https://github.com/yuki-yano/tmux-fuzzy-motion).

## Features

- Capture all panes in the current tab with their scrollback
- Reproduce pane layout using floating windows
- Navigate with [flash.nvim](https://github.com/folke/flash.nvim) + [luamigemo](https://github.com/delphinus/luamigemo) for fuzzy-motion (including Japanese)
- Yank text to clipboard and auto-return to the original tab
- Handles zoomed panes

## Requirements

- [WezTerm](https://wezterm.org/) 20230320 or later (plugin support)
- [Neovim](https://neovim.io/) 0.10 or later
- Git (for lazy.nvim bootstrap on first use)

## Installation

Add to your `wezterm.lua`:

```lua
local wezterm = require "wezterm"
local config = wezterm.config_builder()

local snatch = wezterm.plugin.require "https://github.com/delphinus/snatch.wezterm"

-- Option A: Let the plugin add the keybinding
snatch.apply_to_config(config, {
  key = "[",
  mods = "CMD",
})

-- Option B: Add the keybinding yourself
snatch.apply_to_config(config)
table.insert(config.keys, {
  key = "[",
  mods = "CMD",
  action = snatch.action(),
})

return config
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `key` | `nil` | Key for the keybinding. If `nil`, no keybinding is added |
| `mods` | `nil` | Modifier keys (e.g., `"CMD"`, `"CTRL\|SHIFT"`) |
| `nvim_appname` | `"snatch.wezterm"` | `NVIM_APPNAME` for the Neovim instance |
| `labels` | `"HJKLASDFGYUIOPQWERTNMZXCVB"` | Characters used for flash.nvim jump labels |
| `shell` | `/bin/zsh` (macOS) or `$SHELL` | Shell to spawn Neovim in |

## Usage

1. Press the configured key (e.g., `Cmd+[`) in any WezTerm tab
2. A new tab opens with Neovim showing all panes' content
3. Navigate:
   - `s` to fuzzy-jump with flash.nvim (supports Japanese via migemo)
   - Standard Vim motions (`/`, `?`, `hjkl`, etc.)
   - `v`/`V`/`Ctrl-V` for visual selection
4. `y` to yank — copies to clipboard and auto-closes
5. `q` to quit without copying

## How It Works

1. **WezTerm** captures each pane's text (including scrollback) and writes a layout JSON
2. **Neovim** reads the layout, creates floating windows matching the original pane positions
3. Each floating window loads a pane's text with `wrap=true` at the matching width
4. On yank or quit, temp files are cleaned up and focus returns to the original tab

## License

MIT
