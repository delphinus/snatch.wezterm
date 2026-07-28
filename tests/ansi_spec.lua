-- Tests for the SGR parser. Run with:
--   nvim -l tests/ansi_spec.lua
--
-- Deliberately dependency-free: this has to be runnable from a bare Neovim.

package.path = "nvim/lua/?.lua;" .. package.path
local ansi = require "snatch.ansi"

local PALETTE = {
  foreground = "#c0caf5",
  background = "#1a1b26",
  ansi = { "#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6" },
  brights = { "#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5" },
}

local failures, checks = 0, 0

local function fail(name, msg)
  failures = failures + 1
  io.stderr:write(("  FAIL %s\n       %s\n"):format(name, msg))
end

local function eq(name, got, want)
  checks = checks + 1
  if vim.deep_equal(got, want) then
    return true
  end
  fail(name, ("got %s\n       want %s"):format(vim.inspect(got), vim.inspect(want)))
  return false
end

local function parse(text)
  return ansi.parse(text, PALETTE)
end

local E = "\27"

-- ---------------------------------------------------------------- line shape

do
  local lines = parse("hello\r\nthere\r\n")
  eq("CRLF rows, trailing terminator dropped", lines, { "hello", "there" })
end

do
  local lines = parse "plain\n"
  eq("bare LF also works", lines, { "plain" })
end

do
  -- The bug this project exists to avoid: blank rows are content.
  local lines = parse "a\r\n\r\n\r\nb\r\n"
  eq("interior blank rows survive", lines, { "a", "", "", "b" })
end

do
  local lines = parse "a\r\n\r\n"
  eq("a trailing blank row is not the terminator", lines, { "a", "" })
end

do
  -- lines_to_escapes() pushes one AllAttributes reset *after* the final "\r\n",
  -- so every real capture ends with an unterminated escape-only fragment. It is
  -- not a row; counting it shifts the whole pane down one line.
  local lines = parse("a\r\nb\r\n" .. E .. "[0m")
  eq("trailing attribute reset is not a row", lines, { "a", "b" })
end

do
  -- ...but an unterminated row with actual text is a row.
  local lines = parse "a\r\nb"
  eq("unterminated row with text is kept", lines, { "a", "b" })
end

-- ------------------------------------------------------------------- colours

do
  -- WezTerm's actual output: T.416 colon form with an empty colour-space-id.
  local lines, runs = parse(E .. "[38:2::255:0:0mred" .. E .. "[39m\r\n")
  eq("colon truecolor text", lines, { "red" })
  eq("colon truecolor run", runs[1], { { 0, 3, { fg = "#ff0000" } } })
end

do
  local _, runs = parse(E .. "[38;2;0;255;0mgreen" .. E .. "[39m\r\n")
  eq("semicolon truecolor", runs[1], { { 0, 5, { fg = "#00ff00" } } })
end

do
  local _, runs = parse(E .. "[48:2::17:34:51mbg" .. E .. "[49m\r\n")
  eq("colon truecolor background", runs[1], { { 0, 2, { bg = "#112233" } } })
end

do
  -- Compact colon form without the empty field, for good measure.
  local _, runs = parse(E .. "[38:2:1:2:3mx\r\n")
  eq("compact colon truecolor", runs[1], { { 0, 1, { fg = "#010203" } } })
end

do
  local _, runs = parse(E .. "[31mred" .. E .. "[92mbright\r\n")
  eq("basic and bright colours come from the palette", runs[1], {
    { 0, 3, { fg = "#f7768e" } },
    { 3, 9, { fg = "#9ece6a" } },
  })
end

do
  local _, runs = parse(E .. "[38;5;196mx" .. E .. "[38:5:21my\r\n")
  eq("indexed colour, both separators", runs[1], {
    { 0, 1, { fg = "#ff0000" } },
    { 1, 2, { fg = "#0000ff" } },
  })
end

-- ---------------------------------------------------------------- attributes

do
  local _, runs = parse(E .. "[0;1;4mboth" .. E .. "[0m\r\n")
  eq("compound reset+bold+underline", runs[1], { { 0, 4, { bold = true, underline = true } } })
end

do
  local _, runs = parse(E .. "[3mit" .. E .. "[23mplain\r\n")
  eq("italic on and off", runs[1], { { 0, 2, { italic = true } } })
end

do
  local _, runs = parse(E .. "[mx\r\n")
  eq("bare ESC[m is a reset, so no run", runs[1], {})
end

do
  -- Reverse must be resolved into swapped colours, never left as an attribute
  -- flag: flags OR upward into higher-priority highlights and would invert
  -- jab.nvim's labels.
  local _, runs = parse(E .. "[0;7mrev\r\n")
  eq("reverse with no colours swaps the palette defaults", runs[1], {
    { 0, 3, { fg = "#1a1b26", bg = "#c0caf5" } },
  })
end

do
  local _, runs = parse(E .. "[38:2::255:0:0;7mrev\r\n")
  eq("reverse swaps an explicit foreground into the background", runs[1], {
    { 0, 3, { fg = "#1a1b26", bg = "#ff0000" } },
  })
end

-- ------------------------------------------------------- non-SGR passthrough

do
  local lines, runs = parse("a" .. E .. "[Kb\r\n")
  eq("EL is removed from the text", lines, { "ab" })
  eq("EL with no background produces no run", runs[1], {})
end

do
  local _, runs = parse(E .. "[48:2::0:0:255mx" .. E .. "[K\r\n")
  eq("EL with a background asks for an end-of-line fill", runs[1], {
    { 0, 1, { bg = "#0000ff" } },
    { 1, 1, { bg = "#0000ff" }, nil, eol = true },
  })
end

do
  local lines = parse(E .. "(Bplain\r\n")
  eq("charset designation is removed", lines, { "plain" })
end

do
  local lines, runs = parse(E .. "]8;id=1;https://example.com" .. E .. "\\link" .. E .. "]8;;" .. E .. "\\ after\r\n")
  eq("OSC 8 is removed from the text", lines, { "link after" })
  eq("OSC 8 target is carried on the run", runs[1], { { 0, 4, nil, "https://example.com" } })
end

do
  local lines = parse("a" .. E .. "]0;window title\7b\r\n")
  eq("BEL-terminated OSC is removed", lines, { "ab" })
end

-- ------------------------------------------------------------ wide chars

do
  local text = E .. "[38:2::255:0:0m日本語" .. E .. "[39mabc\r\n"
  local lines, runs = parse(text)
  eq("wide characters survive", lines, { "日本語abc" })
  -- Three 3-byte characters
  eq("run columns are byte offsets", runs[1], { { 0, 9, { fg = "#ff0000" } } })
end

do
  -- Every run boundary must sit on a character boundary. nvim_buf_set_extmark
  -- silently accepts a column inside a multibyte sequence, so the API will not
  -- catch this for us.
  local lines, runs = parse(E .. "[31mあ" .. E .. "[32mい" .. E .. "[33mう\r\n")
  local line = lines[1]
  for _, run in ipairs(runs[1]) do
    for _, col in ipairs { run[1], run[2] } do
      checks = checks + 1
      local byte = col < #line and line:byte(col + 1) or nil
      -- A continuation byte is 0b10xxxxxx
      if byte and byte >= 0x80 and byte < 0xc0 then
        fail("run boundaries land on character boundaries", ("column %d is mid-character"):format(col))
      end
    end
  end
  eq("one run per colour across wide chars", #runs[1], 3)
end

-- ------------------------------------------------------------- across lines

do
  -- termwiz only re-emits attributes when they change, so state has to persist
  -- from one row to the next.
  local _, runs = parse(E .. "[38:2::255:0:0mone\r\ntwo\r\n" .. E .. "[39mthree\r\n")
  eq("colour carries into the next row", runs[1], { { 0, 3, { fg = "#ff0000" } } })
  eq("and stays set on the row after", runs[2], { { 0, 3, { fg = "#ff0000" } } })
  eq("until it is reset", runs[3], {})
end

-- -------------------------------------------------------------------- keys

do
  local a = ansi.key { fg = "#ff0000", bold = true }
  local b = ansi.key { fg = "#ff0000", bold = true }
  local c = ansi.key { fg = "#ff0000" }
  eq("identical attributes share a key", a, b)
  checks = checks + 1
  if a == c then
    fail("different attributes get different keys", "bold and non-bold collided")
  end
end

-- --------------------------------------------------------------------- done

if failures == 0 then
  print(("ansi_spec: %d checks passed"):format(checks))
else
  io.stderr:write(("ansi_spec: %d of %d checks FAILED\n"):format(failures, checks))
  os.exit(1)
end
