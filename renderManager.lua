-- See docs/renderManager.md for the model and API reference.

loadModule('util')
loadModule('timing')

local function print(...)
  return util.print(...)
end

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'My script', 0)
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

function newRenderManager(vm, cm, cmgr)

  ---------- PRIVATE

  local GUTTER      = 4    -- in grid chars
  local HEADER      = 3    -- in grid rows

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
  local modalState = nil   -- nil = closed, else { title, prompt, callback, buf, kind? }
  local swingEditor = nil  -- nil = closed, else { name, snapshot, createBuf, createError }
  local quitting   = false -- set by the quit command, observed by rm:loop

  ----- Cell renderers

  local function renderNote(evt, col, row)
    local function noteName(pitch)
      local NOTE_NAMES = {'C-','C#','D-','D#','E-','F-','F#','G-','G#','A-','A#','B-'}
      local oct = math.floor(pitch / 12) - 1
      local octChar = oct >= 0 and tostring(oct) or 'M'
      return NOTE_NAMES[(pitch % 12) + 1] .. octChar
    end

    local showDelay = col and col.showDelay
    if not evt then
      return showDelay and '··· ·· ···' or '··· ··'
    end

    local label
    if evt.type ~= 'pa' then
      label = select(1, vm:noteProjection(evt)) or noteName(evt.pitch)
    end
    local noteTxt = evt.type == 'pa' and '···' or label
    local velTxt  = evt.vel and string.format('%02X', evt.vel) or '··'
    local text    = noteTxt .. ' ' .. velTxt

    if showDelay then
      local d = evt.delay or 0
      if d == 0 then
        return text .. ' ···'
      end
      text = text .. ' ' .. string.format('%03d', math.abs(d))
      -- Digits sit at char positions 8,9,10 regardless of whether the prefix
      -- uses ASCII note names or multi-byte '···' for pa. Use char indices.
      if d < 0 then return text, nil, { [8] = 'negative', [9] = 'negative', [10] = 'negative' } end
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
    local fn = renderFns[col.type]
    if fn then return fn(evt, col, row) end
  end

  ----- Colour

  local colourCache = {}

  local function colour(name)
    name = name or 'text'
    if not colourCache[name] then
      local c = cm:get('colour.' .. name)
      colourCache[name] = ImGui.ColorConvertDouble4ToU32(c[1], c[2], c[3], c[4])
    end
    return colourCache[name]
  end

  cm:subscribe('configChanged', function() colourCache = {} end)

  ----- Drawing

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
    local rowPerBeat = cm:get('rowPerBeat')

    ImGui.PushStyleColor(ctx, ImGui.Col_Text, colour('header'))
    ImGui.Text(ctx, 'Rows/beat:')
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)

    local textW = ImGui.CalcTextSize(ctx, '32')
    local btnW  = ImGui.GetFrameHeight(ctx)
    ImGui.SetNextItemWidth(ctx, textW + btnW * 2 + 16)
    local changed, n = ImGui.InputInt(ctx, '##rpb', rowPerBeat, 1, 4)
    if changed then vm:setRowPerBeat(util.clamp(n, 1, 32)) end

    ImGui.Separator(ctx)
  end

  local function drawTracker()
    local grid = vm.grid
    local ec = vm:ec()
    local cursorRow, cursorCol, cursorStop = ec:pos()
    local scrollRow, scrollCol, lastVisCol = vm:scroll()

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
        util.add(chanOrder, chan)
      end
      chanW[chan] = (cx + col.width) - chanX[chan]
      cx = cx + col.width + 1
    end

    local totalWidth = math.max(0, cx - 1)
    local draw = printer(ctx, gridX, gridY, gridOriginX, gridOriginY)

    -- Solo (amber) wins over mute (red): audibility semantic.
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

    -- laneByChan: per-channel counter so note columns show their lane number.
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

    -- Header separator sits 1/3 up from the sub-label row.
    draw:hLine(-GUTTER, totalWidth - 1, 0, 'header', -1/3)

    for i = 1, #chanOrder - 1 do
      local chan = chanOrder[i]
      draw:vLine(chanX[chan] + chanW[chan], -HEADER, gridHeight - 1, 'separator')
    end

    for y = 0, gridHeight - 1 do
      local row = scrollRow + y
      if row >= numRows then break end

      local isBarStart, isBeatStart = vm:rowBeatInfo(row)

      if isBarStart or isBeatStart then
        local style = isBarStart and 'rowBarStart' or 'rowBeat'
        for chan = 1, 16 do
          if chanX[chan] then
            draw:box(chanX[chan], chanX[chan] + chanW[chan] - 1, y, y, style)
          end
        end
      end

      local rowNumCol = (isBeatStart and 'textBar') or 'inactive'
      draw:text(-GUTTER, y, string.format('%03d', row), rowNumCol)
    end

    local drawList = ImGui.GetWindowDrawList(ctx)
    local tailBord = colour('tailBord')
    local viewTop  = scrollRow
    local viewBot  = scrollRow + gridHeight
    for _, col in ipairs(grid.cols) do
      if col.x and col.tails then
        local colPx = gridOriginX + col.x * gridX
        for _, tail in ipairs(col.tails) do
          if tail.endRow > viewTop and tail.startRow < viewBot then
            local y1 = gridOriginY + math.max(tail.startRow - scrollRow, 0) * gridY
            local y2 = gridOriginY + math.min(tail.endRow - scrollRow, gridHeight) * gridY
            local x1 = colPx - 4
            ImGui.DrawList_AddRectFilled(drawList, x1-1, y1-1, x1 + 4, y1+1, tailBord)
            ImGui.DrawList_AddRectFilled(drawList, x1-2, y1, x1, y2, tailBord)
            ImGui.DrawList_AddRectFilled(drawList, x1-1, y2-1, x1 + 4, y2+1, tailBord)
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
          local text, textCol, overrides
          if ghost then
            local cellCol
            text, cellCol = renderCell({ val = ghost.val }, col, row)
            textCol = cellCol == 'negative' and 'ghostNegative' or 'ghost'
          else
            text, textCol, overrides = renderCell(evt, col, row)
            if col.overflow and col.overflow[row] then textCol, overrides = 'overflow', nil end
            textCol = textCol or 'text'
            if textCol == 'text' and col.offGrid and col.offGrid[row] then
              textCol = 'offGrid'
            end
          end
          if vm:isChannelEffectivelyMuted(col.midiChan) then textCol, overrides = 'inactive', nil end
          local cx, i = col.x, 0
          for ch in text:gmatch(utf8.charpattern) do
            i = i + 1
            local c = (overrides and overrides[i]) or (ch == '·' and 'inactive' or textCol)
            draw:text(cx, y, ch, c)
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
                local offset = util.clamp(gap / halfGap, -1, 1) * halfW
                ImGui.DrawList_AddLine(drawList, x0, yTop, x1, yTop, barCol, 1)
                local tickX = cx + offset
                ImGui.DrawList_AddLine(drawList, tickX, yTop - 1, tickX, yTop + 2, barCol, 1)
              end
            end
          end
        end
      end
    end

    if ec:hasSelection() then
      local r1, r2, c1i, c2i = ec:region()
      if c2i >= scrollCol and c1i <= lastVisCol then
        local yFrom = math.max(r1 - scrollRow, 0)
        local yTo   = math.min(r2 - scrollRow, gridHeight - 1)
        local c1, c2 = grid.cols[c1i], grid.cols[c2i]
        local s1   = ec:selectionStopSpan(c1i)
        local _,s2 = ec:selectionStopSpan(c2i)
        local x1 = c1.x and c1.x + c1.stopPos[s1]  or 0
        local x2 = c2.x and c2.x + c2.stopPos[s2]  or totalWidth
        draw:box(x1, x2, yFrom, yTo, 'selection')
      end
    end

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
    local ec = vm:ec()
    local cursorRow, cursorCol = ec:row(), ec:col()
    local rowPerBeat    = cm:get('rowPerBeat')
    local currentOctave = cm:get('currentOctave')
    local advanceBy     = cm:get('advanceBy')
    local col      = vm.grid.cols[cursorCol]
    local bar, beat, sub = vm:barBeatSub(cursorRow)
    local colLabel = col and col.label or '?'

    ImGui.Separator(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, colour('header'))
    ImGui.Text(ctx, string.format(
      '%s | %d:%d.%d/%d | Octave: %d | Advance: %d',
      colLabel, bar, beat, sub, rowPerBeat, currentOctave, advanceBy
    ))
    ImGui.PopStyleColor(ctx)
  end

  ----- Input

  cmgr:installDefaultKeymap(ImGui)

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
    local ec = vm:ec()
    local cursorRow, cursorCol, cursorStop = ec:pos()
    local scrollRow, scrollCol, lastVisCol = vm:scroll()

    local clicked      = ImGui.IsMouseClicked(ctx, 0)
    local rightClicked = ImGui.IsMouseClicked(ctx, 1)
    local held         = ImGui.IsMouseDown(ctx, 0)

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
        if charY == -HEADER then ec:selectChannel(last.midiChan)
        else ec:selectColumn(col) end
        return
      end

      local shift = ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift ~= 0

      if shift then
        ec:extendTo(scrollRow + charY, col, stop)
      else
        ec:selClear()
        ec:setPos(scrollRow + charY, col, stop)
        dragging = true
        dragWinX, dragWinY = ImGui.GetWindowPos(ctx)
      end

    elseif dragging and held then
      local mouseX, mouseY = ImGui.GetMousePos(ctx)
      local charY = math.floor((mouseY - gridOriginY) / gridY)
      local row = scrollRow + charY
      local fracX = (mouseX - gridOriginX) / gridX
      local rightEdge = grid.cols[lastVisCol].x + grid.cols[lastVisCol].width

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
        ec:extendTo(row, col, stop)
      end

    elseif dragging and not held then
      dragging = false
    end

    if ImGui.IsWindowHovered(ctx) then
      local wheel,wheelH  = ImGui.GetMouseWheel(ctx)
      if wheel ~= 0 then
        local n = util.round(math.abs(wheel) / 2)
        if n > 0 then
          local cmd = wheel > 0 and cmgr.commands.cursorUp or cmgr.commands.cursorDown
          for _ = 1, n do cmd() end
        end
      end
      if wheelH ~= 0 then
        local n = util.round(math.abs(wheelH))
        if n > 0 then
          local cmd = wheelH > 0 and cmgr.commands.cursorLeft or cmgr.commands.cursorRight
          for _ = 1, n do cmd() end
        end
      end
    end
  end

  local function handleKeys()
    if modalState then return end -- popup owns input

    local grid = vm.grid
    local ec = vm:ec()
    local cursorRow, cursorCol, cursorStop = ec:pos()

    -- Tracker focus: full input (commands + raw char entry).
    -- Aux window focus (e.g. swing editor) with no active item: forward
    -- bound commands only — typing into a slider/InputText must not leak
    -- through as cell edits or navigation.
    local trackerFocused = ImGui.IsWindowFocused(ctx)
    local fwdCommands    = swingEditor and not trackerFocused
                           and ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_AnyWindow)
                           and not ImGui.IsAnyItemActive(ctx)

    local commandHeld = false
    if trackerFocused or fwdCommands then
      for command, keys in pairs(cmgr.keymap) do
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
            if cmgr.commands[command]() == false then
              commandHeld = false  -- command declined; let the char queue see it
            else
              return
            end
          end
        end
      end
    end

    if trackerFocused then
      -- Gate the char queue on commandHeld: IsKeyPressed and the char queue
      -- don't share auto-repeat timing, so a held command key would leak.
      if not commandHeld and ImGui.GetKeyMods(ctx) == ImGui.Mod_None then
        local col = grid.cols[cursorCol]
        if col then
          local rv, char = ImGui.GetInputQueueCharacter(ctx, 0)
          if rv then
            if ec:isSticky() then
              ec:selClear()
            else
              local evt = col.cells and col.cells[cursorRow]
              vm:editEvent(col, evt, cursorStop, char)
            end
          end
        end
      end

      -- Shift-digit: half-step entry at MSB stops (vel, delay, cc/at/pc).
      -- Overwrites the value with digit in MSB, half-value (8 hex / 5 dec) in LSB.
      if not commandHeld and ImGui.GetKeyMods(ctx) == ImGui.Mod_Shift and not ec:isSticky() then
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

      local function close(invoke, ...)
        if invoke then
          local ok, err = pcall(modalState.callback, ...)
          if not ok then
            reaper.ShowConsoleMsg('\nModal callback error: ' .. tostring(err) .. '\n')
          end
        end
        modalState = nil
        ImGui.CloseCurrentPopup(ctx)
      end

      if modalState.kind == 'confirm' then
        if ImGui.IsKeyPressed(ctx, ImGui.Key_Y) or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) then
          close(true, true)
        elseif ImGui.IsKeyPressed(ctx, ImGui.Key_N) or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
          close(true, false)
        end
      else
        if ImGui.IsWindowAppearing(ctx) then
          ImGui.SetKeyboardFocusHere(ctx)
        end
        local rv, buf = ImGui.InputText(ctx, '##modal', modalState.buf,
          ImGui.InputTextFlags_EnterReturnsTrue)
        if rv then
          close(true, buf)
        elseif ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
          close(false)
        else
          modalState.buf = buf
        end
      end
      ImGui.EndPopup(ctx)
    else
      modalState = nil
    end
  end

  ----- Modal-driven commands

  local function openPrompt(title, prompt, callback)
    modalState = { title = title, prompt = prompt, callback = callback, buf = '' }
    ImGui.OpenPopup(ctx, title)
  end

  local function openConfirm(title, callback)
    modalState = {
      title    = title,
      prompt   = 'No selection — ' .. title .. ' whole take? (y/n)',
      kind     = 'confirm',
      callback = callback,
      buf      = '',
    }
    ImGui.OpenPopup(ctx, title)
  end

  -- Selection → vm:<base>Selection();  no selection → confirm → vm:<base>All().
  -- The naming convention is the contract — keeps the registration tight.
  local function scopedAction(title, base)
    return function()
      if vm:ec():hasSelection() then vm[base..'Selection'](vm)
      else openConfirm(title, function(yes) if yes then vm[base..'All'](vm) end end)
      end
    end
  end

  cmgr:registerAll{
    setRPB = function()
      openPrompt('Rows per beat', '1-32', function(buf)
        local n = tonumber(buf); if n then vm:setRowPerBeat(n) end
      end)
    end,

    addTypedCol = function()
      openPrompt('Add Column', 'cc0-127, pb, at, pc, dly', function(typeStr)
        local type, idStr = typeStr:lower():match('^(%a+)(%d*)$')
        if not type then return end
        local id = idStr ~= '' and tonumber(idStr) or nil
        if type == 'dly' then vm:showDelay()
        elseif util.oneOf('cc pb at pc', type) then
          if type == 'cc' and (not id or id < 0 or id > 127) then return end
          vm:addExtraCol(type, id)
        end
      end)
    end,

    reswing              = scopedAction('reswing',                'reswing'),
    quantize             = scopedAction('quantize',               'quantize'),
    quantizeKeepRealised = scopedAction('quantize keep realised', 'quantizeKeepRealised'),

    openSwingEditor = function()
      if swingEditor then return end
      local name = cm:get('swing')
      local lib  = cm:get('swings')
      swingEditor = {
        name      = name,
        snapshot  = name and lib[name] or nil,
        createBuf = '',
        rpb       = 4,
      }
    end,

    quit = function() quitting = true end,
  }

  cmgr:doAfter({ 'reswing', 'quantize', 'quantizeKeepRealised' },
               function() vm:ec():unstick() end)

  ----- Swing editor

  local SWING_ATOMS   = { 'id',
                          'classic', 'drag',
                          'arc', 'pocket', 'lilt', 'shuffle', 'tilt' }
  local SWING_ATOMS_Z = table.concat(SWING_ATOMS, '\0') .. '\0\0'

  -- Plain narration uses the theme's text colour; the editor's outer
  -- Col_Text push is white so controls (combos, sliders, buttons) render
  -- their text white. Wrap a Text call in narrate() to opt back into
  -- theme text for static labels.
  local function narrate(s)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, colour('text'))
    ImGui.Text(ctx, s)
    ImGui.PopStyleColor(ctx)
  end

  local RPB_CHOICES   = { 1, 2, 3, 4, 6, 8, 12, 16 }
  local RPB_CHOICES_Z = (function()
    local s = {}
    for _, v in ipairs(RPB_CHOICES) do s[#s+1] = tostring(v) end
    return table.concat(s, '\0') .. '\0\0'
  end)()

  -- Period presets in qn (the model's native unit), so the whole editor
  -- row is qn-consistent: shift in qn → period in qn → annotation in qn.
  local PERIOD_PRESETS = {
    { label = '1/4 qn', period = {1, 4} },  -- 16th
    { label = '1/3 qn', period = {1, 3} },  -- 8th triplet
    { label = '1/2 qn', period = {1, 2} },  -- 8th
    { label = '1 qn',   period = 1       }, -- quarter
    { label = '2 qn',   period = 2       }, -- half
    { label = '4 qn',   period = 4       }, -- whole
  }

  -- qn-per-beat (denom-derived) and qn-per-bar (num × beat).
  local function meterQN()
    local num, denom = vm:timeSig()
    local beat = 4 / denom
    return beat, num * beat
  end

  local function periodPresetIndex(period)
    local qn = timing.periodQN(period)
    for i, p in ipairs(PERIOD_PRESETS) do
      if math.abs(qn - timing.periodQN(p.period)) < 1e-9 then return i end
    end
    return 0
  end

  local function periodLabel(period)
    local i = periodPresetIndex(period)
    if i > 0 then return PERIOD_PRESETS[i].label end
    local qn = timing.periodQN(period)
    return string.format(qn == math.floor(qn) and '%d qn' or '%.3g qn', qn)
  end

  local SWING_ERR     = 0xff6060ff
  local SWING_MARK    = 0x000000b0
  -- Soft cap on |shift| in QN: musically usable ceiling regardless of
  -- atom or period. Wild mode unlocks the per-atom mathematical max.
  local SWING_SOFT_QN = 0.15

  -- Hard = T_tile · atomMeta.range (the monotonicity edge in QN).
  -- Soft = min(SWING_SOFT_QN, hard); Wild bypasses the soft step.
  local function shiftCap(factor, wild)
    local hard = timing.atomTilePeriod(factor) * timing.atomMeta[factor.atom].range
    return wild and hard or math.min(SWING_SOFT_QN, hard)
  end

  local function materialise(composite)
    local out = {}
    for i, f in ipairs(composite) do
      local T = timing.atomTilePeriod(f)
      out[i] = { S = timing.atoms[f.atom](f.shift / T), T = T }
    end
    return out
  end

  -- Horizontal strip showing one period: cells are unswung subdivisions
  -- (rpb per qn), Xs land at the swung position of each subdivision.
  -- shadeMeter draws beat/bar cell backgrounds (used on the composite
  -- preview, where the period is rounded up to a whole number of bars
  -- so the meter actually means something); per-factor previews leave
  -- it off because their period rarely aligns to bars.
  local function drawSwingGrid(composite, periodQN, rpb, w, h, shadeMeter)
    local x0, y0    = ImGui.GetCursorScreenPos(ctx)
    local dl        = ImGui.GetWindowDrawList(ctx)
    local beat, qpb = meterQN()
    local N         = math.max(2, util.round(periodQN * rpb))
    local cellW     = w / N
    -- text colour with alpha dialled back a touch — pure black is too loud
    -- against the cream bg, near-zero alpha disappears.
    local line      = (colour('text') & 0xffffff00) | 0xb0

    ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, colour('bg'))

    -- Classify a tick at qn position p into 'bar' (downbeat),
    -- 'midBar' (the bar's midpoint when it lands on a beat — true in
    -- 4/4, 6/8; false in 3/4, 2/2), 'beat' (any other beat), or nil
    -- (offbeat). Shading treats midBar as a beat; dot sizing promotes
    -- it to bar tier.
    local function isInt(x)   return math.abs(x - util.round(x)) < 1e-9 end
    local midIsBeat           = shadeMeter and isInt((qpb/2) / beat)
    local function classify(p)
      if not isInt(p / beat) then return nil end
      if isInt(p / qpb) then return 'bar' end
      if midIsBeat and isInt((p - qpb/2) / qpb) then return 'midBar' end
      return 'beat'
    end

    if shadeMeter then
      local SHADE = { bar = 'rowBarStart', midBar = 'rowBeat', beat = 'rowBeat' }
      for i = 0, N - 1 do
        local key = SHADE[classify((i / N) * periodQN)]
        if key then
          local cx = x0 + i * cellW
          ImGui.DrawList_AddRectFilled(dl, cx, y0, cx + cellW, y0 + h, colour(key))
        end
      end
    end

    -- 1px vertical grid lines at every cell boundary.
    for i = 0, N do
      local gx = x0 + (i / N) * w
      ImGui.DrawList_AddLine(dl, gx, y0, gx, y0 + h, line, 1)
    end

    -- Filled dots at the swung image of each unswung tick. Three sizes
    -- so the meter reads at a glance: bar/mid-bar > beat > offbeat.
    -- Atom preview (no shadeMeter) takes the middle size throughout.
    local factors = materialise(composite)
    local rBig    = math.max(2, h * 0.18)
    local rMid    = math.max(2, h * 0.14)
    local rSmall  = math.max(2, h * 0.10)
    local cy      = y0 + h / 2
    for i = 0, N - 1 do
      local p  = (i / N) * periodQN
      local pS = timing.applyFactors(factors, p)
      local sx = x0 + (pS / periodQN) * w
      local tier = shadeMeter and classify(p) or 'beat'
      local r    = (tier == 'bar' or tier == 'midBar') and rBig
                or  tier == 'beat'                     and rMid
                or  rSmall
      ImGui.DrawList_AddCircleFilled(dl, sx, cy, r, SWING_MARK)
    end

    ImGui.Dummy(ctx, w, h)
  end

  -- Each primitive produces a fresh composite and routes through the
  -- single vm write; the snapshot remains untouched so Reset always
  -- has the on-open state.

  local function swingRead()
    return cm:get('swings')[swingEditor.name]
  end

  local function compositesEqual(a, b)
    a, b = a or {}, b or {}
    if #a ~= #b then return false end
    for i, fa in ipairs(a) do
      local fb = b[i]
      if fa.atom ~= fb.atom or fa.shift ~= fb.shift
         or math.abs(timing.periodQN(fa.period) - timing.periodQN(fb.period)) > 1e-12 then
        return false
      end
    end
    return true
  end

  local function swingWrite(composite)
    local old = util.deepClone(swingRead()) or {}
    if compositesEqual(old, composite) then return end
    vm:setSwingComposite(swingEditor.name, composite)
    vm:reswingPreset(swingEditor.name, old, composite)
  end

  local function patchFactor(i, patch)
    local new = util.deepClone(swingRead()) or {}
    if not new[i] then return end
    util.assign(new[i], patch)
    swingWrite(new)
  end

  local function addFactor()
    local new = util.deepClone(swingRead()) or {}
    new[#new+1] = { atom = 'id', shift = 0, period = 1 }
    swingWrite(new)
  end

  local function removeFactor(i)
    local new = util.deepClone(swingRead()) or {}
    table.remove(new, i)
    swingWrite(new)
  end

  local function moveFactor(i, dir)
    local src = swingRead() or {}
    local j = i + dir
    if j < 1 or j > #src then return end
    local new = util.deepClone(src)
    new[i], new[j] = new[j], new[i]
    swingWrite(new)
  end

  local function drawFactorRow(i, f, availW)
    ImGui.PushID(ctx, i)

    ImGui.AlignTextToFramePadding(ctx)
    narrate(string.format('%d.', i))
    ImGui.SameLine(ctx)

    local atomIdx = 0
    for k, a in ipairs(SWING_ATOMS) do if a == f.atom then atomIdx = k - 1; break end end
    ImGui.SetNextItemWidth(ctx, 90)
    local rv, newIdx = ImGui.Combo(ctx, '##atom', atomIdx, SWING_ATOMS_Z)
    if rv then
      -- Drop-in atom swap: shift is in QN and atom-independent, so we
      -- preserve it across the swap and only clamp to the new atom's cap.
      local newAtom = SWING_ATOMS[newIdx + 1]
      local cap     = shiftCap({ atom = newAtom, period = f.period }, swingEditor.wild)
      local shift   = f.shift or 0
      if math.abs(shift) > cap then shift = (shift < 0 and -1 or 1) * cap * 0.999 end
      patchFactor(i, { atom = newAtom, shift = shift })
    end

    ImGui.SameLine(ctx)
    local cap    = shiftCap(f, swingEditor.wild)
    local frozen = cap == 0
    if frozen then ImGui.BeginDisabled(ctx) end
    ImGui.SetNextItemWidth(ctx, 150)
    local lo, hi = -cap * 0.999, cap * 0.999
    local rvA, newShift = ImGui.SliderDouble(ctx, '##shift', f.shift or 0, lo, hi, '%.3f qn')
    -- Continuous reswing: swingWrite reads the stored composite as the
    -- "old" side of the delta, so per-frame calls chain into the right
    -- old→now transformation as the slider drags.
    if rvA then
      local new = util.deepClone(swingRead()) or {}
      if new[i] then new[i].shift = newShift; swingWrite(new) end
    end
    if frozen then ImGui.EndDisabled(ctx) end

    ImGui.SameLine(ctx)
    ImGui.AlignTextToFramePadding(ctx)
    narrate('per')
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 90)
    local pIdx = periodPresetIndex(f.period)
    local items = {}
    for _, p in ipairs(PERIOD_PRESETS) do items[#items+1] = p.label end
    if pIdx == 0 then items[#items+1] = periodLabel(f.period) end
    local itemsZ = table.concat(items, '\0') .. '\0\0'
    local curIdx = pIdx > 0 and (pIdx - 1) or #PERIOD_PRESETS
    local rvP, newPIdx = ImGui.Combo(ctx, '##per', curIdx, itemsZ)
    if rvP and newPIdx + 1 <= #PERIOD_PRESETS then
      patchFactor(i, { period = PERIOD_PRESETS[newPIdx + 1].period })
    end

    -- pulsesPerCycle > 1 doubles the actual repeat. The combo speaks the
    -- user period; this trailing chip surfaces the resulting tile length.
    local mult = timing.atomMeta[f.atom].pulsesPerCycle
    if mult > 1 then
      ImGui.SameLine(ctx)
      ImGui.AlignTextToFramePadding(ctx)
      narrate(string.format('×%d → %.3g qn', mult, timing.atomTilePeriod(f)))
    end

    ImGui.SameLine(ctx)
    if ImGui.ArrowButton(ctx, '##up', ImGui.Dir_Up)   then moveFactor(i, -1) end
    ImGui.SameLine(ctx)
    if ImGui.ArrowButton(ctx, '##dn', ImGui.Dir_Down) then moveFactor(i,  1) end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'x')                         then removeFactor(i)  end

    local _, qpb  = meterQN()
    local nBars   = math.max(1, math.ceil(timing.atomTilePeriod(f) / qpb - 1e-9))
    drawSwingGrid({ f }, nBars * qpb, swingEditor.rpb, availW, 28, true)

    ImGui.PopID(ctx)
  end

  -- Generous estimate — better to show a few px of empty space than to
  -- clip the add-factor button at the bottom.
  local function idealSwingHeight(nFactors)
    return 130         -- chrome: padding + title row + 2 separators + composite preview + add button
         + nFactors * 72  -- controls row + factor preview + separator + spacing
  end

  -- The ×N chip on the controls row (when any factor has pulsesPerCycle > 1)
  -- pushes the move/delete buttons off the right edge at the default width.
  local function idealSwingWidth(composite)
    for _, f in ipairs(composite) do
      if timing.atomMeta[f.atom].pulsesPerCycle > 1 then return 660 end
    end
    return 560
  end

  local function drawSwingEditor()
    if not swingEditor then return end

    local composite = (swingEditor.name and swingRead()) or {}
    local n = #composite

    -- First-time default; then max height = viewport so auto-grow
    -- stays on-screen. Width is user-resizable thereafter.
    local _, vpH = ImGui.Viewport_GetSize(ImGui.GetMainViewport(ctx))
    ImGui.SetNextWindowSizeConstraints(ctx, 400, 120, 9999, vpH)
    ImGui.SetNextWindowSize(ctx, 560, 420, ImGui.Cond_FirstUseEver)

    local idealW = idealSwingWidth(composite)
    if swingEditor.lastCount ~= n or (swingEditor.lastW or 560) < idealW then
      local w = math.max(swingEditor.lastW or 560, idealW)
      local h = math.min(idealSwingHeight(n), vpH)
      ImGui.SetNextWindowSize(ctx, w, h, ImGui.Cond_Always)
      swingEditor.lastCount = n
    end

    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xffffffff)
    local visible, open = ImGui.Begin(ctx, 'Swing', true,
      ImGui.WindowFlags_NoCollapse | ImGui.WindowFlags_NoDocking)
    if not open then swingEditor = nil end

    if visible then
      swingEditor.lastW = ImGui.GetWindowWidth(ctx)

      if ImGui.IsWindowFocused(ctx) and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
        swingEditor = nil
      end

      if swingEditor and not swingEditor.name then
        -- CREATE MODE
        narrate('No swing slot is set.')
        narrate('Name:')
        ImGui.SameLine(ctx)
        ImGui.SetNextItemWidth(ctx, 240)
        local rv, buf = ImGui.InputText(ctx, '##newname', swingEditor.createBuf,
          ImGui.InputTextFlags_EnterReturnsTrue)
        swingEditor.createBuf = buf
        ImGui.SameLine(ctx)
        local confirm = rv or ImGui.Button(ctx, 'Create new swing')
        if confirm then
          local name = buf and buf:match('^%s*(.-)%s*$')
          local lib  = cm:get('swings')
          if not name or name == '' then
            swingEditor.createError = 'Name required.'
          elseif lib[name] then
            swingEditor.createError = 'Name already in use.'
          else
            vm:setSwingComposite(name, {})
            vm:setSwingSlot(name)
            swingEditor.name        = name
            swingEditor.snapshot    = {}
            swingEditor.createBuf   = ''
            swingEditor.createError = nil
          end
        end
        if swingEditor and swingEditor.createError then
          ImGui.TextColored(ctx, SWING_ERR, swingEditor.createError)
        end
      elseif swingEditor then
        -- EDIT MODE
        narrate('Editing: ' .. swingEditor.name)
        ImGui.SameLine(ctx)
        local dirty = not compositesEqual(composite, swingEditor.snapshot)
        if not dirty then ImGui.BeginDisabled(ctx) end
        if ImGui.Button(ctx, 'Reset') then swingWrite(util.deepClone(swingEditor.snapshot) or {}) end
        if not dirty then ImGui.EndDisabled(ctx) end

        ImGui.SameLine(ctx)
        ImGui.AlignTextToFramePadding(ctx)
        narrate('Rows/qn:')
        ImGui.SameLine(ctx)
        ImGui.SetNextItemWidth(ctx, 60)
        local rpbIdx = 0
        for k, v in ipairs(RPB_CHOICES) do if v == swingEditor.rpb then rpbIdx = k - 1; break end end
        local rvR, newRpbIdx = ImGui.Combo(ctx, '##rpb', rpbIdx, RPB_CHOICES_Z)
        if rvR then swingEditor.rpb = RPB_CHOICES[newRpbIdx + 1] end

        ImGui.SameLine(ctx)
        local rvW, newWild = ImGui.Checkbox(ctx, 'Wild', swingEditor.wild or false)
        if rvW then swingEditor.wild = newWild end

        ImGui.Separator(ctx)
        local availW       = ImGui.GetContentRegionAvail(ctx)
        local _, qpb       = meterQN()
        local lcmQN        = timing.compositePeriodQN(composite)
        local nBars        = math.max(1, math.ceil(lcmQN / qpb - 1e-9))
        drawSwingGrid(composite, nBars * qpb,
                      swingEditor.rpb, availW, 32, true)
        ImGui.Separator(ctx)

        for i, f in ipairs(composite) do
          drawFactorRow(i, f, availW)
          ImGui.Separator(ctx)
        end

        if ImGui.Button(ctx, '+ add factor') then addFactor() end
      end
    end
    ImGui.End(ctx)
    ImGui.PopStyleColor(ctx)
  end

  ---------- PUBLIC

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

    if visible then
      if #vm.grid.cols > 0 then
        drawToolbar()
        drawTracker()
        drawStatusBar()
        handleMouse()
        handleKeys()
        drawModal()
      else
        ImGui.Text(ctx, 'Select a MIDI item to begin.')
      end

      ImGui.End(ctx)
    end

    drawSwingEditor()

    ImGui.PopStyleColor(ctx, styleCount)
    ImGui.PopFont(ctx)

    vm:tick()

    return open and not quitting
  end

  return rm
end
