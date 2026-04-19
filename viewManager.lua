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
--   grid.chanFirstCol, grid.chanLastCol : dense 1..16, first/last grid.cols
--     index belonging to each MIDI channel.
--
--   grid.cols    : flat array of all grid columns across all channels
--     Each column: { id, type, label, events, width, midiChan,
--                    cells = { [y] = event }, overflow = { [y] = true } }
--       width: character width (6 for note columns, 4 for pitchbend, 2 for others)
--       cells: row-indexed events (y is 0-based row index)
--       overflow: rows where >1 event landed (only the first is kept in cells)
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
loadModule('microtuning')

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
  local swing      = { apply = function(_, p) return p end,
                       unapply = function(_, p) return p end }
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
    cols         = {},
    chanFirstCol = {},
    chanLastCol  = {},
  }

  -- Scalar column types whose consecutive events can be interpolated and
  -- ghost-rendered. pa lives inside note columns and is not (yet) supported.
  local ghostable = { cc = true, pb = true, at = true, pc = true }

  -- Interpolation shape cycle. 'step' means no interpolation (no ghosts);
  -- 'bezier' is excluded from the cycle but honoured if already set.
  local shapeCycle = { 'step', 'linear', 'slow', 'fast-start', 'fast-end' }
  local function nextShape(s)
    for i, n in ipairs(shapeCycle) do
      if n == s then return shapeCycle[(i % #shapeCycle) + 1] end
    end
    return 'linear'
  end

  -- Lane of a note grid column: its 1-indexed position among note
  -- columns in the same channel. Returns nil for non-note columns.
  local function laneOf(col)
    if not (col and col.type == 'note') then return end
    local lane = 0
    for ci = grid.chanFirstCol[col.midiChan], grid.chanLastCol[col.midiChan] do
      local c = grid.cols[ci]
      if c.type == 'note' then
        lane = lane + 1
        if c == col then return lane end
      end
    end
  end

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

  ---------- CHANNEL MUTE / SOLO
  --
  -- mute and solo are both take-persisted maps ({[chan]=true}), treated
  -- identically in code. Effective mute = persistent mute ∪ solo-implied
  -- mute: when any channel is soloed, non-soloed channels are forced
  -- muted and soloed channels are forced audible (DAW convention — solo
  -- overrides the persistent mute flag). Persisting both is necessary so
  -- that on reload tm's lastMuteSet matches the muted flags already on
  -- the MIDI wire; otherwise reopening a take where solo had silenced
  -- channels would unmute them.

  local effectiveMuted = {}  -- cached for cheap per-cell render queries

  local function recomputeEffectiveMute()
    local m = util:clone(cfg('mutedChannels', {}) or {})
    local s = cfg('soloedChannels', {}) or {}
    if next(s) then
      for c = 1, 16 do
        if s[c] then m[c] = nil
        else        m[c] = true end
      end
    end
    effectiveMuted = m
  end

  local function pushMute()
    recomputeEffectiveMute()
    if tm then tm:setMutedChannels(effectiveMuted) end
  end

  local function toggleChannelFlag(key, chan)
    local s = util:clone(cfg(key, {}) or {})
    s[chan] = (not s[chan]) or nil
    setcfg('take', key, s)
  end

  ---------- MICROTUNING LENS

  local function activeTuning()
    local name = cfg('tuning', nil)
    return name and microtuning.findTuning(name) or nil
  end

  -- Project a note event onto the active tuning. Returns label, gap, halfGap
  -- (both in cents), or nil if no tuning is active / evt is not a note.
  --   gap     = note.cents − displayedStepCents   (sharp is positive)
  --   halfGap = half the distance to the nearest neighbour step, used to
  --             normalise gap so full deflection = "just about to snap to
  --             the next step" regardless of step density.
  local function noteProjection(evt)
    local tuning = activeTuning()
    if not (tuning and evt and evt.pitch) then return end
    local detune    = evt.detune or 0
    local step, oct = microtuning.midiToStep(tuning, evt.pitch, detune)
    local label     = microtuning.stepToText(tuning, step, oct)
    local tm_, td_  = microtuning.stepToMidi(tuning, step, oct)
    local gap       = (evt.pitch * 100 + detune) - (tm_ * 100 + td_)

    local steps, n, period = tuning.cents, #tuning.cents, tuning.period
    local left    = step == 1 and steps[n] - period or steps[step - 1]
    local right   = step == n and steps[1] + period or steps[step + 1]
    local halfGap = math.min(steps[step] - left, right - steps[step]) / 2

    return label, gap, halfGap
  end

  ---------- PPQ / ROW MAPPING

  local function ppqToRow(ppq)
    if ppq <= 0 then return 0 end
    if ppq >= length then return grid.numRows end
    local lo, hi = 0, grid.numRows - 1
    while lo < hi do
      local mid = (lo + hi + 1) // 2
      if rowPPQs[mid] <= ppq then lo = mid else hi = mid - 1 end
    end
    local rowStart = rowPPQs[lo]
    local rowEnd = rowPPQs[lo + 1] or length
    return lo + (rowEnd > rowStart and (ppq - rowStart) / (rowEnd - rowStart) or 0)
  end

  local function rowToPPQ(row)
    if row <= 0 then return 0 end
    if row >= grid.numRows then return length end
    local r = math.floor(row)
    local frac = row - r
    local rowStart = rowPPQs[r]
    local rowEnd = rowPPQs[r + 1] or length
    return math.floor(rowStart + frac * (rowEnd - rowStart) + 0.5)
  end

  -- Per-channel row↔PPQ: compose the straight-grid map with the channel's
  -- effective swing. PPQs on both sides are intent (delay-stripped by tm);
  -- swing is the only transform between row space and intent space.
  local function rowToPPQ_c(chan, row) return math.floor(swing.apply(chan, rowToPPQ(row)))   end
  local function ppqToRow_c(chan, ppq) return ppqToRow(swing.unapply(chan, ppq)) end

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

  local selAnchor = nil  -- { row, col, stop } — fixed end of selection
  local hBlockScope   = 0    -- 0 inactive, 1 col, 2 channel, 3 all
  local vBlockScope   = 0    -- 0 inactive, 1 beat, 2 bar, 3 all-rows
  local function inBlock() return hBlockScope > 0 or vBlockScope > 0 end
  -- Drop the sticky flags but leave sel/selAnchor intact, so the just-edited
  -- region stays visible while the next cursor move clears it.
  local function unstick() hBlockScope, vBlockScope = 0, 0 end

  local function selGrpAt(col, stop)
    local c = grid.cols[col]
    return c and c.selGroups[stop] or 1
  end

  local function cursorSelGrp() return selGrpAt(cursorCol, cursorStop) end

  local function firstStopForSelGrp(col, g)
    local c = grid.cols[col]
    if not c then return 1 end
    for s, gg in ipairs(c.selGroups) do
      if gg == g then return s end
    end
    return 1
  end

  local function selStart()
    selAnchor = { row = cursorRow, col = cursorCol, stop = cursorStop }
    local g = cursorSelGrp()
    sel = { row1 = cursorRow, row2 = cursorRow,
            col1 = cursorCol, col2 = cursorCol,
            selgrp1 = g, selgrp2 = g }
  end

  local function selUpdate()
    local a = selAnchor
    local numRows = grid.numRows or 1

    local r1, r2
    if vBlockScope == 1 or vBlockScope == 2 then
      local unit = vBlockScope == 1 and rowPerBeat or rowPerBar
      r1 = math.floor(cursorRow / unit) * unit
      r2 = math.min(r1 + unit - 1, numRows - 1)
    elseif vBlockScope == 3 then
      r1, r2 = 0, numRows - 1
    else
      r1, r2 = a.row, cursorRow
      if r1 > r2 then r1, r2 = r2, r1 end
    end

    local c1, c2, g1, g2
    if hBlockScope == 2 then
      local chan = grid.cols[cursorCol].midiChan
      c1, c2 = grid.chanFirstCol[chan], grid.chanLastCol[chan]
      g1, g2 = 1, math.huge
    elseif hBlockScope == 3 then
      c1, c2 = 1, #grid.cols
      g1, g2 = 1, math.huge
    else
      c1, c2 = a.col, cursorCol
      g1, g2 = selGrpAt(a.col, a.stop), cursorSelGrp()
      if c1 > c2 then c1, c2, g1, g2 = c2, c1, g2, g1
      elseif c1 == c2 and g1 > g2 then g1, g2 = g2, g1 end
    end
    sel = { row1 = r1, row2 = r2, col1 = c1, col2 = c2,
            selgrp1 = g1, selgrp2 = g2 }
  end

  local function selClear()
    sel = nil; selAnchor = nil
    hBlockScope = 0; vBlockScope = 0; lastCycleRow = nil
  end

  -- First press anchors scope 1. Repeated presses cycle sticky:
  -- 1 (col) → 2 (channel) → 3 (all) → 1. selClear exits block mode.
  local function cycleBlock()
    if #grid.cols == 0 then return end
    if not inBlock() then
      selAnchor  = { row = cursorRow, col = cursorCol, stop = cursorStop }
      hBlockScope = 1
    else
      hBlockScope = (hBlockScope % 3) + 1
    end
    selUpdate()
  end

  -- Mirror of cycleBlock on the vertical axis.
  -- 1 (beat) → 2 (bar) → 3 (all rows) → 1. Composes freely with hBlockScope.
  local function cycleVBlock()
    if (grid.numRows or 0) == 0 then return end
    if not inBlock() then
      selAnchor   = { row = cursorRow, col = cursorCol, stop = cursorStop }
      vBlockScope = 1
    else
      vBlockScope = (vBlockScope % 3) + 1
    end
    selUpdate()
  end

  local function swapBlockEnds()
    if not (sel and selAnchor) then return end
    if vBlockScope < 1 then
      selAnchor.row, cursorRow = cursorRow, selAnchor.row
    end
    if hBlockScope < 2 then
      selAnchor.col,  cursorCol  = cursorCol,  selAnchor.col
      selAnchor.stop, cursorStop = cursorStop, selAnchor.stop
    end
    clampCursor()
    selUpdate()
  end

  local function scrollRowBy(n, selecting)
    killAudition()
    if selecting or inBlock() then
      if not sel then selStart() end
    else selClear() end
    cursorRow = cursorRow + n
    clampCursor()
    if selecting or inBlock() then selUpdate() end
  end

  local function scrollStopBy(n, selecting)
    killAudition()
    if #grid.cols == 0 then return end
    if selecting or inBlock() then
      if not sel then selStart() end
    else selClear() end
    if hBlockScope >= 2 and selAnchor then
      selAnchor.col  = cursorCol
      selAnchor.stop = cursorStop
      hBlockScope     = 1
    end
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
    if selecting or inBlock() then selUpdate() end
  end

  -- Scroll left/right by |n| "units", where a unit is defined by the caller's
  -- toFirstStop/toLastStop closures (a column, a group, ...). 
  local function scrollUnitBy(n, toFirstStop, toLastStop)
    killAudition()
    if #grid.cols == 0 then return end
    if not inBlock() then selClear() end
    local sgn = n > 0 and 1 or -1

    if inBlock() then
      for _ = 1, math.abs(n) do
        if     sgn ==  1 and cursorCol >= selAnchor.col then scrollStopBy(1);  toLastStop()
        elseif sgn ==  1                                then toLastStop();     scrollStopBy(1)
        elseif sgn == -1 and cursorCol <= selAnchor.col then scrollStopBy(-1); toFirstStop()
        else                                                 toFirstStop();    scrollStopBy(-1)
        end
      end
    else
      for _ = 1, math.abs(n) do
        if sgn == 1 then toLastStop();  scrollStopBy(1)
        else             toFirstStop(); scrollStopBy(-1); toFirstStop()
        end
      end
    end
    if inBlock() then selUpdate() end
  end

  local function scrollColBy(n)
    scrollUnitBy(n,
      function()
        cursorStop = 1
        if inBlock() and cursorCol == selAnchor.col and #grid.cols[cursorCol].selGroups == 1 then
          scrollStopBy(1)
          cursorStop = #grid.cols[cursorCol].stopPos
        end
      end,
      function()
        cursorStop = #grid.cols[cursorCol].stopPos
        if inBlock() and cursorCol == selAnchor.col and #grid.cols[cursorCol].selGroups == 1 then
          scrollStopBy(1)
          cursorStop = #grid.cols[cursorCol].stopPos
        end
    end)
  end

  local function scrollChannelBy(n)
    local function chanRange()
      local chan = grid.cols[cursorCol].midiChan
      return grid.chanFirstCol[chan], grid.chanLastCol[chan]
    end
    scrollUnitBy(n,
      function()
        local first, _ = chanRange()
        cursorCol, cursorStop = first, 1
      end,
      function()
        local _, last = chanRange()
        cursorCol  = last
        cursorStop = #grid.cols[cursorCol].stopPos
      end)
    -- pc/pb sit left of the note column, so the raw scroll lands on pc.
    -- Snap forward to the first note column of the landing channel.
    if not inBlock() then
      local first, last = chanRange()
      for ci = first, last do
        if grid.cols[ci].type == 'note' then
          cursorCol, cursorStop = ci, 1
          break
        end
      end
    end
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

  -- Writes digit `d` at place `pos` (0 = ones, 1 = next up, …) in numeric `base`,
  -- zeroing all lower places and keeping higher ones. `half` adds place/2 to
  -- support shift-digit half-step entry.
  local function setDigit(val, d, pos, base, half)
    local place = base ^ pos // 1
    local above = val - (val % (place * base))
    return above + d * place + (half and place // 2 or 0)
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

  local function isNote(e) return e and e.endppq end

  -- between: iterate events with ppq in [lo, hi). Assumes ppq-sorted input.
  local function between(events, lo, hi, filter)
    filter = filter or function(e) return true end
    local i = 0
    return function()
      while true do
        i = i + 1
        local evt = events[i]
        if not evt or evt.ppq >= hi then return end
        if evt.ppq >= lo and filter(evt) then return evt end
      end
    end
  end

  local function truncatePitchInChannel(chan, pitch, ppq, exclCol, excludeEvt)
    for ci = grid.chanFirstCol[chan], grid.chanLastCol[chan] do
      local gc = grid.cols[ci]
      if gc and gc.type == 'note' and gc ~= exclCol then
        for _, evt in ipairs(gc.events) do
          if evt ~= excludeEvt and isNote(evt) and evt.pitch == pitch
            and evt.ppq <= ppq and evt.endppq > ppq then
            if evt.ppq == ppq then
              tm:deleteEvent('note', evt)
            else
              tm:assignEvent('note', evt, { endppq = ppq })
              evt.endppq = ppq
            end
          end
        end
      end
    end
  end

  local function placeNewNote(col, update)
    local last = util:seek(col.events, 'before', update.ppq, isNote)
    local next = util:seek(col.events, 'after',  update.ppq, isNote)
    if last and last.endppq >= update.ppq then
      tm:assignEvent('note', last, { endppq = update.ppq })
    end
    update.vel    = last and last.vel or cfg('defaultVelocity', 100)
    update.endppq = next and next.ppq or length
    update.lane   = laneOf(col)
    tm:addEvent('note', update)
  end

  ----------  PA HELPERS

  local function notePAEvents(col, pitch, startPPQ, endPPQ)
    local pas = {}
    for _, evt in ipairs(col.events) do
      if evt.type == 'pa' and evt.pitch == pitch
        and evt.ppq >= startPPQ and evt.ppq <= endPPQ then
        util:add(pas, evt)
      end
    end
    return pas
  end

  -- Realised-frame overlap bounds for any note anchored at straight ppq in
  -- col, ignoring excludeEvt (e.g. the note being edited). col.events is
  -- already per-lane and straight-sorted; neighbours' own delays are folded
  -- in so the bound is truly realised. When allowOverlap is true the bound
  -- is relaxed by overlapOffset on each side; otherwise it is strict.
  -- Returns (minRealStart, maxRealEnd).
  local function overlapBounds(col, ppq, excludeEvt, allowOverlap)
    local off  = allowOverlap and cfg('overlapOffset', 1/16) * resolution or 0
    local pred = excludeEvt
      and function(e) return isNote(e) and e ~= excludeEvt end
      or isNote
    local prev = util:seek(col.events, 'before', ppq, pred)
    local next = util:seek(col.events, 'after',  ppq, pred)
    local minStart = prev and (prev.endppq + tm:delayToPPQ(prev.delay) - off) or 0
    local maxEnd   = next and (next.ppq    + tm:delayToPPQ(next.delay) + off) or length
    return minStart, maxEnd
  end

  -- Valid delay range (milliQN) for n given its column's realised overlap
  -- bounds. The note's realised start must clear prev; its realised end
  -- must not run into next. Overlap-allowed so neighbouring notes may
  -- skim within overlapOffset.
  local function delayRange(col, n)
    local minStart, maxEnd = overlapBounds(col, n.ppq, n, true)
    return tm:ppqToDelay(minStart - n.ppq), tm:ppqToDelay(maxEnd - n.endppq)
  end

  --- EDIT EVENT
  
  local function editEvent(col, evt, stop, char, half)
    if not col then return end
    local type = col.type
    local cursorPPQ = rowToPPQ_c(col.midiChan, cursorRow)

    local function commit(auditionPitch, auditionVel)
      tm:flush()
      scrollRowBy(advanceBy)
      if auditionPitch then audition(auditionPitch, auditionVel or 100, col.midiChan) end
    end

    -- Writing an event's primary value on an off-grid cell snaps its
    -- intent time to the row the user is editing. Delay survives; tm
    -- re-realises on assign. Endppq shifts by the same delta so straight
    -- duration is preserved.
    local function snap(update)
      if not evt or evt.ppq == cursorPPQ then return update end
      update.ppq = cursorPPQ
      if evt.endppq then update.endppq = cursorPPQ + (evt.endppq - evt.ppq) end
      return update
    end

    ---------- NOTE COLUMN
    if type == 'note' then

      -- Stop 1: note name
      if stop == 1 then
        local nk = noteChars[char]; if not nk then return end
        local pitch = util:clamp((currentOctave + 1 + nk[2]) * 12 + nk[1], 0, 127)
        local detune = 0
        local tuning = activeTuning()
        if tuning then pitch, detune = microtuning.snap(tuning, pitch, 0) end
        truncatePitchInChannel(col.midiChan, pitch, cursorPPQ, col, evt)

        -- Existing note → repitch, snapping intent time to the cursor row
        if isNote(evt) then
          tm:retuneNote(evt, snap({ pitch = pitch, detune = detune }))
          return commit(pitch, evt.vel)
        end

        -- PA cell → wipe host's PA tail, then fall through
        if evt and evt.type == 'pa' then
          local host = util:seek(col.events, 'before', evt.ppq, isNote)
          if host and host.endppq > evt.ppq then
            for _, pa in ipairs(notePAEvents(col, host.pitch, evt.ppq, host.endppq)) do
              tm:deleteEvent('pa', pa)
            end
          else
            tm:deleteEvent('pa', evt)
          end
        end

        local new = { pitch = pitch, detune = detune, ppq = cursorPPQ, chan = col.midiChan }
        placeNewNote(col, new)
        return commit(pitch, new.vel)

      -- Stop 2: octave (only on real notes)
      elseif stop == 2 then
        if not isNote(evt) then return end
        local oct
        if char == string.byte('-') then oct = -1
        else
          local d = char - string.byte('0')
          if d < 0 or d > 9 then return end
          oct = d
        end
        local pitch = util:clamp((oct + 1) * 12 + evt.pitch % 12, 0, 127)
        truncatePitchInChannel(col.midiChan, pitch, evt.ppq, col, evt)
        tm:assignEvent('note', evt, { pitch = pitch })
        return commit(pitch, evt.vel)

      -- Stops 5,6,7: delay (signed, decimal, milli-QN; 3 digits, ±999)
      elseif stop == 5 or stop == 6 or stop == 7 then
        if not isNote(evt) then return end
        local old = evt.delay or 0

        local newDelay
        if char == string.byte('-') then
          if old == 0 then return end
          newDelay = -old
        else
          local d = char - string.byte('0')
          if d < 0 or d > 9 then return end
          local sign = old < 0 and -1 or 1
          local mag  = util:clamp(setDigit(math.abs(old), d, 7 - stop, 10, half), 0, 999)
          newDelay = sign * mag
        end

        local minD, maxD = delayRange(col, evt)
        newDelay = util:clamp(newDelay, math.ceil(minD), math.floor(maxD))
        tm:assignEvent('note', evt, { delay = newDelay })
        return commit()

      -- Stops 3,4: velocity (on note) or PA nibble
      else
        local d = hexDigit[char]; if not d then return end
        local function newVel(old)
          return util:clamp(setDigit(old, d, 4 - stop, 16, half), 1, 127)
        end

        if evt and evt.type == 'pa' then
          tm:assignEvent('pa', evt, snap({ val = newVel(evt.val) }))
          return commit()
        end

        if evt then
          tm:assignEvent('note', evt, { vel = newVel(evt.vel) })
          return commit()
        end

        if cfg('polyAftertouch', true) then
          local note = util:seek(col.events, 'before', cursorPPQ, isNote)
          if note and note.endppq > cursorPPQ then
            local val = newVel(0)
            tm:addEvent('pa', {
              ppq = cursorPPQ, chan = col.midiChan,
              pitch = note.pitch, val = val
            })
            return commit()
          end
        end
        return
      end
    end

    ---------- OTHER COLUMNS
    local update
    if util:oneOf('cc at pc', type) then
      local d = hexDigit[char]; if not d then return end
      update = { val = util:clamp(setDigit(evt and evt.val or 0, d, 2 - stop, 16, half), 0, 127) }
    elseif type == 'pb' then
      local old = evt and evt.val or 0
      if char == string.byte('-') then
        if old == 0 then return end
        update = { val = -old }
      else
        local d = char - string.byte('0')
        if d < 0 or d > 9 then return end
        local sign = old < 0 and -1 or 1
        update = { val = sign * setDigit(math.abs(old), d, 4 - stop, 10, half) }
      end
    else
      return
    end
    
    if evt then
      tm:assignEvent(type, evt, snap(update))
    else
      if type == 'cc' then util:assign(update, { cc = col.cc }) end
      util:assign(update, { ppq = cursorPPQ, chan = col.midiChan })
      tm:addEvent(type, update)
    end
    commit()
  end

  ----------  EVENT DELETION

  local function deleteNote(col, note)
    local P = note.ppq
    tm:deleteEvent('note', note)

    local last = util:seek(col.events, 'before', P, isNote)
    if last and last.endppq >= note.ppq then
      local after = util:seek(col.events, 'after', P, isNote)
      tm:assignEvent('note', last, { endppq = after and after.ppq or length })
    end
    tm:flush()
  end

  local function deleteEvent()
    local col = grid.cols[cursorCol]
    if not col then return end
    local evt = col.cells and col.cells[cursorRow]
    if not evt then
      -- Delete on a ghost cell: unset interpolation on the governing event.
      local ghost = col.ghosts and col.ghosts[cursorRow]
      if ghost then
        tm:assignEvent(col.type, ghost.fromEvt, { shape = 'step' })
        tm:flush()
      end
      return
    end

    if col.type ~= 'note' then
      tm:deleteEvent(col.type, evt)
      return tm:flush()
    end

    local selGrp = cursorSelGrp()
    if evt.type == 'pa' then
      if selGrp == 2 then tm:deleteEvent('pa', evt); tm:flush() end
    elseif selGrp == 2 then
      local prev = util:seek(col.events, 'before', evt.ppq, isNote)
      tm:assignEvent('note', evt, { vel = (prev and prev.vel) or cfg('defaultVelocity', 100) })
      tm:flush()
    elseif selGrp == 3 then
      local chan = col.midiChan
      local base = rowToPPQ_c(chan, math.floor(ppqToRow_c(chan, evt.ppq)))
      local minStart = overlapBounds(col, evt.ppq, evt, false)
      if base ~= evt.ppq and base >= minStart and base < evt.endppq then
        tm:assignEvent('note', evt, { ppq = base })
        tm:flush()
      end
    else
      deleteNote(col, evt)
    end
  end

  ---------- SELECTION OPERATIONS
  
  local function selBounds()
    if sel then
      return sel.row1, sel.row2, sel.col1, sel.col2, sel.selgrp1, sel.selgrp2
    end
    local g = cursorSelGrp()
    return cursorRow, cursorRow, cursorCol, cursorCol, g, g
  end

  -- PPQ span of the selection's row range in the given column's own swing
  -- frame. Rows are the user's mental model; per-column swing means two
  -- columns over the same row range cover different intent-PPQ spans.
  local function selBoundsFor(col, r1, r2)
    return rowToPPQ_c(col.midiChan, r1), rowToPPQ_c(col.midiChan, r2 + 1)
  end

  local function selectedEvents()
    local r1, r2, c1, c2, g1, g2 = selBounds()
    local singleNoteCol = c1 == c2 and g1 == g2
      and grid.cols[c1] and grid.cols[c1].type == 'note'
    local noteMode = 'delete'
    if singleNoteCol and g1 == 2 then noteMode = 'vel'
    elseif singleNoteCol and g1 == 3 then noteMode = 'delay' end

    local result = {}
    for ci = c1, c2 do
      local col = grid.cols[ci]
      if not col then goto nextCol end

      local startPPQ, endPPQ = selBoundsFor(col, r1, r2)
      local locs = {}
      for evt in between(col.events, startPPQ, endPPQ) do
        locs[evt.loc] = evt
      end

      util:add(result, { col = col, locs = locs })
      ::nextCol::
    end
    return result, noteMode
  end

  ---------- INTERPOLATION

  -- Cycle the shape of A (governing pair A→next) forward one step.
  local function cycleShape(col, A)
    if not A then return end
    tm:assignEvent(col.type, A, { shape = nextShape(A.shape or 'step') })
  end

  -- Ctrl-I. Selection: advance every interior pair's shape in each scalar
  -- column; solo: cycle the pair at the cursor, whether on a ghost or on
  -- the real event that starts the pair.
  local function interpolate()
    if sel then
      local r1, r2, c1, c2 = selBounds()
      for ci = c1, c2 do
        local col = grid.cols[ci]
        if col and ghostable[col.type] then
          local startPPQ, endPPQ = selBoundsFor(col, r1, r2)
          local prev
          for evt in between(col.events, startPPQ, endPPQ) do
            if prev then cycleShape(col, prev) end
            prev = evt
          end
        end
      end
      tm:flush()
      return
    end

    local col = grid.cols[cursorCol]
    if not (col and ghostable[col.type]) then return end
    local ghost = col.ghosts and col.ghosts[cursorRow]
    local A = ghost and ghost.fromEvt
              or (col.cells and col.cells[cursorRow])
              or util:seek(col.events, 'before', rowToPPQ_c(col.midiChan, cursorRow + 1))
    if A then cycleShape(col, A); tm:flush() end
  end

  ---------- NOTE DURATION

  local function cursorNoteBefore()
    local col = grid.cols[cursorCol]
    if not (col and col.type == 'note') then return end
    local cursorPPQ = rowToPPQ_c(col.midiChan, cursorRow)
    return col, util:seek(col.events, 'at-or-before', cursorPPQ, isNote)
  end

  local function cursorNoteAfter()
    local col = grid.cols[cursorCol]
    if not (col and col.type == 'note') then return end
    local cursorPPQ = rowToPPQ_c(col.midiChan, cursorRow)
    return col, util:seek(col.events, 'at-or-after', cursorPPQ, isNote)
  end

  -- First event in col that starts anywhere in the cursor row. For note
  -- columns, PAs are skipped.
  local function cursorRowEvent(col)
    if not col then return end
    local lo, hi = rowToPPQ_c(col.midiChan, cursorRow), rowToPPQ_c(col.midiChan, cursorRow + 1)
    local pred = col.type == 'note' and isNote or nil
    local evt = util:seek(col.events, 'at-or-after', lo, pred)
    if evt and evt.ppq < hi then return evt end
  end

  local function applyNoteOff(col, last, targetPPQ, undo)
    if undo then
      local next = util:seek(col.events, 'at-or-after', targetPPQ, isNote)
      tm:assignEvent('note', last, { endppq = next and next.ppq or length })
    elseif last.ppq >= targetPPQ then
      tm:deleteEvent('note', last)
    else
      local _, maxEnd = overlapBounds(col, last.ppq, last, true)
      tm:assignEvent('note', last, { endppq = util:clamp(targetPPQ, last.ppq + 1, maxEnd) })
    end
  end

  local function noteOff()
    if sel then
      local hits = {}
      for ci = sel.col1, sel.col2 do
        local col = grid.cols[ci]
        if col and col.type == 'note' then
          local chan = col.midiChan
          local targetPPQ = rowToPPQ_c(chan, sel.row1)
          local nextPPQ   = rowToPPQ_c(chan, sel.row1 + 1)
          local last = util:seek(col.events, 'before', nextPPQ, isNote)
          if last then util:add(hits, { col = col, note = last, targetPPQ = targetPPQ }) end
        end
      end
      if #hits == 0 then return end

      local undo = true
      for _, h in ipairs(hits) do
        if h.note.endppq ~= h.targetPPQ then undo = false; break end
      end

      for _, h in ipairs(hits) do applyNoteOff(h.col, h.note, h.targetPPQ, undo) end
      tm:flush()
      return
    end

    local col = grid.cols[cursorCol]
    if not (col and col.type == 'note' and cursorSelGrp() == 1) then return 'fallthrough' end
    local cursorPPQ     = rowToPPQ_c(col.midiChan, cursorRow)
    local nextCursorPPQ = rowToPPQ_c(col.midiChan, cursorRow + 1)

    local last = util:seek(col.events, 'before', nextCursorPPQ, isNote)
    if not last then return end
    applyNoteOff(col, last, cursorPPQ, last.endppq == cursorPPQ)
    tm:flush()
  end

  local function adjustDurationCore(col, note, rowDelta)
    local chan = col.midiChan
    local newRow = util:clamp(ppqToRow_c(chan, note.endppq) + rowDelta, 0, grid.numRows)
          newRow = math.floor(newRow / rowDelta) * rowDelta
    local minPPQ = math.min(note.endppq, rowToPPQ_c(chan, math.floor(ppqToRow_c(chan, note.ppq)) + 1))
    local _, maxPPQ = overlapBounds(col, note.ppq, note, true)
    local newPPQ = util:clamp(rowToPPQ_c(chan, newRow), minPPQ, maxPPQ)
    tm:assignEvent('note', note, { endppq = newPPQ })
  end

  local function adjustDuration(rowDelta)
    if sel then
      for _, group in ipairs(selectedEvents()) do
        if group.col.type == 'note' then
          for _, note in pairs(group.locs) do
            adjustDurationCore(group.col, note, rowDelta)
          end
        end
      end
    else
      local col, note = cursorNoteBefore()
      if note then adjustDurationCore(col, note, rowDelta) end
    end
    tm:flush()
  end

  local function adjustPositionMulti(rowDelta)
    if rowDelta == 0 then return end
    local runs = {}
    for _, g in ipairs(selectedEvents()) do
      if g.col.type == 'note' then
        local chan = g.col.midiChan
        local ns = {}
        for _, n in pairs(g.locs) do util:add(ns, n) end
        if #ns > 0 then
          table.sort(ns, function(a, b) return a.ppq < b.ppq end)
          if rowDelta > 0 then
            local _, maxEnd = overlapBounds(g.col, ns[#ns].ppq, ns[#ns], false)
            local room = math.floor(ppqToRow_c(chan, maxEnd) - ppqToRow_c(chan, ns[#ns].endppq))
            if room < rowDelta then return end
          else
            local minStart = overlapBounds(g.col, ns[1].ppq, ns[1], false)
            local room = math.ceil(ppqToRow_c(chan, minStart) - ppqToRow_c(chan, ns[1].ppq))
            if room > rowDelta then return end
          end
          util:add(runs, { col = g.col, notes = ns })
        end
      end
    end
    if #runs == 0 then return end

    -- resizeNote moves PBs in the note's ppq range; within each run, process in
    -- the direction that keeps shifted PBs out of unprocessed notes' ranges.
    for _, r in ipairs(runs) do
      local chan = r.col.midiChan
      local notes = r.notes
      local s, e, step = 1, #notes, 1
      if rowDelta > 0 then s, e, step = #notes, 1, -1 end
      for i = s, e, step do
        local n = notes[i]
        tm:assignEvent('note', n, {
          ppq    = rowToPPQ_c(chan, ppqToRow_c(chan, n.ppq)    + rowDelta),
          endppq = rowToPPQ_c(chan, ppqToRow_c(chan, n.endppq) + rowDelta),
        })
      end
    end
    tm:flush()

    local maxRow = grid.numRows - 1
    sel.row1      = util:clamp(sel.row1      + rowDelta, 0, maxRow)
    sel.row2      = util:clamp(sel.row2      + rowDelta, 0, maxRow)
    selAnchor.row = util:clamp(selAnchor.row + rowDelta, 0, maxRow)
    cursorRow     = cursorRow + rowDelta
    clampCursor()
  end

  local function adjustPosition(rowDelta)
    if sel then return adjustPositionMulti(rowDelta) end

    local col, note = cursorNoteBefore()
    if not note then return end
    local chan = col.midiChan

    local absDelta = math.abs(rowDelta)
    local rawRow   = ppqToRow_c(chan, note.ppq) + rowDelta
    local reqRow   = (rowDelta > 0 and math.ceil(rawRow / absDelta) or math.floor(rawRow / absDelta)) * absDelta

    local curLen    = ppqToRow_c(chan, note.endppq) - ppqToRow_c(chan, note.ppq)
    local minLen    = math.min(absDelta, curLen)
    local minPPQ, maxEndPPQ = overlapBounds(col, note.ppq, note, false)
    local minRow    = ppqToRow_c(chan, minPPQ)
    local maxEndRow = ppqToRow_c(chan, maxEndPPQ)

    local newEndRow, newRow
    if rowDelta > 0 then
      newEndRow = math.min(reqRow + curLen, maxEndRow)
      newRow    = math.min(reqRow, newEndRow - minLen)
    else
      newRow    = math.max(reqRow, minRow)
      newEndRow = math.max(reqRow + curLen, newRow + minLen)
    end
    local newPPQ = rowToPPQ_c(chan, newRow)
    local newEndPPQ = rowToPPQ_c(chan, newEndRow)

    if newPPQ == note.ppq and newEndPPQ == note.endppq then return end

    local finalDur = newEndPPQ - newPPQ
    if finalDur ~= note.endppq - note.ppq then
      if rowDelta > 0 then
        tm:assignEvent('note', note, { endppq = note.ppq + finalDur })
      else
        tm:assignEvent('note', note, { ppq = note.endppq - finalDur })
      end
    end
    tm:assignEvent('note', note, { ppq = newPPQ, endppq = newEndPPQ })
    tm:flush()
  end

  local copySelection  -- forward decl; assigned in CLIPBOARD section, used by deleteRow

  local function insertRowCore(col, topRow, numRows)
    local chan = col.midiChan
    local C = rowToPPQ_c(chan, topRow)
    local R = rowToPPQ_c(chan, topRow + numRows) - C

    local shifted = {}
    for e in between(col.events, C, length) do util:add(shifted, e) end
    for i = #shifted, 1, -1 do
      local e = shifted[i]
      local newPpq = e.ppq + R
      if newPpq >= length then
        tm:deleteEvent(col.type, e)
      elseif isNote(e) then
        tm:assignEvent('note', e, { ppq = newPpq, endppq = math.min(e.endppq + R, length) })
      else
        tm:assignEvent(col.type, e, { ppq = newPpq })
      end
    end

    if col.type == 'note' then
      local spanning = util:seek(col.events, 'before', C, isNote)
      if spanning and spanning.endppq > C then
        tm:assignEvent('note', spanning, { endppq = math.min(spanning.endppq + R, length) })
      end
    end
  end

  local function deleteRowCore(col, topRow, numRows)
    local chan = col.midiChan
    local C = rowToPPQ_c(chan, topRow)
    local D = rowToPPQ_c(chan, topRow + numRows)
    local R = D - C

    if col.type == 'note' then
      local spanning = util:seek(col.events, 'before', C, isNote)
      if spanning and spanning.endppq > C then
        local newEnd = spanning.endppq > D and spanning.endppq - R or C
        tm:assignEvent('note', spanning, { endppq = newEnd })
      end
    end

    local touched = {}
    for e in between(col.events, C, length) do util:add(touched, e) end
    for _, e in ipairs(touched) do
      if e.ppq < D then
        tm:deleteEvent(col.type, e)
      elseif isNote(e) then
        tm:assignEvent('note', e, { ppq = e.ppq - R, endppq = e.endppq - R })
      else
        tm:assignEvent(col.type, e, { ppq = e.ppq - R })
      end
    end
  end

  local function forEachRowOp(core, preSel)
    if sel then
      if preSel then preSel() end
      local n = sel.row2 - sel.row1 + 1
      for ci = sel.col1, sel.col2 do
        local col = grid.cols[ci]
        if col then core(col, sel.row1, n) end
      end
    else
      for _, col in ipairs(grid.cols) do core(col, cursorRow, 1) end
    end
    tm:flush()
  end

  local function insertRow() forEachRowOp(insertRowCore) end
  local function deleteRow() forEachRowOp(deleteRowCore, copySelection) end

  -- On a note column the selgrp or selection's noteMode picks the nudge
  -- target: selgrp 1 / default → pitch, selgrp 2 / 'vel' → velocity,
  -- selgrp 3 / 'delay' → skip. Keys unioned so the same lookup serves
  -- both cursor (numeric selgrp) and selection (string noteMode).
  local noteKind = { [2] = 'vel', [3] = 'skip', vel = 'vel', delay = 'skip' }

  -- Snap v to the next multiple of interval in the dir direction; values
  -- already on a boundary move a full interval. Used for value-typed
  -- coarse nudges. Pitch coarse is additive (octave transposition), not
  -- a snap.
  local function snapTo(v, dir, interval)
    if dir > 0 then return (math.floor(v / interval) + 1) * interval end
    return (math.ceil(v / interval) - 1) * interval
  end

  local function pitchStep(coarse)
    if not coarse then return 1 end
    local t = activeTuning()
    return t and t.octaveStep or 12
  end

  -- Coarse snap interval per column type. nil = no coarse (pc).
  local function valueInterval(col)
    if col.type == 'cc' or col.type == 'at' then return 8
    elseif col.type == 'pb'                 then return 100
    end
  end

  local function valueBounds(col)
    if col.type == 'pb' then local lim = cfg('pbRange', 2) * 100; return -lim, lim end
    return 0, 127
  end

  -- Compute a snapped or fine-nudged target within [lo, hi]; returns the
  -- new value (possibly unchanged).
  local function nudgedScalar(v, lo, hi, dir, interval)
    local target = interval and snapTo(v, dir, interval) or (v + dir)
    return util:clamp(target, lo, hi)
  end

  local function nudgePitch(col, note, dir, coarse, audible)
    local delta  = dir * pitchStep(coarse)
    local tuning = activeTuning()
    local pitch, detune
    if tuning then
      pitch, detune = microtuning.transposeStep(tuning, note.pitch, note.detune or 0, delta)
    else
      pitch, detune = util:clamp(note.pitch + delta, 0, 127), note.detune or 0
    end
    if pitch == note.pitch and detune == (note.detune or 0) then return end
    tm:retuneNote(note, { pitch = pitch, detune = detune })
    if audible then audition(pitch, note.vel, col.midiChan) end
  end

  local function nudgeVel(note, dir, coarse)
    local newVel = nudgedScalar(note.vel, 1, 127, dir, coarse and 8 or nil)
    if newVel ~= note.vel then tm:assignEvent('note', note, { vel = newVel }) end
  end

  local function nudgeValue(col, evt, dir, coarse)
    local lo, hi   = valueBounds(col)
    local newVal   = nudgedScalar(evt.val, lo, hi, dir, coarse and valueInterval(col) or nil)
    if newVal ~= evt.val then tm:assignEvent(col.type, evt, { val = newVal }) end
  end

  local function applyNudge(col, evt, kind, dir, coarse, audible)
    if     kind == 'val'   then nudgeValue(col, evt, dir, coarse)
    elseif kind == 'vel'   then nudgeVel(evt, dir, coarse)
    elseif kind == 'pitch' then nudgePitch(col, evt, dir, coarse, audible) end
  end

  -- Column-typed nudge. Selection rule: if any note event is selected,
  -- transpose (or velocity-nudge) the notes and leave value events alone;
  -- otherwise nudge val on every value event. Delay-selgrp is a no-op.
  -- Solo cursor: first event in the cursor row, column- and selgrp-typed.
  local function nudge(dir, coarse)
    if sel then
      local groups, noteMode = selectedEvents()
      local selNoteKind = noteKind[noteMode] or 'pitch'
      if selNoteKind == 'skip' then return end

      local anyNote = false
      for _, g in ipairs(groups) do
        if g.col.type == 'note' then
          for _, e in pairs(g.locs) do
            if isNote(e) then anyNote = true; break end
          end
          if anyNote then break end
        end
      end

      for _, g in ipairs(groups) do
        local kind = g.col.type == 'note' and selNoteKind
                     or (not anyNote and 'val' or nil)
        if kind then
          for _, e in pairs(g.locs) do
            if kind == 'val' or isNote(e) then
              applyNudge(g.col, e, kind, dir, coarse, false)
            end
          end
        end
      end
      tm:flush()
      return
    end

    local col = grid.cols[cursorCol]
    local evt = cursorRowEvent(col)
    if not evt then return end
    local kind = col.type == 'note' and (noteKind[cursorSelGrp()] or 'pitch') or 'val'
    if kind == 'skip' then return end
    applyNudge(col, evt, kind, dir, coarse, true)
    tm:flush()
  end

  -- Queue note deletions with predecessor endppq fixup. PAs are ignored in the
  -- fixup pass (they have no duration).
  local function queueDeleteNotes(col, locs)
    local lastSurvivor, pendingFixup = nil, false
    for _, evt in ipairs(col.events) do
      if evt.type ~= 'pa' then
        if locs[evt.loc] then
          if not pendingFixup and lastSurvivor and lastSurvivor.endppq == evt.ppq then
            pendingFixup = true
          end
        else
          if pendingFixup and lastSurvivor then
            tm:assignEvent('note', lastSurvivor, { endppq = evt.ppq })
          end
          pendingFixup = false
          lastSurvivor = evt
        end
      end
    end
    if pendingFixup and lastSurvivor then
      tm:assignEvent('note', lastSurvivor, { endppq = length })
    end
    for _, evt in pairs(locs) do
      tm:deleteEvent(evt.type == 'pa' and 'pa' or 'note', evt)
    end
  end

  -- Queue delay resets; zero the `delay` metadata on each selected note.
  local function queueResetDelays(col, locs)
    for _, evt in pairs(locs) do
      if evt.type ~= 'pa' and (evt.delay or 0) ~= 0 then
        tm:assignEvent('note', evt, { delay = 0 })
      end
    end
  end

  -- Queue velocity resets; delete selected PA events, use non-selected PA/note vels for carry-forward.
  local function queueResetVelocities(col, locs)
    local prevVel = cfg('defaultVelocity', 100)
    for _, evt in ipairs(col.events) do
      local toMatch = locs[evt.loc]
      if toMatch and toMatch.type == evt.type then
        if evt.type == 'pa' then
          tm:deleteEvent('pa', evt)
        else
          tm:assignEvent('note', evt, { vel = prevVel })
        end
      else
        prevVel = evt.vel
      end
    end
  end

  local function queueDeleteCCs(col, locs)
    for _, evt in pairs(locs) do tm:deleteEvent(col.type, evt) end
  end

    local function deleteSelection()
    local groups, noteMode = selectedEvents()

    for _, group in ipairs(groups) do
      local col, locs = group.col, group.locs
      if col.type == 'note' then
        if     noteMode == 'vel'   then queueResetVelocities(col, locs)
        elseif noteMode == 'delay' then queueResetDelays(col, locs)
        else                            queueDeleteNotes(col, locs) end
      else
        queueDeleteCCs(col, locs)
      end
    end

    tm:flush()
    selClear()
  end

  ---------- CLIPBOARD

  local function clipboardSave(clip)
    reaper.SetExtState('rdm', 'clipboard', util:serialise(clip, { loc = true, sourceIdx = true }), false)
  end

  local function clipboardLoad()
    local raw = reaper.GetExtState('rdm', 'clipboard')
    if raw == '' then return end
    return util:unserialise(raw)
  end

  local function collectSelection()
    local r1, r2, c1, c2, g1, g2 = selBounds()
    local numRows  = r2 - r1 + 1

    -- Rows are encoded per source column, in that column's own swing frame,
    -- via ppqToRow_c. Paste decodes into the destination column via
    -- rowToPPQ_c, so the round-trip is consistent even when source and
    -- destination columns have different effective swings.
    local function noteEvent(col, evt, endPPQ)
      local chan = col.midiChan
      local ce = { row = ppqToRow_c(chan, evt.ppq) - r1,
                   pitch = evt.pitch, vel = evt.vel, loc = evt.loc }
      if isNote(evt) and evt.endppq <= endPPQ then
        ce.endRow = ppqToRow_c(chan, evt.endppq) - r1
      end
      return ce
    end

    local function scalarEvent(col, evt, val)
      return { row = ppqToRow_c(col.midiChan, evt.ppq) - r1, val = val, loc = evt.loc }
    end

    -- Single-column mode
    if c1 == c2 then
      local col = grid.cols[c1]
      if not col then return end
      local startPPQ, endPPQ = selBoundsFor(col, r1, r2)

      local clipType, events = nil, {}
      local emit
      if col.type == 'note' and g1 == 1 then
        clipType, emit = 'note', function(e) return noteEvent(col, e, endPPQ) end
      elseif col.type == 'note' and g1 == 2 then
        clipType, emit = '7bit', function(e) return scalarEvent(col, e, e.vel) end
      elseif col.type == 'pb' then
        clipType, emit = 'pb',   function(e) return scalarEvent(col, e, e.val) end
      else
        clipType, emit = '7bit', function(e) return scalarEvent(col, e, e.val) end
      end
      for evt in between(col.events, startPPQ, endPPQ) do
        util:add(events, emit(evt))
      end

      if #events == 0 then return end
      return { mode = 'single', type = clipType, numRows = numRows,
               sourceIdx = c1, events = events }
    end

    -- Multi-column mode. Each col carries (type, chanDelta, key, events):
    --   note: key = 0-indexed positional note-col index within its source channel
    --   cc:   key = cc number (keyed paste)
    --   pb/pc/at: key = nil (channel singletons)
    local cols = {}
    local leftChan
    local notePosByChan = {}
    for ci = c1, c2 do
      local col = grid.cols[ci]
      if not col then goto nextCol end
      leftChan = leftChan or col.midiChan

      local entry = {
        type = col.type,
        chanDelta = col.midiChan - leftChan,
        events = {},
      }
      if col.type == 'note' then
        local n = notePosByChan[col.midiChan] or 0
        entry.key = n
        notePosByChan[col.midiChan] = n + 1
      elseif col.type == 'cc' then
        entry.key = col.cc
      end

      local startPPQ, endPPQ = selBoundsFor(col, r1, r2)
      for evt in between(col.events, startPPQ, endPPQ) do
        if col.type == 'note' then
          util:add(entry.events, noteEvent(col, evt, endPPQ))
        else
          util:add(entry.events, scalarEvent(col, evt, evt.val))
        end
      end
      util:add(cols, entry)
      ::nextCol::
    end

    if #cols == 0 then return end
    return { mode = 'multi', numRows = numRows, startType = cols[1].type, cols = cols }
  end

  copySelection = function()
    local clip = collectSelection()
    if clip then clipboardSave(clip) end
  end

  local function cutSelection()
    copySelection()
    deleteSelection()
  end



  local function pasteVelocities(events, dstCol, startPPQ, endPPQ)
    local last = util:seek(dstCol.events, 'before', startPPQ)
    local currentVel = last and last.vel or cfg('defaultVelocity', 100)

    -- Delete existing PA events in the paste region
    for evt in between(dstCol.events, startPPQ, endPPQ) do
      if evt.type == 'pa' then tm:deleteEvent('pa', evt) end
    end

    -- Pass 1: carry-forward velocities onto note-ons
    local ci = 1
    for evt in between(dstCol.events, startPPQ, endPPQ) do
      if evt.pitch then
        while ci <= #events and events[ci].ppq <= evt.ppq do
          if events[ci].val > 0 then
            currentVel = util:clamp(events[ci].val, 1, 127)
          end
          ci = ci + 1
        end
        tm:assignEvent('note', evt, { vel = currentVel })
      end
    end

    -- Pass 2: create PA events for clipboard values landing on sustain rows
    if cfg('polyAftertouch', true) then
      for _, ce in ipairs(events) do
        local note = util:seek(dstCol.events, 'before', ce.ppq, isNote)
        if note and note.endppq > ce.ppq
          and note.ppq ~= ce.ppq then
          tm:addEvent('pa', {
            ppq = ce.ppq, chan = dstCol.midiChan,
            pitch = note.pitch, val = util:clamp(ce.val, 1, 127)
          })
        end
      end
    end

    tm:flush()
  end

  local function pasteSingle(clip)
    local dstCol = grid.cols[cursorCol]
    if not dstCol then return end
    local chan = dstCol.midiChan
    local startPPQ = rowToPPQ_c(chan, cursorRow)
    local endPPQ = rowToPPQ_c(chan, cursorRow + clip.numRows)
    local selGrp = cursorSelGrp()

    -- Resolve clipboard events to target PPQs, truncating past end
    local events = {}
    for _, ce in ipairs(clip.events) do
      local ppq = rowToPPQ_c(chan, cursorRow + ce.row)
      if ppq >= endPPQ then goto nextCe end
      local e = util:assign({ ppq = ppq }, ce)
      if ce.endRow then
        e.endppq = math.min(rowToPPQ_c(chan, cursorRow + ce.endRow), endPPQ)
      end
      util:add(events, e)
      ::nextCe::
    end
    table.sort(events, function(a, b) return a.ppq < b.ppq end)

    -- (1) note -> note (pitch selgrp): delete existing, paste with target vels
    if clip.type == 'note' and dstCol.type == 'note' and selGrp == 1 then
      local velList = {}
      for evt in between(dstCol.events, startPPQ, endPPQ) do
        if evt.pitch and evt.vel > 0 then
          util:add(velList, { ppq = evt.ppq, val = evt.vel })
        end
      end
      local last = util:seek(dstCol.events, 'before', startPPQ)
      local currentVel = last and last.vel or cfg('defaultVelocity', 100)

      local lastNote = util:seek(dstCol.events, 'before', startPPQ, isNote)
      local nextNote = util:seek(dstCol.events, 'at-or-after', endPPQ, isNote)
      local nextNotePPQ = nextNote and nextNote.ppq or length
      local lane = laneOf(dstCol)

      -- Delete in-region events directly: queueDeleteNotes' survivor-extension
      -- fixup is for leaving a hole, but we're filling it. An extended lastNote
      -- would overlap the new notes and force the allocator to spill on rebuild.
      if lastNote and events[1] and lastNote.endppq > events[1].ppq then
        tm:assignEvent('note', lastNote, { endppq = events[1].ppq })
      end
      for evt in between(dstCol.events, startPPQ, endPPQ) do
        tm:deleteEvent(evt.type == 'pa' and 'pa' or 'note', evt)
      end

      local vi = 1
      for _, ce in ipairs(events) do
        while vi <= #velList and velList[vi].ppq <= ce.ppq do
          currentVel = util:clamp(velList[vi].val, 1, 127)
          vi = vi + 1
        end
        truncatePitchInChannel(dstCol.midiChan, ce.pitch, ce.ppq, dstCol)
        tm:addEvent('note', {
          ppq = ce.ppq,
          endppq = ce.endppq or nextNotePPQ,
          chan = dstCol.midiChan, pitch = ce.pitch, vel = currentVel,
          lane = lane,
        })
      end
      tm:flush()
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
      for evt in between(dstCol.events, startPPQ, endPPQ) do
        tm:deleteEvent(dstCol.type, evt)
      end

      for _, ce in ipairs(events) do
        local add = { ppq = ce.ppq, chan = dstCol.midiChan, val = ce.val }
        if dstCol.type == 'cc' then add.cc = dstCol.cc end
        tm:addEvent(dstCol.type, add)
      end
      tm:flush()
      return
    end
  end

  local function pasteMulti(clip)
    local cursor = grid.cols[cursorCol]
    if not cursor then return end
    -- Notes need a note-col home; other kinds paste wherever, using cursor's
    -- channel as the anchor.
    if clip.startType == 'note' and cursor.type ~= 'note' then return end

    -- Per-channel lookup for destination columns, built lazily. Note
    -- columns are indexed by lane (1..N, dense); cc columns by number;
    -- singletons by type.
    local chanInfo = {}
    local function infoFor(chan)
      local info = chanInfo[chan]
      if info then return info end
      info = { noteCols = {}, ccCols = {}, other = {} }
      local first, last = grid.chanFirstCol[chan], grid.chanLastCol[chan]
      local lane = 0
      for ci = first or 1, last or 0 do
        local col = grid.cols[ci]
        if col.type == 'note' then
          lane = lane + 1
          info.noteCols[lane] = col
        elseif col.type == 'cc' then
          info.ccCols[col.cc] = col
        else
          info.other[col.type] = col
        end
      end
      chanInfo[chan] = info
      return info
    end

    local cursorNotePos = laneOf(cursor) or 0

    -- Resolve a clip col to a dst target, or nil if out of 1..16.
    --   note: { type='note', chan, lane, col }  (col may be nil => will create)
    --   cc:   { type='cc',   chan, ccNum, col }  (col may be nil => will create)
    --   pb/pc/at: { type, chan, col }
    local function resolve(clipCol)
      local chan = cursor.midiChan + clipCol.chanDelta
      if chan < 1 or chan > 16 then return end
      local info = infoFor(chan)

      if clipCol.type == 'note' then
        local base = (clipCol.chanDelta == 0 and cursorNotePos > 0) and cursorNotePos or 1
        local lane = base + clipCol.key
        return { type = 'note', chan = chan, lane = lane, col = info.noteCols[lane] }
      elseif clipCol.type == 'cc' then
        return { type = 'cc', chan = chan, ccNum = clipCol.key, col = info.ccCols[clipCol.key] }
      else
        return { type = clipCol.type, chan = chan, col = info.other[clipCol.type] }
      end
    end

    for _, clipCol in ipairs(clip.cols) do
      local r = resolve(clipCol)
      if not r then goto nextCol end
      local dst = r.col
      local startPPQ = rowToPPQ_c(r.chan, cursorRow)
      local endPPQ   = rowToPPQ_c(r.chan, cursorRow + clip.numRows)

      -- Materialise clip events to target PPQs, sorted.
      local events = {}
      for _, ce in ipairs(clipCol.events) do
        local ppq = rowToPPQ_c(r.chan, cursorRow + ce.row)
        if ppq < endPPQ then
          local e = util:assign({ ppq = ppq }, ce)
          if ce.endRow then
            e.endppq = math.min(rowToPPQ_c(r.chan, cursorRow + ce.endRow), endPPQ)
          end
          util:add(events, e)
        end
      end
      table.sort(events, function(a, b) return a.ppq < b.ppq end)

      -- Wipe existing events in the paste region. For notes, delete directly
      -- rather than via queueDeleteNotes — its survivor-extension fixup is for
      -- leaving a hole, but we're filling it. An extended last-survivor would
      -- overlap the new notes and force the allocator to spill on rebuild.
      -- Attached PAs cascade-delete with their host note.
      if dst then
        if r.type == 'note' then
          local last = util:seek(dst.events, 'before', startPPQ, isNote)
          if last and events[1] and last.endppq > events[1].ppq then
            tm:assignEvent('note', last, { endppq = events[1].ppq })
          end
          for evt in between(dst.events, startPPQ, endPPQ, isNote) do
            tm:deleteEvent('note', evt)
          end
        else
          for evt in between(dst.events, startPPQ, endPPQ) do
            tm:deleteEvent(r.type, evt)
          end
        end
      end

      -- End cap for pasted notes that lack an explicit endppq.
      local capPPQ = endPPQ
      if r.type == 'note' and dst then
        local nn = util:seek(dst.events, 'at-or-after', endPPQ, isNote)
        if nn then capPPQ = math.min(capPPQ, nn.ppq) end
      end

      -- Write clip events.
      for _, e in ipairs(events) do
        if r.type == 'note' then
          truncatePitchInChannel(r.chan, e.pitch, e.ppq, dst)
          tm:addEvent('note', {
            ppq = e.ppq, endppq = e.endppq or capPPQ,
            chan = r.chan, pitch = e.pitch, vel = e.vel,
            lane = r.lane,
          })
        elseif r.type == 'cc' then
          tm:addEvent('cc', { ppq = e.ppq, chan = r.chan, cc = r.ccNum, val = e.val })
        else
          tm:addEvent(r.type, { ppq = e.ppq, chan = r.chan, val = e.val })
        end
      end
      ::nextCol::
    end
    tm:flush()
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

  -- Drop the top `trim` rows of a clip in place, re-indexing surviving events.
  -- A note whose start row falls within the trimmed band is dropped entirely.
  local function trimClipTop(clip, trim)
    local function filter(events)
      local i = 1
      for _, e in ipairs(events) do
        if e.row >= trim then
          e.row = e.row - trim
          if e.endRow then e.endRow = e.endRow - trim end
          events[i] = e
          i = i + 1
        end
      end
      for j = #events, i, -1 do events[j] = nil end
    end
    clip.numRows = clip.numRows - trim
    if clip.mode == 'single' then
      filter(clip.events)
    else
      for _, c in ipairs(clip.cols) do filter(c.events) end
    end
  end

  -- Duplicate the current selection (or cursor row) to the adjacent block in
  -- the given direction (dir=1 below, dir=-1 above), overwriting what's there.
  -- The selection follows so repeated invocations stack. Going up past row 0
  -- trims the top of the clip — the start of the block is cut off, not the end.
  -- Preserves the user's clipboard.
  local function duplicate(dir)
    local clip = collectSelection()
    if not clip then return end
    local r1, r2, c1, c2, g1, g2 = selBounds()
    local numRows   = r2 - r1 + 1
    local targetRow = dir > 0 and r2 + 1 or r1 - numRows
    local trim      = targetRow < 0 and -targetRow or 0
    targetRow       = math.max(targetRow, 0)
    local effRows   = numRows - trim
    if effRows <= 0 or targetRow >= (grid.numRows or 0) then return end

    if trim > 0 then trimClipTop(clip, trim) end

    local savedRow, savedCol, savedStop = cursorRow, cursorCol, cursorStop
    cursorRow, cursorCol = targetRow, c1
    cursorStop = firstStopForSelGrp(c1, g1)
    clampCursor()

    if clip.mode == 'single' then pasteSingle(clip) else pasteMulti(clip) end

    local shift = targetRow - r1
    cursorRow, cursorCol, cursorStop = savedRow + shift, savedCol, savedStop
    clampCursor()
    if sel then
      sel = { row1 = targetRow, row2 = targetRow + effRows - 1,
              col1 = c1, col2 = c2, selgrp1 = g1, selgrp2 = g2 }
      selAnchor = { row = sel.row1, col = c1, stop = firstStopForSelGrp(c1, g1) }
      hBlockScope = 0; vBlockScope = 0
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
    local ppq         = rowToPPQ(row)
    local ts          = timeSigAt(ppq)
    if not ts then return false, false end
    local offset      = ppq - ts.ppq

    local ppqPerBeat  = resolution * 4 / ts.denom
    local nearestBeat = math.floor(offset / ppqPerBeat + 0.5)
    local isBeatStart = math.floor(ppqToRow(ts.ppq + nearestBeat * ppqPerBeat)) == row

    local ppqPerBar   = ppqPerBeat * ts.num
    local nearestBar  = math.floor(offset / ppqPerBar  + 0.5)
    local isBarStart  = math.floor(ppqToRow(ts.ppq + nearestBar  * ppqPerBar))  == row
    return isBarStart, isBeatStart
  end

  local function barBeatSub(row)
    local bar = 1
    for i, ts in ipairs(timeSigs) do
      local ppqPerBeat = resolution * 4 / ts.denom
      local ppqPerBar  = ppqPerBeat * ts.num
      local nextPPQ    = timeSigs[i + 1] and timeSigs[i + 1].ppq or math.huge
      local nextRow    = timeSigs[i + 1] and math.floor(ppqToRow(nextPPQ)) or math.huge

      if row < nextRow then
        local ppq      = rowToPPQ(row)
        local offset   = ppq - ts.ppq
        local inBar    = offset % ppqPerBar
        local beatNum  = inBar // ppqPerBeat
        local beatPPQ  = ppq - offset % ppqPerBeat
        local beatRow  = math.floor(ppqToRow(beatPPQ))
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

  function vm:ppqToRow(ppq) return ppqToRow(ppq) end
  function vm:rowToPPQ(row) return rowToPPQ(row) end
  function vm:ppqToRow_c(chan, ppq) return ppqToRow_c(chan, ppq) end
  function vm:rowToPPQ_c(chan, row) return rowToPPQ_c(chan, row) end

  function vm:activeTuning()   return activeTuning() end
  function vm:noteProjection(evt) return noteProjection(evt) end

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

  function vm:setRowPerBeat(n)
    n = util:clamp(n, 1, 32)
    if n == rowPerBeat then return end
    cursorRow = math.floor(cursorRow * n / rowPerBeat)
    setcfg('track', 'rowPerBeat', n)
  end

  function vm:selStart() selStart() end
  function vm:selUpdate() selUpdate() end
  function vm:selClear() selClear() end

  -- Anchor a sticky, all-rows selection of the given horizontal scope.
  -- scope 1 spans a single column (stop1..stop2); scope 2 spans a channel.
  local function selectSpan(scope, col, stop1, stop2)
    cursorCol, cursorStop = col, stop2
    selAnchor = { row = cursorRow, col = col, stop = stop1 }
    hBlockScope, vBlockScope = scope, 3
    selUpdate()
  end

  function vm:selectChannel(chan)
    local first = grid.chanFirstCol[chan]
    if first then selectSpan(2, first, 1, 1) end
  end

  function vm:isChannelMuted(chan)            return (cfg('mutedChannels',  {}) or {})[chan] == true end
  function vm:isChannelSoloed(chan)           return (cfg('soloedChannels', {}) or {})[chan] == true end
  function vm:isChannelEffectivelyMuted(chan) return effectiveMuted[chan] == true end
  function vm:toggleChannelMute(chan)         toggleChannelFlag('mutedChannels',  chan) end
  function vm:toggleChannelSolo(chan)         toggleChannelFlag('soloedChannels', chan) end

  function vm:selectColumn(col)
    local c = grid.cols[col]
    if c then selectSpan(1, col, 1, #c.stopPos) end
  end

  function vm:editEvent(col, evt, stop, char, half)
    editEvent(col, evt, stop, char, half)
  end

  function vm:tick()
    if auditionNote and reaper.time_precise() - auditionTime > AUDITION_TIMEOUT then
      killAudition()
    end
  end

  --- Column indices spanned by the current selection, or just the cursor col.
  local function selectedCols()
    if not sel then return { cursorCol } end
    local out = {}
    for ci = sel.col1, sel.col2 do util:add(out, ci) end
    return out
  end

  --- Unique midi channels spanned by the selection (or cursor col).
  local function selectedChans()
    local seen, out = {}, {}
    for _, ci in ipairs(selectedCols()) do
      local c = grid.cols[ci]
      if c and not seen[c.midiChan] then
        seen[c.midiChan] = true
        util:add(out, c.midiChan)
      end
    end
    return out
  end

  --- Parse a type string like "cc74", "pb", "at", "pc", "dly" and add as extra column.
  --- When a selection is active, applies to every channel (or note col, for dly) in it.
  local function addTypedColFromString(typeStr)
    local type, idStr = typeStr:lower():match('^(%a+)(%d*)$')
    if not type then return end
    local id = idStr ~= '' and tonumber(idStr) or nil

    if type == 'dly' then
      vm:showDelay(selectedCols())
    elseif type == 'cc' then
      if not id or id < 0 or id > 127 then return end
      vm:addExtraCol(type, id, selectedChans())
    elseif util:oneOf('pb at pc', type) then
      vm:addExtraCol(type, id, selectedChans())
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
    goLeft         = function() scrollColBy(-cursorCol) end,
    goRight        = function() scrollColBy(#grid.cols - cursorCol) end,
    cursorRight    = function() scrollStopBy(1) end,
    cursorLeft     = function() scrollStopBy(-1) end,
    selectDown     = function() scrollRowBy(1, true) end,
    selectUp       = function() scrollRowBy(-1, true) end,
    selectRight    = function() scrollStopBy(1, true) end,
    selectLeft     = function() scrollStopBy(-1, true) end,
    selectClear    = function() selClear() end,
    colRight       = function() scrollColBy(1) end,
    colLeft        = function() scrollColBy(-1) end,
    channelRight   = function() scrollChannelBy(1) end,
    channelLeft    = function() scrollChannelBy(-1) end,
    cycleBlock     = function() cycleBlock() end,
    cycleVBlock    = function() cycleVBlock() end,
    swapBlockEnds  = function() swapBlockEnds() end,
    delete         = function()
      if inBlock() then deleteSelection()
      else selClear(); deleteEvent(); scrollRowBy(advanceBy) end
    end,
    interpolate    = function() interpolate() end,
    deleteSel      = function() deleteSelection() end,
    copy           = function() copySelection(); selClear() end,
    cut            = function() cutSelection() end,
    paste          = function() pasteClipboard() end,
    duplicateDown  = function() duplicate( 1) end,
    duplicateUp    = function() duplicate(-1) end,
    inputOctaveUp   = function() setcfg('take', 'currentOctave', util:clamp(currentOctave+1, -1, 9)) end,
    inputOctaveDown = function() setcfg('take', 'currentOctave', util:clamp(currentOctave-1, -1, 9)) end,
    noteOff        = noteOff,
    growNote       = function() adjustDuration(1) end,
    shrinkNote     = function() adjustDuration(-1) end,
    nudgeBack    = function() adjustPosition(-1) end,
    nudgeForward = function() adjustPosition(1) end,
    insertRow    = function() insertRow() end,
    deleteRow    = function() deleteRow() end,
    nudgeCoarseUp   = function() nudge( 1, true)  end,
    nudgeCoarseDown = function() nudge(-1, true)  end,
    nudgeFineUp     = function() nudge( 1, false) end,
    nudgeFineDown   = function() nudge(-1, false) end,
    play           = function() tm:play() end,
    playPause      = function() tm:playPause() end,
    playFromTop    = function() tm:playFrom(0) end,
    playFromCursor = function()
      local col = grid.cols[cursorCol]
      tm:playFrom(col and rowToPPQ_c(col.midiChan, cursorRow) or rowToPPQ(cursorRow))
    end,
    stop           = function() tm:stop() end,
    addNoteCol     = function() vm:addExtraCol('note') end,
    addTypedCol    = function()
      return 'modal', {
        title    = 'Add Column',
        prompt   = 'cc0-127, pb, at, pc, dly',
        callback = addTypedColFromString,
      }
    end,
    hideExtraCol   = function() vm:hideExtraCol() end,
    doubleRPB      = function() vm:setRowPerBeat(rowPerBeat * 2) end,
    halveRPB       = function() vm:setRowPerBeat(math.floor(rowPerBeat / 2)) end,
    setRPB         = function()
      return 'modal', {
        title    = 'Rows per beat',
        prompt   = '1-32',
        callback = function(buf)
          local n = tonumber(buf)
          if n then vm:setRowPerBeat(n) end
        end,
      }
    end,
    cycleTuning    = function()
      local names = { '12EDO', '19EDO', '31EDO', '53EDO' }
      local cur, i = cfg('tuning', nil), 0
      for k, v in ipairs(names) do if v == cur then i = k; break end end
      setcfg('track', 'tuning', names[(i + 1) % (#names + 1)])
    end,
    cycleSwing     = function()
      -- 'off' is the nil-slot sentinel for cycling; in storage, no key == id.
      local stops = { 'off', 'classic-55', 'classic-58', 'classic-62', 'classic-67' }
      local cur = (cfg('swing') or {}).name or 'off'
      local i = 1
      for k, v in ipairs(stops) do if v == cur then i = k; break end end
      local next = stops[(i % #stops) + 1]
      if next == 'off' then cm:remove('take', 'swing')
      else                  setcfg('take', 'swing', { name = next, period = 1 }) end
      util:print('swing: ' .. next)
    end,
    quit           = function() return 'quit' end,
  }

  -- In mark mode, paste's first press is swallowed as a cancel: it pastes at
  -- cursor (not over selection), so we want an explicit second press.
  for _, name in ipairs({ 'paste' }) do
    local orig = vm.commands[name]
    vm.commands[name] = function()
      if inBlock() then selClear() else return orig() end
    end
  end

  -- These commands operate on the current selection when sticky, then drop the
  -- sticky flags so the edited region stays visible but doesn't extend on move.
  for _, name in ipairs({
    'nudgeCoarseUp', 'nudgeCoarseDown', 'nudgeFineUp', 'nudgeFineDown',
    'growNote', 'shrinkNote', 'nudgeBack', 'nudgeForward',
    'duplicateDown', 'duplicateUp', 'interpolate', 'insertRow', 'deleteRow', 'noteOff',
  }) do
    local orig = vm.commands[name]
    vm.commands[name] = function()
      local r, s = orig()
      unstick()
      return r, s
    end
  end

  -- After these, the affected events are gone; an empty sel rect isn't useful
  -- feedback, so clear the selection entirely.
  for _, name in ipairs({ 'delete', 'deleteSel', 'cut' }) do
    local orig = vm.commands[name]
    vm.commands[name] = function()
      local r, s = orig()
      selClear()
      return r, s
    end
  end

  function vm:markMode() return inBlock() end
  function vm:clearMark() selClear() end

  --- Add an extra view-only column to one or more channels.
  --- type: 'note', 'cc', 'pb', 'at', 'pc'. cc: CC number (cc type only).
  --- chans: list of midi channels (1..16); defaults to the cursor's channel.
  function vm:addExtraCol(type, cc, chans)
    if not chans then
      local col = grid.cols[cursorCol]
      if not col then return end
      chans = { col.midiChan }
    end

    if type == 'note' then
      -- Note columns are managed via cfg.noteColumns, not the extras list.
      local nc = cfg('noteColumns', {}) or {}
      for _, chan in ipairs(chans) do
        nc[chan] = (nc[chan] or 1) + 1
      end
      setcfg('take', 'noteColumns', nc)
      return
    end

    local extras = cfg('extraColumns', {})
    local changed = false
    for _, chan in ipairs(chans) do
      local first, last = grid.chanFirstCol[chan], grid.chanLastCol[chan]
      local exists = false
      if first and last then
        for ci = first, last do
          local c = grid.cols[ci]
          if c.type == type and (type ~= 'cc' or c.cc == cc) then
            exists = true; break
          end
        end
      end
      if not exists then
        local chanExtras = extras[chan] or {}
        util:add(chanExtras, { type = type, cc = cc })
        extras[chan] = chanExtras
        changed = true
      end
    end
    if changed then setcfg('take', 'extraColumns', extras) end
  end

  --- Delete the empty column under the cursor.
  --- For note columns: shift any higher-lane notes (and noteDelay entries)
  --- down, and decrement cfg.noteColumns[chan]. Refuses if the column has
  --- events or is the channel's only note column.
  --- For cc/pb/at/pc extras: remove from the extras list.
  function vm:hideExtraCol()
    local col = grid.cols[cursorCol]
    if not col then return end
    local chan = col.midiChan

    -- Note col with delay shown: strip the delay first; the column itself
    -- only goes on a subsequent hide.
    if col.type == 'note' then
      local lane = laneOf(col)
      local nd = cfg('noteDelay', {})
      local chanMap = nd[chan]
      if chanMap and chanMap[lane] then
        chanMap[lane] = nil
        nd[chan] = next(chanMap) and chanMap or nil
        setcfg('take', 'noteDelay', next(nd) and nd or nil)
        vm:rebuild()
        return
      end
    end

    if #col.events > 0 then return end

    if col.type == 'note' then
      local noteCols = {}
      for ci = grid.chanFirstCol[chan], grid.chanLastCol[chan] do
        local c = grid.cols[ci]
        if c.type == 'note' then util:add(noteCols, c) end
      end
      if #noteCols <= 1 then return end
      local k = laneOf(col)

      -- Queue lane shifts for higher-lane notes.
      for lane = k + 1, #noteCols do
        for _, evt in ipairs(noteCols[lane].events) do
          tm:assignEvent('note', evt, { lane = lane - 1 })
        end
      end

      -- Shift noteDelay keys in this channel.
      local nd = cfg('noteDelay', {})
      local chanMap = nd[chan]
      if chanMap then
        local newMap = {}
        for lane, v in pairs(chanMap) do
          if lane < k then newMap[lane] = v
          elseif lane > k then newMap[lane - 1] = v end
        end
        nd[chan] = next(newMap) and newMap or nil
        setcfg('take', 'noteDelay', next(nd) and nd or nil)
      end

      -- Drop the configured count by one.
      local ncCfg = cfg('noteColumns', {}) or {}
      local newCount = #noteCols - 1
      ncCfg[chan] = newCount > 1 and newCount or nil
      setcfg('take', 'noteColumns', next(ncCfg) and ncCfg or nil)

      tm:flush()
      return
    end

    local extras = cfg('extraColumns', {})
    local chanExtras = extras[chan]
    if not chanExtras then return end
    for i, extra in ipairs(chanExtras) do
      if extra.type == col.type
         and (col.type ~= 'cc' or extra.cc == col.cc) then
        table.remove(chanExtras, i)
        extras[chan] = #chanExtras > 0 and chanExtras or nil
        setcfg('take', 'extraColumns', next(extras) and extras or nil)
        vm:rebuild()
        return
      end
    end
  end

  --- Show the delay sub-column on one or more note columns (idempotent).
  --- cols: list of grid column indices; defaults to the cursor column.
  --- Non-note columns in the list are skipped.
  function vm:showDelay(cols)
    cols = cols or { cursorCol }
    local nd = cfg('noteDelay', {})
    local changed = false
    for _, ci in ipairs(cols) do
      local col = grid.cols[ci]
      if col and col.type == 'note' then
        local lane = laneOf(col)
        local chanMap = nd[col.midiChan] or {}
        if not chanMap[lane] then
          chanMap[lane] = true
          nd[col.midiChan] = chanMap
          changed = true
        end
      end
    end
    if changed then setcfg('take', 'noteDelay', nd) end
  end

  for i = 0, 9 do
    vm.commands['advBy' .. i] = function() setcfg('take', 'advanceBy', i) end
  end

  ---------- REBUILD

  local rebuilding = false

  function vm:rebuild(changed)
    if not tm or rebuilding then return end
    rebuilding = true
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

      grid.cols         = {}
      grid.chanFirstCol = {}
      grid.chanLastCol  = {}

      local noteDelayCfg = cfg('noteDelay', {})

      -- `key` is the lane number for note columns, the cc number for cc
      -- columns, and nil for singletons (pb/at/pc).
      local function addGridCol(chan, type, key, events)
        local showDelay = type == 'note' and (noteDelayCfg[chan] or {})[key] or false

        -- cursor stop positions in each column
        local stopPos = {
          note = showDelay and {0,2,4,5,7,8,9} or {0,2,4,5},  -- C-4 30 [040]
          pb   = {0,1,2,3},        -- 0200
          cc   = {0,1},            -- 94
          pa   = {0,1},
          at   = {0,1},
          pc   = {0,1},
        }

        -- assigns stop positions to selection groups (for marking)
        local selGroups = {
          note = showDelay and {1,1,2,2,3,3,3} or {1,1,2,2},  -- C-4 30 [040]
          pb   = {1,1,1,1},        -- 0200
          cc   = {1,1},            -- 94
          pa   = {1,1},
          at   = {1,1},
          pc   = {1,1},
        }

        local colLabels = {
          note = 'Note',
          cc   = 'CC', --tostring(id) or '',
          pb   = 'PB',  at = 'AT',  pa = 'PA',  pc = 'PC',
        }

        local gridCol = {
          type      = type,
          cc        = type == 'cc' and key or nil,
          label     = colLabels[type] or '',
          events    = events or {},
          showDelay = showDelay,
          stopPos   = stopPos[type] or {0},
          selGroups = selGroups[type] or {0},
          width     = type == 'note' and (showDelay and 10 or 6)
                   or type == 'pb' and 4
                   or 2,
          midiChan  = chan,
          cells     = {},
        }
        util:add(grid.cols, gridCol)
        grid.chanFirstCol[chan] = grid.chanFirstCol[chan] or #grid.cols
        grid.chanLastCol[chan]  = #grid.cols
      end

      local extras = cfg('extraColumns', {})

      for chan, channel in tm:channels() do
        local noteLane = 0
        for _, column in ipairs(channel.columns) do
          local key
          if column.type == 'note' then
            noteLane = noteLane + 1
            key = noteLane
          else
            key = column.cc  -- nil for singletons
          end
          addGridCol(chan, column.type, key, column.events)
        end

        -- Inject non-note extra columns not already provided by tm.
        -- (Note columns are managed via cfg.noteColumns and always come
        -- from tm.)
        local chanExtras = extras[chan]
        if chanExtras then
          for _, extra in ipairs(chanExtras) do
            if extra.type ~= 'note' then
              local found = false
              for _, col in ipairs(channel.columns) do
                if col.type == extra.type
                   and (col.type ~= 'cc' or col.cc == extra.cc) then
                  found = true
                  break
                end
              end
              if not found then
                addGridCol(chan, extra.type, extra.cc)
              end
            end
          end
        end

        -- Canonicalise column order within the channel (matches trackerManager).
        local first, last = grid.chanFirstCol[chan], grid.chanLastCol[chan]
        if first and last and last > first then
          local slice = {}
          for i = first, last do util:add(slice, grid.cols[i]) end
          slice = canonicaliseColumns(slice)
          for i, col in ipairs(slice) do grid.cols[first + i - 1] = col end
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

      -- Swing snapshot for this rebuild — resolved slots, T baked in.
      -- Hoisted into factory scope so _c helpers see it from anywhere
      -- in vm. tm has already stripped delay from col.events, so evt.ppq
      -- is intent; unapply(chan, intentPPQ) → straight-grid PPQ.
      swing = tm:swingSnapshot()

      for _, gridCol in ipairs(grid.cols) do
        gridCol.overflow = {}
        gridCol.offGrid  = {}
        local chan = gridCol.midiChan
        for _, evt in ipairs(gridCol.events) do
          local exact = ppqToRow_c(chan, evt.ppq or 0)
          local y     = math.floor(exact + 0.5)
          if y >= 0 and y < numRows then
            if gridCol.cells[y] then
              gridCol.overflow[y] = true
            else
              gridCol.cells[y] = evt
              if math.abs(exact - y) > 1e-3 then gridCol.offGrid[y] = true end
            end
          end
        end
      end

      -- Ghost cells: sampled intermediate values between consecutive scalar
      -- events A, B when A.shape is a non-step curve. The shape of A governs
      -- the pair (A, B). Ghosts are skipped on rows already holding a real
      -- event.
      for _, gridCol in ipairs(grid.cols) do
        if ghostable[gridCol.type] then
          gridCol.ghosts = {}
          local chan = gridCol.midiChan
          local evts = gridCol.events
          for i = 1, #evts - 1 do
            local A, B = evts[i], evts[i+1]
            local shape = A.shape
            if shape and shape ~= 'step' then
              local rA = ppqToRow_c(chan, A.ppq)
              local rB = ppqToRow_c(chan, B.ppq)
              local yA, yB = math.floor(rA + 0.5), math.floor(rB + 0.5)
              local span, delta = rB - rA, (B.val or 0) - (A.val or 0)
              for y = yA + 1, yB - 1 do
                if y >= 0 and y < numRows and not gridCol.cells[y] then
                  local t   = (y - rA) / span
                  local val = (A.val or 0) + util:curveSample(shape, A.tension, t) * delta
                  gridCol.ghosts[y] = {
                    val = math.floor(val + 0.5), fromEvt = A, toEvt = B,
                  }
                end
              end
            end
          end
        end
      end

      -- Clamp cursor/scroll after layout changes
      clampCursor()
    end
    pushMute()
    rebuilding = false
  end

  -- LIFECYCLE

  local callback = function(changed, _tm)
    if changed.data or changed.take then
      vm:rebuild(changed)
    end
  end

  -- Mute/solo changes don't affect grid shape — only colour and the
  -- effective set pushed to tm. Skip the full rebuild for those keys.
  local muteKeys = { mutedChannels = true, soloedChannels = true }

  local configCallback = function(changed, _cm)
    if not changed.config then return end
    if muteKeys[changed.key] then pushMute()
    else vm:rebuild({ take = false, data = true }) end
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
