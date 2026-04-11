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
--     Each group: { id, label, firstCol, lastCol }
--
--   grid.cols    : flat array of all grid columns across all channels
--     Each column: { id, type, label, events, renderFn, width, group, midiChan,
--                    cells = { [y] = event } }
--       renderFn(evt) -> text, isEmpty
--       width: character width (6 for note columns, 4 for pitchbend, 2 for others)
--       cells: row-indexed events (y is 0-based row index, evt.overflow if >1 at same row)
--
-- DISPLAY PARAMETERS
--   ppqPerQN  : PPQ per quarter note (from tm:reso() on take change)
--   rowPerBeat: rows per beat (from config, default 4; beat = 1/denom note)
--   rowPerBar : rows per bar  (rows per beat * numerator of time sig)
--   ppqPerRow : derived as (ppqPerQN * 4 / denom) / rowPerBeat
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

  ---------- PRIVATE STATE

  local ppqPerRow  = 60
  local ppqPerQN   = 240
  local rowPerBeat = 4
  local rowPerBar  = 16
  local rowPPQs    = {}
  local length     = 0
  local timeSigs   = {}
  local advanceBy  = 1
  local currentOctave = 2

  local scrollCol   = 1
  local scrollRow   = 0
  local cursorCol   = 1
  local cursorStop  = 1
  local cursorRow   = 0
  local sel         = nil   -- { row1, row2, col1, col2, selgrp1, selgrp2 } or nil

  local GUTTER      = 4    -- row-number width in grid chars
  local HEADER      = 2    -- header rows above grid data

  local gridX       = nil
  local gridY       = nil
  local gridOriginX = 0
  local gridOriginY = 0
  local gridWidth   = 0
  local gridHeight  = 0

  local ctx         = nil  -- ImGui handles
  local font        = nil
  local dragging    = false
  local dragWinX, dragWinY = 0, 0

  local grid = {
    cols    = {},
    groups  = {},
  }

  ----------  CONFIG HELPERS

  local function cfg(key, default)
    if cm then
      local val = cm:get(key)
      if val ~= nil then return val end
    end
    return default
  end

  local function setcfg(lev, key, val)
    if cm then cm:set(lev, key, val) end
  end

  ---------- PPQ / ROW MAPPING

  local function ppqToRow(ppq)
    if ppq >= (rowPPQs[grid.numRows - 1] or 0) + ppqPerRow then
      return grid.numRows
    end
    local lo, hi = 0, grid.numRows - 1
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if rowPPQs[mid] <= ppq then lo = mid else hi = mid - 1 end
    end
    return lo
  end

  ---------- SCROLL / CURSOR NAVIGATION

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

  local function clampCursor()
    -- clamp cursor
    local maxRow = math.max(0, (grid.numRows or 1) - 1)
    cursorRow    = util:clamp(cursorRow, 0, maxRow)
    if #grid.cols > 0 then
      cursorCol  = util:clamp(cursorCol, 1, #grid.cols)
      cursorStop = util:clamp(cursorStop, 1, #grid.cols[cursorCol].stopPos)
    end
    
    -- Row follow
    local maxRow    = math.max(0, (grid.numRows or 1) - 1)
    local maxScroll = math.max(0, maxRow - gridHeight + 1)
    scrollRow = util:clamp(scrollRow,
      math.max(0, cursorRow - gridHeight + 1),
      math.min(cursorRow, maxScroll))

    -- Column follow
    if #grid.cols == 0 then return end
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

  local selAnchor = nil  -- { row, col, selgrp } — fixed end of selection

  local function cursorSelGrp()
    local col = grid.cols[cursorCol]
    return col and col.selGroups[cursorStop] or 1
  end

  local function selStart()
    selAnchor = { row = cursorRow, col = cursorCol, selgrp = cursorSelGrp() }
    sel = { row1 = cursorRow, row2 = cursorRow,
            col1 = cursorCol, col2 = cursorCol,
            selgrp1 = selAnchor.selgrp, selgrp2 = selAnchor.selgrp }
  end

  local function selUpdate()
    local a = selAnchor
    local r1, r2 = a.row, cursorRow
    local c1, c2 = a.col, cursorCol
    local g1, g2 = a.selgrp, cursorSelGrp()
    if r1 > r2 then r1, r2 = r2, r1 end
    if c1 > c2 then c1, c2, g1, g2 = c2, c1, g2, g1
    elseif c1 == c2 and g1 > g2 then g1, g2 = g2, g1 end
    sel = { row1 = r1, row2 = r2, col1 = c1, col2 = c2,
            selgrp1 = g1, selgrp2 = g2 }
  end

  local function selClear() sel = nil; selAnchor = nil end

  local function scrollRowBy(n, selecting)
    if selecting then
      if not sel then selStart() end
    else selClear() end
    cursorRow = cursorRow + n
    clampCursor()
    if selecting then selUpdate() end
  end

  local function scrollStopBy(n, selecting)
    if #grid.cols == 0 then return end
    if selecting then
      if not sel then selStart() end
    else selClear() end
    local dir = n > 0 and 1 or -1
    for _ = 1, math.abs(n) do
      local s = cursorStop + dir
      if s > #grid.cols[cursorCol].stopPos then
        if cursorCol >= #grid.cols then break end
        cursorCol  = cursorCol + 1
        cursorStop = 1
      elseif s < 1 then
        if cursorCol <= 1 then break end
        cursorCol  = cursorCol - 1
        cursorStop = #grid.cols[cursorCol].stopPos
      else
        cursorStop = s
      end
    end
    clampCursor()
    if selecting then selUpdate() end
  end

  local function scrollColBy(n)
    if #grid.cols == 0 then return end
    selClear()
    cursorCol  = util:clamp(cursorCol + n, 1, #grid.cols)
    cursorStop = 1
    clampCursor()
  end

  local function scrollGroupBy(n)
    if #grid.cols == 0 then return end
    selClear()
    local groupId = grid.cols[cursorCol].group.id
    local newGroupId = util:clamp(groupId + n, 1, #grid.groups)
    cursorCol  = grid.groups[newGroupId].firstCol
    cursorStop = 1
    clampCursor()
  end

  ---------- ADD/EDIT EVENTS
  

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

  local function neighbours(events, ppq)
    local last, next
    for _, evt in ipairs(events) do
      if evt.ppq < ppq then last = evt
      elseif evt.ppq > ppq then next = evt; break end
    end
    return last, next
  end

  local function placeNewNote(col, update)
    local last, next = neighbours(col.events, update.ppq)
    if last then
      tm:assignEvent('note', last, { endppq = update.ppq })
    end
    update.vel = last and last.vel or cfg('defaultVelocity', 100)
    update.endppq = next and next.ppq or length
    tm:addEvent('note', update)
  end

  local function editEvent(col, evt, stop, char)
    if not col then return end
    local type = col.type
    local update
    
    -- Note column
    if type == 'note' then
      -- Stop 1 (note name): character-based layout lookup
      if stop == 1 then
        local nk = noteChars[char]
        if not nk then return end
        local pitch = (currentOctave + 1 + nk[2]) * 12 + nk[1]
        update = { pitch = util:clamp(pitch, 0, 127) }

      -- Stop 2 (octave): digit sets octave, minus gives -1
      elseif stop == 2 then
        if not evt then return end
        local oct
        if char == string.byte('-') then oct = -1
        else
          local d = char - string.byte('0')
          if d < 0 or d > 9 then return end
          oct = d
        end
        update = { pitch = util:clamp((oct + 1) * 12 + evt.pitch % 12, 0, 127) }

      -- Stops 3,4 (velocity high/low nibble)
      else
        local d = hexDigit[char]
        if not d then return end
        if not evt then return end
        update = { vel = util:clamp(replaceNibble(evt.vel, stop - 3, d), 1, 127) }
      end

    -- CC, PA, AT, PC: 2-nibble hex
    elseif type == 'cc' or type == 'pa' or type == 'at' or type == 'pc' then
      local d = hexDigit[char]
      if not d then return end
      update = { val = replaceNibble(evt and evt.val or 0, stop - 1, d) }

    -- PB: 4-digit decimal
    elseif type == 'pb' then
      local d = char - string.byte('0')
      if d < 0 or d > 9 then return end
      local pow = ({1000, 100, 10, 1})[stop]
      local old = evt and evt.val or 0
      local place = math.floor(old / pow) % 10
      update = { val = util:clamp(old + (d - place) * pow, 0, 8191) }
    end

    if evt then
      tm:assignEvent(type, evt, update)
    else
      util:assign(update, { ppq = rowPPQs[cursorRow], chan = col.midiChan })
      if type == 'note' then
        return placeNewNote(col, update)
      end
      if type == 'cc' then
        util:assign(update, { cc = col.id })
      end
      if type == 'at' or type == 'pc' or type == 'pb' or type == 'pa' then
        util:assign(update, { msgType = type })
      end
      tm:addEvent(type, update)
    end
  end
  
  ----------  EVENT DELETION

  local function deleteNote(col, note)
    local last, next = neighbours(col.events, note.ppq)
    if last then
      tm:assignEvent('note', last, { endppq = next and next.ppq or length })
    end
    tm:deleteEvent('note', note)
  end

  local function deleteEvent()
    local col = grid.cols[cursorCol]
    local evt = col and col.cells and col.cells[cursorRow]
    if col and evt then
      if col.type == 'note' then
        deleteNote(col, evt)
      else
        tm:deleteEvent(col.type, evt)
      end
    end
  end

  -- Append note deletion ops (with predecessor endppq fixup) to ops list.
  local function appendDeleteNotes(ops, col, locs)
    local lastSurvivor, pendingFixup = nil, false
    for _, evt in ipairs(col.events) do
      if locs[evt.loc] then
        pendingFixup = true
      else
        if pendingFixup and lastSurvivor then
          ops[#ops + 1] = { lastSurvivor, { endppq = evt.ppq } }
        end
        pendingFixup = false
        lastSurvivor = evt
      end
    end
    if pendingFixup and lastSurvivor then
      ops[#ops + 1] = { lastSurvivor, { endppq = length } }
    end
    for _, evt in pairs(locs) do
      ops[#ops + 1] = { evt, { loc = util.REMOVE } }
    end
  end

  -- Append velocity reset ops to ops list.
  local function appendResetVelocities(ops, col, locs)
    local prevVel = cfg('defaultVelocity', 100)
    for _, evt in ipairs(col.events) do
      if locs[evt.loc] then
        ops[#ops + 1] = { evt, { vel = prevVel } }
      else
        prevVel = evt.vel
      end
    end
  end

  -- Append CC deletion ops to ops list.
  local function appendDeleteCCs(ops, locs)
    for _, evt in pairs(locs) do
      ops[#ops + 1] = { evt, { loc = util.REMOVE } }
    end
  end

  ---------- SELECTION OPERATIONS

  local function selBounds()
    local r1, r2, c1, c2, g1, g2
    if sel then
      r1, r2 = sel.row1, sel.row2
      c1, c2 = sel.col1, sel.col2
      g1, g2 = sel.selgrp1, sel.selgrp2
    else
      r1, r2 = cursorRow, cursorRow
      c1, c2 = cursorCol, cursorCol
      g1, g2 = cursorSelGrp(), cursorSelGrp()
    end
    return r1, r2, c1, c2, g1, g2, rowPPQs[r1], rowPPQs[r2 + 1] or length
  end

  local function selectedEvents()
    local r1, r2, c1, c2, g1, g2, startPPQ, endPPQ = selBounds()
    local singleCol = c1 == c2 and g1 == g2
    local isVelOnly = singleCol and grid.cols[c1]
      and grid.cols[c1].type == 'note' and g1 > 1

    local result = {}
    for ci = c1, c2 do
      local col = grid.cols[ci]
      if not col then goto nextCol end

      local locs = {}
      for _, evt in ipairs(col.events) do
        if evt.ppq >= startPPQ and evt.ppq < endPPQ then
          locs[evt.loc] = evt
        end
      end

      result[#result + 1] = { col = col, locs = locs }
      ::nextCol::
    end

    return result, isVelOnly
  end

  local function deleteSelection()
    local groups, isVelOnly = selectedEvents()
    local noteOps, ccOps = {}, {}

    for _, group in ipairs(groups) do
      local col, locs = group.col, group.locs
      if col.type == 'note' then
        if isVelOnly then
          appendResetVelocities(noteOps, col, locs)
        else
          appendDeleteNotes(noteOps, col, locs)
        end
      else
        appendDeleteCCs(ccOps, locs)
      end
    end

    if #noteOps > 0 then tm:assignEvents('note', noteOps) end
    if #ccOps > 0 then tm:assignEvents('cc', ccOps) end
    selClear()
  end

  ---------- CLIPBOARD

  local CLIP_SECTION = "rdm"
  local CLIP_KEY     = "clipboard"

  local function clipboardSave(clip)
    reaper.SetExtState(CLIP_SECTION, CLIP_KEY,
      util:serialise(clip, { loc = true, sourceIdx = true }), false)
  end

  local function clipboardLoad()
    local raw = reaper.GetExtState(CLIP_SECTION, CLIP_KEY)
    if raw == "" then return nil end
    return util:unserialise(raw)
  end

  local function collectSelection()
    local r1, r2, c1, c2, g1, g2, startPPQ, endPPQ = selBounds()
    local numRows  = r2 - r1 + 1

    local function fractionalRow(ppq)
      local absRow = ppqToRow(ppq)
      local rowStart = rowPPQs[absRow]
      local rowEnd = rowPPQs[absRow + 1] or length
      local frac = (rowEnd > rowStart) and (ppq - rowStart) / (rowEnd - rowStart) or 0
      return absRow - r1 + frac
    end

    local function noteEvent(evt)
      local ce = { row = fractionalRow(evt.ppq),
                   pitch = evt.pitch, vel = evt.vel, loc = evt.loc }
      if evt.endppq and evt.endppq < endPPQ then
        ce.endRow = fractionalRow(evt.endppq)
      end
      return ce
    end

    local function scalarEvent(evt, val)
      return { row = fractionalRow(evt.ppq), val = val, loc = evt.loc }
    end

    -- Single-column mode
    if c1 == c2 and g1 == g2 then
      local col = grid.cols[c1]
      if not col then return nil end

      local clipType, events = nil, {}
      if col.type == 'note' and g1 == 1 then
        clipType = 'note'
        for _, evt in ipairs(col.events) do
          if evt.ppq >= startPPQ and evt.ppq < endPPQ then
            events[#events + 1] = noteEvent(evt)
          end
        end
      elseif col.type == 'note' and g1 == 2 then
        clipType = '7bit'
        for _, evt in ipairs(col.events) do
          if evt.ppq >= startPPQ and evt.ppq < endPPQ then
            events[#events + 1] = scalarEvent(evt, evt.vel)
          end
        end
      elseif col.type == 'pb' then
        clipType = 'pb'
        for _, evt in ipairs(col.events) do
          if evt.ppq >= startPPQ and evt.ppq < endPPQ then
            events[#events + 1] = scalarEvent(evt, evt.val)
          end
        end
      else
        clipType = '7bit'
        for _, evt in ipairs(col.events) do
          if evt.ppq >= startPPQ and evt.ppq < endPPQ then
            events[#events + 1] = scalarEvent(evt, evt.val)
          end
        end
      end

      if #events == 0 then return nil end
      return { mode = 'single', type = clipType, numRows = numRows,
               sourceIdx = c1, events = events }
    end

    -- Multi-column mode
    local cols = {}
    for ci = c1, c2 do
      local col = grid.cols[ci]
      if not col then goto nextCol end
      local events = {}

      for _, evt in ipairs(col.events) do
        if evt.ppq >= startPPQ and evt.ppq < endPPQ then
          if col.type == 'note' then
            events[#events + 1] = noteEvent(evt)
          elseif col.type == 'pb' then
            events[#events + 1] = scalarEvent(evt, evt.rawVal)
          else
            events[#events + 1] = scalarEvent(evt, evt.val)
          end
        end
      end

      cols[#cols + 1] = {
        type = col.type, id = col.id, midiChan = col.midiChan,
        sourceIdx = ci, events = events,
      }
      ::nextCol::
    end

    if #cols == 0 then return nil end
    return { mode = 'multi', numRows = numRows, cols = cols }
  end

  local function copySelection()
    local clip = collectSelection()
    if clip then clipboardSave(clip) end
  end

  local function cutSelection()
    copySelection()
    deleteSelection()
  end

  local function rowToPPQ(baseRow, fractRow)
    local k = math.floor(fractRow)
    local frac = fractRow - k
    local absRow = baseRow + k
    local rowStart = rowPPQs[absRow]
    if not rowStart then return nil end
    local rowEnd = rowPPQs[absRow + 1] or length
    return math.floor(rowStart + frac * (rowEnd - rowStart) + 0.5)
  end

  local function pasteVelocities(events, dstCol, startPPQ, endPPQ)
    local currentVel = cfg('defaultVelocity', 100)
    for _, evt in ipairs(dstCol.events) do
      if evt.ppq >= startPPQ then break end
      currentVel = evt.vel
    end

    local ops = {}
    local ci = 1
    for _, evt in ipairs(dstCol.events) do
      if evt.ppq >= startPPQ and evt.ppq < endPPQ then
        while ci <= #events and events[ci].ppq <= evt.ppq do
          if events[ci].val > 0 then
            currentVel = util:clamp(events[ci].val, 1, 127)
          end
          ci = ci + 1
        end
        ops[#ops + 1] = { evt, { vel = currentVel } }
      end
    end
    if #ops > 0 then tm:assignEvents('note', ops) end
  end

  local function pasteSingle(clip)
    local dstCol = grid.cols[cursorCol]
    if not dstCol then return end
    local startPPQ = rowPPQs[cursorRow]
    local endPPQ = rowPPQs[cursorRow + clip.numRows] or length
    local selGrp = cursorSelGrp()

    -- Resolve clipboard events to target PPQs, truncating past end
    local events = {}
    for _, ce in ipairs(clip.events) do
      local ppq = rowToPPQ(cursorRow, ce.row)
      if not ppq or ppq >= endPPQ then goto nextCe end
      local e = util:assign({ ppq = ppq }, ce)
      if ce.endRow then
        local ep = rowToPPQ(cursorRow, ce.endRow)
        e.endppq = ep and math.min(ep, endPPQ) or endPPQ
      end
      events[#events + 1] = e
      ::nextCe::
    end
    table.sort(events, function(a, b) return a.ppq < b.ppq end)

    -- (1) note → note (pitch selgrp): delete existing, paste with target vels
    if clip.type == 'note' and dstCol.type == 'note' and selGrp == 1 then
      local velList = {}
      for _, evt in ipairs(dstCol.events) do
        if evt.ppq >= startPPQ and evt.ppq < endPPQ and evt.vel > 0 then
          velList[#velList + 1] = { ppq = evt.ppq, val = evt.vel }
        end
      end
      local currentVel = cfg('defaultVelocity', 100)
      for _, evt in ipairs(dstCol.events) do
        if evt.ppq >= startPPQ then break end
        currentVel = evt.vel
      end

      local afterRegionPPQ = length
      for _, evt in ipairs(dstCol.events) do
        if evt.ppq >= endPPQ then afterRegionPPQ = evt.ppq; break end
      end

      local locs = {}
      for _, evt in ipairs(dstCol.events) do
        if evt.ppq >= startPPQ and evt.ppq < endPPQ then
          locs[evt.loc] = evt
        end
      end
      local deleteOps = {}
      appendDeleteNotes(deleteOps, dstCol, locs)

      local adds = {}
      local vi = 1
      for _, ce in ipairs(events) do
        while vi <= #velList and velList[vi].ppq <= ce.ppq do
          currentVel = util:clamp(velList[vi].val, 1, 127)
          vi = vi + 1
        end
        adds[#adds + 1] = {
          ppq = ce.ppq,
          endppq = ce.endppq or afterRegionPPQ,
          chan = dstCol.midiChan, pitch = ce.pitch, vel = currentVel,
        }
      end

      if #deleteOps > 0 then tm:assignEvents('note', deleteOps) end
      if #adds > 0 then tm:addEvents('note', adds) end
      return
    end

    -- (4) 7bit → note velocity (vel selgrp): carry-forward
    if clip.type == '7bit' and dstCol.type == 'note' and selGrp == 2 then
      pasteVelocities(events, dstCol, startPPQ, endPPQ)
      return
    end

    -- (2) pb → pb, (3) 7bit → 7bit: wipe and replace
    if (clip.type == 'pb' and dstCol.type == 'pb')
    or (clip.type == '7bit' and dstCol.type ~= 'note' and dstCol.type ~= 'pb') then
      local delOps = {}
      for _, evt in ipairs(dstCol.events) do
        if evt.ppq >= startPPQ and evt.ppq < endPPQ then
          delOps[#delOps + 1] = { evt, { loc = util.REMOVE } }
        end
      end

      local adds = {}
      for _, ce in ipairs(events) do
        local add = { ppq = ce.ppq, chan = dstCol.midiChan, val = ce.val }
        if dstCol.type == 'cc' then add.msgType = 'cc'; add.cc = dstCol.id
        else add.msgType = dstCol.type end
        adds[#adds + 1] = add
      end

      if #delOps > 0 then tm:assignEvents('cc', delOps) end
      if #adds > 0 then tm:addEvents('cc', adds) end
      return
    end
  end

  local function pasteMulti(clip)
    local dstCol = grid.cols[cursorCol]
    if not dstCol then return end
    local chanOffset = dstCol.midiChan - clip.cols[1].midiChan
    local endPPQ = rowPPQs[cursorRow + clip.numRows] or length

    -- Resolve all clipboard events to target PPQs
    local noteAddsByCol = {}  -- keyed by "chan:colID"
    local ccAdds = {}

    for _, srcCol in ipairs(clip.cols) do
      local dstChan = util:clamp(srcCol.midiChan + chanOffset, 1, 16)

      for _, ce in ipairs(srcCol.events) do
        local targetPPQ = rowToPPQ(cursorRow, ce.row)
        if not targetPPQ or targetPPQ >= endPPQ then goto nextCe end

        if srcCol.type == 'note' then
          local endNPQ
          if ce.endRow then
            local ep = rowToPPQ(cursorRow, ce.endRow)
            endNPQ = ep and math.min(ep, endPPQ) or endPPQ
          end
          local key = dstChan .. ":" .. (srcCol.id or 1)
          if not noteAddsByCol[key] then
            noteAddsByCol[key] = { chan = dstChan, colID = srcCol.id or 1, adds = {} }
          end
          local adds = noteAddsByCol[key].adds
          adds[#adds + 1] = {
            ppq = targetPPQ, endppq = endNPQ,
            chan = dstChan, pitch = ce.pitch, vel = ce.vel,
            colID = srcCol.id or 1,
          }
        else
          local add = { ppq = targetPPQ, chan = dstChan, val = ce.val }
          if srcCol.type == 'pb' then add.msgType = 'pb'
          elseif srcCol.type == 'cc' then add.msgType = 'cc'; add.cc = srcCol.id
          else add.msgType = srcCol.type end
          ccAdds[#ccAdds + 1] = add
        end
        ::nextCe::
      end
    end

    -- Resolve endppq per note column group
    local startPPQ = rowPPQs[cursorRow]
    local allNoteAdds = {}
    for _, group in pairs(noteAddsByCol) do
      -- Find matching destination column for afterRegionPPQ
      local afterPPQ = length
      for _, col in ipairs(grid.cols) do
        if col.type == 'note' and col.midiChan == group.chan and col.id == group.colID then
          for _, evt in ipairs(col.events) do
            if evt.ppq >= endPPQ then afterPPQ = evt.ppq; break end
          end
          break
        end
      end

      local adds = group.adds
      table.sort(adds, function(a, b) return a.ppq < b.ppq end)
      for _, add in ipairs(adds) do
        add.endppq = add.endppq or afterPPQ
        allNoteAdds[#allNoteAdds + 1] = add
      end
    end

    if #allNoteAdds > 0 then tm:addEvents('note', allNoteAdds) end
    if #ccAdds > 0 then tm:addEvents('cc', ccAdds) end
  end

  local function pasteClipboard()
    local clip = clipboardLoad()
    if not clip then return end
    if clip.mode == 'single' then
      pasteSingle(clip)
    else
      pasteMulti(clip)
    end
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

  ---------- TIME SIGNATURE HELPERS

  local function timeSigAt(ppq)
    local active = timeSigs[1]
    for i = 2, #timeSigs do
      if timeSigs[i].ppq <= ppq then active = timeSigs[i]
      else break end
    end
    return active
  end

  local function rowBeatInfo(row)
    local ppq = rowPPQs[row]
    local ts = timeSigAt(ppq)
    if not ts then return false, false end
    local ppqPerBeat = ppqPerQN * 4 / ts.denom
    local ppqPerBar  = ppqPerBeat * ts.num
    local offset     = ppq - ts.ppq
    local nearestBeat = math.floor(offset / ppqPerBeat + 0.5)
    local nearestBar  = math.floor(offset / ppqPerBar  + 0.5)
    local isBeatStart = ppqToRow(ts.ppq + nearestBeat * ppqPerBeat) == row
    local isBarStart  = ppqToRow(ts.ppq + nearestBar  * ppqPerBar)  == row
    return isBarStart, isBeatStart
  end

  local function barBeatSub(row)
    local bar = 1
    for i, ts in ipairs(timeSigs) do
      local ppqPerBeat = ppqPerQN * 4 / ts.denom
      local ppqPerBar  = ppqPerBeat * ts.num
      local nextPPQ    = timeSigs[i + 1] and timeSigs[i + 1].ppq or math.huge
      local nextRow    = timeSigs[i + 1] and ppqToRow(nextPPQ) or math.huge

      if row < nextRow then
        local ppq      = rowPPQs[row]
        local offset   = ppq - ts.ppq
        local inBar    = offset % ppqPerBar
        local beatNum  = math.floor(inBar / ppqPerBeat)
        local beatPPQ  = ts.ppq + math.floor(offset / ppqPerBar) * ppqPerBar + beatNum * ppqPerBeat
        local beatRow  = ppqToRow(beatPPQ)
        return bar + math.floor(offset / ppqPerBar),
               beatNum + 1,
               row - beatRow + 1,
               ts
      else
        bar = bar + math.floor((nextPPQ - ts.ppq) / ppqPerBar)
      end
    end
    return bar, 1, 1, timeSigs[1]
  end

  ---------- CELL RENDERERS

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
    return noteTxt .. ' ' .. velTxt, evt.overflow and 'overflow'
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

  local function printer(ctx, gridX, gridY, x0, y0)
    local drawList = ImGui.GetWindowDrawList(ctx)
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

  local function drawToolbar()
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, colour('header'))
    ImGui.Text(ctx, "Rows/beat:")
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
        cursorRow = math.floor(cursorRow * s / rowPerBeat)
        setcfg("track", "rowPerBeat", s)
      end
      if isActive then ImGui.PopStyleColor(ctx, 2) end
      ImGui.SameLine(ctx)
    end

    ImGui.NewLine(ctx)
    ImGui.Separator(ctx)
  end

  local function drawTracker()
    if not gridX then
      local charW, charH = ImGui.CalcTextSize(ctx, "W")
      gridX              = 2 * math.ceil(charW / 2) -1
      gridY              = 2 * math.ceil(charH / 2) -1
    end

    local px, py = ImGui.GetCursorScreenPos(ctx)
    gridOriginX  = px + GUTTER * gridX
    gridOriginY  = py + HEADER * gridY

    local windowWidth, windowHeight = ImGui.GetContentRegionAvail(ctx)
    gridWidth  = math.max(1, math.floor(windowWidth  / gridX) - GUTTER)
    gridHeight = math.max(1, math.floor(windowHeight / gridY) - HEADER - 1)
    local numRows = grid.numRows or 0

    -- Clamp cursor/scroll after possible resize
    clampCursor()

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
      if col.x then draw:text(col.x, -1, col.label) end
    end

    -- Separator below headers
    draw:hLine(-GUTTER, totalWidth - 1, 0, 'header')

    -- Rows
    for y = 0, gridHeight - 1 do
      local row = scrollRow + y
      if row >= numRows then break end

      local isBarStart, isBeatStart = rowBeatInfo(row)
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
          local evt = col.cells and col.cells[row]
          local text, textCol = col.renderFn(evt)
          draw:text(col.x, y, text, textCol or 'text')
        end
      end
    end

    -- Selection highlight
    if sel and sel.col2 >= scrollCol and sel.col1 <= lastVisibleFrom(scrollCol) then
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
      draw:box(charX, charX, charY, charY, 'cursor')
      local evt = col.cells and col.cells[cursorRow]
      local text = col.renderFn(evt)
      local ch = text:sub(stopOffset + 1, stopOffset + 1)
      if ch ~= '' then draw:text(charX, charY, ch, 'cursorText') end
    end

    -- Reserve content space so ImGui knows the drawable area
    ImGui.Dummy(ctx, (totalWidth + GUTTER) * gridX, (gridHeight + HEADER) * gridY)
  end

  local function drawStatusBar()
    local ppq      = rowPPQs[cursorRow]
    local bar, beat, sub, ts = barBeatSub(cursorRow)
    local col      = grid.cols[cursorCol]
    local colLabel = col and col.label or '?'
    local tsLabel  = ts and string.format("%d/%d", ts.num, ts.denom) or "?"

    ImGui.Separator(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, colour('header'))
    ImGui.Text(ctx, string.format(
      "%s | PPQ: %d | %d:%d.%d/%d | Octave: %d | Advance: %d",
      colLabel, math.floor(ppq), bar, beat, sub, rowPerBeat, currentOctave, advanceBy
    ))
    ImGui.PopStyleColor(ctx)
  end

  ---------- COMMANDS & KEYBOARD

  local commands = {
    cursorDown  = function() scrollRowBy(1) end,
    cursorUp    = function() scrollRowBy(-1) end,
    pageDown    = function() scrollRowBy(rowPerBar) end,
    pageUp      = function() scrollRowBy(-rowPerBar) end,
    goTop       = function() scrollRowBy(1 - cursorRow) end,
    goBottom    = function() scrollRowBy((grid.numRows or 1) - cursorRow) end,
    cursorRight = function() scrollStopBy(1) end,
    cursorLeft  = function() scrollStopBy(-1) end,
    selectDown  = function() scrollRowBy(1, true) end,
    selectUp    = function() scrollRowBy(-1, true) end,
    selectRight = function() scrollStopBy(1, true) end,
    selectLeft  = function() scrollStopBy(-1, true) end,
    tabRight    = function() scrollGroupBy(1) end,
    tabLeft     = function() scrollGroupBy(-1) end,
    delete      = function() selClear(); deleteEvent(); scrollRowBy(advanceBy) end,
    deleteSel   = function() deleteSelection() end,
    copy        = function() copySelection() end,
    cut         = function() cutSelection() end,
    paste       = function() pasteClipboard() end,
    upOctave    = function() setcfg('take', 'currentOctave', util:clamp(currentOctave+1, -1, 9)) end,
    downOctave  = function() setcfg('take', 'currentOctave', util:clamp(currentOctave-1, -1, 9)) end,
  }

  for i = 0, 9 do
    commands["advBy" .. i] = function() setcfg('take', 'advanceBy', i) end
  end

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
    copy        = { { ImGui.Key_C, ImGui.Mod_Shortcut } },
    cut         = { { ImGui.Key_X, ImGui.Mod_Shortcut } },
    paste       = { { ImGui.Key_V, ImGui.Mod_Shortcut } },
    quit        = { ImGui.Key_Enter },
    upOctave    = { { ImGui.Key_8,  ImGui.Mod_Shift } },
    downOctave  = { ImGui.Key_Slash },
  }

  for i = 0, 9 do
    keymap["advBy" .. i] = { { ImGui.Key_0 + i, ImGui.Mod_Ctrl } }
  end

  local function nearestStop(mouseX, mouseY)
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
        if not sel then selStart() end
        cursorRow, cursorCol, cursorStop = scrollRow + charY, col, stop
        clampCursor()
        selUpdate()
      else
        selClear()
        cursorRow, cursorCol, cursorStop = scrollRow + charY, col, stop
        clampCursor()
        dragging = true
        dragWinX, dragWinY = ImGui.GetWindowPos(ctx)
      end

    elseif dragging and held then
      local mouseX, mouseY = ImGui.GetMousePos(ctx)
      local charY = math.floor((mouseY - gridOriginY) / gridY)
      local row = scrollRow + charY
      local fracX = (mouseX - gridOriginX) / gridX
      local lastVis = lastVisibleFrom(scrollCol)
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
        if not sel then selStart() end
        cursorRow, cursorCol, cursorStop = row, col, stop
        clampCursor()
        selUpdate()
      end

    elseif dragging and not held then
      dragging = false
    end
  end

  local function handleKeys()
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
          if ImGui.IsKeyDown(ctx, key) then commandHeld = true end
          if ImGui.IsKeyPressed(ctx, key) and ImGui.GetKeyMods(ctx) == mods then
            if command == 'quit' then
              return true
            else
              commands[command]()
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
          local type = col.type

          -- Character queue: hex/decimal edits, octave changes
          local idx = 0
          while true do
            local rv, char = ImGui.GetInputQueueCharacter(ctx, idx)
            if not rv then break end
            idx = idx + 1

            local evt = col.cells and col.cells[cursorRow]
            editEvent(col, evt, cursorStop, char)
            scrollRowBy(advanceBy)
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

  ---------- REBUILD

  function vm:rebuild(changed)
    if not tm then return end
    changed = changed or { take = false, data = true }

    if changed.take then
      ppqPerQN  = tm:reso()
      length    = tm:length()
      timeSigs  = tm:timeSigs()
      cursorRow = 0
      cursorCol = 1
      selClear()
    end

    if changed.take or changed.data then
      advanceBy = cfg('advanceBy', 1)
      currentOctave = cfg('currentOctave', 2)
      rowPerBeat = cfg("rowPerBeat", 4)
      -- Grid resolution is pinned to the first time sig's denominator;
      -- mid-item time sig changes affect bar/beat highlighting but not row size.
      local denom = timeSigs[1] and timeSigs[1].denom or 4
      local num   = timeSigs[1] and timeSigs[1].num or 4
      rowPerBar = rowPerBeat * num
      ppqPerRow = (ppqPerQN * 4 / denom) / rowPerBeat

      grid.cols   = {}
      grid.groups = {}

      local renderFns = {
        note = renderNote,
        pb   = renderPB,
        cc   = renderCC,
        pa   = renderCC,
        at   = renderCC,
        pc   = renderCC,
      }

      -- cursor stop positions in each column
      local stopPos = {
        note = {0, 2, 4, 5},   -- C-4 30
        pb = {0,1,2,3},        -- 0200
        cc = {0,1},            -- 94
        pa = {0,1},
        at = {0,1},
        pc = {0,1},
      }

      -- assigns stop positions to selection groups (for marking)
      local selGroups = {
        note = {1, 1, 2, 2},      -- C-4 30
        pb = {1, 1, 1, 1},        -- 0200
        cc = {1,1},               -- 94
        pa = {1,1},
        at = {1,1},
        pc = {1,1},
      }

      for chan, channel in tm:channels() do
        local group = util:add(grid.groups, {
          id       = util.IDX,
          label    = channel.label,
        })

        for _, column in ipairs(channel.columns) do
          local gridCol = util:pick(column, "id type label events")
          util:assign(gridCol, {
            renderFn = renderFns[gridCol.type] or renderDefault,
            stopPos  = stopPos[gridCol.type] or {0},
            selGroups= selGroups[gridCol.type] or {0},
            width    = gridCol.type == "note" and 6
                    or gridCol.type == "pb" and 4
                    or 2,
            group    = group,
            midiChan = chan,
            cells    = {},
          })
          util:add(grid.cols, gridCol)
          group.firstCol = group.firstCol or #grid.cols
          group.lastCol  = #grid.cols
        end
      end

      rowPPQs = {}
      local r = 0
      while true do
        local ppq = math.floor(r * ppqPerRow + 0.5)
        if ppq >= length and r > 0 then break end
        rowPPQs[r] = ppq
        r = r + 1
      end

      local numRows = r
      grid.numRows = numRows

      for _, gridCol in ipairs(grid.cols) do
        for _, evt in ipairs(gridCol.events) do
          local y = ppqToRow(evt.ppq or 0)
          if y >= 0 and y < numRows then
            if gridCol.cells[y] then
              gridCol.cells[y].overflow = true
            else
              gridCol.cells[y] = evt
            end
          end
        end
      end

      -- Clamp cursor/scroll after layout changes
      clampCursor()
    end
  end

  function vm:loop()
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
      if #grid.cols > 0 then
        drawToolbar()
        drawTracker()
        drawStatusBar()
        handleMouse()
        quit = handleKeys()
      else
        ImGui.Text(ctx, "Select a MIDI item to begin.")
      end

      ImGui.End(ctx)
    end

    ImGui.PopStyleColor(ctx, styleCount)
    ImGui.PopFont(ctx)

    return open and not quit
  end

  -- LIFECYCLE

  local callback = function(changed, _tm)
    if changed.data or changed.take then
      vm:rebuild(changed)
    end
  end

  local configCallback = function(changed, _cm)
    if changed.config then
      colourCache = {}
      vm:rebuild({ take = false, data = true })
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
