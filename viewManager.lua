--------------------
-- newViewManager
--
-- Builds a renderable grid from a trackerManager's channel/column data.
-- Each cell in the grid maps a (row, column) position to one or more
-- tracker events, with a render function that produces display text.
--
-- The grid is rebuilt automatically whenever the attached trackerManager
-- fires a callback (i.e. when the underlying MIDI data changes).
--
-- CONSTRUCTION
--   local vm = newViewManager(tm, cm)  -- attach to trackerManager tm
--   local vm = newViewManager(nil)     -- create empty, call vm:attach(tm) later
--
-- LIFECYCLE
--   vm:init()           -- create ImGui context and font
--   vm:loop()           -- per-frame draw; returns false when the window is closed
--   vm:attach(tm, cm)   -- attach to a trackerManager; triggers immediate rebuild
--   vm:detach()         -- remove callback from the attached trackerManager
--   vm:rebuild(changed) -- manually trigger a grid rebuild
--
-- GRID STRUCTURE
--   grid.groups  : array of column groups, one per channel
--     Each group: { id, label, cols }
--
--   grid.cols    : flat array of all grid columns across all channels
--     Each column: { id, type, label, events, renderFn, width, groupId }
--       renderFn(evt) -> text, isEmpty
--       width: character width (7 for note columns, 5 for others)
--
--   grid.rows    : table keyed by row index (0-based)
--     grid.rows[y][x] = array of events at that cell (x is 1-based col index)
--
-- DISPLAY PARAMETERS
--   ppqPerQN  : PPQ per quarter note (from tm:reso() on take change)
--   rowPerQN  : rows per quarter note (from config, default 4)
--   ppqPerRow : derived as ppqPerQN / rowPerQN
--   length    : item length in PPQ
--------------------

loadModule('util')
loadModule('midiManager')
loadModule('trackerManager')

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

function newViewManager(tm, cm)

  ---------- PRIVATE DATA

  local ppqPerRow  = 60
  local ppqPerQN   = 240
  local rowPerQN   = 4
  local length     = 0

  local grid = {
    cols    = {},
    rows    = {},
    groups  = {},
  }

  local function cfg(key, default)
    if cm then
      local val = cm:get(key)
      if val ~= nil then return val end
    end
    return default
  end

  ---------- COLOUR DEFAULTS

  local colourDefaults = {
    bg           = {218/256, 214/256, 201/256, 1  },
    text         = { 48/256,  48/256,  33/256, 1  },
    textBar      = { 48/256,  48/256,  33/256, 1  },
    header       = { 48/256,  48/256,  33/256, 1  },
    inactive     = {178/256, 174/256, 161/256, 1  },
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
  }

  local colourCache = {}

  local function colour(name)
    if not colourCache[name] then
      local c = cfg("colour." .. name, colourDefaults[name])
      colourCache[name] = ImGui.ColorConvertDouble4ToU32(c[1], c[2], c[3], c[4])
    end
    return colourCache[name]
  end

  ---------- IMGUI HANDLES

  local ctx  = nil
  local font = nil

  ---------- RENDER STATE

  local scrollRow   = 0
  local cursorRow   = 0
  local cursorCol   = 0
  local dx          = nil
  local dy          = nil
  local visibleRows = 0

  ---------- PRIVATE FUNCTIONS

  -- given event, returns rendered text and "empty" flag

  local function renderNote(evt)
    local function noteName(pitch)
      local NOTE_NAMES = {"C-","C#","D-","D#","E-","F-","F#","G-","G#","A-","A#","B-"}
      local oct = math.floor(pitch / 12) - 1
      return string.format("%s%d", NOTE_NAMES[(pitch % 12) + 1], oct)
    end

    if not evt then return "... ..", true end

    local noteTxt = '...'
    local velTxt  = evt.vel and string.format("%02X", evt.vel) or '..'

    if evt.pitch then noteTxt = noteName(evt.pitch)
    elseif evt.type == 'pa' then noteTxt = 'PA ' end

    return noteTxt .. ' ' .. velTxt
  end

  local function renderPB(evt)
    if evt and not evt.hidden then
      return string.format("%+05d", math.floor(evt.val or 0))
    else return ".....", true end
  end

  local function renderCC(evt)
    if evt and evt.val then
      if evt.val < 0 then return string.format("-%04X", math.abs(evt.val))
      else return string.format("%02X", evt.val) end
    else return "..", true end
  end

  local function renderDefault(evt)
    if evt then return "**"
    else return "..", true
    end
  end

  ---------- REBUILD

  local function rebuild(changed)
    if not tm then return end
    changed = changed or { take = false, data = true }

    if changed.take then
      ppqPerQN  = tm:reso()
      rowPerQN  = cfg("rowPerQN", 4)
      ppqPerRow = math.floor(ppqPerQN / rowPerQN)
      length    = tm:length()
    end

    if changed.take or changed.data then
      grid.cols   = {}
      grid.groups = {}

      local renderFns = {
        note = renderNote,
        pb   = renderPB,
        cc   = renderCC,
        pa   = renderCC,
        at   = renderCC,
        pc   = renderCC,
        sx   = renderDefault,
      }

      for chan, channel in tm:channels() do
        local group = util:add(grid.groups, {
          id    = util.IDX,
          label = channel.label,
          cols  = {}
        })

        for _, column in ipairs(channel.columns) do
          local gridCol = util:pick(column, "id type label events")
          util:assign(gridCol, {
            renderFn = renderFns[gridCol.type] or renderDefault,
            width    = gridCol.type == "note" and 7 or 5,
            groupId  = group.id
          })
          util:add(grid.cols, gridCol)
          util:add(group.cols, gridCol)
        end
      end

      local numRows = math.ceil(length * rowPerQN / ppqPerQN)
      if numRows < 1 then numRows = 1 end

      grid.rows    = {}

      for y = 0, numRows - 1 do
        grid.rows[y] = {}
      end

      for x, gridCol in ipairs(grid.cols) do
        for _, evt in ipairs(gridCol.events) do
          local y = math.floor((evt.ppq or 0) / ppqPerRow)
          if y >= 0 and y < numRows then
            local entry = grid.rows[y][x] or {}
            util:add(entry, evt)
            grid.rows[y][x] = entry
          end
        end
      end
    end
  end

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

  local function drawToolbar()
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, colour('header'))
    ImGui.Text(ctx, "Rows/beat:")
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)

    local subdivOptions = {1, 2, 3, 4, 6, 8, 12, 16}
    for _, s in ipairs(subdivOptions) do
      local isActive = (s == rowPerQN)
      if isActive then
        ImGui.PushStyleColor(ctx, ImGui.Col_Button, colour('cursor'))
        ImGui.PushStyleColor(ctx, ImGui.Col_Text,   colour('cursorText'))
      end
      if ImGui.SmallButton(ctx, tostring(s)) then
        cm:set("track", "rowPerQN", s)
      end
      if isActive then ImGui.PopStyleColor(ctx, 2) end
      ImGui.SameLine(ctx)
    end
    ImGui.NewLine(ctx)
    ImGui.Separator(ctx)
  end

  local function drawStatusBar()
    ImGui.Separator(ctx)
    local ppq  = cursorRow * ppqPerRow
    local beat = math.floor(cursorRow / rowPerQN) + 1
    local sub  = (cursorRow % rowPerQN) + 1
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, colour('header'))
    ImGui.Text(ctx, string.format(
      "Row: %d | PPQ: %d | Beat: %d.%d | Step: 1/%d",
      cursorRow, ppq, beat, sub, rowPerQN
    ))
    ImGui.PopStyleColor(ctx)
  end

  local function drawTracker()
    if not dx then
      dx, dy = ImGui.CalcTextSize(ctx, "W")
    end

    local rowHeight   = dy + 2
    local rowNumWidth = ImGui.CalcTextSize(ctx, "00000") + 12
    local numRows     = #grid.rows

    -- Visible rows from available height (subtract header rows and status bar)
    local _, windowHeight = ImGui.GetContentRegionAvail(ctx)
    visibleRows = math.max(1, math.floor(windowHeight / rowHeight) - 3)

    -- Clamp cursor and scroll; cursor-follow
    cursorRow = util:clamp(cursorRow, 0, math.max(0, numRows - 1))
    scrollRow = util:clamp(scrollRow, 0, math.max(0, numRows - visibleRows))
    if cursorRow < scrollRow then
      scrollRow = cursorRow
    elseif cursorRow >= scrollRow + visibleRows then
      scrollRow = cursorRow - visibleRows + 1
    end

    -- Pre-compute pixel widths for each column (width field is in characters)
    local colWidths = {}
    for x, col in ipairs(grid.cols) do
      colWidths[x] = col.width * dx + 8
    end

    -- Total width for background fills and dummy spacer
    local totalWidth = rowNumWidth
    for _, w in ipairs(colWidths) do totalWidth = totalWidth + w end

    local drawList       = ImGui.GetWindowDrawList(ctx)
    local startX, startY = ImGui.GetCursorScreenPos(ctx)
    local totalHeight    = (visibleRows + 3) * rowHeight

    -- Header row 1: group labels
    -- colXs[x] = pixel x-start of column x (1-based); built during this pass
    ImGui.DrawList_AddText(drawList, startX + 4, startY, colour('inactive'), "Row")

    local hx      = startX + rowNumWidth
    local colXs   = { hx }    -- colXs[1] = start of first column
    local flatIdx = 1

    for _, group in ipairs(grid.groups) do
      if #group.cols > 0 then
        -- Vertical separator between groups (and between row-num and first group)
        ImGui.DrawList_AddLine(drawList, hx - 2, startY,
          hx - 2, startY + totalHeight, colour('separator'), 1)
        -- Group label
        ImGui.DrawList_AddText(drawList, hx + 4, startY, colour('accent'), group.label)
        -- Advance through this group's columns, recording each start x
        for _ = 1, #group.cols do
          hx = hx + colWidths[flatIdx]
          flatIdx = flatIdx + 1
          colXs[flatIdx] = hx
        end
      end
    end

    -- Header row 2: column labels
    local colLabelY = startY + rowHeight
    ImGui.DrawList_AddText(drawList, startX + 4, colLabelY, colour('inactive'), "---")
    for x, col in ipairs(grid.cols) do
      ImGui.DrawList_AddText(drawList, colXs[x] + 4, colLabelY, colour('header'), col.label)
    end

    -- Separator line below headers
    local rowsY = colLabelY + rowHeight
    ImGui.DrawList_AddLine(drawList, startX, rowsY - 2,
      startX + totalWidth, rowsY - 2, colour('header'), 1)

    -- Rows
    local rowsPerBar = rowPerQN * 4

    for vi = 0, visibleRows - 1 do
      local row = scrollRow + vi
      if row >= numRows then break end

      local rowY        = rowsY + vi * rowHeight
      local isBarStart  = (row % rowsPerBar == 0)
      local isBeatStart = (row % rowPerQN   == 0)
      local isCursor    = (row == cursorRow)

      -- Row background
      if isCursor then
        ImGui.DrawList_AddRectFilled(drawList, startX, rowY,
          startX + totalWidth, rowY + rowHeight, colour('cursor'))
      elseif isBarStart then
        ImGui.DrawList_AddRectFilled(drawList, startX, rowY,
          startX + totalWidth, rowY + rowHeight, colour('rowBarStart'))
      elseif isBeatStart then
        ImGui.DrawList_AddRectFilled(drawList, startX, rowY,
          startX + totalWidth, rowY + rowHeight, colour('rowBeat'))
      end

      -- Row number
      local rowNumCol = isCursor    and colour('cursorText')
                     or isBeatStart and colour('textBar')
                     or                 colour('inactive')
      ImGui.DrawList_AddText(drawList, startX + 4, rowY, rowNumCol,
        string.format("%03d", row))

      -- Cells
      local rowData = grid.rows[row]
      for x, col in ipairs(grid.cols) do
        local evt        = rowData and rowData[x] and rowData[x][1]
        local text, isEmpty = col.renderFn(evt)
        local textCol    = isCursor  and colour('cursorText')
                        or isEmpty   and colour('inactive')
                        or               colour('text')
        ImGui.DrawList_AddText(drawList, colXs[x] + 4, rowY, textCol, text)
      end
    end

    -- Reserve content space so ImGui knows the drawable area
    ImGui.Dummy(ctx, totalWidth, rowsY - startY + visibleRows * rowHeight + 4)

    -- Keyboard navigation
    if ImGui.IsWindowFocused(ctx) then
      if ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow) then
        cursorRow = math.min(cursorRow + 1, numRows - 1)
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow) then
        cursorRow = math.max(cursorRow - 1, 0)
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_PageDown) then
        cursorRow = math.min(cursorRow + visibleRows, numRows - 1)
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_PageUp) then
        cursorRow = math.max(cursorRow - visibleRows, 0)
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_Home) then
        cursorRow = 0
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_End) then
        cursorRow = numRows - 1
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_RightArrow) then
        cursorCol = math.min(cursorCol + 1, math.max(0, #grid.cols - 1))
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_LeftArrow) then
        cursorCol = math.max(cursorCol - 1, 0)
      end
    end
  end

  --------------------
  -- Public interface
  --------------------

  local vm = {}

  function vm:init()
    ctx  = ImGui.CreateContext('Readium Tracker')
    font = ImGui.CreateFont('Source Code Pro', ImGui.FontFlags_Bold)
    ImGui.Attach(ctx, font)
  end

  function vm:loop()
    if not ctx then return false end

    ImGui.PushFont(ctx, font, 15)
    local styleCount = pushStyles()

    local visible, open = ImGui.Begin(ctx, 'Readium Tracker', true,
      ImGui.WindowFlags_NoScrollbar
      | ImGui.WindowFlags_NoScrollWithMouse
      | ImGui.WindowFlags_NoDocking)

    if visible then
      if #grid.cols > 0 then
        drawToolbar()
        drawTracker()
        drawStatusBar()
      else
        ImGui.Text(ctx, "Select a MIDI item to begin.")
      end

      ImGui.End(ctx)
    end

    ImGui.PopStyleColor(ctx, styleCount)
    ImGui.PopFont(ctx)

    return open
  end

  function vm:rebuild(changed)
    rebuild(changed)
  end

  -- LIFECYCLE

  local callback = function(changed, _tm)
    if changed.data or changed.take then
      rebuild(changed)
    end
  end

  local configCallback = function(changed, _cm)
    if changed.config then
      colourCache = {}
      rebuild({ take = true, data = true })
    end
  end

  function vm:attach(newTM, newCM)
    if not (newTM and newCM) then return end

    self:detach()
    tm = newTM
    cm = newCM
    tm:addCallback(callback)
    cm:addCallback(configCallback)
    self:rebuild({ take = true, data = true })
  end

  function vm:detach()
    if tm then tm:removeCallback(callback) end
    if cm then cm:removeCallback(configCallback) end
  end

  -- FACTORY BODY

  if tm and cm then vm:attach(tm, cm) end
  return vm
end
