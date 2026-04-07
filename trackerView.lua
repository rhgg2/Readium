-- trackerView.lua
-- Tracker-style MIDI viewer for ReaImGui
-- Exposes: newTrackerView()

loadModule('util')
loadModule('takeManager')
loadModule('takeParser')

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

function newTrackerView()

  ---------
  -- Config
  ---------

  local config = {
    colours = {
      -- Colour palette (RGBA, 0–1)
      bg            = {218/256, 214/256, 201/256, 1},
      text          = { 48/256,  48/256,  33/256, 1},
      textBar       = { 48/256,  48/256,  33/256, 1},
      header        = { 48/256,  48/256,  33/256, 1},
      inactive      = {178/256, 174/256, 161/256, 1},
      cursor        = { 37/256,  41/256,  54/256, 1},
      cursorText    = {207/256, 207/256, 222/256, 1},
      rowNormal     = {218/256, 214/256, 201/256, 0},
      rowBeat       = {181/256, 179/256, 158/256, 0.4},
      rowBarStart   = {159/256, 147/256, 115/256, 0.4},
      editCursor    = {1, 1, 0, 1},
      selection     = {247/256, 247/256, 244/256, 0.5},
      scrollHandle  = { 48/256,  48/256,  33/256, 1},
      scrollBg      = {218/256, 214/256, 201/256, 1},
      accent        = {159/256, 147/256, 115/256, 1},
      separator     = {159/256, 147/256, 115/256, 0.3},
    },
  }

  local function colour(c)
    local colour = config.colours[c]
    return ImGui.ColorConvertDouble4ToU32(colour[1], colour[2], colour[3], colour[4])
  end

  --------------------
  -- Internal state
  --------------------

  -- take manager, take parser, ImGui context, font
  
  local tm   = nil
  local tp   = nil
  local ctx  = nil
  local font = nil
  
  -- state data

  local state = {
    ppqPerRow    = 60,
    ppqPerQN     = 240,
    rowPerQN     = 4,
    activeChan   = 1,
  }

  -- holds rendering data
  
  local render = {
    scrollRow    = 0,
    cursorRow    = 0,
    cursorCol    = 0,
  }
  
  --------------------
  -- Build row grid from parser data
  -- Guarantees: tm, tp, tp.take, render.dx, render.dy are defined
  --------------------


  local function buildGrid(chan)
    local NOTE_NAMES = {"C-","C#","D-","D#","E-","F-","F#","G-","G#","A-","A#","B-"}

    local function noteName(pitch)
      if not pitch then return "..." end
      local oct = math.floor(pitch / 12) - 1
      return string.format("%s%d", NOTE_NAMES[(pitch % 12) + 1], oct)
    end

    local function velStr(vel)
      if not vel then return ".." end
      return string.format("%02X", vel)
    end

    local function ccValStr(val)
      if not val then return ".." end
      if val < 0 then return string.format("-%04X", math.abs(val)) end
      return string.format("%02X", val)
    end

    -- returns text and "empty" flag 
    local function renderNote(evt)
      if evt and evt.pitch then
        return noteName(evt.pitch) .. " " .. velStr(evt.vel)
      elseif evt and evt.type == "pa" then
        return "AT " .. velStr(evt.val)-- , isCursor and colour(cursorText) or colour(accent)
      else
        return "... ..", true
      end
    end

    local function renderPB(evt)
      if evt then
        if evt.hidden then
          return "-----", true
        else
          return string.format("%+05d", math.floor(evt.val or 0))
        end
      else
        return ".....", true
      end
    end

    local function renderCC(evt)
      if evt then
        return ccValStr(evt.val)
      else
        return "..", true
      end
    end

    local function renderDefault(evt)
      if evt then
        return "**"
      else
        return "..", true
      end
    end
    
    local take = tp.take
    local channel = take.channels[chan]
    if not channel then return end

    local numRows = math.ceil(state.length * state.rowPerQN / state.ppqPerQN)
    if numRows < 1 then numRows = 1 end

    local cols = {}
    for _, col in ipairs(channel.columns) do
      local width = (col.type == "note" and 7 or 5) * render.dx + 8
      local renderFn = renderDefault
      if col.type == "note" then
        renderFn = renderNote
      elseif col.type == "pb" then
        renderFn = renderPB
      elseif col.type == "cc" or col.type == "at" or col.type == "pc" then
        renderFn = renderCC
      end

      cols[#cols + 1] = {
        id    = col.id,
        type  = col.type,
        label = col.label,
        width = width,
        renderFn = renderFn,
      }
    end

    local grid = {}
    for y = 0, numRows-1 do
      grid[y] = {}
    end

    for x, _ in ipairs(cols) do
      local col = channel.columns[x]
      if col then
        for _, evt in ipairs(col.events) do
          local y = math.floor((evt.ppq or 0) / state.ppqPerRow)
          if y >= 0 and y < numRows then
            local entry = grid[y][x] or { }
            entry[#entry + 1] = evt
            grid[y][x] = entry
          end
        end
      end
    end

    util:assign(render, {
                  grid = grid,
                  cols = cols,
                  numRows = numRows,
                  numCols = #cols,
                  rowHeight = rowHeight or render.dy + 2,
    })
  end

  --------------------
  -- Toolbar
  --------------------

  local function drawToolbar(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, colour('header'))
    ImGui.Text(ctx, "Rows/beat:")
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)

    local subdivOptions = {1, 2, 3, 4, 6, 8, 12, 16}
    for _, s in ipairs(subdivOptions) do
      local isActive = (s == state.rowPerQN)
      if isActive then
        ImGui.PushStyleColor(ctx, ImGui.Col_Button, colour('cursor'))
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, colour('cursorText'))
      end
      if ImGui.SmallButton(ctx, tostring(s)) then
        state.rowPerQN = s
      end
      if isActive then
        ImGui.PopStyleColor(ctx, 2)
      end
      ImGui.SameLine(ctx)
    end
    ImGui.NewLine(ctx)
    ImGui.Separator(ctx)
  end

  --------------------
  -- Status bar
  --------------------

  local function drawStatusBar(ctx)
    ImGui.Separator(ctx)
    local row = render.cursorRow
    local ppq = row * state.ppqPerRow
    local beat = math.floor(row / state.rowPerQN) + 1
    local sub  = (row % state.rowPerQN) + 1
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, colour('header'))
    ImGui.Text(ctx, string.format(
      "Row: %d | PPQ: %d | Beat: %d.%d | Ch: %d | Step: 1/%d",
      row, ppq, beat, sub, state.activeChan, state.rowPerQN
    ))
    ImGui.PopStyleColor(ctx)
  end

  --------------------
  -- Main tracker draw
  --------------------

  local function drawTracker(ctx)
    if not (tm and tp and tp.take and ctx) then return end

    local take = tp.take
    local chan = state.activeChan
    local channel = take.channels[chan]
    if not channel then return end

    state.ppqPerQN  = tm:reso()
    state.ppqPerRow = math.floor(state.ppqPerQN / state.rowPerQN)
    state.length    = tm:length()

    if not render.dx then
      render.dx, render.dy = ImGui.CalcTextSize(ctx, "W")
    end

    buildGrid(chan)

    -- Channel tabs (only channels with events) [3]
    if ImGui.BeginTabBar(ctx, "channels") then
      for c = 1, 16 do
        local hasEvents = false
        for _, col in ipairs(take.channels[c].columns) do
          if #col.events > 0 then hasEvents = true; break end
        end
        if hasEvents then
          if ImGui.BeginTabItem(ctx, "Ch " .. c) then
            state.activeChan = c
            ImGui.EndTabItem(ctx)
          end
        end
      end
      ImGui.EndTabBar(ctx)
    end

    ImGui.Separator(ctx)

    -- Layout
    local _, windowHeight = ImGui.GetContentRegionAvail(ctx)
    render.visibleRows = math.floor(windowHeight / render.rowHeight) - 2

    render.scrollRow = util:clamp(render.scrollRow, 0, math.max(0, render.numRows - render.visibleRows))
    render.cursorRow = util:clamp(render.cursorRow, 0, render.numRows-1)

    if render.cursorRow < render.scrollRow then
      render.scrollRow = render.cursorRow
    elseif render.cursorRow >= render.scrollRow + render.visibleRows then
      render.scrollRow = render.cursorRow - render.visibleRows + 1
    end

    -- Edit cursor
    local editCursorPPQ  = tm:editCursor()
    local editCursorRow  = math.floor(editCursorPPQ / state.ppqPerRow)

    local drawList = ImGui.GetWindowDrawList(ctx)
    local startX, startY = ImGui.GetCursorScreenPos(ctx)
    local rowNumWidth = ImGui.CalcTextSize(ctx, "00000") + 12

    -- Column headers
    ImGui.DrawList_AddText(drawList, startX + 2, startY, colour('header'), "Row")
    local x = startX + rowNumWidth

    for _, renderCol in ipairs(render.cols) do
      ImGui.DrawList_AddLine(drawList, x - 2, startY, x - 2,
        startY + (render.visibleRows + 1) * render.rowHeight, colour('separator'), 1)
      ImGui.DrawList_AddText(drawList, x + 6, startY, colour('header'), renderCol.label)
      x = x + renderCol.width
    end

    local headerY = startY + render.rowHeight
    ImGui.DrawList_AddLine(drawList, startX, headerY, x, headerY, colour('header'), 1)

    -- Rows
    local rowsPerBeat = state.rowPerQN
    local rowsPerBar  = rowsPerBeat * 4

    for vi = 0, render.visibleRows-1 do
      local row = render.scrollRow + vi
      if row >= render.numRows then break end

      local rowY = headerY + 2 + vi * render.rowHeight
      local isBarStart   = (row % rowsPerBar == 0)
      local isBeatStart  = (row % rowsPerBeat == 0)
      local isCursor     = (row == render.cursorRow)
      local isEditCursor = (row == editCursorRow)
      local totalWidth   = x - startX

      if isCursor then
        ImGui.DrawList_AddRectFilled(drawList, startX, rowY - 1,
          startX + totalWidth, rowY + render.rowHeight - 1, colour('cursor'))
      elseif isBarStart then
        ImGui.DrawList_AddRectFilled(drawList, startX, rowY - 1,
          startX + totalWidth, rowY + render.rowHeight - 1, colour('rowBarStart'))
      elseif isBeatStart then
        ImGui.DrawList_AddRectFilled(drawList, startX, rowY - 1,
          startX + totalWidth, rowY + render.rowHeight - 1, colour('rowBeat'))
      end

      if isEditCursor then
        ImGui.DrawList_AddRectFilled(drawList, startX, rowY - 1,
          startX + 3, rowY + render.rowHeight - 1, colour('editCursor'))
      end

      -- Row number
      local rowTextCol = isCursor and colour('cursorText')
                       or (isBeatStart and colour('textBar') or colour('inactive'))
      ImGui.DrawList_AddText(drawList, startX + 8, rowY, rowTextCol,
        string.format("%03d", row))

      -- Cell data
      local cx = startX + rowNumWidth
      local rowData = render.grid[row]

      for colIdx, colDef in ipairs(render.cols) do
        local evt = rowData and rowData[colIdx] and rowData[colIdx][1]
        local textCol = isCursor and colour('cursorText') or colour('text')
        local emptyCol = isCursor and colour('cursorText') or colour('inactive')
        
        local renderText, isEmpty = colDef.renderFn(evt)
        local renderCol = isEmpty and emptyCol or textCol
        
        ImGui.DrawList_AddText(drawList, cx + 6, rowY, renderCol, renderText)
        cx = cx + colDef.width
      end
    end

    ImGui.Dummy(ctx, x - startX, (render.visibleRows + 1) * render.rowHeight + 4)

    -- Keyboard navigation
    if ImGui.IsWindowFocused(ctx) then
      if ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow) then
        render.cursorRow = math.min(render.cursorRow + 1, render.numRows - 1)
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow) then
        render.cursorRow = math.max(render.cursorRow - 1, 0)
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_PageDown) then
        render.cursorRow = math.min(render.cursorRow + render.visibleRows, render.numRows - 1)
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_PageUp) then
        render.cursorRow = math.max(render.cursorRow - render.visibleRows, 0)
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_Home) then
        render.cursorRow = 0
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_End) then
        render.cursorRow = render.numRows - 1
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_RightArrow) then
        render.cursorCol = math.min(render.cursorCol + 1, render.numCols - 1)
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_LeftArrow) then
        render.cursorCol = math.max(render.cursorCol - 1, 0)
      end
    end
  end

  --------------------
  -- Style push/pop helpers (version-safe) [2]
  --------------------

  local function pushStyles(ctx)
    local count = 0
    local function push(enum, col)
      if enum then
        ImGui.PushStyleColor(ctx, enum, colour(col))
        count = count + 1
      end
    end
    push(ImGui.Col_WindowBg, 'bg')
    push(ImGui.Col_Tab, 'bg')
    push(ImGui.Col_TabSelected, 'cursor')
    push(ImGui.Col_TabHovered, 'rowBeat')
    push(ImGui.Col_ScrollbarBg, 'scrollBg')
    push(ImGui.Col_ScrollbarGrab, 'scrollHandle')
    return count
  end

  --------------------
  -- Public interface
  --------------------

  local view = {}

  function view:init()
    ctx = ImGui.CreateContext('Readium Tracker')
    font = ImGui.CreateFont('Courier New', ImGui.FontFlags_Bold)
    ImGui.Attach(ctx, font)
  end

  function view:setSource(takeManager, parser)
    tm = takeManager
    tp = parser
  end

  function view:loop()
    if not ctx then return false end

    ImGui.PushFont(ctx, font, 15)
    local styleCount = pushStyles(ctx)

    local visible, open = ImGui.Begin(ctx, 'Readium Tracker', true,
      ImGui.WindowFlags_NoScrollbar
      | ImGui.WindowFlags_NoScrollWithMouse
      | ImGui.WindowFlags_NoDocking)

    if visible then
      -- Refresh on item change
      local item = reaper.GetSelectedMediaItem(0, 0)
      if item then
        local take = reaper.GetActiveTake(item)
        if take and tm and tm.take ~= take then
          tm:load(take)
          tp = newTakeParser(tm)
        end
      end

      if tp then
        drawToolbar(ctx)
        drawTracker(ctx)
        drawStatusBar(ctx)
      else
        ImGui.Text(ctx, "Select a MIDI item to begin.")
      end

      ImGui.End(ctx)
    end

    ImGui.PopStyleColor(ctx, styleCount)
    ImGui.PopFont(ctx)

    return open
  end

  return view
end
