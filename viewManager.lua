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
--   vm:attach(tm, cm)   -- attach to a trackerManager; triggers immediate rebuild
--   vm:detach()         -- remove callback from the attached trackerManager
--   vm:rebuild(changed) -- manually trigger a grid rebuild
--
-- GRID STRUCTURE
--   grid.groups  : array of column groups, one per channel
--     Each group: { id, label, firstCol, lastCol }
--
--   grid.cols    : flat array of all grid columns across all channels
--     Each column: { id, type, label, events, width, group, midiChan,
--                    cells = { [y] = event } }
--       width: character width (6 for note columns, 4 for pitchbend, 2 for others)
--       cells: row-indexed events (y is 0-based row index, evt.overflow if >1 at same row)
--
-- DISPLAY PARAMETERS
--   resolution: PPQ per quarter note (from tm:resolution() on take change)
--   rowPerBeat: rows per beat (from config, default 4; beat = 1/denom note)
--   rowPerBar : rows per bar  (rows per beat * numerator of time sig)
--   length    : item length in PPQ
--------------------

loadModule('util')
loadModule('midiManager')
loadModule('trackerManager')

local function print(...)
  return util:print(...)
end

--------------------
-- Factory
--------------------

function newViewManager(tm, cm)

  ---------- PRIVATE STATE

  local resolution   = 240
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

  -- Audition: one pending note-off at a time
  local auditionNote     = nil  -- { chan, pitch } (chan is 0-indexed for MIDI)
  local auditionTime     = 0    -- reaper.time_precise() when note was sent
  local AUDITION_TIMEOUT = 0.8  -- seconds

  local gridWidth   = 0
  local gridHeight  = 0

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
    if ppq >= length then
      return grid.numRows
    end
    local lo, hi = 0, grid.numRows - 1
    while lo < hi do
      local mid = (lo + hi + 1) // 2
      if rowPPQs[mid] <= ppq then lo = mid else hi = mid - 1 end
    end
    return lo
  end

  ---------- AUDITION

  local function killAudition()
    if not auditionNote then return end
    reaper.StuffMIDIMessage(0, 0x80 | auditionNote.chan, auditionNote.pitch, 0)
    auditionNote = nil
  end

  local function audition(pitch, vel, chan)
    killAudition()
    local midiChan = (chan or 1) - 1  -- internal 1-indexed → MIDI 0-indexed
    reaper.StuffMIDIMessage(0, 0x90 | midiChan, pitch, vel or 100)
    auditionNote = { chan = midiChan, pitch = pitch }
    auditionTime = reaper.time_precise()
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

    -- Row follow (skip before gridHeight is set to avoid inverted bounds)
    if gridHeight > 0 then
      local maxScroll = math.max(0, maxRow - gridHeight + 1)
      scrollRow = util:clamp(scrollRow,
        math.max(0, cursorRow - gridHeight + 1),
        math.min(cursorRow, maxScroll))
    end

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
    killAudition()
    if selecting then
      if not sel then selStart() end
    else selClear() end
    cursorRow = cursorRow + n
    clampCursor()
    if selecting then selUpdate() end
  end

  local function scrollStopBy(n, selecting)
    killAudition()
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
    killAudition()
    if #grid.cols == 0 then return end
    selClear()
    cursorCol  = util:clamp(cursorCol + n, 1, #grid.cols)
    cursorStop = 1
    clampCursor()
  end

  local function scrollGroupBy(n)
    killAudition()
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

  local function lastBefore(events, ppq)
    local last
    for _, evt in ipairs(events) do
      if evt.ppq < ppq then last = evt
      elseif evt.ppq >= ppq then break end
    end
    return last
  end

  local function firstNotBefore(events, ppq)
    local next
    for _, evt in ipairs(events) do
      if evt.ppq >= ppq then next = evt; break end
    end
  end
  
  local function firstAfter(events, ppq)
    local next
    for j = #events, 1, -1 do
      local evt = events[j]
      if evt.ppq > ppq then next = evt
      elseif evt.ppq <= ppq then break end
    end
    return next
  end

  local function lastNotAfter(events, ppq)
    local last
    for j = #events, 1, -1 do
      local evt = events[j]
      if evt.ppq <= ppq then last = evt; break end
    end
    return last
  end

  local function truncatePitchInGroup(col, pitch, ppq, excludeEvt)
    local group = col.group
    for ci = group.firstCol, group.lastCol do
      local gc = grid.cols[ci]
      if gc and gc.type == 'note' and gc ~= col then
        for _, evt in ipairs(gc.events) do
          if evt ~= excludeEvt and evt.pitch == pitch
            and evt.ppq <= ppq and evt.endppq > ppq then
            tm:assignEvent('note', evt, { endppq = ppq })
            evt.endppq = ppq
          end
        end
      end
    end
  end

  local function placeNewNote(col, update)
    local last = lastBefore(col.events, update.ppq)
    local next = firstAfter(col.events, update.ppq)
    if last and last.endppq >= update.ppq then
      tm:assignEvent('note', last, { endppq = update.ppq })
    end
    update.vel    = last and last.vel or cfg('defaultVelocity', 100)
    update.endppq = next and next.ppq or length
    update.colID  = col.id
    util:print_r(update)
    tm:addEvent('note', update)
  end

  --- EDIT EVENT
  
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
        local pitch = util:clamp((currentOctave + 1 + nk[2]) * 12 + nk[1], 0, 127)
        local ppq = evt and evt.ppq or rowPPQs[cursorRow]
        truncatePitchInGroup(col, pitch, ppq, evt)
        update = { pitch = pitch }

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
        local pitch = util:clamp((oct + 1) * 12 + evt.pitch % 12, 0, 127)
        truncatePitchInGroup(col, pitch, evt.ppq, evt)
        update = { pitch = pitch }

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
      local place = (old // pow) % 10
      update = { val = util:clamp(old + (d - place) * pow, 0, 8191) }
    end

    if evt then
      tm:assignEvent(type, evt, update)
    else
      util:assign(update, { ppq = rowPPQs[cursorRow], chan = col.midiChan })
      if type == 'note' then
        util:assign(update)
        placeNewNote(col, update)
      elseif type == 'cc' then
        tm:addEvent(type, util:assign(update, { cc = col.id }))
      elseif type == 'at' or type == 'pc' or type == 'pb' or type == 'pa' then
        tm:addEvent(type, util:assign(update, { msgType = type }))
      end
    end

    scrollRowBy(advanceBy)

    -- Audition note on pitch entry
    if type == 'note' and update.pitch then
      local vel = update.vel or (evt and evt.vel) or 100
      audition(update.pitch, vel, col.midiChan)
    end
  end

  ----------  EVENT DELETION

  local function deleteNote(col, note)
    local last = lastBefore(col.events, note.ppq)
    if last and last.endppq >= note.ppq then
      local after = firstAfter(col.events, note.ppq)
      tm:assignEvent('note', last, { endppq = after and after.ppq or length })
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

  ---------- NOTE DURATION

  local function cursorNote()
    local col = grid.cols[cursorCol]
    if not col or col.type ~= 'note' then return end
    local note = col.cells and col.cells[cursorRow]
    if note then return col, note end
    
    local cursorPPQ = rowPPQs[cursorRow]
    if not cursorPPQ then return end
    local last = lastBefore(col.events, cursorPPQ)
    return col, last
  end

  local function overlapLimit(col, note)
    local _, next = firstAfter(col.events, note.ppq)
    if next then return next.ppq + cfg('overlapOffset', 1/16) * resolution end
    return length
  end

  local function noteOff()
    local col = grid.cols[cursorCol]
    if not col or col.type ~= 'note' then return end
    local cursorPPQ = rowPPQs[cursorRow]
    if not cursorPPQ then return end
    
    local last = lastBefore(col.events, cursorPPQ)
    if not last then return end
    if last.endppq == cursorPPQ then
      local next = firstAfter(col.events, cursorPPQ)
      tm:assignEvent('note', last, { endppq = next and next.ppq or length })
    else
      local maxPPQ = overlapLimit(col, last)
      tm:assignEvent('note', last, { endppq = util:clamp(cursorPPQ, last.ppq + 1, maxPPQ) })
    end
  end

  local function adjustDuration(rowDelta, fine)
    local col, note = cursorNote()
    if not note then return end
    local endRow = ppqToRow(note.endppq)
    local rowLen = (rowPPQs[endRow + 1] or length) - (rowPPQs[endRow] or 0)
    local step = fine
      and math.max(1, math.floor(rowLen / cfg('durationFineSteps', 4) + 0.5))
      or rowLen
    local maxPPQ = rowDelta > 0 and overlapLimit(col, note) or length
    local newPPQ = util:clamp(note.endppq + step * rowDelta, note.ppq + 1, maxPPQ)
    tm:assignEvent('note', note, { endppq = newPPQ })
  end

  -- Append note deletion ops (with predecessor endppq fixup) to ops list.
  local function appendDeleteNotes(ops, col, locs)
    local lastSurvivor, pendingFixup = nil, false
    print("RIGHT NOW, OPS IS:")
    util:print_r(ops)
    print("----")
    for _, evt in ipairs(col.events) do
      if locs[evt.loc] then
        if not pendingFixup and lastSurvivor and lastSurvivor.endppq == evt.ppq then
          pendingFixup = true
        end
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
        if isVelOnly  then
          appendResetVelocities(noteOps, col, locs)
        else
          appendDeleteNotes(noteOps, col, locs)
        end
      else
        appendDeleteCCs(ccOps, locs)
      end
    end

    util:print_r(noteOps)
    print("  then  ")
    util:print_r(ccOps)
    if #noteOps > 0 then tm:assignEvents('note', noteOps) end
    if #ccOps > 0 then tm:assignEvents('cc', ccOps) end
    selClear()
  end

  ---------- CLIPBOARD

  local function clipboardSave(clip)
    reaper.SetExtState('rdm', 'clipboard', util:serialise(clip, { loc = true, sourceIdx = true }), false)
  end

  local function clipboardLoad()
    local raw = reaper.GetExtState('rdm', 'clipboard')
    if raw == '' then return nil end
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
    if c1 == c2 then
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
      util:print_r({ mode = 'single', type = clipType, numRows = numRows,
                     sourceIdx = c1, events = events })
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
    util:print_r({ mode = 'multi', numRows = numRows, cols = cols })
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
    local last = lastBefore(dstCol.events, startPPQ)
    local currentVel = last and last.vel or cfg('defaultVelocity', 100)

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

    -- (1) note -> note (pitch selgrp): delete existing, paste with target vels
    if clip.type == 'note' and dstCol.type == 'note' and selGrp == 1 then
      local velList = {}
      for _, evt in ipairs(dstCol.events) do
        if evt.ppq >= startPPQ and evt.ppq < endPPQ and evt.vel > 0 then
          velList[#velList + 1] = { ppq = evt.ppq, val = evt.vel }
        end
      end
      local last = lastBefore(dstCol.events, startPPQ)
      local currentVel = last and last.vel or cfg('defaultVelocity', 100)

      local subseq = firstNotBefore(dstCol.events, endPPQ)
      local afterRegionPPQ = subseq and subseq.ppq or length

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
      print("NOW DELET_OPS IS")
      util:print_r(deleteOps)
      if #deleteOps > 0 then tm:assignEvents('note', deleteOps) end
      if #adds > 0 then tm:addEvents('note', adds) end
      return
    end

    -- (4) 7bit -> note velocity (vel selgrp): carry-forward
    if clip.type == '7bit' and dstCol.type == 'note' and selGrp == 2 then
      pasteVelocities(events, dstCol, startPPQ, endPPQ)
      return
    end

    -- (2) pb -> pb, (3) 7bit -> 7bit: wipe and replace
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
    local noteAddsByCol = {}  -- keyed by 'chan:colID'
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
          local key = dstChan .. ':' .. (srcCol.id or 1)
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
          local next = firstNotBefore(col.events, endPPQ)
          if next then afterPPQ = next.ppq end
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
    local ppq         = rowPPQs[row]
    local ts          = timeSigAt(ppq)
    if not ts then return false, false end
    local offset      = ppq - ts.ppq

    local ppqPerBeat  = resolution * 4 / ts.denom
    local nearestBeat = math.floor(offset / ppqPerBeat + 0.5)
    local isBeatStart = ppqToRow(ts.ppq + nearestBeat * ppqPerBeat) == row

    local ppqPerBar   = ppqPerBeat * ts.num
    local nearestBar  = math.floor(offset / ppqPerBar  + 0.5)
    local isBarStart  = ppqToRow(ts.ppq + nearestBar  * ppqPerBar)  == row
    return isBarStart, isBeatStart
  end

  local function barBeatSub(row)
    local bar = 1
    for i, ts in ipairs(timeSigs) do
      local ppqPerBeat = resolution * 4 / ts.denom
      local ppqPerBar  = ppqPerBeat * ts.num
      local nextPPQ    = timeSigs[i + 1] and timeSigs[i + 1].ppq or math.huge
      local nextRow    = timeSigs[i + 1] and ppqToRow(nextPPQ) or math.huge

      if row < nextRow then
        local ppq      = rowPPQs[row]
        local offset   = ppq - ts.ppq
        local inBar    = offset % ppqPerBar
        local beatNum  = inBar // ppqPerBeat
        local beatPPQ  = ppq - offset % ppqPerBeat
        local beatRow  = ppqToRow(beatPPQ)
        return bar + offset // ppqPerBar,
               beatNum + 1,
               row - beatRow + 1,
               ts
      else
        bar = bar + (nextPPQ - ts.ppq) // ppqPerBar
      end
    end
    return bar, 1, 1, timeSigs[1]
  end

  --------------------
  -- Public interface
  --------------------

  local vm = {}

  -- Exposed state for renderManager
  vm.grid = grid

  function vm:cursor()
    return cursorRow, cursorCol, cursorStop, scrollRow, scrollCol
  end

  function vm:selection() return sel end

  function vm:displayParams()
    return rowPerBeat, rowPerBar, resolution, currentOctave, advanceBy
  end

  function vm:fractionalRow(ppq)
    if ppq >= length then return grid.numRows or 0 end
    local row = ppqToRow(ppq)
    local rowPPQ = rowPPQs[row] or 0
    local nextPPQ = rowPPQs[row + 1] or length
    local rowLen = nextPPQ - rowPPQ
    if rowLen <= 0 then return row end
    return row + (ppq - rowPPQ) / rowLen
  end

  function vm:rowPPQ(row) return rowPPQs[row] end

  function vm:rowBeatInfo(row) return rowBeatInfo(row) end

  function vm:barBeatSub(row) return barBeatSub(row) end

  function vm:lastVisibleFrom(startCol) return lastVisibleFrom(startCol) end

  function vm:setGridSize(w, h)
    gridWidth, gridHeight = w, h
  end

  function vm:setCursor(row, col, stop)
    cursorRow, cursorCol, cursorStop = row, col, stop
    clampCursor()
  end

  function vm:selStart() selStart() end
  function vm:selUpdate() selUpdate() end
  function vm:selClear() selClear() end

  function vm:editEvent(col, evt, stop, char)
    editEvent(col, evt, stop, char)
  end

  function vm:tick()
    if auditionNote and reaper.time_precise() - auditionTime > AUDITION_TIMEOUT then
      killAudition()
    end
  end

  -- Command table — renderManager maps keys to these
  vm.commands = {
    cursorDown     = function() scrollRowBy(1) end,
    cursorUp       = function() scrollRowBy(-1) end,
    pageDown       = function() scrollRowBy(rowPerBar) end,
    pageUp         = function() scrollRowBy(-rowPerBar) end,
    goTop          = function() scrollRowBy(-cursorRow) end,
    goBottom       = function() scrollRowBy((grid.numRows or 1) - cursorRow) end,
    cursorRight    = function() scrollStopBy(1) end,
    cursorLeft     = function() scrollStopBy(-1) end,
    selectDown     = function() scrollRowBy(1, true) end,
    selectUp       = function() scrollRowBy(-1, true) end,
    selectRight    = function() scrollStopBy(1, true) end,
    selectLeft     = function() scrollStopBy(-1, true) end,
    tabRight       = function() scrollGroupBy(1) end,
    tabLeft        = function() scrollGroupBy(-1) end,
    delete         = function() selClear(); deleteEvent(); scrollRowBy(advanceBy) end,
    deleteSel      = function() deleteSelection() end,
    copy           = function() copySelection() end,
    cut            = function() cutSelection() end,
    paste          = function() pasteClipboard() end,
    upOctave       = function() setcfg('take', 'currentOctave', util:clamp(currentOctave+1, -1, 9)) end,
    downOctave     = function() setcfg('take', 'currentOctave', util:clamp(currentOctave-1, -1, 9)) end,
    noteOff        = noteOff,
    growNote       = function() adjustDuration(1, false) end,
    shrinkNote     = function() adjustDuration(-1, false) end,
    growNoteFine   = function() adjustDuration(1, true) end,
    shrinkNoteFine = function() adjustDuration(-1, true) end,
    play           = function() tm:play() end,
    playPause      = function() tm:playPause() end,
    playFromTop    = function() tm:playFrom(0) end,
    playFromCursor = function() tm:playFrom(rowPPQs[cursorRow] or 0) end,
    stop           = function() tm:stop() end,
    addNoteCol     = function() vm:addExtraCol('note') end,
  }

  --- Add an extra view-only column to the current channel.
  --- type: 'note', 'cc', 'pb', 'at', 'pc'. id: CC number or nil.
  function vm:addExtraCol(type, id)
    local col = grid.cols[cursorCol]
    if not col then return end
    local chan = col.midiChan

    if type == 'note' then
      local maxId = 0
      for _, c in ipairs(grid.cols) do
        if c.midiChan == chan and c.type == 'note' and c.id > maxId then maxId = c.id end
      end
      id = maxId + 1
    else
      -- Duplicate check
      for _, c in ipairs(grid.cols) do
        if c.midiChan == chan and c.type == type and c.id == id then return end
      end
    end

    local extras = cfg('extraColumns', {})
    local chanExtras = extras[chan] or {}
    chanExtras[#chanExtras + 1] = { type = type, id = id }
    extras[chan] = chanExtras
    setcfg('take', 'extraColumns', extras)
    vm:rebuild()
  end

  --- Parse a type string like "cc74", "pb", "at", "pc" and add as extra column.
  function vm:addTypedCol(typeStr)
    local type, idStr = typeStr:lower():match('^(%a+)(%d*)$')
    if not type then return end
    local id = idStr ~= '' and tonumber(idStr) or nil

    if type == 'cc' then
      if not id or id < 0 or id > 127 then return end
    elseif type ~= 'pb' and type ~= 'at' and type ~= 'pc' then
      return
    end
    vm:addExtraCol(type, id)
  end

  for i = 0, 9 do
    vm.commands['advBy' .. i] = function() setcfg('take', 'advanceBy', i) end
  end

  ---------- REBUILD

  function vm:rebuild(changed)
    if not tm then return end
    changed = changed or { take = false, data = true }

    if changed.take then
      resolution = tm:resolution()
      length     = tm:length()
      timeSigs   = tm:timeSigs()
      cursorRow  = 0
      cursorCol  = 1
      selClear()
    end

    if changed.take or changed.data then
      advanceBy = cfg('advanceBy', 1)
      currentOctave = cfg('currentOctave', 2)
      rowPerBeat = cfg('rowPerBeat', 4)
      -- Grid resolution is pinned to the first time sig's denominator;
      -- mid-item time sig changes affect bar/beat highlighting but not row size.
      local denom = timeSigs[1] and timeSigs[1].denom or 4
      local num   = timeSigs[1] and timeSigs[1].num or 4
      rowPerBar = rowPerBeat * num
      local ppqPerRow = (resolution * 4 / denom) / rowPerBeat

      grid.cols   = {}
      grid.groups = {}

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

      local function addGridCol(group, chan, type, id, events)
        local colLabels = {
          note = id and id > 1 and ('Note ' .. id) or 'Note',
          cc   = 'CC' .. (id or ''),
          pb   = 'PB',  at = 'AT',  pa = 'PA',  pc = 'PC',
        }
        local gridCol = {
          id        = id,
          type      = type,
          label     = colLabels[type] or '',
          events    = events or {},
          stopPos   = stopPos[type] or {0},
          selGroups = selGroups[type] or {0},
          width     = type == 'note' and 6
                   or type == 'pb' and 4
                   or 2,
          group     = group,
          midiChan  = chan,
          cells     = {},
        }
        util:add(grid.cols, gridCol)
        group.firstCol = group.firstCol or #grid.cols
        group.lastCol  = #grid.cols
      end

      local extras = cfg('extraColumns', {})
      local extrasChanged = false

      for chan, channel in tm:channels() do
        local group = util:add(grid.groups, {
          id       = util.IDX,
          label    = 'Ch ' .. chan,
        })

        for _, column in ipairs(channel.columns) do
          addGridCol(group, chan, column.type, column.id, column.events)
        end

        -- Inject view-only extra columns, pruning any now owned by trackerManager
        local chanExtras = extras[chan]
        if chanExtras then
          local kept = {}
          for _, extra in ipairs(chanExtras) do
            local found = false
            for _, col in ipairs(channel.columns) do
              if col.type == extra.type and col.id == extra.id then
                found = true
                break
              end
            end
            if found then
              extrasChanged = true
            else
              kept[#kept + 1] = extra
              addGridCol(group, chan, extra.type, extra.id)
            end
          end
          extras[chan] = #kept > 0 and kept or nil
          group.extraColumns = extras[chan]
        end
      end

      if extrasChanged then
        setcfg('take', 'extraColumns', next(extras) and extras or nil)
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

  -- LIFECYCLE

  local callback = function(changed, _tm)
    if changed.data or changed.take then
      vm:rebuild(changed)
    end
  end

  local configCallback = function(changed, _cm)
    if changed.config then
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
