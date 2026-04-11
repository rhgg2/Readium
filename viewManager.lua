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
--     Each column: { id, type, label, events, renderFn, width, groupId, midiChan }
--       renderFn(evt) -> text, isEmpty
--       width: character width (6 for note columns, 4 for pitchbend, 2 for others)
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
  }

  local colourCache = {}

  local function colour(name)
    name = name or 'text'
    if not colourCache[name] then
      local c = cfg("colour." .. name, colourDefaults[name] or {0, 0, 0, 1})
      colourCache[name] = ImGui.ColorConvertDouble4ToU32(c[1], c[2], c[3], c[4])
    end
    return colourCache[name]
  end

  ---------- IMGUI HANDLES

  local ctx  = nil
  local font = nil

  ---------- RENDER STATE

  local scrollCol   = 1
  local scrollRow   = 0
  local cursorCol   = 1
  local cursorStop  = 1
  local cursorRow   = 0
  
  local GUTTER      = 4    -- row-number width in grid chars
  local HEADER      = 2    -- header rows above grid data

  local gridX       = nil
  local gridY       = nil
  local gridWidth   = 0
  local gridHeight  = 0

  ---------- PRIVATE FUNCTIONS

  -- given event, returns rendered text and "empty" flag

  local function renderNote(evt)
    local function noteName(pitch)
      local NOTE_NAMES = {"C-","C#","D-","D#","E-","F-","F#","G-","G#","A-","A#","B-"}
      local oct = math.floor(pitch / 12) - 1
      local octChar = oct >= 0 and tostring(oct) or "M"
      return NOTE_NAMES[(pitch % 12) + 1] .. octChar
    end

    if not evt then return "... ..", 'inactive' end

    local noteTxt = '...'
    local velTxt  = evt.vel and string.format("%02X", evt.vel) or '..'

    if evt.pitch then noteTxt = noteName(evt.pitch)
    elseif evt.type == 'pa' then noteTxt = 'PA ' end

    return noteTxt .. ' ' .. velTxt
  end

  local function renderPB(evt)
    if evt and not evt.hidden then
      if evt.val < 0 then return string.format("%04d", math.abs(evt.val)), 'negative'
      else return string.format("%04d", math.floor(evt.val or 0)) end
    else return "....", 'inactive' end
  end

  local function renderCC(evt)
    if evt and evt.val then return string.format("%02X", evt.val)
    else return "..", 'inactive' end
  end

  local function renderDefault(evt)
    if evt then return "**"
    else return "..", 'inactive'
    end
  end

  ---------- SCROLL CURSOR

  local function scrollRowBy(n)
    local maxRow    = math.max(0, (grid.numRows or 1) - 1)
    cursorRow       = util:clamp(cursorRow + n, 0, maxRow)
    local maxScroll = math.max(0, maxRow - gridHeight + 1)
    scrollRow = util:clamp(scrollRow,
      math.max(0, cursorRow - gridHeight + 1),
      math.min(cursorRow, maxScroll))
  end

  local function lastVisibleFrom(startCol)
    local used = 0
    local last = startCol - 1
    for i = startCol, #grid.cols do
      local w = grid.cols[i].width + (i > startCol and 1 or 0)
      if used + w > gridWidth then break end
      used = used + w
      last = i
    end
    return last
  end

  local function scrollStopBy(n)
    if #grid.cols == 0 then return end

    -- Linearise (col, stop) → flat index
    local pos = cursorStop - 1
    for i = 1, cursorCol - 1 do
      pos = pos + #grid.cols[i].stopPos
    end

    local total = 0
    for _, col in ipairs(grid.cols) do total = total + #col.stopPos end

    pos = util:clamp(pos + n, 0, total - 1)

    -- De-linearise back to (col, stop)
    for i, col in ipairs(grid.cols) do
      if pos < #col.stopPos then
        cursorCol  = i
        cursorStop = pos + 1
        break
      end
      pos = pos - #col.stopPos
    end

    -- Scroll-follow
    scrollCol = util:clamp(scrollCol, 1, #grid.cols)
    if cursorCol < scrollCol then
      scrollCol = cursorCol
    elseif cursorCol > lastVisibleFrom(scrollCol) then
      while scrollCol < cursorCol do
        scrollCol = scrollCol + 1
        if cursorCol <= lastVisibleFrom(scrollCol) then break end
      end
    end
  end

  local function eventAtPos(x, y)
    x = x or cursorCol
    y = y or cursorRow
    local rowData = grid.rows and grid.rows[y]
    return rowData and rowData[x] and rowData[x][1]
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
      
      -- cursor stop positions in each column
      local stopPos = {
        note = {0, 2, 4, 5},      -- C-4 30
        pb = {0, 1, 2, 3},  -- 0200
        cc = {0,1},
        pa = {0,1},
        at = {0,1},
        pc = {0,1},
        sx = {0},
      }

      for chan, channel in tm:channels() do
        local group = util:add(grid.groups, {
          id       = util.IDX,
          label    = channel.label,
          cols     = {}
        })

        for _, column in ipairs(channel.columns) do
          local gridCol = util:pick(column, "id type label events")
          util:assign(gridCol, {
            renderFn = renderFns[gridCol.type] or renderDefault,
            stopPos  = stopPos[gridCol.type] or {0},
            width    = gridCol.type == "note" and 6
                    or gridCol.type == "pb" and 4
                    or 2,
            groupId  = group.id,
            midiChan = chan,
          })
          util:add(grid.cols, gridCol)
          util:add(group.cols, gridCol)
        end
      end

      local numRows = math.max(1, math.ceil(length * rowPerQN / ppqPerQN))

      grid.numRows = numRows
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

      -- Clamp cursor/scroll after layout changes
      scrollRowBy(0)
      scrollStopBy(0)
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

  ---------- EDIT INPUT

  local hexDigit = {}
  for i = 0, 9 do hexDigit[string.byte(tostring(i))] = i end
  for i = 0, 5 do
    hexDigit[string.byte('a') + i] = 10 + i
    hexDigit[string.byte('A') + i] = 10 + i
  end

  local function replaceNibble(old, nibble, d)
    if nibble == 0 then return util:clamp((d << 4) | (old & 0x0F), 0, 127)
    else return util:clamp((old & 0xF0) | d, 0, 127) end
  end

  local currentOctave = 2

  -- Note input layouts: each has two rows of characters matching the
  -- physical piano-key positions (Z-row = base octave, Q-row = +1).
  -- Entries are single-char strings or Unicode codepoints for non-ASCII.
  local noteLayouts = {
    qwerty = {
      { 'z','s','x','d','c','v','g','b','h','n','j','m',',','l','.',';','/' },
      { 'q','2','w','3','e','r','5','t','6','y','7','u','i','9','o','0','p','[','=',']' },
    },
    colemak = {
      { 'z','r','x','s','c','v','d','b','h','k','n','m',',','i','.','o','/' },
      { 'q','2','w','3','f','p','5','g','6','j','7','l','u','9','y','0',';','[','=',']' },
    },
    dvorak = {
      { ';','o','q','e','j','k','i','x','d','b','h','m','w','n','v','s','z' },
      { "'", '2',',','3','.','p','5','y','6','f','7','g','c','9','r','0','l','/',']','=' },
    },
    azerty = {
      { 'w','s','x','d','c','v','g','b','h','n','j',',',';','l',':','m','!' },
      { 'a',233,'z','"','e','r','(','t','-','y',232,'u','i',231,'o',224,'p','^','=','$' },
    },
  }

  local function buildNoteChars(layout)
    local t = {}
    for octOff, row in ipairs(layout) do
      for semi, ch in ipairs(row) do
        local code = type(ch) == 'number' and ch or string.byte(ch)
        t[code] = { semi - 1, octOff - 1 }
      end
    end
    return t
  end

  local noteChars = buildNoteChars(noteLayouts.colemak)

  local function resolveEdit(col, stop, charCode)
    local t = col.type

    -- Note column
    if t == 'note' then
      -- Stop 1 (note name): character-based layout lookup
      if stop == 1 then
        local nk = noteChars[charCode]
        if not nk then return nil end
        local pitch = (currentOctave + 1 + nk[2]) * 12 + nk[1]
        return {
          field = 'pitch',
          apply = function() return util:clamp(pitch, 0, 127) end
        }
      end

      -- Stop 2 (octave): digit sets octave, minus gives -1
      if stop == 2 then
        local oct
        if charCode == string.byte('-') then oct = -1
        else
          local d = charCode - string.byte('0')
          if d < 0 or d > 9 then return nil end
          oct = d
        end
        return {
          field = 'pitch',
          apply = function(old)
            return util:clamp((oct + 1) * 12 + old % 12, 0, 127)
          end
        }
      end

      -- Stops 3,4 (velocity high/low nibble)
      local d = hexDigit[charCode]
      if not d then return nil end
      return {
        field = 'vel',
        apply = function(old) return replaceNibble(old, stop - 3, d) end
      }
    end

    -- CC, PA, AT, PC: 2-nibble hex
    if t == 'cc' or t == 'pa' or t == 'at' or t == 'pc' then
      local d = hexDigit[charCode]
      if not d then return nil end
      return {
        field = 'val',
        apply = function(old) return replaceNibble(old, stop - 1, d) end
      }
    end

    -- PB: 4-digit decimal
    if t == 'pb' then
      local d = charCode - string.byte('0')
      if d < 0 or d > 9 then return nil end
      local pow = ({1000, 100, 10, 1})[stop]
      return {
        field = 'val',
        apply = function(old)
          local place = math.floor(old / pow) % 10
          return util:clamp(old + (d - place) * pow, 0, 8191)
        end
      }
    end

    return nil
  end

  local function applyEdit(type, evt, stop, char)
    -- Note column
    if type == 'note' then
      -- Stop 1 (note name): character-based layout lookup
      if stop == 1 then
        local nk = noteChars[char]
        if not nk then return end
        local pitch = (currentOctave + 1 + nk[2]) * 12 + nk[1]
        return { pitch = util:clamp(pitch, 0, 127) }
      end

      -- Stop 2 (octave): digit sets octave, minus gives -1
      if stop == 2 then
        if not evt then return end
        local oct
        if char == string.byte('-') then oct = -1
        else
          local d = char - string.byte('0')
          if d < 0 or d > 9 then return end
          oct = d
        end
        return { pitch = util:clamp((oct + 1) * 12 + evt.pitch % 12, 0, 127) }
      end

      -- Stops 3,4 (velocity high/low nibble)
      local d = hexDigit[char]
      if not d then return end
      if not evt then return end
      return { vel = replaceNibble(evt.vel, stop - 3, d) }
    end

    -- CC, PA, AT, PC: 2-nibble hex
    if type == 'cc' or type == 'pa' or type == 'at' or type == 'pc' then
      local d = hexDigit[char]
      if not d then return end
      return { val = replaceNibble(evt and evt.val or 0, stop - 1, d) }
    end

    -- PB: 4-digit decimal
    if type == 'pb' then
      local d = char - string.byte('0')
      if d < 0 or d > 9 then return end
      local pow = ({1000, 100, 10, 1})[stop]
      local old = evt and evt.val or 0
      local place = math.floor(old / pow) % 10
      return { val = util:clamp(old + (d - place) * pow, 0, 8191) }
    end

    return nil
  end

  ---------- COMMANDS & KEYMAP

  local commands = {
    cursorDown  = function() scrollRowBy(1) end,
    cursorUp    = function() scrollRowBy(-1) end,
    pageDown    = function() scrollRowBy(gridHeight) end,
    pageUp      = function() scrollRowBy(-gridHeight) end,
    goTop       = function() scrollRowBy(1 - cursorRow) end,
    goBottom    = function() scrollRowBy((grid.numRows or 1) - cursorRow) end,
    cursorRight = function() scrollStopBy(1) end,
    cursorLeft  = function() scrollStopBy(-1) end,
    tabRight    = function()
      local col = grid.cols[cursorCol]
      local nxt = grid.cols[cursorCol + 1]
      if nxt then scrollStopBy(1 - cursorStop + #col.stopPos) end
    end,
    tabLeft     = function()
      local prev = grid.cols[cursorCol - 1]
      scrollStopBy(prev and 1 - cursorStop - #prev.stopPos or 1 - cursorStop)
    end,
  }

  local keymap = {
    cursorDown  = { ImGui.Key_DownArrow  },
    cursorUp    = { ImGui.Key_UpArrow    },
    pageDown    = { ImGui.Key_PageDown   },
    pageUp      = { ImGui.Key_PageUp     },
    goTop       = { ImGui.Key_Home       },
    goBottom    = { ImGui.Key_End        },
    cursorRight = { ImGui.Key_RightArrow },
    cursorLeft  = { ImGui.Key_LeftArrow  },
    tabRight    = { ImGui.Key_Tab },
    tabLeft     = { { ImGui.Key_Tab, ImGui.Mod_Shift } },
  }

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
    local ppq      = cursorRow * ppqPerRow
    local beat     = math.floor(cursorRow / rowPerQN) + 1
    local sub      = (cursorRow % rowPerQN) + 1
    local col      = grid.cols[cursorCol]
    local colLabel = col and col.label or '?'
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, colour('header'))
    ImGui.Text(ctx, string.format(
      "Row: %d | PPQ: %d | Beat: %d.%d | Step: 1/%d | Col: %d (%s) Stop: %d",
      cursorRow, ppq, beat, sub, rowPerQN, cursorCol, colLabel, cursorStop
    ))
    ImGui.PopStyleColor(ctx)
  end

  local function printer(ctx, gridX, gridY)
    local drawList = ImGui.GetWindowDrawList(ctx)
    local px, py   = ImGui.GetCursorScreenPos(ctx)
    local x0, y0   = px + GUTTER * gridX, py + HEADER * gridY
    local halfW    = math.floor(gridX / 2)
    local halfH    = math.floor(gridY / 2)

    local pt = {}

    local function drawTextAt(xpos, ypos, txt, c)
      for char in txt:gmatch(".") do
        ImGui.DrawList_AddText(drawList, xpos, ypos, colour(c), char)
        xpos = xpos + gridX
      end
    end
    
    function pt:text(x, y, txt, c)
      drawTextAt(x0 + x * gridX, y0 + y * gridY, txt, c)
    end

    function pt:textCentred(x1, x2, y, txt, c)
      local textWidth = ImGui.CalcTextSize(ctx, txt)
      local maxWidth  = (x2 - x1 + 1) * gridX
      local offset    = math.max(0, math.floor((maxWidth - textWidth) / 2))
      drawTextAt(x0 + x1 * gridX + offset, y0 + y * gridY, txt, c)
    end

    function pt:vLine(x, y1, y2, c)
      ImGui.DrawList_AddLine(drawList, x0 + x * gridX + halfW, y0 + y1 * gridY, x0 + x * gridX + halfW, y0 + y2 * gridY + gridY, colour(c), 1)
    end

    function pt:hLine(x1, x2, y, c)
      ImGui.DrawList_AddLine(drawList, x0 + x1 * gridX, y0 + y * gridY, x0 + x2 * gridX + gridX, y0 + y * gridY, colour(c), 1)
    end

    function pt:box(x1, x2, y1, y2, c)
      ImGui.DrawList_AddRectFilled(drawList, x0 + x1 * gridX, y0 + y1 * gridY, x0 + x2 * gridX + gridX, y0 + y2 * gridY + gridY, colour(c))
    end

    return pt
  end

  local function drawTracker()
    if not gridX then
      local charW, charH = ImGui.CalcTextSize(ctx, "W")
      gridX              = 2 * math.ceil(charW / 2) -1
      gridY              = 2 * math.ceil(charH / 2) -1
    end

    local windowWidth, windowHeight = ImGui.GetContentRegionAvail(ctx)
    gridWidth  = math.max(1, math.floor(windowWidth  / gridX) - GUTTER)
    gridHeight = math.max(1, math.floor(windowHeight / gridY) - HEADER - 1)
    local numRows = grid.numRows or 0

    -- Clamp cursor/scroll after possible resize
    scrollRowBy(0)
    scrollStopBy(0)

    -- Compute start position for each visible column and its group
    for _, group in ipairs(grid.groups) do
      group.x     = nil
      group.width = 0
      for _, col in ipairs(group.cols) do
        col.x = nil
      end
    end

    local cx = 0
    for i = scrollCol, #grid.cols do
      local col = grid.cols[i]
      if cx + col.width > gridWidth then break end
      col.x = cx
      local group = grid.groups[col.groupId]
      if group then
        if not group.x then group.x = col.x end
        group.width = (col.x + col.width) - group.x
      end
      cx = cx + col.width + 1
    end

    local totalWidth = math.max(0, cx - 1)
    local draw = printer(ctx, gridX, gridY)

    -- Header row 1: group labels
    draw:text(-GUTTER, -HEADER, 'Row', 'accent')
    for _, group in ipairs(grid.groups) do
      if group.x then
        draw:textCentred(group.x, group.x + group.width - 1, -HEADER, group.label, 'accent')
      end
    end

    -- Header row 2: column labels
    for _, col in ipairs(grid.cols) do
      if col.x then draw:text(col.x, -1, col.label) end
    end

    -- Separator below headers
    draw:hLine(-GUTTER, totalWidth - 1, 0, 'header')

    -- Rows
    local rowsPerBar = rowPerQN * 4

    for y = 0, gridHeight - 1 do
      local row = scrollRow + y
      if row >= numRows then break end

      local isBarStart  = (row % rowsPerBar == 0)
      local isBeatStart = (row % rowPerQN   == 0)
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
      draw:text(-GUTTER, y, string.format("%03d", row), rowNumCol)

      -- Cells
      for x, col in ipairs(grid.cols) do
        if col.x then
          local evt = eventAtPos(x, row)
          local text, textCol = col.renderFn(evt)
          draw:text(col.x, y, text, textCol or 'text')
        end
      end
    end

    -- Cursor: 1-char highlight at the current stop position
    local col = grid.cols[cursorCol]
    if col and col.x then
      local stopOffset = (col.stopPos and col.stopPos[cursorStop]) or 0
      local charX = col.x + stopOffset
      draw:box(charX, charX, y, y, 'cursor')
      local evt = eventAtPos()
      local text = col.renderFn(evt)
      local ch = text:sub(stopOffset + 1, stopOffset + 1)
      if ch ~= '' then draw:text(charX, y, ch, 'cursorText') end
    end

    -- Reserve content space so ImGui knows the drawable area
    ImGui.Dummy(ctx, (totalWidth + GUTTER) * gridX, (gridHeight + HEADER) * gridY)

    -- Keyboard
    if ImGui.IsWindowFocused(ctx) then
      for command, keys in pairs(keymap) do
        for _, key in ipairs(keys) do
          local mods = ImGui.Mod_None
          if type(key) == 'table' then
            for i = 2, #key do
              mods = mods | key[i]
            end
            key = key[1]
          end
          if ImGui.IsKeyPressed(ctx, key) and ImGui.GetKeyMods(ctx) == mods then
            commands[command]()
          end
        end
      end

      -- Edit keys: unmodified alphanumeric input
      if ImGui.GetKeyMods(ctx) == ImGui.Mod_None then
        local col = grid.cols[cursorCol]
        if col then
          local type = col.type
          
          -- Character queue: hex/decimal edits, octave changes
          local idx = 0
          while true do
            local rv, char = ImGui.GetInputQueueCharacter(ctx, idx)
            if not rv then break end
            idx = idx + 1

            local evt = eventAtCursor()
            local update = applyEdit(type, evt, cursorStop, char)

            if update and evt then
              tm:assignEvent(type, evt, update)
            elseif update and type ~= 'note' then
              util:assign(update, { ppq = cursorRow * ppqPerRow, chan = col.midiChan })
              if type == 'cc' then
                util:assign(update, { cc = col.id })
              end
              tm:addEvent(type, update)
            end
            scrollRowBy(1)
          end              
        end
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
      | ImGui.WindowFlags_NoDocking
      | ImGui.WindowFlags_NoNav)

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
