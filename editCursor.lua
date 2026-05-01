-- See docs/viewManager.md for the model and API reference.

loadModule('util')

local function print(...)
  return util.print(...)
end

function newEditCursor(deps)

  ---------- PRIVATE

  local grid     = deps.grid
  local cm       = deps.cm
  local getRPBar = deps.rowPerBar
  local moveHook = deps.moveHook or function () end

  local cursorRow, cursorCol, cursorStop = 0, 1, 1
  local hBlockScope, vBlockScope         = 0, 0
  local sel, selAnchor

  ----- Position

  local function clampPos()
    local maxRow = math.max(0, (grid.numRows or 1) - 1)
    cursorRow = util.clamp(cursorRow, 0, maxRow)
    cursorCol  = util.clamp(cursorCol, 1, #grid.cols)
    cursorStop = util.clamp(cursorStop, 1, #grid.cols[cursorCol].stopPos)
  end

  ----- Kinds

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

  -- Kind is the semantic name for a position's editable axis:
  --   note col → 'pitch' | 'vel' | 'delay' (selgrp 1/2/3)
  --   scalar col / missing col → 'val'
  local NOTE_KIND_BY_SELGRP = { 'pitch', 'vel', 'delay' }
  local SELGRP_BY_NOTE_KIND = { pitch = 1, vel = 2, delay = 3 }

  local function isNoteCol(col)
    local c = grid.cols[col]
    return c and c.type == 'note'
  end

  local function kindFromSelGrp(col, g)
    if not isNoteCol(col) then return 'val' end
    return NOTE_KIND_BY_SELGRP[g] or 'pitch'
  end

  local function cursorKind() return kindFromSelGrp(cursorCol, selGrpAt(cursorCol, cursorStop)) end

  local function firstStopForKind(col, kind)
    if not isNoteCol(col) then return 1 end
    return firstStopForSelGrp(col, SELGRP_BY_NOTE_KIND[kind] or 1)
  end

  ----- Selection

  local function isSticky() return hBlockScope > 0 or vBlockScope > 0 end

  local function selStart()
    selAnchor = { row = cursorRow, col = cursorCol, stop = cursorStop }
    local g = cursorSelGrp()
    sel = { row1 = cursorRow, row2 = cursorRow, col1 = cursorCol, col2 = cursorCol, selgrp1 = g, selgrp2 = g }
  end

  local function selUpdate()
    local a = selAnchor
    if not a then return end
    local numRows = grid.numRows or 1

    local r1, r2
    if vBlockScope == 1 or vBlockScope == 2 then
      local unit = vBlockScope == 1 and cm:get('rowPerBeat') or getRPBar()
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
    sel = { row1 = r1, row2 = r2, col1 = c1, col2 = c2, selgrp1 = g1, selgrp2 = g2 }
  end

  local function selClear()
    sel = nil; selAnchor = nil
    hBlockScope = 0; vBlockScope = 0
  end

  local function cycleHBlock()
    if not isSticky() then
      selAnchor   = { row = cursorRow, col = cursorCol, stop = cursorStop }
      hBlockScope = 1
    else
      hBlockScope = (hBlockScope % 3) + 1
    end
    selUpdate()
  end

  local function cycleVBlock()
    if (grid.numRows or 0) == 0 then return end
    if not isSticky() then
      selAnchor   = { row = cursorRow, col = cursorCol, stop = cursorStop }
      vBlockScope = 1
    else
      vBlockScope = (vBlockScope % 3) + 1
    end
    selUpdate()
  end

  local function swapEnds()
    if not (sel and selAnchor) then return end
    if vBlockScope < 1 then
      selAnchor.row, cursorRow = cursorRow, selAnchor.row
    end
    if hBlockScope < 2 then
      selAnchor.col,  cursorCol  = cursorCol,  selAnchor.col
      selAnchor.stop, cursorStop = cursorStop, selAnchor.stop
    end
    clampPos(); moveHook()
    selUpdate()
  end

  ----- Movement

  local function moveRow(n, selecting)
    if selecting or isSticky() then
      if not sel then selStart() end
    else selClear() end
    cursorRow = cursorRow + n
    clampPos(); moveHook()
    if selecting or isSticky() then selUpdate() end
  end

  local function moveStop(n, selecting)
    if selecting or isSticky() then
      if not sel then selStart() end
    else selClear() end
    if hBlockScope >= 2 and selAnchor then
      selAnchor.col  = cursorCol
      selAnchor.stop = cursorStop
      hBlockScope    = 1
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
    clampPos(); moveHook()
    if selecting or isSticky() then selUpdate() end
  end

  local moveCol, moveChannel do
    local function moveUnit(n, toFirstStop, toLastStop)
      if not isSticky() then selClear() end
      local sgn  = n > 0 and 1 or -1
      local land = sgn > 0 and toLastStop or toFirstStop

      if isSticky() then
        for _ = 1, math.abs(n) do
          local extending = (sgn > 0 and cursorCol >= selAnchor.col)
                         or (sgn < 0 and cursorCol <= selAnchor.col)
          if extending then moveStop(sgn); land()
          else              land();        moveStop(sgn) end
        end
      else
        for _ = 1, math.abs(n) do
          if sgn > 0 then toLastStop();  moveStop(1)
          else            toFirstStop(); moveStop(-1); toFirstStop()
          end
        end
      end
      if isSticky() then selUpdate() end
    end

    function moveCol(n)
      moveUnit(n,
        function()
          cursorStop = 1
          if isSticky() and cursorCol == selAnchor.col and #grid.cols[cursorCol].selGroups == 1 then
            moveStop(1)
            cursorStop = #grid.cols[cursorCol].stopPos
          end
        end,
        function()
          cursorStop = #grid.cols[cursorCol].stopPos
          if isSticky() and cursorCol == selAnchor.col and #grid.cols[cursorCol].selGroups == 1 then
            moveStop(1)
            cursorStop = #grid.cols[cursorCol].stopPos
          end
      end)
    end

    function moveChannel(n)
      local function chanRange()
        local chan = grid.cols[cursorCol].midiChan
        return grid.chanFirstCol[chan], grid.chanLastCol[chan]
      end
      moveUnit(n,
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
      if not isSticky() then
        local first, last = chanRange()
        for ci = first, last do
          if grid.cols[ci].type == 'note' then
            cursorCol, cursorStop = ci, 1
            break
          end
        end
      end
    end
  end

  ---------- PUBLIC

  local ec = {}

  ----- Position

  function ec:row()           return cursorRow  end
  function ec:col()           return cursorCol  end
  function ec:pos()           return cursorRow, cursorCol, cursorStop end

  function ec:setPos(row, col, stop)
    if row  then cursorRow  = row  end
    if col  then cursorCol  = col  end
    if stop then cursorStop = stop end
    clampPos(); moveHook()
  end

  function ec:clampPos()      clampPos() end

  function ec:rescaleRow(oldRPB, newRPB)
    cursorRow = math.floor(cursorRow * newRPB / oldRPB)
  end

  function ec:reset()
    cursorRow, cursorCol, cursorStop = 0, 1, 1
    selClear()
  end

  ----- Kind & Region

  function ec:cursorKind()    return cursorKind() end
  function ec:hasSelection()  return sel ~= nil end
  function ec:isSticky()      return isSticky() end

  -- The rect to operate on, kind-typed. Internal sel stores selgrp
  -- (selUpdate / selectionStopSpan need the numeric handle); the public
  -- boundary speaks kinds. Degenerates to 1x1 at cursor when no selection
  -- — `hasSelection()` is the bit when that distinction matters.
  function ec:region()
    if sel then
      return sel.row1, sel.row2, sel.col1, sel.col2,
             kindFromSelGrp(sel.col1, sel.selgrp1),
             kindFromSelGrp(sel.col2, sel.selgrp2)
    end
    local k = cursorKind()
    return cursorRow, cursorRow, cursorCol, cursorCol, k, k
  end

  -- (col, stop) of the region's top-left corner. Returns a pair so callers
  -- can splat directly into setPos: `ec:setPos(row, ec:regionStart())`.
  -- Degenerates to the cursor's col/stop when no selection.
  function ec:regionStart()
    if not sel then return cursorCol, cursorStop end
    return sel.col1,
           firstStopForKind(sel.col1, kindFromSelGrp(sel.col1, sel.selgrp1))
  end

  -- Iterator over the cols an op should target: the selection's cols if
  -- a selection is active, otherwise just the cursor's col (or nothing if
  -- it's nil). Skips nil cols. Callers that need to distinguish a real
  -- selection from the cursor-fallback case still have ec:hasSelection().
  function ec:eachSelectedCol()
    if not sel then
      local col, ci = grid.cols[cursorCol], cursorCol
      local done = col == nil
      return function()
        if done then return end
        done = true
        return col, ci
      end
    end
    local ci = sel.col1 - 1
    return function()
      ci = ci + 1
      while ci <= sel.col2 do
        local col = grid.cols[ci]
        if col then return col, ci end
        ci = ci + 1
      end
    end
  end

  function ec:setSelection(r)
    local g1 = SELGRP_BY_NOTE_KIND[r.kind1] or 1
    local g2 = SELGRP_BY_NOTE_KIND[r.kind2] or 1
    sel = { row1 = r.row1, row2 = r.row2, col1 = r.col1, col2 = r.col2,
            selgrp1 = g1, selgrp2 = g2 }
    selAnchor = { row = r.row1, col = r.col1, stop = firstStopForSelGrp(r.col1, g1) }
    hBlockScope, vBlockScope = 0, 0
  end

  function ec:selectionStopSpan(col)
    if not sel then return nil end
    local c = grid.cols[col]
    if not c then return nil end
    local s1, s2 = 1, #c.stopPos
    if col == sel.col1 then
      for s, g in ipairs(c.selGroups) do
        if g >= sel.selgrp1 then s1 = s; break end
      end
    end
    if col == sel.col2 then
      s2 = 1
      for s = #c.selGroups, 1, -1 do
        if c.selGroups[s] <= sel.selgrp2 then s2 = s; break end
      end
    end
    return s1, s2
  end

  function ec:selClear()  selClear()  end
  function ec:unstick()   hBlockScope, vBlockScope = 0, 0 end

  -- Extend the selection to land on (row, col, stop), creating a fresh
  -- 1x1 sel anchored at the current cursor first if none was active.
  -- Mouse shift-click and drag both speak this verb.
  function ec:extendTo(row, col, stop)
    if not sel then selStart() end
    self:setPos(row, col, stop)
    selUpdate()
  end

  function ec:shiftSelection(rowDelta)
    local maxRow = grid.numRows - 1
    sel.row1      = util.clamp(sel.row1      + rowDelta, 0, maxRow)
    sel.row2      = util.clamp(sel.row2      + rowDelta, 0, maxRow)
    selAnchor.row = util.clamp(selAnchor.row + rowDelta, 0, maxRow)
    cursorRow     = cursorRow + rowDelta
    clampPos(); moveHook()
  end

  ----- Motion

  function ec:advance() moveRow(cm:get('advanceBy')) end

  do
    local function selectSpan(scope, col, stop1, stop2)
      cursorCol, cursorStop = col, stop2
      selAnchor = { row = cursorRow, col = col, stop = stop1 }
      hBlockScope, vBlockScope = scope, 3
      selUpdate()
    end

    function ec:selectChannel(chan)
      local first = grid.chanFirstCol[chan]
      if first then selectSpan(2, first, 1, 1) end
    end

    function ec:selectColumn(col)
      local c = grid.cols[col]
      if c then selectSpan(1, col, 1, #c.stopPos) end
    end
  end

  ----- Commands

  function ec:registerCommands(cmgr)
    cmgr:registerAll{
      cursorDown    = function() moveRow(1) end,
      cursorUp      = function() moveRow(-1) end,
      pageDown      = function() moveRow(getRPBar()) end,
      pageUp        = function() moveRow(-getRPBar()) end,
      goTop         = function() moveRow(-cursorRow) end,
      goBottom      = function() moveRow((grid.numRows or 1) - cursorRow) end,
      goLeft        = function() moveCol(-cursorCol) end,
      goRight       = function() moveCol(#grid.cols - cursorCol) end,
      cursorRight   = function() moveStop(1) end,
      cursorLeft    = function() moveStop(-1) end,
      selectDown    = function() moveRow(1, true) end,
      selectUp      = function() moveRow(-1, true) end,
      selectRight   = function() moveStop(1, true) end,
      selectLeft    = function() moveStop(-1, true) end,
      selectClear   = function() selClear() end,
      colRight      = function() moveCol(1) end,
      colLeft       = function() moveCol(-1) end,
      channelRight  = function() moveChannel(1) end,
      channelLeft   = function() moveChannel(-1) end,
      cycleBlock    = function() cycleHBlock() end,
      cycleVBlock   = function() cycleVBlock() end,
      swapBlockEnds = function() swapEnds() end,
    }
  end

  ----- Decoration

  -- Stamp kind-shape fields onto a half-built grid column. ec owns both
  -- the shape tables and the field names; addGridCol never names them.
  do
    local STOPS = {
      note          = {0,2,4,5},          -- C-4 30
      noteWithDelay = {0,2,4,5,7,8,9},    -- C-4 30 [040]
      pb            = {0,1,2,3},
      cc = {0,1}, pa = {0,1}, at = {0,1}, pc = {0,1},
    }

    local SELGROUPS = {
      note          = {1,1,2,2},
      noteWithDelay = {1,1,2,2,3,3,3},
      pb            = {1,1,1,1},
      cc = {1,1}, pa = {1,1}, at = {1,1}, pc = {1,1},
    }

    function ec:decorateCol(col)
      local key = (col.type == 'note' and col.showDelay) and 'noteWithDelay' or col.type
      col.stopPos   = STOPS[key]     or {0}
      col.selGroups = SELGROUPS[key] or {0}
    end
  end

  return ec
end

---------- CLIPBOARD

function newClipboard(deps)

  ---------- PRIVATE

  local ec           = deps.ec
  local grid         = deps.grid
  local tm           = deps.tm
  local cm           = deps.cm
  local currentFrame = deps.currentFrame
  local assignTail   = deps.assignTail
  local paFrame      = deps.paFrame
  local getCtx       = deps.getCtx
  local getLength    = deps.getLength

  local function save(clip)
    reaper.SetExtState('rdm', 'clipboard', util.serialise(clip, { loc = true, sourceIdx = true }), false)
  end

  local function load()
    local raw = reaper.GetExtState('rdm', 'clipboard')
    if raw == '' then return end
    return util.unserialise(raw)
  end

  local function collect()
    local ctx = getCtx()
    local r1, r2, c1, c2, kind1 = ec:region()
    local numRows  = r2 - r1 + 1

    -- Rows are encoded per source column, in that column's own swing frame,
    -- via ppqToRow_c. Paste decodes into the destination column via
    -- rowToPPQ_c, so the round-trip is consistent even when source and
    -- destination columns have different effective swings.
    local function noteEvent(col, evt, endppq)
      local chan = col.midiChan
      local ce = { row = ctx:ppqToRow(evt.ppq, chan) - r1,
                   pitch = evt.pitch, vel = evt.vel, loc = evt.loc }
      if util.isNote(evt) and evt.endppq <= endppq then
        ce.endRow = ctx:ppqToRow(evt.endppq, chan) - r1
      end
      return ce
    end

    local function scalarEvent(col, evt, val)
      return { row = ctx:ppqToRow(evt.ppq, col.midiChan) - r1, val = val, loc = evt.loc }
    end

    -- Single-column mode
    if c1 == c2 then
      local col = grid.cols[c1]
      if not col then return end
      local startppq, endppq = ctx:rowToPPQ(r1, col.midiChan), ctx:rowToPPQ(r2 + 1, col.midiChan)

      local clipType, events = nil, {}
      local emit
      if col.type == 'note' and kind1 == 'pitch' then
        clipType, emit = 'note', function(e) return noteEvent(col, e, endppq) end
      elseif col.type == 'note' and kind1 == 'vel' then
        clipType, emit = '7bit', function(e) return scalarEvent(col, e, e.vel) end
      elseif col.type == 'pb' then
        clipType, emit = 'pb',   function(e) return scalarEvent(col, e, e.val) end
      else
        clipType, emit = '7bit', function(e) return scalarEvent(col, e, e.val) end
      end
      for evt in util.between(col.events, startppq, endppq) do
        util.add(events, emit(evt))
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
    for col in ec:eachSelectedCol() do
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

      local startppq, endppq = ctx:rowToPPQ(r1, col.midiChan), ctx:rowToPPQ(r2 + 1, col.midiChan)
      for evt in util.between(col.events, startppq, endppq) do
        if col.type == 'note' then
          util.add(entry.events, noteEvent(col, evt, endppq))
        else
          util.add(entry.events, scalarEvent(col, evt, evt.val))
        end
      end
      util.add(cols, entry)
    end

    if #cols == 0 then return end
    return { mode = 'multi', numRows = numRows, startType = cols[1].type, cols = cols }
  end

  local function pasteVelocities(events, dstCol, startppq, endppq)
    local last = util.seek(dstCol.events, 'before', startppq)
    local currentVel = last and last.vel or cm:get('defaultVelocity')

    -- Delete existing PA events in the paste region
    for evt in util.between(dstCol.events, startppq, endppq) do
      if evt.type == 'pa' then tm:deleteEvent('pa', evt) end
    end

    -- Pass 1: carry-forward velocities onto note-ons
    local ci = 1
    for evt in util.between(dstCol.events, startppq, endppq) do
      if evt.pitch then
        while ci <= #events and events[ci].ppq <= evt.ppq do
          if events[ci].val > 0 then
            currentVel = util.clamp(events[ci].val, 1, 127)
          end
          ci = ci + 1
        end
        tm:assignEvent('note', evt, { vel = currentVel })
      end
    end

    -- Pass 2: create PA events for clipboard values landing on sustain rows
    if cm:get('polyAftertouch') then
      for _, ce in ipairs(events) do
        local note = util.seek(dstCol.events, 'before', ce.ppq, util.isNote)
        if note and note.endppq > ce.ppq
          and note.ppq ~= ce.ppq then
          tm:addEvent('pa', {
            ppq = ce.ppq, ppqL = ce.ppqL,
            chan = dstCol.midiChan,
            pitch = note.pitch, val = util.clamp(ce.val, 1, 127),
            frame = paFrame(note.frame, dstCol.midiChan),
          })
        end
      end
    end

    tm:flush()
  end

  local function pasteSingle(clip)
    local ctx = getCtx()
    local dstCol = grid.cols[ec:col()]
    if not dstCol then return end
    local chan = dstCol.midiChan
    local r = ec:row()
    local startppq = ctx:rowToPPQ(r, chan)
    local endppq = ctx:rowToPPQ(r + clip.numRows, chan)
    local kind = ec:cursorKind()
    local logPerRow = ctx:ppqPerRow()
    local capRow = r + clip.numRows  -- logical row of endppq

    -- Resolve clipboard events to target PPQs, truncating past end.
    -- ppqL rides alongside ppq so the destination keeps its
    -- authoring-row identity in the current take frame.
    local events = {}
    for _, ce in ipairs(clip.events) do
      local ppq = ctx:rowToPPQ(r + ce.row, chan)
      if ppq >= endppq then goto nextCe end
      local e = util.assign({ ppq = ppq, ppqL = (r + ce.row) * logPerRow }, ce)
      if ce.endRow then
        local eRow = math.min(r + ce.endRow, capRow)
        e.endppq         = math.min(ctx:rowToPPQ(r + ce.endRow, chan), endppq)
        e.endppqL = eRow * logPerRow
      end
      util.add(events, e)
      ::nextCe::
    end
    table.sort(events, function(a, b) return a.ppq < b.ppq end)

    if clip.type == 'note' and dstCol.type == 'note' and kind == 'pitch' then
      local velList = {}
      for evt in util.between(dstCol.events, startppq, endppq) do
        if evt.pitch and evt.vel > 0 then
          util.add(velList, { ppq = evt.ppq, val = evt.vel })
        end
      end
      local last = util.seek(dstCol.events, 'before', startppq)
      local currentVel = last and last.vel or cm:get('defaultVelocity')

      local lastNote = util.seek(dstCol.events, 'before', startppq, util.isNote)
      local nextNote = util.seek(dstCol.events, 'at-or-after', endppq, util.isNote)
      local nextNotePPQ = nextNote and nextNote.ppq or getLength()
      local lane = dstCol.lane

      -- Delete in-region events directly: queueDeleteNotes' survivor-extension
      -- fixup is for leaving a hole, but we're filling it. An extended lastNote
      -- would overlap the new notes and force the allocator to spill on rebuild.
      if lastNote and events[1] and lastNote.endppq > events[1].ppq then
        assignTail(lastNote, dstCol.midiChan, events[1].ppq, events[1].ppqL)
      end
      for evt in util.between(dstCol.events, startppq, endppq) do
        tm:deleteEvent(evt.type == 'pa' and 'pa' or 'note', evt)
      end

      local frame = currentFrame(dstCol.midiChan)
      local capEndppqL = ctx:ppqToRow(nextNotePPQ, chan) * logPerRow
      local vi = 1
      for _, ce in ipairs(events) do
        while vi <= #velList and velList[vi].ppq <= ce.ppq do
          currentVel = util.clamp(velList[vi].val, 1, 127)
          vi = vi + 1
        end
        tm:addEvent('note', {
          ppq            = ce.ppq,
          endppq         = ce.endppq         or nextNotePPQ,
          ppqL    = ce.ppqL,
          endppqL = ce.endppqL or capEndppqL,
          chan = dstCol.midiChan, pitch = ce.pitch, vel = currentVel,
          lane = lane,
          frame = frame,
        })
      end
      tm:flush()
      return
    end

    if clip.type == '7bit' and dstCol.type == 'note' and kind == 'vel' then
      pasteVelocities(events, dstCol, startppq, endppq)
      return
    end

    if (clip.type == 'pb' and dstCol.type == 'pb')
    or (clip.type == '7bit' and dstCol.type ~= 'note' and dstCol.type ~= 'pb') then
      for evt in util.between(dstCol.events, startppq, endppq) do
        tm:deleteEvent(dstCol.type, evt)
      end

      local frame = currentFrame(dstCol.midiChan)
      for _, ce in ipairs(events) do
        local add = {
          ppq = ce.ppq, ppqL = ce.ppqL,
          chan = dstCol.midiChan, val = ce.val, frame = frame,
        }
        if dstCol.type == 'cc' then add.cc = dstCol.cc end
        tm:addEvent(dstCol.type, add)
      end
      tm:flush()
      return
    end
  end

  local function pasteMulti(clip)
    local ctx = getCtx()
    local cursor = grid.cols[ec:col()]
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

    local cursorNotePos = cursor.lane or 0

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

    local cRow = ec:row()
    local logPerRow = ctx:ppqPerRow()
    local capRow = cRow + clip.numRows
    for _, clipCol in ipairs(clip.cols) do
      local r = resolve(clipCol)
      if not r then goto nextCol end
      local dst = r.col
      local startppq = ctx:rowToPPQ(cRow, r.chan)
      local endppq   = ctx:rowToPPQ(capRow, r.chan)

      -- Materialise clip events to target PPQs, sorted.
      local events = {}
      for _, ce in ipairs(clipCol.events) do
        local ppq = ctx:rowToPPQ(cRow + ce.row, r.chan)
        if ppq < endppq then
          local e = util.assign({ ppq = ppq, ppqL = (cRow + ce.row) * logPerRow }, ce)
          if ce.endRow then
            local eRow = math.min(cRow + ce.endRow, capRow)
            e.endppq         = math.min(ctx:rowToPPQ(cRow + ce.endRow, r.chan), endppq)
            e.endppqL = eRow * logPerRow
          end
          util.add(events, e)
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
          local last = util.seek(dst.events, 'before', startppq, util.isNote)
          if last and events[1] and last.endppq > events[1].ppq then
            assignTail(last, r.chan, events[1].ppq, events[1].ppqL)
          end
          for evt in util.between(dst.events, startppq, endppq, util.isNote) do
            tm:deleteEvent('note', evt)
          end
        else
          for evt in util.between(dst.events, startppq, endppq) do
            tm:deleteEvent(r.type, evt)
          end
        end
      end

      -- End cap for pasted notes that lack an explicit endppq.
      local capPPQ      = endppq
      local capppqL = capRow * logPerRow
      if r.type == 'note' and dst then
        local nn = util.seek(dst.events, 'at-or-after', endppq, util.isNote)
        if nn then
          capPPQ      = math.min(capPPQ, nn.ppq)
          capppqL = math.min(capppqL, ctx:ppqToRow(nn.ppq, r.chan) * logPerRow)
        end
      end

      -- Write clip events.
      local frame = currentFrame(r.chan)
      for _, e in ipairs(events) do
        if r.type == 'note' then
          tm:addEvent('note', {
            ppq = e.ppq, endppq = e.endppq or capPPQ,
            ppqL    = e.ppqL,
            endppqL = e.endppqL or capppqL,
            chan = r.chan, pitch = e.pitch, vel = e.vel,
            lane = r.lane, frame = frame,
          })
        elseif r.type == 'cc' then
          tm:addEvent('cc', {
            ppq = e.ppq, ppqL = e.ppqL,
            chan = r.chan, cc = r.ccNum, val = e.val, frame = frame,
          })
        else
          tm:addEvent(r.type, {
            ppq = e.ppq, ppqL = e.ppqL,
            chan = r.chan, val = e.val, frame = frame,
          })
        end
      end
      ::nextCol::
    end
    tm:flush()
  end

  local function pasteClip(clip)
    if clip.mode == 'single' then pasteSingle(clip) else pasteMulti(clip) end
  end

  -- Drop the top `trim` rows of a clip in place, re-indexing surviving events.
  -- A note whose start row falls within the trimmed band is dropped entirely.
  local function trimTop(clip, trim)
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

  ---------- PUBLIC

  local clipboard = {}
  function clipboard:collect()           return collect() end
  function clipboard:copy()              local c = collect(); if c then save(c) end end
  function clipboard:pasteClip(clip)     pasteClip(clip) end
  function clipboard:trimTop(clip, trim) trimTop(clip, trim) end

  function clipboard:registerCommands(cmgr)
    cmgr:registerAll{
      copy  = function() local c = collect(); if c then save(c) end; ec:selClear() end,
      paste = function()
        if ec:isSticky() then ec:selClear()
        else local c = load(); if c then pasteClip(c) end
        end
      end,
    }
  end

  return clipboard
end
