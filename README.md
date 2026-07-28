# snatch.wezterm

Capture terminal screen text in [Neovim](https://neovim.io/) for navigation and copying.
A [WezTerm](https://wezterm.org/) plugin inspired by [tmux-fuzzy-motion](https://github.com/yuki-yano/tmux-fuzzy-motion).

## Features

- Capture all panes in the current tab with their scrollback, in colour
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
| `color` | `true` | Reproduce the terminal's colours; `false` gives plain text |
| `screenshot` | `false` | Capture before/after screenshots for [fidelity checking](#fidelity-testing) (macOS only) |

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

1. **WezTerm** captures each pane with `pane:get_lines_as_escapes()` (including scrollback) and writes it verbatim, plus a layout JSON carrying the pane geometry and the window's resolved colour palette
2. **Neovim** reads the layout, creates floating windows matching the original pane positions
3. `lua/snatch/ansi.lua` parses the escape sequences into text plus per-row highlight runs; the text goes into a scratch buffer with `wrap=false` at the matching width, so one buffer line is one terminal row, and the runs become extmarks
4. On yank or quit, temp files are cleaned up and focus returns to the original tab

### Why `get_lines_as_escapes()`

The obvious APIs, `pane:get_lines_as_text()` and `pane:get_logical_lines_as_text()`, both **drop empty lines**. They accumulate every line into one buffer and call `trim_end()` on the whole buffer after each line; `"\n"` is whitespace, so a line that contributes no characters also eats the newline written before it. Runs of blank lines vanish entirely. This is a WezTerm bug rather than a terminal limitation — it hits all output, not just alternate screen applications like `less` or `man`. ([Fix submitted upstream](https://github.com/wezterm/wezterm/pull/7985); `wezterm cli get-text` was never affected, if you want to cross-check by hand.)

`get_lines_as_escapes()` goes through `lines_to_escapes()`, which writes `"\r\n"` after every line unconditionally, so the grid survives intact — and it keeps the colours, which is what makes the reproduction match the terminal.

Two details of that output are easy to get wrong, and both shift the whole pane by a row if you do:

- The final `"\r\n"` is a terminator, not a separator, so it must not produce a trailing row.
- `lines_to_escapes()` appends one attribute reset *after* that last newline, leaving an unterminated fragment that carries escapes but no text. It is not a row either.

Colours arrive in the ITU-T T.416 **colon** form (`ESC[38:2::R:G:B`). Most ANSI parsers only handle the semicolon form; baleia.nvim, for instance, strips the sequence and renders no colour at all. The parser here handles both.

### Colours

`snatch.action { color = false }` falls back to plain text. Otherwise the reproduction picks up the terminal's palette:

- `Normal` and `NormalFloat` come from WezTerm's `resolved_palette`, so default-coloured cells and the gaps between panes match the real background.
- Selection is `reverse` and the cursor line is underlined, because Neovim's defaults for both are background-only and disappear under coloured cells.
- While jab.nvim is searching, colour flattens to the pane background. jab dims the screen with a single foreground-only `Comment` highlight, which would otherwise leave the backgrounds at full strength with grey text on top. Giving `Comment` a background turns it into a real backdrop; colour returns on the jump.

## Fidelity Testing

To check the reproduction against the real thing, turn on screenshots:

```lua
action = snatch.action { screenshot = true }
```

WezTerm then grabs the window when the key is pressed, Neovim grabs it again once the floating windows are laid out, and `scripts/fidelity.sh` stacks the two into `/tmp/snatch-<timestamp>-compare.png` and opens it. A row or column shift shows up as a misalignment across the magenta rule.

macOS only. It uses `screencapture(1)`, so the first run asks for Screen Recording permission; it also reads the window bounds through System Events, which needs Accessibility permission. Without the latter it falls back to capturing the whole primary display. ImageMagick is optional — without it the two images are left for you to compare by hand.

Note that the reproduction runs in a **new tab**, so if you hide the tab bar for single-tab windows the two shots will be one row out of step. That is the harness, not the capture.

## Development

`nvim/` is deployed into `$XDG_CONFIG_HOME/<nvim_appname>/` on config load. Only a change to the `-- spec-version:` line in `nvim/init.lua` asks the next launch to run `Lazy! sync`, so editing the parser does not cost a network round trip before the capture appears. Bump it when the lazy.nvim specs change.

Run the parser tests with:

```console
$ nvim -l tests/ansi_spec.lua
```

## Known Limitations

- **Wrapped lines yank as separate lines**: the capture is physical (already wrapped) rows, so a long line that WezTerm wrapped across two rows is two lines in the buffer. This is what makes the screen reproduction exact; the cost is that yanking such a line gives you the break too.

## License

MIT
