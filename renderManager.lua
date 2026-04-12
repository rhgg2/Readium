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
  local HEADER      = 2    -- header rows above grid data

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
  local colPromptBuf = nil   -- nil = closed, string = input buffer

  ---------- CONFIG HELPERS

  local function cfg(key, default)
    if cm then
      local val = cm:get(key)
      if val ~= nil then return val end
    end
    return default
  end

  ---------- CELL RENDERERS

  local function renderNote(evt)
    local function noteName(pitch)
      local NOTE_NAMES = {'C-','C#','D-','D#','E-','F-','F#','G-','G#','A-','A#','B-'}
      local oct = math.floor(pitch / 12) - 1
      local octChar = oct >= 0 and tostring(oct) or 'M'
      return NOTE_NAMES[(pitch % 12) + 1] .. octChar
    end

    if not evt then return '··· ··', 'inactive' end

    local noteTxt = '···'
    local velTxt  = evt.vel and string.format('%02X', evt.vel) or '\u{00B7}\u{00B7}'

    if evt.pitch then noteTxt = noteName(evt.pitch)
    elseif evt.type == 'pa' then noteTxt = 'PA ' end
    return noteTxt .. ' ' .. velTxt, evt.overflow and 'overflow'
  end

  local function renderPB(evt)
    if evt and not evt.hidden then
      if evt.val < 0 then return string.format('%04d', math.abs(evt.val)), 'negative'
      else return string.format('%04d', math.floor(evt.val or 0)) end
    else return '····', 'inactive' end
  end

  local function renderCC(evt)
    if evt and evt.val then return string.format('%02X', evt.val)
    else return '··', 'inactive' end
  end

  local function renderDefault(evt)
    if evt then return '**'
    else return '··', 'inactive'
    end
  end

  local renderFns = {
    note = renderNote,
    pb   = renderPB,
    cc   = renderCC,
    pa   = renderCC,
    at   = renderCC,
    pc   = renderCC,
  }

  local function renderCell(col, evt)
    return (renderFns[col.type] or renderDefault)(evt)
  end

  ---------- COLOUR

  local colourDefaults = {
    bg           = {218/256, 214/256, 201/256, 1  },
    text         = { 48/256,  48/256,  33/256, 1  },
    overflow     = {150/256,  90/256,  35/256, 1  },
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
    separator    = {159/256, 147/256, 115/256, 0.3},
    tail         = {100/256, 130/256, 160/256, 0.15},
    tailBord     = {100/256, 130/256, 160/256, 0.7},
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
      local offset    = math.max(0, math.floor((maxWidth - textWidth) / 2))
      drawTextAt(x0 + x1 * gX + offset, y0 + y * gY, txt, c)
    end

    function pt:vLine(x, y1, y2, c)
      ImGui.DrawList_AddLine(drawList, x0 + x * gX + halfW, y0 + y1 * gY, x0 + x * gX + halfW, y0 + y2 * gY + gY, colour(c), 1)
    end

    function pt:hLine(x1, x2, y, c)
      ImGui.DrawList_AddLine(drawList, x0 + x1 * gX, y0 + y * gY, x0 + x2 * gX + gX, y0 + y * gY, colour(c), 1)
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

    local subdivOptions = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
    for _, s in ipairs(subdivOptions) do
      local isActive = (s == rowPerBeat)
      if isActive then
        ImGui.PushStyleColor(ctx, ImGui.Col_Button, colour('cursor'))
        ImGui.PushStyleColor(ctx, ImGui.Col_Text,   colour('cursorText'))
      end
      if ImGui.SmallButton(ctx, tostring(s)) then
        local cursorRow, cursorCol, cursorStop = vm:cursor()
        vm:setCursor(math.floor(cursorRow * s / rowPerBeat), cursorCol, cursorStop)
        cm:set('track', 'rowPerBeat', s)
      end
      if isActive then ImGui.PopStyleColor(ctx, 2) end
      ImGui.SameLine(ctx)
    end

    ImGui.NewLine(ctx)
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

    -- Compute start position for each visible column and its group
    for _, group in ipairs(grid.groups) do
      group.x     = nil
      group.width = 0
      for i = group.firstCol, group.lastCol do
        grid.cols[i].x = nil
      end
    end

    local cx = 0
    for i = scrollCol, #grid.cols do
      local col = grid.cols[i]
      if cx + col.width > gridWidth then break end
      col.x = cx
      local group = col.group
      if not group.x then group.x = col.x end
      group.width = (col.x + col.width) - group.x
      cx = cx + col.width + 1
    end

    local totalWidth = math.max(0, cx - 1)
    local draw = printer(ctx, gridX, gridY, gridOriginX, gridOriginY)

    -- Header row 1: group labels
    draw:text(-GUTTER, -HEADER, 'Row', 'accent')
    for _, group in ipairs(grid.groups) do
      if group.x then
        draw:textCentred(group.x, group.x + group.width - 1, -HEADER, group.label, 'accent')
      end
    end

    -- Header row 2: column labels
    for _, col in ipairs(grid.cols) do
--      if col.x then draw:text(col.x, -1, col.label) end
      if col.x then draw:textCentred(col.x, col.x + col.width-1, -1, col.label) end
    end

    -- Separator below headers
    draw:hLine(-GUTTER, totalWidth - 1, 0, 'header')

    -- Rows
    for y = 0, gridHeight - 1 do
      local row = scrollRow + y
      if row >= numRows then break end

      local isBarStart, isBeatStart = vm:rowBeatInfo(row)
      local isCursor    = (row == cursorRow)

      -- Row background
      for _, group in ipairs(grid.groups) do
        if group.x then
          if isBarStart then
            draw:box(group.x, group.x + group.width - 1, y, y, 'rowBarStart')
          elseif isBeatStart then
            draw:box(group.x, group.x + group.width - 1, y, y, 'rowBeat')
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
          local startFrac = vm:fractionalRow(evt.ppq)
          local endFrac   = vm:fractionalRow(evt.endppq)
          if endFrac > viewTop and startFrac < viewBot then
            local y1 = gridOriginY + math.max(startFrac - scrollRow, 0) * gridY
            local y2 = gridOriginY + math.min(endFrac - scrollRow, gridHeight) * gridY
            local x1 = colPx - 4 -- (slot + 1) * (barW + 1)
--                        ImGui.DrawList_AddRectFilled(drawList, x1-6, y1, x1 + 5, y1+2, tailBord)
--            ImGui.DrawList_AddTriangleFilled(drawList, x1 - 0.5*gridX, y1, x1+2.5*gridX, y1, x1 + gridX, y1+6, tailCol)
            ImGui.DrawList_AddRectFilled(drawList, x1-2, y1-1, x1 + 4, y1+1, tailBord)
            ImGui.DrawList_AddRectFilled(drawList, x1-2, y1, x1, y2, tailBord)
            ImGui.DrawList_AddRectFilled(drawList, x1-2, y2-1, x1 + 4, y2+1, tailBord)
--            ImGui.DrawList_AddRect(drawList, x1-2, y1, x1 + 1, y2+1, tailBord,2)
          end
        end
      end
    end

    -- Cells
    for y = 0, gridHeight - 1 do
      local row = scrollRow + y
      if row >= numRows then break end
      for x, col in ipairs(grid.cols) do
        if col.x then
          local evt = col.cells and col.cells[row]
          local text, textCol = renderCell(col, evt)
          draw:text(col.x, y, text, textCol or 'text')
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
      local text = renderCell(col, evt)
      local ch = utf8.offset(text, stopOffset + 1) and text:sub(utf8.offset(text, stopOffset + 1), utf8.offset(text, stopOffset + 2) - 1) or ''
      if ch ~= '' then draw:text(charX, charY, ch, 'cursorText') end
    end

    -- Reserve content space so ImGui knows the drawable area
    ImGui.Dummy(ctx, (totalWidth + GUTTER) * gridX, (gridHeight + HEADER) * gridY)
  end

  local function drawStatusBar()
    local cursorRow, cursorCol = vm:cursor()
    local rowPerBeat, _, _, currentOctave, advanceBy = vm:displayParams()
    local ppq      = vm:rowPPQ(cursorRow)
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

  local keymap = {
    cursorDown  = { ImGui.Key_DownArrow  },
    cursorUp    = { ImGui.Key_UpArrow    },
    pageDown    = { ImGui.Key_PageDown   },
    pageUp      = { ImGui.Key_PageUp     },
    goTop       = { ImGui.Key_Home       },
    goBottom    = { ImGui.Key_End        },
    cursorRight = { ImGui.Key_RightArrow },
    cursorLeft  = { ImGui.Key_LeftArrow  },
    selectDown  = { { ImGui.Key_DownArrow,  ImGui.Mod_Shift } },
    selectUp    = { { ImGui.Key_UpArrow,    ImGui.Mod_Shift } },
    selectRight = { { ImGui.Key_RightArrow, ImGui.Mod_Shift } },
    selectLeft  = { { ImGui.Key_LeftArrow,  ImGui.Mod_Shift } },
    tabRight    = { ImGui.Key_Tab },
    tabLeft     = { { ImGui.Key_Tab, ImGui.Mod_Shift } },
    delete      = { ImGui.Key_Period },
    deleteSel   = { ImGui.Key_Delete },
    copy        = { { ImGui.Key_C, ImGui.Mod_Ctrl } },
    cut         = { { ImGui.Key_X, ImGui.Mod_Ctrl } },
    paste       = { { ImGui.Key_V, ImGui.Mod_Ctrl } },
    quit        = { ImGui.Key_Enter },
    upOctave       = { { ImGui.Key_8,  ImGui.Mod_Shift } },
    downOctave     = { ImGui.Key_Slash },
    noteOff        = { ImGui.Key_1 },
    growNote       = { ImGui.Key_RightBracket },
    shrinkNote     = { ImGui.Key_LeftBracket },
    growNoteFine   = { { ImGui.Key_RightBracket, ImGui.Mod_Shift } },
    shrinkNoteFine = { { ImGui.Key_LeftBracket,  ImGui.Mod_Shift } },
    playPause      = { ImGui.Key_Space },
    playFromTop    = { ImGui.Key_F6 },
    playFromCursor = { ImGui.Key_F7 },
    stop           = { ImGui.Key_F8 },
    addNoteCol     = { { ImGui.Key_N, ImGui.Mod_Ctrl } },
    addTypedCol    = { { ImGui.Key_T, ImGui.Mod_Ctrl } },
  }

  for i = 0, 9 do
    keymap['advBy' .. i] = { { ImGui.Key_0 + i, ImGui.Mod_Ctrl } }
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

    local clicked = ImGui.IsMouseClicked(ctx, 0)
    local held    = ImGui.IsMouseDown(ctx, 0)

    if clicked and ImGui.IsWindowHovered(ctx) then
      local mouseX, mouseY = ImGui.GetMousePos(ctx)
      local charY = math.floor((mouseY - gridOriginY) / gridY)
      local col, stop, fracX = nearestStop(mouseX, mouseY)
      if not col then return end
      if charY < 0 or charY >= gridHeight then return end
      if fracX < 0 then return end
      local last = grid.cols[col]
      if fracX >= last.x + last.width + 1 then return end

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
    if colPromptBuf then return end -- popup owns input

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
            if command == 'quit' then
              return true
            elseif command == 'addTypedCol' then
              colPromptBuf = ''
              ImGui.OpenPopup(ctx, 'Add Column')
              return
            else
              local fallThrough = vm.commands[command]()
              if not fallThrough then return end
              commandHeld = false
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
          local type = col.type

          -- Character queue: hex/decimal edits, octave changes
          -- Only process one event
          local rv, char = ImGui.GetInputQueueCharacter(ctx, 0)
          if rv then
            local evt = col.cells and col.cells[cursorRow]
            vm:editEvent(col, evt, cursorStop, char)
          end
        end
      end
    end
  end

  local function drawColPrompt()
    if not colPromptBuf then return end
    local center_x, center_y = ImGui.Viewport_GetCenter(ImGui.GetWindowViewport(ctx))
    ImGui.SetNextWindowPos(ctx, center_x, center_y, ImGui.Cond_Appearing, 0.5, 0.5)

    if ImGui.BeginPopupModal(ctx, 'Add Column', true, ImGui.WindowFlags_AlwaysAutoResize) then
      ImGui.Text(ctx, 'cc0-127, pb, at, pc')
      if ImGui.IsWindowAppearing(ctx) then
        ImGui.SetKeyboardFocusHere(ctx)
      end
      local rv, buf = ImGui.InputText(ctx, '##coltype', colPromptBuf,
        ImGui.InputTextFlags_EnterReturnsTrue)
      if rv then
        vm:addTypedCol(buf)
        colPromptBuf = nil
        ImGui.CloseCurrentPopup(ctx)
      elseif ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
        colPromptBuf = nil
        ImGui.CloseCurrentPopup(ctx)
      else
        colPromptBuf = buf
      end
      ImGui.EndPopup(ctx)
    else
      colPromptBuf = nil
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

    ImGui.PushFont(ctx, font, 18)
    
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
        drawColPrompt()
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
