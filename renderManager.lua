--------------------
-- newRenderManager
--
-- Handles all ImGui rendering and input for a viewManager.
-- Reads grid, cursor, and selection state from vm; dispatches
-- commands and edit input back through vm's public interface.
--
-- CONSTRUCTION
--   local rm = newRenderManager(vm, cm)
--
-- LIFECYCLE
--   rm:init()    -- create ImGui context and font
--   rm:loop()    -- per-frame draw; returns false when the window is closed
--------------------

loadModule('util')

local function print(...)
  return util:print(...)
end

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

--------------------
-- Factory
--------------------

function newRenderManager(vm, cm)

  ---------- PRIVATE STATE

  local GUTTER      = 4    -- row-number width in grid chars
  local HEADER      = 3    -- header rows above grid data

  local gridX       = nil
  local gridY       = nil
  local gridOriginX = 0
  local gridOriginY = 0
  local gridWidth   = 0
  local gridHeight  = 0

  local ctx         = nil
  local font        = nil
  local dragging    = false
  local dragWinX, dragWinY = 0, 0
  local modalState = nil   -- nil = closed, else { title, prompt, callback, buf }

  ---------- CONFIG HELPERS

  local function cfg(key, default)
    if cm then
      local val = cm:get(key)
      if val ~= nil then return val end
    end
    return default
  end

  ---------- CELL RENDERERS

  local function renderNote(evt, col, row)
    local function noteName(pitch)
      local NOTE_NAMES = {'C-','C#','D-','D#','E-','F-','F#','G-','G#','A-','A#','B-'}
      local oct = math.floor(pitch / 12) - 1
      local octChar = oct >= 0 and tostring(oct) or 'M'
      return NOTE_NAMES[(pitch % 12) + 1] .. octChar
    end

    local showDelay = col and col.showDelay
    if not evt then
      return showDelay and '··· ·· ··' or '··· ··'
    end

    local label
    if evt.type ~= 'pa' then
      label = select(1, vm:noteProjection(evt)) or noteName(evt.pitch)
    end
    local noteTxt = evt.type == 'pa' and '···' or label
    local velTxt  = evt.vel and string.format('%02X', evt.vel) or '··'
    local text    = noteTxt .. ' ' .. velTxt

    if showDelay then
      local basePPQ = vm:rowToPPQ(row)
      local nextPPQ = vm:rowToPPQ(row + 1)
      local rowLen  = nextPPQ - basePPQ
      local val     = rowLen > 0 and math.floor((evt.ppq - basePPQ) / rowLen * 0x80 + 0.5) or 0
      text = text .. ' ' .. (val > 0 and string.format('%02X', val) or '··')
    end
    return text
  end

  local function renderPB(evt)
    if evt and not evt.hidden then
      if evt.val < 0 then return string.format('%04d', math.abs(evt.val)), 'negative'
      else return string.format('%04d', math.floor(evt.val or 0)) end
    else return '····' end
  end

  local function renderCC(evt)
    if evt and evt.val then return string.format('%02X', evt.val)
    else return '··' end
  end

  local renderFns = {
    note = renderNote,
    pb   = renderPB,
    cc   = renderCC,
    pa   = renderCC,
    at   = renderCC,
    pc   = renderCC,
  }

  local function renderCell(evt, col, row)
    return renderFns[col.type] and renderFns[col.type](evt, col, row)
  end

  ---------- COLOUR

  local colourDefaults = {
    bg           = {218/256, 214/256, 201/256, 1  },
    text         = { 48/256,  48/256,  33/256, 1  },
    overflow     = {190/256,  90/256,  35/256, 1  },
    negative     = {218/256,  48/256,  33/256, 1  },
    textBar      = { 48/256,  48/256,  33/256, 1  },
    header       = { 48/256,  48/256,  33/256, 1  },
    inactive     = {138/256, 134/256, 121/256, 1  },
    cursor       = { 37/256,  41/256,  54/256, 1  },
    cursorText   = {207/256, 207/256, 222/256, 1  },
    rowNormal    = {218/256, 214/256, 201/256, 0  },
    rowBeat      = {181/256, 179/256, 158/256, 0.4},
    rowBarStart  = {159/256, 147/256, 115/256, 0.4},
    editCursor   = {1,       1,       0,       1  },
    selection    = {247/256, 247/256, 244/256, 0.5},
    scrollHandle = { 48/256,  48/256,  33/256, 1  },
    scrollBg     = {218/256, 214/256, 201/256, 1  },
    accent       = {159/256, 147/256, 115/256, 1  },
    mute         = {218/256,  48/256,  33/256, 1  },
    solo         = {220/256, 180/256,  50/256, 1  },
    separator    = {159/256, 147/256, 115/256, 0.3},
    tail         = {100/256, 130/256, 160/256, 0.15},
--    tailBord     = {100/256, 130/256, 160/256, 0.4},
    tailBord     = {140/256, 170/256, 200/256, 1},
    ghost        = {100/256, 130/256, 160/256, 0.9},
  }

  local colourCache = {}

  local function colour(name)
    name = name or 'text'
    if not colourCache[name] then
      local c = cfg('colour.' .. name, colourDefaults[name] or {0, 0, 0, 1})
      colourCache[name] = ImGui.ColorConvertDouble4ToU32(c[1], c[2], c[3], c[4])
    end
    return colourCache[name]
  end

  -- Flush colour cache on config changes
  local configCallback = function(changed, _cm)
    if changed.config then colourCache = {} end
  end
  if cm then cm:addCallback(configCallback) end

  ---------- DRAWING

  local function pushStyles()
    local count = 0
    local function push(enum, col)
      if enum then
        ImGui.PushStyleColor(ctx, enum, colour(col))
        count = count + 1
      end
    end
    push(ImGui.Col_WindowBg,      'bg')
    push(ImGui.Col_ScrollbarBg,   'scrollBg')
    push(ImGui.Col_ScrollbarGrab, 'scrollHandle')
    return count
  end

  local function printer(ctx, gX, gY, x0, y0)
    local drawList = ImGui.GetWindowDrawList(ctx)
    local halfW    = math.floor(gX / 2)
    local halfH    = math.floor(gY / 2)

    local pt = {}

    local function drawTextAt(xpos, ypos, txt, c)
      for char in txt:gmatch(utf8.charpattern) do
        ImGui.DrawList_AddText(drawList, xpos, ypos, colour(c), char)
        xpos = xpos + gX
      end
    end

    function pt:text(x, y, txt, c)
      drawTextAt(x0 + x * gX, y0 + y * gY - 1, txt, c)
    end

    function pt:textCentred(x1, x2, y, txt, c)
      local textWidth = ImGui.CalcTextSize(ctx, txt)
      local maxWidth  = (x2 - x1 + 1) * gX
      local offset    = math.floor((maxWidth - textWidth) / 2)
      drawTextAt(x0 + x1 * gX + offset, y0 + y * gY, txt, c)
    end

    function pt:textCentredSmall(x1, x2, y, txt, size, c)
      local scale     = size / 15
      local textWidth = ImGui.CalcTextSize(ctx, txt) * scale
      local maxWidth  = (x2 - x1 + 1) * gX
      local xPos = x0 + x1 * gX + math.floor((maxWidth - textWidth) / 2)
      ImGui.DrawList_AddTextEx(drawList, font, size, xPos, y0 + y * gY, colour(c), txt)
    end

    function pt:vLine(x, y1, y2, c)
      ImGui.DrawList_AddLine(drawList, x0 + x * gX + halfW, y0 + y1 * gY, x0 + x * gX + halfW, y0 + y2 * gY + gY, colour(c), 1)
    end

    function pt:hLine(x1, x2, y, c, yOff)
      local yPos = y0 + (y + (yOff or 0)) * gY
      ImGui.DrawList_AddLine(drawList, x0 + x1 * gX, yPos, x0 + x2 * gX + gX, yPos, colour(c), 1)
    end

    function pt:box(x1, x2, y1, y2, c)
      ImGui.DrawList_AddRectFilled(drawList, x0 + x1 * gX, y0 + y1 * gY, x0 + x2 * gX + gX, y0 + y2 * gY + gY, colour(c))
    end

    return pt
  end

  local function drawToolbar()
    local rowPerBeat = vm:displayParams()

    ImGui.PushStyleColor(ctx, ImGui.Col_Text, colour('header'))
    ImGui.Text(ctx, 'Rows/beat:')
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)

    local textW = ImGui.CalcTextSize(ctx, '32')
    local btnW  = ImGui.GetFrameHeight(ctx)
    ImGui.SetNextItemWidth(ctx, textW + btnW * 2 + 16)
    local changed, n = ImGui.InputInt(ctx, '##rpb', rowPerBeat, 1, 4)
    if changed then vm:setRowPerBeat(util:clamp(n, 1, 32)) end

--    ImGui.NewLine(ctx)
    ImGui.Separator(ctx)
  end

  local function drawTracker()
    local grid = vm.grid
    local cursorRow, cursorCol, cursorStop, scrollRow, scrollCol = vm:cursor()
    local sel = vm:selection()

    if not gridX then
      local charW, charH = ImGui.CalcTextSize(ctx, 'W')
      gridX              = 2 * math.ceil(charW / 2) -1
      gridY              = 2 * math.ceil(charH / 2) -1
    end

    local px, py = ImGui.GetCursorScreenPos(ctx)
    gridOriginX  = px + GUTTER * gridX
    gridOriginY  = py + HEADER * gridY

    local windowWidth, windowHeight = ImGui.GetContentRegionAvail(ctx)
    gridWidth  = math.max(1, math.floor(windowWidth  / gridX) - GUTTER)
    gridHeight = math.max(1, math.floor(windowHeight / gridY) - HEADER - 1)
    vm:setGridSize(gridWidth, gridHeight)
    local numRows = grid.numRows or 0

    -- Clear last frame's layout; then lay out visible columns left-to-right,
    -- accumulating each channel's x/width as we go.
    for _, col in ipairs(grid.cols) do col.x = nil end
    local chanX, chanW, chanOrder = {}, {}, {}

    local cx = 0
    for i = scrollCol, #grid.cols do
      local col = grid.cols[i]
      if cx + col.width > gridWidth then break end
      col.x = cx
      local chan = col.midiChan
      if chanX[chan] == nil then
        chanX[chan] = cx
        util:add(chanOrder, chan)
      end
      chanW[chan] = (cx + col.width) - chanX[chan]
      cx = cx + col.width + 1
    end

    local totalWidth = math.max(0, cx - 1)
    local draw = printer(ctx, gridX, gridY, gridOriginX, gridOriginY)

    -- Header row 1: channel labels. Colour signals mute/solo state:
    -- solo (amber) wins over mute (red), matching the audibility semantic.
    draw:text(-GUTTER, -HEADER, 'Row', 'accent')
    for chan = 1, 16 do
      if chanX[chan] then
        local key = vm:isChannelSoloed(chan) and 'solo'
                 or vm:isChannelMuted(chan)  and 'mute'
                 or 'accent'
        draw:textCentred(chanX[chan], chanX[chan] + chanW[chan] - 1,
                         -HEADER, 'Ch ' .. chan, key)
      end
    end

    -- Header rows 2 & 3: column labels and sub-labels. Track per-channel
    -- note-lane counters so note columns can display their lane number.
    local laneByChan = {}
    for _, col in ipairs(grid.cols) do
      local sub
      if col.type == 'note' then
        local n = (laneByChan[col.midiChan] or 0) + 1
        laneByChan[col.midiChan] = n
        sub = tostring(n)
      elseif col.type == 'cc' then
        sub = tostring(col.cc)
      end
      if col.x then
        local xr = col.x + col.width - 1
        draw:textCentred(col.x, xr, -2.1, col.label)
        if sub then
          draw:textCentredSmall(col.x, xr, -1.2, sub, 14, 'accent')
        end
      end
    end

    -- Separator below headers (1/3 up from the sub-label row)
    draw:hLine(-GUTTER, totalWidth - 1, 0, 'header', -1/3)

    -- Vertical dividers between channels, sitting in the inter-column gap
    for i = 1, #chanOrder - 1 do
      local chan = chanOrder[i]
      draw:vLine(chanX[chan] + chanW[chan], -HEADER, gridHeight - 1, 'separator')
    end

    -- Rows
    for y = 0, gridHeight - 1 do
      local row = scrollRow + y
      if row >= numRows then break end

      local isBarStart, isBeatStart = vm:rowBeatInfo(row)
      local isCursor    = (row == cursorRow)

      -- Row background
      if isBarStart or isBeatStart then
        local style = isBarStart and 'rowBarStart' or 'rowBeat'
        for chan = 1, 16 do
          if chanX[chan] then
            draw:box(chanX[chan], chanX[chan] + chanW[chan] - 1, y, y, style)
          end
        end
      end

      -- Row number
      local rowNumCol = (isBeatStart and 'textBar') or 'inactive'
      draw:text(-GUTTER, y, string.format('%03d', row), rowNumCol)
    end

    -- Sustain tails: one continuous bar per note
    local drawList = ImGui.GetWindowDrawList(ctx)
    local tailCol  = colour('tail')
    local tailBord = colour('tailBord')
    local barW     = gridX*3
    local viewTop  = scrollRow
    local viewBot  = scrollRow + gridHeight
    for _, col in ipairs(grid.cols) do
      if col.x and col.type == 'note' and col.events then
        local colPx = gridOriginX + col.x * gridX
        for _, evt in ipairs(col.events) do
          if evt.endppq then
            local startFrac = vm:ppqToRow(evt.ppq)
            local endFrac   = vm:ppqToRow(evt.endppq)
            if endFrac > viewTop and startFrac < viewBot then
              local y1 = gridOriginY + math.max(startFrac - scrollRow, 0) * gridY
              local y2 = gridOriginY + math.min(endFrac - scrollRow, gridHeight) * gridY
              local x1 = colPx - 4 -- (slot + 1) * (barW + 1)
              --                        ImGui.DrawList_AddRectFilled(drawList, x1-6, y1, x1 + 5, y1+2, tailBord)
              --            ImGui.DrawList_AddTriangleFilled(drawList, x1 - 0.5*gridX, y1, x1+2.5*gridX, y1, x1 + gridX, y1+6, tailCol)
              ImGui.DrawList_AddRectFilled(drawList, x1-1, y1-1, x1 + 4, y1+1, tailBord)
              ImGui.DrawList_AddRectFilled(drawList, x1-2, y1, x1, y2, tailBord)
              ImGui.DrawList_AddRectFilled(drawList, x1-1, y2-1, x1 + 4, y2+1, tailBord)
              --            ImGui.DrawList_AddRect(drawList, x1-2, y1, x1 + 1, y2+1, tailBord,2)
            end
          end
        end
      end
    end

    -- Cells. Dots (·) are always 'inactive' even when the rest of the
    -- cell is active, so split runs on dot boundaries.
    for y = 0, gridHeight - 1 do
      local row = scrollRow + y
      if row >= numRows then break end
      for x, col in ipairs(grid.cols) do
        if col.x then
          local evt = col.cells and col.cells[row]
          local ghost = not evt and col.ghosts and col.ghosts[row]
          local text, textCol
          if ghost then
            text    = renderCell({ val = ghost.val }, col, row)
            textCol = 'ghost'
          else
            text, textCol = renderCell(evt, col, row)
            if col.overflow and col.overflow[row] then textCol = 'overflow' end
            textCol = textCol or 'text'
          end
          if vm:isChannelEffectivelyMuted(col.midiChan) then textCol = 'inactive' end
          local cx = col.x
          for ch in text:gmatch(utf8.charpattern) do
            draw:text(cx, y, ch, ch == '·' and 'inactive' or textCol)
            cx = cx + 1
          end
        end
      end
    end

    -- Off-grid bars: projection gap between note intent and displayed step.
    -- Drawn only under an active tuning, only for notes with a non-zero gap.
    if vm:activeTuning() then
      local barCol = colour('accent')
      for _, col in ipairs(grid.cols) do
        if col.x and col.type == 'note' and col.cells then
          local x0 = gridOriginX + col.x * gridX
          local x1 = x0 + 3 * gridX
          local cx = (x0 + x1) / 2
          local halfW = (x1 - x0) / 2 - 1
          for y = 0, gridHeight - 1 do
            local row = scrollRow + y
            if row >= numRows then break end
            local evt = col.cells[row]
            if evt and evt.pitch then
              local _, gap, halfGap = vm:noteProjection(evt)
              if gap and gap ~= 0 and halfGap > 0 then
                local yTop = gridOriginY + y * gridY + 1
                local offset = util:clamp(gap / halfGap, -1, 1) * halfW
                ImGui.DrawList_AddLine(drawList, x0, yTop, x1, yTop, barCol, 1)
                local tickX = cx + offset
                ImGui.DrawList_AddLine(drawList, tickX, yTop - 1, tickX, yTop + 2, barCol, 1)
              end
            end
          end
        end
      end
    end

    -- Selection highlight
    if sel and sel.col2 >= scrollCol and sel.col1 <= vm:lastVisibleFrom(scrollCol) then
      local yFrom = math.max(sel.row1 - scrollRow, 0)
      local yTo   = math.min(sel.row2 - scrollRow, gridHeight - 1)
      local c1, c2 = grid.cols[sel.col1], grid.cols[sel.col2]
      local x1, x2
      if c1.x then
        x1 = c1.x
        for s, g in ipairs(c1.selGroups) do
          if g >= sel.selgrp1 then x1 = c1.x + c1.stopPos[s]; break end
        end
      else x1 = 0 end
      if c2.x then
        x2 = c2.x + c2.stopPos[#c2.stopPos]
        for s = #c2.selGroups, 1, -1 do
          if c2.selGroups[s] <= sel.selgrp2 then x2 = c2.x + c2.stopPos[s]; break end
        end
      else x2 = totalWidth end
      draw:box(x1, x2, yFrom, yTo, 'selection')
    end

    -- Cursor
    local col = grid.cols[cursorCol]
    if col and col.x then
      local stopOffset = (col.stopPos and col.stopPos[cursorStop]) or 0
      local charX = col.x + stopOffset
      local charY = cursorRow - scrollRow
      draw:box(charX, charX, charY+0.1, charY-0.1, 'cursor')
      local evt = col.cells and col.cells[cursorRow]
      local text = renderCell(evt, col, cursorRow)
      local ch = utf8.offset(text, stopOffset + 1) and text:sub(utf8.offset(text, stopOffset + 1), utf8.offset(text, stopOffset + 2) - 1) or ''
      if ch ~= '' then draw:text(charX, charY, ch, 'cursorText') end
    end

    -- Reserve content space so ImGui knows the drawable area
    ImGui.Dummy(ctx, (totalWidth + GUTTER) * gridX, (gridHeight + HEADER) * gridY)
  end

  local function drawStatusBar()
    local cursorRow, cursorCol = vm:cursor()
    local rowPerBeat, _, _, currentOctave, advanceBy = vm:displayParams()
    local ppq      = vm:rowToPPQ(cursorRow)
    local bar, beat, sub, ts = vm:barBeatSub(cursorRow)
    local col      = vm.grid.cols[cursorCol]
    local colLabel = col and col.label or '?'
    local tsLabel  = ts and string.format('%d/%d', ts.num, ts.denom) or '?'

    ImGui.Separator(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, colour('header'))
    ImGui.Text(ctx, string.format(
      '%s | PPQ: %d | %d:%d.%d/%d | Octave: %d | Advance: %d',
      colLabel, math.floor(ppq), bar, beat, sub, rowPerBeat, currentOctave, advanceBy
    ))
    ImGui.PopStyleColor(ctx)
  end

  ---------- COMMANDS & KEYBOARD

  local keymap     = {
    cursorUp       = { ImGui.Key_UpArrow,    {ImGui.Key_P, ImGui.Mod_Super} },
    cursorDown     = { ImGui.Key_DownArrow,  {ImGui.Key_N, ImGui.Mod_Super} },
    cursorLeft     = { ImGui.Key_LeftArrow,  {ImGui.Key_B, ImGui.Mod_Super} },
    cursorRight    = { ImGui.Key_RightArrow, {ImGui.Key_F, ImGui.Mod_Super} },
    goTop          = { ImGui.Key_Home,       {ImGui.Key_Comma, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
    goBottom       = { ImGui.Key_End,        {ImGui.Key_Period, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
    pageUp         = { ImGui.Key_PageUp },
    pageDown       = { ImGui.Key_PageDown },
    goLeft         = { {ImGui.Key_A, ImGui.Mod_Super} },
    goRight        = { {ImGui.Key_E, ImGui.Mod_Super} },
    colLeft        = { {ImGui.Key_B, ImGui.Mod_Ctrl} },
    colRight       = { {ImGui.Key_F, ImGui.Mod_Ctrl} },
    channelLeft    = { {ImGui.Key_Tab, ImGui.Mod_Shift} },
    channelRight   = { ImGui.Key_Tab },
    noteOff        = { ImGui.Key_1 },
    shrinkNote     = { {ImGui.Key_LeftBracket, ImGui.Mod_Shift} },
    growNote       = { {ImGui.Key_RightBracket, ImGui.Mod_Shift} },
    nudgeBack      = { ImGui.Key_LeftBracket },
    nudgeForward   = { ImGui.Key_RightBracket },
    insertRow      = { {ImGui.Key_DownArrow, ImGui.Mod_Ctrl} },
    deleteRow      = { {ImGui.Key_UpArrow, ImGui.Mod_Ctrl} },
    delete         = { ImGui.Key_Period },
    interpolate    = { {ImGui.Key_I, ImGui.Mod_Ctrl} },
    selectUp       = { {ImGui.Key_UpArrow, ImGui.Mod_Shift} },
    selectDown     = { {ImGui.Key_DownArrow, ImGui.Mod_Shift} },
    selectLeft     = { {ImGui.Key_LeftArrow, ImGui.Mod_Shift} },
    selectRight    = { {ImGui.Key_RightArrow, ImGui.Mod_Shift} },
    cycleBlock     = { {ImGui.Key_Space, ImGui.Mod_Super} },
    cycleVBlock    = { {ImGui.Key_O, ImGui.Mod_Super} },
    swapBlockEnds  = { {ImGui.Key_GraveAccent, ImGui.Mod_Ctrl} },
    selectClear    = { {ImGui.Key_G, ImGui.Mod_Super} },
    cut            = { {ImGui.Key_W, ImGui.Mod_Super}, {ImGui.Key_X, ImGui.Mod_Ctrl} },
    copy           = { {ImGui.Key_W, ImGui.Mod_Ctrl}, {ImGui.Key_C, ImGui.Mod_Ctrl} },
    paste          = { {ImGui.Key_Y, ImGui.Mod_Super}, {ImGui.Key_V, ImGui.Mod_Ctrl} },
    duplicateDown  = { {ImGui.Key_D, ImGui.Mod_Ctrl} },
    duplicateUp    = { {ImGui.Key_D, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
    deleteSel      = { ImGui.Key_Delete },
    nudgeCoarseUp   = { ImGui.Key_Equal },
    nudgeCoarseDown = { ImGui.Key_Minus },
    nudgeFineUp     = { {ImGui.Key_Equal, ImGui.Mod_Shift} },
    nudgeFineDown   = { {ImGui.Key_Minus, ImGui.Mod_Shift} },
    addNoteCol     = { {ImGui.Key_N, ImGui.Mod_Ctrl} },
    addTypedCol    = { {ImGui.Key_T, ImGui.Mod_Ctrl} },
    doubleRPB      = { {ImGui.Key_Equal, ImGui.Mod_Super} },
    halveRPB       = { {ImGui.Key_Minus, ImGui.Mod_Super} },
    setRPB         = { {ImGui.Key_R, ImGui.Mod_Ctrl} },
    hideExtraCol   = { {ImGui.Key_H, ImGui.Mod_Ctrl} },
    inputOctaveUp   = { {ImGui.Key_8, ImGui.Mod_Shift} },
    inputOctaveDown = { ImGui.Key_Slash },
    playPause      = { ImGui.Key_Space },
    playFromTop    = { ImGui.Key_F6 },
    playFromCursor = { ImGui.Key_F7 },
    stop           = { ImGui.Key_F8 },
    quit           = { ImGui.Key_Enter },
    cycleTuning    = { {ImGui.Key_T, ImGui.Mod_Super} },
  }

  for i = 0, 9 do
    keymap['advBy' .. i] = { {ImGui.Key_0 + i, ImGui.Mod_Ctrl} }
  end

  ---------- INPUT HANDLING

  local function nearestStop(mouseX, mouseY)
    local grid = vm.grid
    local fracX = (mouseX - gridOriginX) / gridX
    local bestCol, bestStop, bestDist = nil, nil, math.huge
    for i, col in ipairs(grid.cols) do
      if col.x then
        for s, pos in ipairs(col.stopPos) do
          local dist = math.abs(fracX - col.x - pos - 0.5)
          if dist < bestDist then
            bestCol, bestStop, bestDist = i, s, dist
          end
        end
      end
    end
    return bestCol, bestStop, fracX
  end

  local function handleMouse()
    local grid = vm.grid
    local cursorRow, cursorCol, cursorStop, scrollRow, scrollCol = vm:cursor()

    local clicked      = ImGui.IsMouseClicked(ctx, 0)
    local rightClicked = ImGui.IsMouseClicked(ctx, 1)
    local held         = ImGui.IsMouseDown(ctx, 0)

    -- Right-click on the channel-header row toggles that channel's mute.
    if rightClicked and ImGui.IsWindowHovered(ctx) then
      local mouseX, mouseY = ImGui.GetMousePos(ctx)
      local charY = math.floor((mouseY - gridOriginY) / gridY)
      local col, _, fracX = nearestStop(mouseX, mouseY)
      if col and charY == -HEADER and fracX >= 0 then
        local last = grid.cols[col]
        if fracX < last.x + last.width + 1 then
          vm:toggleChannelMute(last.midiChan)
        end
      end
      return
    end

    if clicked and ImGui.IsWindowHovered(ctx) then
      local mouseX, mouseY = ImGui.GetMousePos(ctx)
      local charY = math.floor((mouseY - gridOriginY) / gridY)
      local col, stop, fracX = nearestStop(mouseX, mouseY)
      if not col then return end
      if charY < -HEADER or charY >= gridHeight then return end
      if fracX < 0 then return end
      local last = grid.cols[col]
      if fracX >= last.x + last.width + 1 then return end

      if charY < 0 then
        if charY == -HEADER then vm:selectChannel(last.midiChan)
        else vm:selectColumn(col) end
        return
      end

      local shift = ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift ~= 0

      if shift then
        if not vm:selection() then vm:selStart() end
        vm:setCursor(scrollRow + charY, col, stop)
        vm:selUpdate()
      else
        vm:selClear()
        vm:setCursor(scrollRow + charY, col, stop)
        dragging = true
        dragWinX, dragWinY = ImGui.GetWindowPos(ctx)
      end

    elseif dragging and held then
      local mouseX, mouseY = ImGui.GetMousePos(ctx)
      local charY = math.floor((mouseY - gridOriginY) / gridY)
      local row = scrollRow + charY
      local fracX = (mouseX - gridOriginX) / gridX
      local lastVis = vm:lastVisibleFrom(scrollCol)
      local rightEdge = grid.cols[lastVis].x + grid.cols[lastVis].width

      local col, stop
      if fracX < 0 then
        col, stop = cursorCol, cursorStop - 1
        if stop < 1 then
          if col > 1 then col = col - 1; stop = #grid.cols[col].stopPos
          else stop = 1 end
        end
      elseif fracX >= rightEdge then
        col, stop = cursorCol, cursorStop + 1
        if stop > #grid.cols[cursorCol].stopPos then
          if col < #grid.cols then col = col + 1; stop = 1
          else stop = #grid.cols[col].stopPos end
        end
      else
        col, stop = nearestStop(mouseX, mouseY)
        if not col then return end
      end

      -- Only start selection once cursor moves to a different position
      if row ~= cursorRow or col ~= cursorCol or stop ~= cursorStop then
        if not vm:selection() then vm:selStart() end
        vm:setCursor(row, col, stop)
        vm:selUpdate()
      end

    elseif dragging and not held then
      dragging = false
    end

    -- Mouse wheel scroll
    if ImGui.IsWindowHovered(ctx) then
      local wheel,wheelH  = ImGui.GetMouseWheel(ctx)
      if wheel ~= 0 then
        local n = math.floor(math.abs(wheel) / 2 + 0.5)
        if n > 0 then
          local cmd = wheel > 0 and vm.commands.cursorUp or vm.commands.cursorDown
          for _ = 1, n do cmd() end
        end
      end
      if wheelH ~= 0 then
        local n = math.floor(math.abs(wheelH) + 0.5)
        if n > 0 then
          local cmd = wheelH > 0 and vm.commands.cursorLeft or vm.commands.cursorRight
          for _ = 1, n do cmd() end
        end
      end
    end
  end

  local function handleKeys()
    if modalState then return end -- popup owns input

    local grid = vm.grid
    local cursorRow, cursorCol, cursorStop = vm:cursor()

    if ImGui.IsWindowFocused(ctx) then
      local commandHeld = false
      for command, keys in pairs(keymap) do
        for _, key in ipairs(keys) do
          local mods = ImGui.Mod_None
          if type(key) == 'table' then
            for i = 2, #key do
              mods = mods | key[i]
            end
            key = key[1]
          end
          if ImGui.IsKeyDown(ctx, key) and mods == ImGui.Mod_None then commandHeld = true end
          if ImGui.IsKeyPressed(ctx, key) and ImGui.GetKeyMods(ctx) == mods then
            local result, state = vm.commands[command]()
            if result == 'quit' then
              return true
            elseif result == 'modal' then
              modalState = state
              modalState.buf = ''
              ImGui.OpenPopup(ctx, state.title)
              return
            elseif result == 'fallthrough' then
              commandHeld = false
            else
              return
            end
          end
        end
      end

      -- Edit keys: unmodified alphanumeric input
      -- Skip if a command key is held — auto-repeat timing mismatches
      -- between IsKeyPressed and the character queue can leak input
      if not commandHeld and ImGui.GetKeyMods(ctx) == ImGui.Mod_None then
        local col = grid.cols[cursorCol]
        if col then
          -- Character queue: hex/decimal edits, octave changes
          -- Only process one event
          local rv, char = ImGui.GetInputQueueCharacter(ctx, 0)
          if rv then
            if vm:markMode() then
              vm:clearMark()
            else
              local evt = col.cells and col.cells[cursorRow]
              vm:editEvent(col, evt, cursorStop, char)
            end
          end
        end
      end

      -- Shift-digit: half-step entry at MSB stops (vel, delay, cc/at/pc).
      -- Overwrites the value with digit in MSB, half-value (8 hex / 5 dec) in LSB.
      if not commandHeld and ImGui.GetKeyMods(ctx) == ImGui.Mod_Shift and not vm:markMode() then
        local col = grid.cols[cursorCol]
        if col then
          for d = 0, 9 do
            if ImGui.IsKeyPressed(ctx, ImGui.Key_0 + d) then
              local evt = col.cells and col.cells[cursorRow]
              vm:editEvent(col, evt, cursorStop, string.byte('0') + d, true)
              break
            end
          end
        end
      end
    end
  end

  local function drawModal()
    if not modalState then return end
    local center_x, center_y = ImGui.Viewport_GetCenter(ImGui.GetWindowViewport(ctx))
    ImGui.SetNextWindowPos(ctx, center_x, center_y, ImGui.Cond_Appearing, 0.5, 0.5)

    if ImGui.BeginPopupModal(ctx, modalState.title, true, ImGui.WindowFlags_AlwaysAutoResize) then
      ImGui.Text(ctx, modalState.prompt)
      if ImGui.IsWindowAppearing(ctx) then
        ImGui.SetKeyboardFocusHere(ctx)
      end
      local rv, buf = ImGui.InputText(ctx, '##modal', modalState.buf,
        ImGui.InputTextFlags_EnterReturnsTrue)
      if rv then
        local ok, err = pcall(modalState.callback, buf)
        if not ok then
          reaper.ShowConsoleMsg('\nModal callback error: ' .. tostring(err) .. '\n')
        end
        modalState = nil
        ImGui.CloseCurrentPopup(ctx)
      elseif ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
        modalState = nil
        ImGui.CloseCurrentPopup(ctx)
      else
        modalState.buf = buf
      end
      ImGui.EndPopup(ctx)
    else
      modalState = nil
    end
  end

  --------------------
  -- Public interface
  --------------------

  local rm = {}

  function rm:init()
    ctx  = ImGui.CreateContext('Readium Tracker')
    font = ImGui.CreateFont('Source Code Pro')
    ImGui.Attach(ctx, font)
  end

  function rm:loop()
    if not ctx then return false end

    ImGui.PushFont(ctx, font, 15)
    
    local styleCount = pushStyles()

    if dragging then
      ImGui.SetNextWindowPos(ctx, dragWinX, dragWinY)
    end
    local visible, open = ImGui.Begin(ctx, 'Readium Tracker', true,
      ImGui.WindowFlags_NoScrollbar
      | ImGui.WindowFlags_NoScrollWithMouse
      | ImGui.WindowFlags_NoDocking
      | ImGui.WindowFlags_NoNav)
    local quit = false

    if visible then
      if #vm.grid.cols > 0 then
        drawToolbar()
        drawTracker()
        drawStatusBar()
        handleMouse()
        quit = handleKeys()
        drawModal()
      else
        ImGui.Text(ctx, 'Select a MIDI item to begin.')
      end

      ImGui.End(ctx)
    end

    ImGui.PopStyleColor(ctx, styleCount)
    ImGui.PopFont(ctx)

    vm:tick()

    return open and not quit
  end

  return rm
end
