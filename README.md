# snatch.wezterm

Capture terminal screen text in [Neovim](https://neovim.io/) for navigation and copying.
A [WezTerm](https://wezterm.org/) plugin inspired by [tmux-fuzzy-motion](https://github.com/yuki-yano/tmux-fuzzy-motion).

## Features

- Capture all panes in the current tab with their scrollback
- Reproduce pane layout using floating windows
- Navigate with [jab.nvim](https://github.com/atusy/jab.nvim) + [luamigemo](https://github.com/delphinus/luamigemo) for fuzzy-motion (including Japanese), labelling every pane at once
- Yank text to clipboard and auto-return to the original tab
- Handles zoomed panes

## Requirements

- [WezTerm](https://wezterm.org/) 20240127-113634 or later (for `pane:get_lines_as_escapes()`)
- [Neovim](https://neovim.io/) 0.10 or later
- Git (for lazy.nvim bootstrap on first use)

## Installation

Add to your `wezterm.lua`:

```lua
local wezterm = require "wezterm"
local config = wezterm.config_builder()

local snatch = wezterm.plugin.require "https://github.com/delphinus/snatch.wezterm"

config.keys = {
  {
    key = "[",
    mods = "CMD",
    action = snatch.action(),
  },
}

return config
```

## Options

`snatch.action(opts)` accepts an optional table:

| Option | Default | Description |
|--------|---------|-------------|
| `nvim_appname` | `"snatch.wezterm"` | `NVIM_APPNAME` for the Neovim instance |
| `labels` | `"HJKLASDFGYUIOPQWERTNMZXCVB"` | Characters used for jab.nvim jump labels |
| `shell` | `/bin/zsh` (macOS) or `$SHELL` | Shell to spawn Neovim in |

## Usage

1. Press the configured key (e.g., `Cmd+[`) in any WezTerm tab
2. A new tab opens with Neovim showing all panes' content
3. Navigate:
   - `s` to fuzzy-jump across panes with jab.nvim (supports Japanese via migemo)
   - Standard Vim motions (`/`, `?`, `hjkl`, etc.)
   - `v`/`V`/`Ctrl-V` for visual selection
4. `y` to yank — copies to clipboard and auto-closes
5. `q` to quit without copying

## Updating

After `wezterm.plugin.update_all()`, the plugin redeploys its `init.lua` on the
next config reload. If that file changed, the following launch runs
`Lazy! sync` once before opening the capture, so Neovim plugins follow the new
specs. This matters because lazy.nvim only auto-installs plugins that are
*missing*: when a spec moves to a different repository or branch, the existing
clone is kept as is, and the mismatch is otherwise silent.

## How It Works

1. **WezTerm** captures each pane with `pane:get_lines_as_escapes()` (including scrollback), strips the escape sequences, and writes a layout JSON
2. **Neovim** reads the layout, creates floating windows matching the original pane positions
3. Each floating window loads a pane's text with `wrap=false` at the matching width, so one buffer line is one terminal row
4. On yank or quit, temp files are cleaned up and focus returns to the original tab

### Why `get_lines_as_escapes()`

The obvious APIs, `pane:get_lines_as_text()` and `pane:get_logical_lines_as_text()`, both **drop empty lines**. They accumulate every line into one buffer and call `trim_end()` on the whole buffer after each line; `"\n"` is whitespace, so a line that contributes no characters also eats the newline written before it. Runs of blank lines vanish entirely. This is a WezTerm bug rather than a terminal limitation — it hits all output, not just alternate screen applications like `less` or `man`.

`get_lines_as_escapes()` goes through `lines_to_escapes()`, which writes `"\r\n"` after every line unconditionally, so the grid survives intact. We strip the SGR/EL/charset sequences back out and get exactly what is on screen. `wezterm cli get-text` is unaffected for the same reason, if you ever need to cross-check by hand.

## Known Limitations

- **Wrapped lines yank as separate lines**: the capture is physical (already wrapped) rows, so a long line that WezTerm wrapped across two rows is two lines in the buffer. This is what makes the screen reproduction exact; the cost is that yanking such a line gives you the break too.
- **Colors are discarded**: `get_lines_as_escapes()` returns styling, but the escapes are stripped before the text reaches Neovim.

## License

MIT
