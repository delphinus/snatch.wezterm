-- SGR parser for the escape text WezTerm's pane:get_lines_as_escapes() produces.
--
-- Deployed by the snatch.wezterm WezTerm plugin.
-- Do not edit directly; changes will be overwritten on plugin update.
--
-- The grammar is small and fully known: WezTerm renders through termwiz's
-- TerminfoRenderer, which emits SGR, EL, OSC 8 hyperlinks and the ASCII charset
-- designation, and nothing else -- no cursor motion. Colours arrive in the
-- ITU-T T.416 *colon* form (`38:2::R:G:B`), which most ANSI parsers get wrong,
-- so this handles both that and the usual semicolon form.

local M = {}

-- Byte offsets, not character offsets: extmark columns are byte indices, so
-- counting bytes makes the wide characters in these captures line up for free.

local function hex(r, g, b)
  return ("#%02x%02x%02x"):format(r, g, b)
end

---Look up an indexed colour, preferring WezTerm's own palette so the
---reproduction matches the terminal rather than Neovim's idea of "red".
---@param palette table
---@param n integer 0-255
---@return string|nil
local function indexed_color(palette, n)
  if n < 8 then
    local ansi = palette.ansi
    return ansi and ansi[n + 1] or nil
  elseif n < 16 then
    local brights = palette.brights
    return brights and brights[n - 7] or nil
  elseif n < 232 then
    -- 6x6x6 cube
    local i = n - 16
    local steps = { 0, 95, 135, 175, 215, 255 }
    return hex(steps[math.floor(i / 36) % 6 + 1], steps[math.floor(i / 6) % 6 + 1], steps[i % 6 + 1])
  elseif n < 256 then
    local v = 8 + (n - 232) * 10
    return hex(v, v, v)
  end
  return nil
end

---Parse one SGR parameter string (the bit between `ESC[` and `m`) into `state`.
---
---Parameters are separated by `;`, but a single parameter may itself carry
---colon-separated sub-parameters, which is how WezTerm writes truecolor. Split
---on `;` first, then decide per parameter.
local function apply_sgr(state, params, palette)
  -- `ESC[m` is an implicit reset
  if params == "" then
    params = "0"
  end

  local parts = {}
  for p in (params .. ";"):gmatch "([^;]*);" do
    parts[#parts + 1] = p
  end

  local i = 1
  while i <= #parts do
    local p = parts[i]
    local n = tonumber(p)

    if p:find ":" then
      -- Colon form: everything for this colour is inside this one parameter.
      local which, rest = p:match "^(%d+):(.*)$"
      if which == "38" or which == "48" then
        local sub = {}
        for s in (rest .. ":"):gmatch "([^:]*):" do
          sub[#sub + 1] = s
        end
        local color
        if sub[1] == "2" then
          -- `2:<colour-space-id>:R:G:B`, and the id is usually empty. Take the
          -- last three numeric components so both `2::R:G:B` and `2:R:G:B` work.
          local r, g, b = sub[#sub - 2], sub[#sub - 1], sub[#sub]
          if tonumber(r) and tonumber(g) and tonumber(b) then
            color = hex(tonumber(r), tonumber(g), tonumber(b))
          end
        elseif sub[1] == "5" and tonumber(sub[2]) then
          color = indexed_color(palette, tonumber(sub[2]))
        end
        if which == "38" then
          state.fg = color
        else
          state.bg = color
        end
      elseif which == "4" then
        -- `4:0` off, `4:1`..`4:5` are underline styles; treat any non-zero as on
        state.underline = rest ~= "0"
      end
    elseif n == 38 or n == 48 then
      -- Semicolon form: the colour spills into the following parameters.
      local color
      if parts[i + 1] == "2" then
        local r, g, b = tonumber(parts[i + 2]), tonumber(parts[i + 3]), tonumber(parts[i + 4])
        if r and g and b then
          color = hex(r, g, b)
        end
        i = i + 4
      elseif parts[i + 1] == "5" then
        local idx = tonumber(parts[i + 2])
        if idx then
          color = indexed_color(palette, idx)
        end
        i = i + 2
      end
      if n == 38 then
        state.fg = color
      else
        state.bg = color
      end
    elseif n == 0 then
      state.fg, state.bg = nil, nil
      state.bold, state.italic, state.underline, state.strikethrough, state.reverse = nil, nil, nil, nil, nil
    elseif n == 1 then
      state.bold = true
    elseif n == 3 then
      state.italic = true
    elseif n == 4 then
      state.underline = true
    elseif n == 7 then
      state.reverse = true
    elseif n == 9 then
      state.strikethrough = true
    elseif n == 22 then
      state.bold = nil
    elseif n == 23 then
      state.italic = nil
    elseif n == 24 then
      state.underline = nil
    elseif n == 27 then
      state.reverse = nil
    elseif n == 29 then
      state.strikethrough = nil
    elseif n == 39 then
      state.fg = nil
    elseif n == 49 then
      state.bg = nil
    elseif n and n >= 30 and n <= 37 then
      state.fg = indexed_color(palette, n - 30)
    elseif n and n >= 40 and n <= 47 then
      state.bg = indexed_color(palette, n - 40)
    elseif n and n >= 90 and n <= 97 then
      state.fg = indexed_color(palette, n - 90 + 8)
    elseif n and n >= 100 and n <= 107 then
      state.bg = indexed_color(palette, n - 100 + 8)
    end

    i = i + 1
  end
end

---Freeze the current state into an attribute table, resolving reverse video by
---swapping the colours here.
---
---Doing the swap now rather than with `nvim_set_hl { reverse = true }` matters:
---Neovim ORs attribute *flags* upward into higher-priority highlights, so a
---`reverse` run underneath jab.nvim's `CurSearch` label would invert the label
---too. Colours do not propagate that way, so a plain fg/bg pair is safe.
local function freeze(state, palette)
  local fg, bg = state.fg, state.bg
  if state.reverse then
    fg, bg = bg or palette.background, fg or palette.foreground
  end
  if not (fg or bg or state.bold or state.italic or state.underline or state.strikethrough) then
    return nil
  end
  return {
    fg = fg,
    bg = bg,
    bold = state.bold,
    italic = state.italic,
    underline = state.underline,
    strikethrough = state.strikethrough,
  }
end

---A stable key for an attribute table, so identical runs share one highlight
---group. Real captures collapse to a few dozen groups.
function M.key(attrs)
  return table.concat({
    attrs.fg or "",
    attrs.bg or "",
    attrs.bold and "b" or "",
    attrs.italic and "i" or "",
    attrs.underline and "u" or "",
    attrs.strikethrough and "s" or "",
  }, "|")
end

---Parse a whole capture.
---
---@param text string raw output of pane:get_lines_as_escapes()
---@param palette table|nil { foreground, background, ansi[8], brights[8] }
---@return string[] lines  text with all escapes removed, one entry per terminal row
---@return table runs      runs[row] = { { start_col, end_col, attrs, url }, ... }, 1-based row
function M.parse(text, palette)
  palette = palette or {}

  -- lines_to_escapes() terminates every row with "\r\n", so the newline is a
  -- terminator rather than a separator and must not yield a trailing row. It
  -- then appends one final attribute reset *after* that last newline, leaving
  -- an unterminated fragment that carries escapes but no text.
  --
  -- Track which rows were newline-terminated so both can be handled: a row that
  -- ends the text without a newline and parses to nothing is that reset and is
  -- dropped, while a genuinely blank row in the middle of the grid survives.
  -- Getting this wrong shifts every pane by a row and breaks bottom alignment.
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local rows, terminated = {}, {}
  local pos = 1
  while pos <= #text do
    local nl = text:find("\n", pos, true)
    if nl then
      rows[#rows + 1] = text:sub(pos, nl - 1)
      terminated[#rows] = true
      pos = nl + 1
    else
      rows[#rows + 1] = text:sub(pos)
      terminated[#rows] = false
      pos = #text + 1
    end
  end

  local lines, runs = {}, {}
  -- Attributes persist across rows; only SGR 0 (or an explicit off) clears them.
  local state = {}
  local url = nil

  for lnum, row in ipairs(rows) do
    local out, lruns = {}, {}
    local col = 0
    local attrs = freeze(state, palette)
    local start = 0
    local start_url = url
    local i = 1

    local function close(at)
      if attrs and at > start then
        lruns[#lruns + 1] = { start, at, attrs, start_url }
      elseif start_url and at > start then
        lruns[#lruns + 1] = { start, at, nil, start_url }
      end
    end

    while true do
      local esc = row:find("\27", i, true)
      if not esc then
        break
      end
      if esc > i then
        local lit = row:sub(i, esc - 1)
        out[#out + 1] = lit
        col = col + #lit
      end

      local nxt = row:sub(esc + 1, esc + 1)
      if nxt == "[" then
        local _, e, params, final = row:find("^\27%[([0-9;:?<=>]*)[ -/]*([@-~])", esc)
        if e then
          if final == "m" then
            close(col)
            apply_sgr(state, params, palette)
            attrs = freeze(state, palette)
            start, start_url = col, url
          elseif final == "K" then
            -- Erase to end of line with the current attributes. Only visible
            -- when a background is set; the caller turns this into hl_eol.
            if attrs and attrs.bg then
              close(col)
              lruns[#lruns + 1] = { col, col, attrs, start_url, eol = true }
              start, start_url = col, url
            end
          end
          i = e + 1
        else
          i = esc + 1
        end
      elseif nxt == "]" then
        -- OSC: `ESC]8;params;URL` sets a hyperlink, empty URL clears it.
        local _, e, body = row:find("^\27%]([^\7\27]*)[\7]", esc)
        if not e then
          _, e, body = row:find("^\27%]([^\27]*)\27\\", esc)
        end
        if e then
          local target = body:match "^8;[^;]*;(.*)$"
          if target ~= nil then
            close(col)
            url = target ~= "" and target or nil
            start, start_url = col, url
          end
          i = e + 1
        else
          i = esc + 1
        end
      else
        -- ESC intermediates final, e.g. the ESC ( B charset designation
        local _, e = row:find("^\27[ -/]*[0-~]", esc)
        i = (e or esc) + 1
      end
    end

    if i <= #row then
      local lit = row:sub(i)
      out[#out + 1] = lit
      col = col + #lit
    end
    close(col)

    lines[lnum] = table.concat(out)
    runs[lnum] = lruns
  end

  -- The trailing attribute reset described above.
  local last = #lines
  if last > 0 and not terminated[last] and lines[last] == "" then
    lines[last], runs[last] = nil, nil
  end

  return lines, runs
end

return M
