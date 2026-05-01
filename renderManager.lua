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
  local CHROME_PAD_X, CHROME_PAD_Y = 8, 4   -- inner padding for chrome bands and grid

  local gridX       = nil
  local gridY       = nil
  local gridOriginX = 0
  local gridOriginY = 0
  local gridWidth   = 0
  local gridHeight  = 0

  -- Per-frame layout, populated by computeLayout() before any draw routine
  -- that needs it. drawLaneStrip and drawTracker both consume these.
  local chanX, chanW, chanOrder, totalWidth = {}, {}, {}, 0

  -- Pack columns left-to-right starting at scrollCol, fitting as many as
  -- gridWidth allows; sets col.x on visible cols, clears on the rest.
  local function layoutColumns(cols, scrollCol)
    for _, col in ipairs(cols) do col.x = nil end
    local cX, cW, cOrder = {}, {}, {}
    local cx = 0
    for i = scrollCol, #cols do
      local col = cols[i]
      if cx + col.width > gridWidth then break end
      col.x = cx
      local chan = col.midiChan
      if cX[chan] == nil then
        cX[chan] = cx
        util.add(cOrder, chan)
      end
      cW[chan] = (cx + col.width) - cX[chan]
      cx = cx + col.width + 1
    end
    return cX, cW, cOrder, math.max(0, cx - 1)
  end

  local ctx         = nil
  local font        = nil   -- monospace, used inside the tracker grid
  local uiFont      = nil   -- system sans-serif, used for chrome (toolbar, status, modals, swing editor)
  local dragging    = false
  local dragWinX, dragWinY = 0, 0
  local modalState = nil   -- nil = closed, else { title, prompt, callback, buf, kind? }
  local swingEditor = nil  -- nil = closed, else { name, snapshot, createBuf, createError }
  local quitting   = false -- set by the quit command, observed by rm:loop
  local pickerOpenRequest = nil -- 'temper' | 'swing' | nil; consumed next frame by drawSlotPicker
  local pickerFilter = {}       -- kind -> typeahead buffer; reset on each open
  local pickerCursor = {}       -- kind -> 1-based highlight index into filtered matches
  local pickerActive  = false   -- a picker popup owned input this frame; handleKeys must skip

  -- Lane-strip mouse interaction. drawLaneStrip publishes laneLayout each
  -- frame (or nils it if the strip isn't showing an envelope); handleMouse
  -- reads it for hover/drag dispatch.
  local laneLayout  = nil  -- { x0, yTop, yBot, w, valSpan, valMin, valMax,
                           --   scrollRow, rowSpan, col, colIdx, chan }
  local laneHover   = nil  -- event index in laneLayout.col.events, or nil
  local laneDrag    = nil  -- { colIdx, idx, shifted }

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

  -- Walk the colour table from a starting cm key to a terminal atom.
  -- Entries: {r,g,b,a} atom | 'fullKey' alias | {'fullKey', a} alias-with-
  -- alpha-override. Outermost override wins (`override or v[2]` is safe
  -- because Lua treats 0 as truthy). Cycles raise with the chain.
  local function resolveColour(key)
    local seen, override = {}, nil
    while true do
      if seen[key] then
        seen[#seen+1] = key
        error('colour cycle: ' .. table.concat(seen, ' → '))
      end
      seen[#seen+1] = key; seen[key] = true
      local v = cm:get(key)
      if v == nil then error('unknown colour: ' .. key) end
      if type(v) == 'string' then
        key = v
      elseif type(v[1]) == 'string' then
        key      = v[1]
        override = override or v[2]
      else
        return v[1], v[2], v[3], override or v[4]
      end
    end
  end

  -- Roles live under `colour.*`; callers pass the bare role name and we
  -- prepend the namespace once at the entry point. The cache is keyed by
  -- the bare name and invalidated by configChanged below.
  local function colour(name)
    name = name or 'text'
    if not colourCache[name] then
      local r, g, b, a = resolveColour('colour.' .. name)
      colourCache[name] = ImGui.ColorConvertDouble4ToU32(r, g, b, a)
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

    function pt:text(x, y, txt, c, font)
      if font then
        ImGui.PushFont(ctx, font, 15)
      end
      drawTextAt(x0 + x * gX, y0 + y * gY - 1, txt, c)
      if font then
        ImGui.PopFont(ctx)
      end
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

  -- Effective lane-strip row count: 0 when hidden, else the configured size.
  -- Single point of truth for both layout and rendering.
  local function laneStripRows()
    if not cm:get('laneStrip.visible') then return 0 end
    return cm:get('laneStrip.rows') or 0
  end

  -- reaper-imgui has no Separator(Vertical); draw a 1px vertical line
  -- via the window draw list and reserve a Dummy slot so SameLine works.
  local function verticalSeparator()
    local x, y = ImGui.GetCursorScreenPos(ctx)
    local h    = ImGui.GetFrameHeight(ctx)
    ImGui.DrawList_AddLine(ImGui.GetWindowDrawList(ctx),
      x, y, x, y + h, colour('separator'), 1)
    ImGui.Dummy(ctx, 1, h)
  end

  -- One picker = a "<heading>:" label followed by a button "<preview> ▾"
  -- that opens a popup containing Off, current library entries, and any
  -- unseeded presets (prefixed '+ '). `onPick(name)` receives nil for Off,
  -- a lib name for a normal entry, or a preset name for an unseeded preset —
  -- the callback is responsible for seeding the lib in that case.
  --
  -- The popup carries a typeahead filter (autofocused on open). Enter
  -- picks the first surviving match; group separators show only when
  -- the filter is empty (groups become incoherent under filtering).
  local function drawSlotPicker(d)
    local popupId = '##picker_' .. d.kind

    -- Heading inherits the toolbar's outer Col_Text push (chrome.shade);
    -- no inner push needed.
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, d.heading .. ':  ')
    ImGui.SameLine(ctx)

    -- ##d.kind disambiguates the ImGui ID — different pickers may all show
    -- "Off ▾" once the heading is no longer part of the button label.
    local btnTxt  = (d.current or 'Off') .. ' \xe2\x96\xbe##' .. d.kind
    local opening = ImGui.Button(ctx, btnTxt)
    -- Anchor popup to the button rect; otherwise OpenPopup uses the mouse
    -- position at call time, which puts a keyboard-triggered popup at the
    -- text cursor instead of under the toolbar.
    local btnX = ImGui.GetItemRectMin(ctx)
    local _, btnY = ImGui.GetItemRectMax(ctx)
    if pickerOpenRequest == d.kind then
      pickerOpenRequest = nil
      opening = true
    end
    if opening then
      pickerFilter[d.kind] = ''
      ImGui.OpenPopup(ctx, popupId)
    end

    ImGui.SetNextWindowPos(ctx, btnX, btnY, ImGui.Cond_Appearing)
    -- NoNav: kill ImGui's built-in keyboard nav highlight on the popup —
    -- otherwise it draws a second cursor that fights ours and steals
    -- arrow keys / character input from the filter InputText.
    if not ImGui.BeginPopup(ctx, popupId, ImGui.WindowFlags_NoNav) then return end
    pickerActive = true  -- block handleKeys this frame so Enter doesn't leak through

    -- Build candidate items with a group tag for separator placement.
    local items = { { group = 1, label = 'Off', name = nil, current = d.current == nil } }
    local libNames = {}
    for k in pairs(d.lib) do libNames[#libNames + 1] = k end
    table.sort(libNames)
    for _, name in ipairs(libNames) do
      items[#items + 1] = { group = 2, label = name, name = name, current = d.current == name }
    end
    local presetNames = {}
    for k in pairs(d.presets) do
      if not (d.excludePresets and d.excludePresets[k]) and not d.lib[k] then
        presetNames[#presetNames + 1] = k
      end
    end
    table.sort(presetNames)
    for _, name in ipairs(presetNames) do
      items[#items + 1] = { group = 3, label = '+ ' .. name, name = name, current = false }
    end

    if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
    ImGui.SetNextItemWidth(ctx, 180)
    local prevFilter = pickerFilter[d.kind] or ''
    -- Plain InputText (no EnterReturnsTrue): with that flag, ReaImGui only
    -- commits the buffer back on Enter, so the live filter would never
    -- update during typing. We watch Enter ourselves below.
    local _, filter = ImGui.InputText(ctx, '##filter_' .. d.kind, prevFilter)
    pickerFilter[d.kind] = filter
    local entered = ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
                 or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)
    ImGui.Separator(ctx)

    local lf = filter:lower()
    local matches, currentMatch = {}, nil
    for _, it in ipairs(items) do
      if filter == '' or it.label:lower():find(lf, 1, true) then
        matches[#matches + 1] = it
        if it.current then currentMatch = #matches end
      end
    end

    -- Initial highlight: on open or on filter change, jump to the current
    -- pick if it survived; otherwise top of list. Arrow keys then walk
    -- the filtered list with wrap; Enter picks the highlighted match.
    if ImGui.IsWindowAppearing(ctx) or filter ~= prevFilter then
      pickerCursor[d.kind] = currentMatch or 1
    end
    local cursor = pickerCursor[d.kind] or 1
    local n = #matches
    if n > 0 then
      if ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow) then
        cursor = cursor % n + 1
      elseif ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow) then
        cursor = (cursor - 2) % n + 1
      end
    end
    cursor = math.min(math.max(cursor, 1), math.max(n, 1))
    pickerCursor[d.kind] = cursor

    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
      ImGui.CloseCurrentPopup(ctx)
    elseif entered then
      if matches[cursor] then d.onPick(matches[cursor].name) end
      ImGui.CloseCurrentPopup(ctx)
    else
      local lastGroup
      for i, it in ipairs(matches) do
        if filter == '' and lastGroup and lastGroup ~= it.group then
          ImGui.Separator(ctx)
        end
        if ImGui.Selectable(ctx, it.label, i == cursor) then d.onPick(it.name) end
        lastGroup = it.group
      end
    end

    ImGui.EndPopup(ctx)
  end

  -- Seed-and-select wrappers: the picker hands us a name and we ensure
  -- the lib has it before committing to the slot.
  local function pickTemper(name)
    if name and not cm:get('tempers')[name] then
      vm:setTemper(name, tuning.presets[name])
    end
    vm:setTemperSlot(name)
  end

  local function pickSwing(name)
    if name and not cm:get('swings')[name] then
      vm:setSwingComposite(name, timing.presets[name])
    end
    vm:setSwingSlot(name)
  end

  local function pickColSwing(chan, name)
    if name and not cm:get('swings')[name] then
      vm:setSwingComposite(name, timing.presets[name])
    end
    vm:setColSwingSlot(chan, name)
  end

  -- Identity composite ('id') is the no-swing default — represented in
  -- the UI as "Off" rather than as a pickable preset row.
  local SWING_PRESET_EXCLUDE = { id = true }

  -- Chrome styling shared by the toolbar and the swing editor: hairline
  -- frame border + the toolbar palette for buttons, frames, popups, and
  -- text. Caller pairs with popChromeStyles().
  local function pushChromeStyles()
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 1)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text,           colour('toolbar.text'))
    ImGui.PushStyleColor(ctx, ImGui.Col_Button,         colour('toolbar.button'))
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered,  colour('toolbar.buttonHover'))
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,   colour('toolbar.buttonActive'))
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg,        colour('toolbar.button'))
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, colour('toolbar.buttonHover'))
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive,  colour('toolbar.buttonActive'))
    ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark,      colour('toolbar.checkMark'))
    ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg,        colour('toolbar.popupBg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_Border,         colour('toolbar.buttonBorder'))
  end

  local function popChromeStyles()
    ImGui.PopStyleColor(ctx, 10)
    ImGui.PopStyleVar(ctx, 1)
  end

  local function drawToolbar()
    pickerActive = false
    local rowPerBeat = cm:get('rowPerBeat')

    pushChromeStyles()
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 10, 3)

    -- The outer push is `toolbar.text`; the label inherits it.
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Rows/beat:')
    ImGui.SameLine(ctx, 0, 12)

    local textW = ImGui.CalcTextSize(ctx, '32')
    local btnW  = ImGui.GetFrameHeight(ctx)
    ImGui.SetNextItemWidth(ctx, textW + btnW * 2 + 16)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, rowPerBeat > 9 and 5 or 8, 3)
    local changed, n = ImGui.InputInt(ctx, '##rpb', rowPerBeat, 1, 4)
    ImGui.PopStyleVar(ctx, 1)
    if changed then vm:setRowPerBeat(util.clamp(n, 1, 32)) end

    ImGui.SameLine(ctx, 0, 12)
    verticalSeparator()
    ImGui.SameLine(ctx, 0, 12)

    -- Col_Text is already 'text' from the toolbar's outer push, so the
    -- checkbox label inherits it.
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 0, 0)
    local cy = ImGui.GetCursorPosY(ctx)
    ImGui.SetCursorPosY(ctx, cy + 3)
    local cv, newVis = ImGui.Checkbox(ctx, '  Graph', cm:get('laneStrip.visible'))
    ImGui.PopStyleVar(ctx, 1)
    if cv then cm:set('global', 'laneStrip.visible', newVis) end

    ImGui.SameLine(ctx, 0, 12)
    verticalSeparator()
    ImGui.SameLine(ctx, 0, 12)

    drawSlotPicker {
      kind     = 'temper',  heading = 'Tuning',
      current  = cm:get('temper'),
      lib      = cm:get('tempers'),
      presets  = tuning.presets,
      onPick   = pickTemper,
    }

    ImGui.SameLine(ctx, 0, 12)
    verticalSeparator()
    ImGui.SameLine(ctx, 0, 12)

    drawSlotPicker {
      kind     = 'swing',   heading = 'Swing',
      current  = cm:get('swing'),
      lib      = cm:get('swings'),
      presets  = timing.presets,
      excludePresets = SWING_PRESET_EXCLUDE,
      onPick   = pickSwing,
    }

    -- Channel for the per-column swing picker is the cursor's column
    -- channel. Every column has a channel today, so this is always
    -- live; if global-channel columns land later, the disable path
    -- here triggers.
    local cursorCol = vm.grid.cols[vm:ec():col()]
    local chan      = cursorCol and cursorCol.midiChan
    ImGui.SameLine(ctx, 0, 8)
    if not chan then ImGui.BeginDisabled(ctx) end
    drawSlotPicker {
      kind     = 'colSwing',
      heading  = 'Ch swing',
      current  = chan and cm:get('colSwing')[chan] or nil,
      lib      = cm:get('swings'),
      presets  = timing.presets,
      excludePresets = SWING_PRESET_EXCLUDE,
      onPick   = function(name) pickColSwing(chan, name) end,
    }
    if not chan then ImGui.EndDisabled(ctx) end

    ImGui.PopStyleVar(ctx, 1)
    popChromeStyles()
  end

  -- Establish per-frame layout: char metrics, column packing, and the
  -- integer-row grid height that fits within `budgetH` pixels (the space
  -- the loop has reserved between toolbar and statusBar). Width comes
  -- from the current GetContentRegionAvail; height is explicit so the
  -- caller can carve out a fixed footer first.
  local function computeLayout(budgetW, budgetH)
    local grid = vm.grid
    local _, scrollCol = vm:scroll()

    if not gridX then
      local charW, charH = ImGui.CalcTextSize(ctx, 'W')
      gridX = 2 * math.ceil(charW / 2) - 1
      gridY = 2 * math.ceil(charH / 2) - 1
    end

    gridWidth  = math.max(1, math.floor(budgetW / gridX) - GUTTER)
    -- Lane strip eats a fixed number of rows above the tracker header.
    local laneRows = laneStripRows()
    gridHeight = math.max(1, math.floor(budgetH / gridY) - HEADER - 1 - laneRows)
    vm:setGridSize(gridWidth, gridHeight)

    chanX, chanW, chanOrder, totalWidth = layoutColumns(grid.cols, scrollCol)
  end

  ----- Lane strip

  -- Single horizontal envelope above the grid, mirroring the tracker's
  -- horizontal extent. Renders the column the cursor is currently on if
  -- it's a cc/pb/at; blank background otherwise. Time on x, value on y;
  -- shape (step/linear/curve) honoured between consecutive events.
  local laneRenderable = { cc = true, pb = true, at = true }

  -- Min/max are in *configured* rows. The strip pads a half-row top and
  -- bottom, so visible inner-band height = (rows - 1) gridY. A min of 3
  -- gives the requested 2-row visible floor.
  local LANE_ROW_MIN = 3
  local LANE_ROW_MAX = 32

  local function drawLaneStrip()
    local laneRows = laneStripRows()
    if laneRows <= 0 then return end

    local px, py    = ImGui.GetCursorScreenPos(ctx)
    local x0        = px + GUTTER * gridX
    local y0        = py
    local w         = totalWidth * gridX
    local h         = laneRows  * gridY
    local drawList  = ImGui.GetWindowDrawList(ctx)
    local scrollRow = select(1, vm:scroll())
    local numRows   = vm.grid.numRows or 0
    -- The strip's horizontal extent maps to the rows actually rendered:
    -- min of viewport height and remaining data. This makes rowToX agree
    -- with the lastRow bound used by the bar/beat shading below.
    local rowSpan = math.max(1, math.min(gridHeight, numRows - scrollRow))
    local function rowToX(row) return x0 + (row - scrollRow) / rowSpan * w end

    -- Half-row padding top and bottom: bar/beat shading, dividers, and the
    -- envelope value-axis are all confined to this inner band so anchor
    -- dots at the value extremes have breathing room.
    local pad     = gridY / 2
    local yTop    = y0 + pad
    local yBot    = y0 + h - pad
    local valSpan = math.max(1, h - 2 * pad)

    -- Bar/beat cell shading + 1px row dividers, aligned with the tracker
    -- rows below. The strip inherits the window's ambient bg.
    if w > 0 then
      local barCol, beatCol, dividerCol =
        colour('rowBarStart'), colour('rowBeat'), colour('laneRowDivider')
      for row = scrollRow, scrollRow + rowSpan - 1 do
        local x = math.floor(rowToX(row)) + 0.5
        local isBar, isBeat = vm:rowBeatInfo(row)
        if isBar or isBeat then
          local x2 = math.floor(rowToX(row + 1)) + 0.5
          ImGui.DrawList_AddRectFilled(drawList, x, yTop, x2, yBot, isBar and barCol or beatCol)
        end
        ImGui.DrawList_AddLine(drawList, x, yTop, x, yBot, dividerCol, 1)
      end
    end

    laneLayout = nil
    laneHover  = nil
    local colIdx = vm:ec():col()
    local col    = vm.grid.cols[colIdx]
    if w > 0 and col and laneRenderable[col.type] and #col.events > 0 then
      local chan   = col.midiChan
      local events = col.events
      local n      = #events

      local valMin, valMax
      if col.type == 'pb' then
        local cents = (cm:get('pbRange') or 2) * 100
        valMin, valMax = -cents, cents
      else
        valMin, valMax = 0, 127
      end

      local function ppqToX(ppq) return rowToX(vm:ppqToRow(ppq, chan)) end
      local function valToY(v)
        local t = util.clamp((v - valMin) / (valMax - valMin), 0, 1)
        return yBot - t * valSpan
      end

      local axisCol         = colour('laneAxis')
      local envCol          = colour('laneEnvelope')
      local anchorCol       = colour('laneAnchor')
      local anchorActiveCol = colour('laneAnchorActive')

      local axisY = valToY(0)
      ImGui.DrawList_AddLine(drawList, x0, axisY, x0 + w, axisY, axisCol, 1)

      -- Pad on the clip rect lets anchor dots near the value extremes
      -- overlap the strip edges instead of being half-clipped.
      ImGui.DrawList_PushClipRect(drawList, x0 - 4, y0 - 4, x0 + w + 4, y0 + h + 4, true)

      -- One sample per pixel column. We work in row-space (vm:ppqToRow is
      -- exact), and compute a fractional ppq by lerping inside the segment
      -- only at sample time — vm:rowToPPQ rounds to integer ppq, which
      -- would plateau the curve when many pixels share an integer ppq.
      local rowOf = {}
      for i = 1, n do rowOf[i] = vm:ppqToRow(events[i].ppq, chan) end

      local segIdx = 1
      local function evalAtRow(row)
        while segIdx < n and rowOf[segIdx + 1] <= row do
          segIdx = segIdx + 1
        end
        local A, B = events[segIdx], events[segIdx + 1]
        if not B or row < rowOf[segIdx] then return A.val end
        local rA, rB = rowOf[segIdx], rowOf[segIdx + 1]
        local t      = rB > rA and (row - rA) / (rB - rA) or 0
        local fracP  = A.ppq + t * (B.ppq - A.ppq)
        return vm:sampleCurve(A, B, fracP) or A.val
      end

      local pts     = {}
      local pxLeft  = math.floor(x0)
      local pxRight = math.ceil(x0 + w)
      for px = pxLeft, pxRight do
        local row = scrollRow + (px - x0) / w * rowSpan
        pts[#pts + 1] = px
        pts[#pts + 1] = valToY(evalAtRow(row))
      end

      ImGui.DrawList_AddPolyline(drawList, reaper.new_array(pts), envCol, 0, 1.5)

      -- Anchor positions, then hover hit-test, then draw with the active
      -- index promoted to bigger+red. Drag wins over hover for active-ness.
      local ax, ay = {}, {}
      for i = 1, n do
        ax[i], ay[i] = ppqToX(events[i].ppq), valToY(events[i].val)
      end

      if not laneDrag then
        local mx, my = ImGui.GetMousePos(ctx)
        local best2  = 36   -- 6px squared
        for i = 1, n do
          local dx, dy = mx - ax[i], my - ay[i]
          local d2 = dx*dx + dy*dy
          if d2 < best2 then best2, laneHover = d2, i end
        end
      end

      local activeIdx = (laneDrag and laneDrag.colIdx == colIdx and laneDrag.idx) or laneHover
      for i = 1, n do
        if i == activeIdx then
          ImGui.DrawList_AddCircleFilled(drawList, ax[i], ay[i], 4.5, anchorActiveCol)
        else
          ImGui.DrawList_AddCircleFilled(drawList, ax[i], ay[i], 2.5, anchorCol)
        end
      end

      ImGui.DrawList_PopClipRect(drawList)

      laneLayout = {
        x0      = x0,      yTop    = yTop,    yBot    = yBot,    w = w,
        valSpan = valSpan, valMin  = valMin,  valMax  = valMax,
        scrollRow = scrollRow, rowSpan = rowSpan,
        col     = col,     colIdx  = colIdx,  chan    = chan,
      }
    end

    if w > 0 then
      ImGui.DrawList_AddRect(drawList, x0, yTop, x0 + w, yBot, colour('rowBeat'), 0, 0, 1)
    end

    ImGui.Dummy(ctx, (totalWidth + GUTTER) * gridX, h)

    -- Height nudges in the gutter, top-aligned with the strip's visible
    -- box (yTop). Side-by-side; SetCursorScreenPos jumps in, SameLine
    -- chains the second button, then we restore cursor so subsequent
    -- widgets resume below the strip.
    local cx, cy = ImGui.GetCursorScreenPos(ctx)
    local rows = cm:get('laneStrip.rows') or 0
    ImGui.SetCursorScreenPos(ctx, px - 2, yTop)
    if ImGui.SmallButton(ctx, '-##laneRows') then
      cm:set('global', 'laneStrip.rows', math.max(LANE_ROW_MIN, rows - 1))
    end
    ImGui.SameLine(ctx, 0, 2)
    if ImGui.SmallButton(ctx, '+##laneRows') then
      cm:set('global', 'laneStrip.rows', math.min(LANE_ROW_MAX, rows + 1))
    end
    ImGui.SetCursorScreenPos(ctx, cx, cy)
  end

  local function drawTracker()
    local grid = vm.grid
    local ec = vm:ec()
    local cursorRow, cursorCol, cursorStop = ec:pos()
    local scrollRow, scrollCol, lastVisCol = vm:scroll()

    local px, py = ImGui.GetCursorScreenPos(ctx)
    gridOriginX  = px + GUTTER * gridX
    gridOriginY  = py + HEADER * gridY

    local numRows = grid.numRows or 0
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

    draw:hLine(-GUTTER, totalWidth - 1, 0, 'text', -0.25)

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

      local rowNumCol = (isBeatStart and 'text') or 'inactive'
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
    -- Drawn only under an active temperament, only for notes with a non-zero gap.
    if vm:activeTemper() then
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

    -- statusBar is rendered inside its own chrome BeginChild whose outer
    -- Col_Text push is `statusBar.text`; we just print, no inner push.
    ImGui.Text(ctx, string.format(
      '%s | %d:%d.%d/%d | Octave: %d | Advance: %d',
      colLabel, bar, beat, sub, rowPerBeat, currentOctave, advanceBy
    ))
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

  -- Lane-strip click/drag dispatch. Returns true when the strip claims
  -- the gesture; handleMouse skips its tracker-grid path in that case.
  --
  -- Snap rule (unmodified drag) is direction-aware: round(mouseRow) is
  -- only accepted as the target if it lies on the same side of currRow
  -- as mouseRow does. This keeps off-grid events from jittering to the
  -- nearest integer row on every twitch, and gracefully degrades to
  -- "no move" when an off-grid event is sandwiched between off-grid
  -- neighbours with no integer row between them. Identity-by-index is
  -- enforced by vm:moveLaneEvent's ppq clamp.
  local function handleLaneStrip()
    local clicked = ImGui.IsMouseClicked(ctx, 0)
    local held    = ImGui.IsMouseDown(ctx, 0)

    if laneDrag and not held then
      laneDrag, dragging = nil, false
      return false
    end

    if not laneDrag and clicked and laneHover and laneLayout
       and ImGui.IsWindowHovered(ctx) then
      local mx = ImGui.GetMousePos(ctx)
      laneDrag = {
        colIdx        = laneLayout.colIdx,
        idx           = laneHover,
        startMouseRow = laneLayout.scrollRow + (mx - laneLayout.x0)
                                              / laneLayout.w * laneLayout.rowSpan,
      }
      -- Pin window position for the duration of the drag (same shimmy
      -- as the tracker-grid drag — without it ImGui repositions the
      -- window when the mouse clips offscreen).
      dragging = true
      dragWinX, dragWinY = ImGui.GetWindowPos(ctx)
      return true
    end

    if not (laneDrag and held and laneLayout) then return false end

    local L   = laneLayout
    local col = vm.grid.cols[laneDrag.colIdx]
    if not (col and laneRenderable[col.type] and col.events[laneDrag.idx]) then
      laneDrag, dragging = nil, false
      return true
    end

    local mx, my   = ImGui.GetMousePos(ctx)
    local shifted  = ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift ~= 0
    local mouseRow = L.scrollRow + (mx - L.x0) / L.w * L.rowSpan
    local i        = laneDrag.idx
    local currRow  = vm:ppqToRow(col.events[i].ppq, L.chan)
    local startRow = laneDrag.startMouseRow

    -- Direction is mouse-vs-start (not mouse-vs-event): clicking inside
    -- the 6 px hit-circle of an off-grid anchor used to compare against
    -- the event's exact row, so a click landing pixel-wise on either
    -- side of that row would snap the event on frame 1. Comparing to
    -- startMouseRow makes the click frame a no-op by construction.
    -- The inner geometric check still uses currRow — it's about which
    -- side of the event's row the snap target lands on.
    local toRow = currRow
    if shifted then
      toRow = mouseRow
    else
      local target = util.round(mouseRow)
      if mouseRow > startRow and target > currRow then
        if i < #col.events then
          local nextRow = vm:ppqToRow(col.events[i+1].ppq, L.chan)
          target = math.min(target, math.ceil(nextRow) - 1)
        end
        if target > currRow then toRow = target end
      elseif mouseRow < startRow and target < currRow then
        if i > 1 then
          local prevRow = vm:ppqToRow(col.events[i-1].ppq, L.chan)
          target = math.max(target, math.floor(prevRow) + 1)
        end
        if target < currRow then toRow = target end
      end
    end

    local rawVal = L.valMin + (L.yBot - my) / L.valSpan * (L.valMax - L.valMin)
    local toVal  = util.clamp(util.round(rawVal), L.valMin, L.valMax)

    vm:moveLaneEvent(col, i, toRow, toVal)

    -- Re-anchor startMouseRow whenever a horizontal move actually
    -- happens. Without this, after the event snaps from row 3.7 to
    -- row 5 (mouse went up past startRow), back-tracking the mouse
    -- below startRow but still above the new currRow=5 wouldn't bring
    -- the event back: mouseRow > startRow stays true, so the "down"
    -- branch never fires. Re-anchoring resets the directional reference
    -- to where the mouse currently is, restoring smooth follow-back.
    if toRow ~= currRow then
      laneDrag.startMouseRow = mouseRow
    end

    return true
  end

  local function handleMouse()
    if handleLaneStrip() then return end

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
    if modalState or pickerActive then return end -- popup owns input

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

    openTemperPicker = function() pickerOpenRequest = 'temper' end,
    openSwingPicker  = function() pickerOpenRequest = 'swing'  end,

    quit = function() quitting = true end,
  }

  cmgr:doAfter({ 'reswing', 'quantize', 'quantizeKeepRealised' },
               function() vm:ec():unstick() end)

  ----- Swing editor

  local SWING_ATOMS   = { 'id',
                          'classic', 'pocket', 'lilt', 'shuffle', 'tilt' }
  local SWING_ATOMS_Z = table.concat(SWING_ATOMS, '\0') .. '\0\0'

  local RPB_CHOICES   = { 1, 2, 3, 4, 6, 8, 12, 16 }

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

  -- Combo speaks tile-qn (= user-period × pulsesPerCycle), so atoms with
  -- ppC > 1 surface their actual repeat directly in the dropdown. Storage
  -- stays as user-period; setPeriodFromTileQN divides on write.
  local function periodPresetIndex(tileQN)
    for i, p in ipairs(PERIOD_PRESETS) do
      if math.abs(tileQN - timing.periodQN(p.period)) < 1e-9 then return i end
    end
    return 0
  end

  local function periodLabel(tileQN)
    local i = periodPresetIndex(tileQN)
    if i > 0 then return PERIOD_PRESETS[i].label end
    return string.format(tileQN == math.floor(tileQN) and '%d qn' or '%.3g qn', tileQN)
  end

  -- Preset .period is already a tidy rational; halving it for ppC=2 keeps
  -- it tidy ({n,d} → {n,2d}; integer → {n,2}).
  local function periodOverPPC(period, ppC)
    if ppC == 1 then return period end
    if type(period) == 'table' then return { period[1], period[2] * ppC } end
    return { period, ppC }
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

    -- Half-pad top and bottom so bar/beat shading and dividers sit in an
    -- inner band; dots can extend past the band edge for emphasis. Same
    -- structural idea as drawLaneStrip (height-2 lane preview look).
    local pad  = math.max(2, h * 0.15)
    local yTop = y0 + pad
    local yBot = y0 + h - pad

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
          ImGui.DrawList_AddRectFilled(dl, cx, yTop, cx + cellW, yBot, colour(key))
        end
      end
    end

    -- 1px vertical dividers at every cell boundary, palette pale enough to
    -- sit behind the dots — same role the main lane strip uses.
    local divider = colour('laneRowDivider')
    for i = 0, N do
      local gx = x0 + (i / N) * w
      ImGui.DrawList_AddLine(dl, gx, yTop, gx, yBot, divider, 1)
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
    if compositesEqual(swingRead() or {}, composite) then return end
    vm:setSwingComposite(swingEditor.name, composite)
    vm:reswingPreset(swingEditor.name)
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
    ImGui.Text(ctx, string.format('%d.', i))
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
    ImGui.Text(ctx, 'per')
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 90)
    local ppC    = timing.atomMeta[f.atom].pulsesPerCycle
    local tileQN = timing.atomTilePeriod(f)
    local pIdx   = periodPresetIndex(tileQN)
    local items = {}
    for _, p in ipairs(PERIOD_PRESETS) do items[#items+1] = p.label end
    if pIdx == 0 then items[#items+1] = periodLabel(tileQN) end
    local itemsZ = table.concat(items, '\0') .. '\0\0'
    local curIdx = pIdx > 0 and (pIdx - 1) or #PERIOD_PRESETS
    local rvP, newPIdx = ImGui.Combo(ctx, '##per', curIdx, itemsZ)
    if rvP and newPIdx + 1 <= #PERIOD_PRESETS then
      patchFactor(i, { period = periodOverPPC(PERIOD_PRESETS[newPIdx + 1].period, ppC) })
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

  local function idealSwingWidth() return 560 end

  local function drawSwingEditor()
    if not swingEditor then return end

    local composite = (swingEditor.name and swingRead()) or {}
    local n = #composite

    -- First-time default; then max height = viewport so auto-grow
    -- stays on-screen. Width is user-resizable thereafter.
    local _, vpH = ImGui.Viewport_GetSize(ImGui.GetMainViewport(ctx))
    ImGui.SetNextWindowSizeConstraints(ctx, 400, 120, 9999, vpH)
    ImGui.SetNextWindowSize(ctx, 560, 420, ImGui.Cond_FirstUseEver)

    local idealW = idealSwingWidth()
    if swingEditor.lastCount ~= n or (swingEditor.lastW or 560) < idealW then
      local w = math.max(swingEditor.lastW or 560, idealW)
      local h = math.min(idealSwingHeight(n), vpH)
      ImGui.SetNextWindowSize(ctx, w, h, ImGui.Cond_Always)
      swingEditor.lastCount = n
    end

    -- Match the toolbar's chrome family, then add window-shape styling
    -- (border, title bar, window bg, separator) so the editor reads as a
    -- sibling of the toolbar rather than a default-grey ImGui panel
    -- floating over the parchment grid. Surfaces use editor.bg (opaque
    -- pale) — toolbar.bg is authored at 0.5 alpha, which would bleed the
    -- grid through a floating window.
    pushChromeStyles()
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowBorderSize, 1)
    ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg,         colour('editor.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg,          colour('editor.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive,    colour('editor.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgCollapsed, colour('editor.bg'))
    ImGui.PushStyleColor(ctx, ImGui.Col_Separator,        colour('toolbar.buttonBorder'))
    local visible, open = ImGui.Begin(ctx, 'Swing', true,
      ImGui.WindowFlags_NoCollapse | ImGui.WindowFlags_NoDocking)
    if not open then swingEditor = nil end

    if visible and swingEditor then
      swingEditor.lastW = ImGui.GetWindowWidth(ctx)

      if ImGui.IsWindowFocused(ctx) and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
        swingEditor = nil
      end

      if swingEditor and not swingEditor.name then
        -- CREATE MODE
        ImGui.Text(ctx, 'No swing slot is set.')
        ImGui.Text(ctx, 'Name:')
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
        -- EDIT MODE — toolbar row mirrors the main toolbar's chrome:
        -- (10, 3) FramePadding, vertical separators between groups,
        -- compact checkbox, manual ▾ on the rpb picker (smaller than
        -- ImGui.Combo's auto-arrow). Padding push is scoped to the row;
        -- the factor strip below uses the inherited padding.
        ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 10, 3)

        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, 'Editing: ' .. swingEditor.name)
        ImGui.SameLine(ctx, 0, 12)
        local dirty = not compositesEqual(composite, swingEditor.snapshot)
        if not dirty then ImGui.BeginDisabled(ctx) end
        if ImGui.Button(ctx, 'Reset') then swingWrite(util.deepClone(swingEditor.snapshot) or {}) end
        if not dirty then ImGui.EndDisabled(ctx) end

        ImGui.SameLine(ctx, 0, 12)
        verticalSeparator()
        ImGui.SameLine(ctx, 0, 12)

        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, 'Rows/qn:')
        ImGui.SameLine(ctx, 0, 6)
        -- Button + popup, mirroring drawSlotPicker's chrome (manual ▾
        -- glyph at font size, smaller than ImGui.Combo's frame-tall arrow).
        local rpbBtn = tostring(swingEditor.rpb) .. ' \xe2\x96\xbe##rpb'
        if ImGui.Button(ctx, rpbBtn) then ImGui.OpenPopup(ctx, '##rpb_popup') end
        local btnX = ImGui.GetItemRectMin(ctx)
        local _, btnY = ImGui.GetItemRectMax(ctx)
        ImGui.SetNextWindowPos(ctx, btnX, btnY, ImGui.Cond_Appearing)
        if ImGui.BeginPopup(ctx, '##rpb_popup', ImGui.WindowFlags_NoNav) then
          for _, v in ipairs(RPB_CHOICES) do
            if ImGui.Selectable(ctx, tostring(v), v == swingEditor.rpb) then
              swingEditor.rpb = v
            end
          end
          ImGui.EndPopup(ctx)
        end

        ImGui.SameLine(ctx, 0, 12)
        verticalSeparator()
        ImGui.SameLine(ctx, 0, 12)

        ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 0, 0)
        local cy = ImGui.GetCursorPosY(ctx)
        ImGui.SetCursorPosY(ctx, cy + 3)
        local rvW, newWild = ImGui.Checkbox(ctx, '  Wild', swingEditor.wild or false)
        ImGui.PopStyleVar(ctx, 1)
        if rvW then swingEditor.wild = newWild end

        ImGui.PopStyleVar(ctx, 1)
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
        end

        if ImGui.Button(ctx, '+ add factor') then addFactor() end
      end
    end
    ImGui.End(ctx)
    ImGui.PopStyleColor(ctx, 5)
    ImGui.PopStyleVar(ctx, 1)
    popChromeStyles()
  end

  ---------- PUBLIC

  local rm = {}

  function rm:init()
    ctx    = ImGui.CreateContext('Readium Tracker')
    ImGui.SetConfigVar(ctx, ImGui.ConfigVar_ViewportsNoDecoration, 0)
    -- macOS' system font is private (dot-prefixed) and not reachable by
    -- family name, so load SFNS.ttf directly. Other platforms resolve by name.
    local os = reaper.GetOS()
    font       = ImGui.CreateFont('Source Code Pro')
    if os:find('OSX') or os:find('mac') then
      uiFont = ImGui.CreateFontFromFile('/System/Library/Fonts/SFNS.ttf')
    else
      uiFont = ImGui.CreateFont(os:find('Win') and 'Segoe UI' or 'sans-serif')
    end
    ImGui.Attach(ctx, font)
    ImGui.Attach(ctx, uiFont)
  end

  function rm:loop()
    if not ctx then return false end

    ImGui.PushFont(ctx, uiFont, 13)

    local styleCount = pushStyles()

    if dragging then
      ImGui.SetNextWindowPos(ctx, dragWinX, dragWinY)
    end
    -- Zero the main window's padding so the chrome BeginChild bands and
    -- the parchment grid go edge-to-edge. Each child sets its own inner
    -- WindowPadding for breathing room around its content.
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 0, 0)
    local visible, open = ImGui.Begin(ctx, 'Readium Tracker', true,
      ImGui.WindowFlags_NoScrollbar
      | ImGui.WindowFlags_NoScrollWithMouse
      | ImGui.WindowFlags_NoDocking
      | ImGui.WindowFlags_NoNav)
    ImGui.PopStyleVar(ctx)

    if visible then
      if #vm.grid.cols > 0 then
        -- Layout: chrome toolbar (auto-fit) | parchment grid (integer rows
        -- + leftover gap) | chrome statusBar (fixed height). The colour
        -- change between blocks IS the visual separator — no rules.
        ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, colour('toolbar.bg'))
        ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, CHROME_PAD_X, CHROME_PAD_Y)
        if ImGui.BeginChild(ctx, '##toolbar', 0, 0,
                            ImGui.ChildFlags_AutoResizeY | ImGui.ChildFlags_AlwaysUseWindowPadding,
                            ImGui.WindowFlags_NoScrollbar) then
          drawToolbar()
        end
        ImGui.EndChild(ctx)
        ImGui.PopStyleVar(ctx)
        ImGui.PopStyleColor(ctx)

        -- Reserve a fixed footer at the bottom; the grid takes
        -- `availH - footerH` pixels and snaps to integer rows, leaving
        -- the fractional remainder as a parchment gap *above* the footer.
        local cursorY   = ImGui.GetCursorPosY(ctx)
        local _, availH = ImGui.GetContentRegionAvail(ctx)
        local footerH   = ImGui.GetFrameHeightWithSpacing(ctx) + 4
        local gridBudget = availH - footerH

        -- Shift the grid in by the same chrome pad so it isn't flush against
        -- the window edge. Indent persists across drawLaneStrip's Dummy
        -- (which would otherwise reset cursor X back to 0); SetCursorPosY
        -- handles the top pad, no equivalent vertical Indent.
        ImGui.Indent(ctx, CHROME_PAD_X)
        ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + CHROME_PAD_Y)

        ImGui.PushFont(ctx, font, 15)
        local availW = ImGui.GetContentRegionAvail(ctx)
        computeLayout(availW - CHROME_PAD_X, gridBudget - CHROME_PAD_Y)
        drawLaneStrip()
        drawTracker()
        ImGui.PopFont(ctx)
        ImGui.Unindent(ctx, CHROME_PAD_X)

        -- Pin the footer to (toolbarBottom + gridBudget); the parchment
        -- gap between drawTracker's last row and here is the leftover.
        ImGui.SetCursorPosY(ctx, cursorY + gridBudget)
        ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, colour('statusBar.bg'))
        ImGui.PushStyleColor(ctx, ImGui.Col_Text,    colour('statusBar.text'))
        ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, CHROME_PAD_X + 4, CHROME_PAD_Y)
        if ImGui.BeginChild(ctx, '##statusBar', 0, footerH,
                            ImGui.ChildFlags_AlwaysUseWindowPadding,
                            ImGui.WindowFlags_NoScrollbar) then
          drawStatusBar()
        end
        ImGui.EndChild(ctx)
        ImGui.PopStyleVar(ctx)
        ImGui.PopStyleColor(ctx, 2)

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
