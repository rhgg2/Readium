-- See docs/viewManager.md for the model and API reference.

loadModule('util')
loadModule('midiManager')
loadModule('trackerManager')
loadModule('microtuning')
loadModule('commandManager')
loadModule('editCursor')

local function print(...)
  return util.print(...)
end

function newViewContext(args)
  local swing      = args.swing
  local rowPPQs    = args.rowPPQs
  local length     = args.length
  local numRows    = args.numRows
  local rowPerBeat = args.rowPerBeat
  local ppqPerRow  = args.ppqPerRow
  local timeSigs   = args.timeSigs
  local tuning     = args.tuning
  local ctx        = {}

  ----- Tuning

  function ctx:activeTuning() return tuning end

  function ctx:noteProjection(evt)
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

  ----- Timing

  function ctx:ppqToRow(ppq, chan)
    ppq = swing.unapply(chan, ppq)
    if ppq <= 0 then return 0 end
    if ppq >= length then return numRows end
    local lo, hi = 0, numRows - 1
    while lo < hi do
      local mid = (lo + hi + 1) // 2
      if rowPPQs[mid] <= ppq then lo = mid else hi = mid - 1 end
    end
    local rowStart = rowPPQs[lo]
    local rowEnd   = rowPPQs[lo + 1] or length
    return lo + (rowEnd > rowStart and (ppq - rowStart) / (rowEnd - rowStart) or 0)
  end

  function ctx:rowToPPQ(row, chan)
    if row <= 0 then return 0 end
    if row >= numRows then return length end
    local r        = math.floor(row)
    local frac     = row - r
    local rowStart = rowPPQs[r]
    local rowEnd   = rowPPQs[r + 1] or length
    return math.floor(swing.apply(chan, rowStart + frac * (rowEnd - rowStart)) + 0.5)
  end

  function ctx:snapRow(ppq, chan) return util.round(self:ppqToRow(ppq, chan)) end

  -- Did `ppq` come from authoring on an integer row in this frame?
  -- Returns the row if so, nil otherwise. Sidesteps the ε amplification
  -- that knocks ppqToRow off-row under steep apply slopes (extreme
  -- atoms, multi-atom composites): the inverse-via-unapply guess is
  -- noisy but the forward round-trip test is exact.
  function ctx:authoredRow(ppq, chan)
    local hint = util.round(swing.unapply(chan, ppq) / ppqPerRow)
    return timing.recoverAuthoredRow(
      function(p) return swing.apply(chan, p) end,
      ppqPerRow, ppq, hint)
  end

  do -- exports ctx:rowBeatInfo, ctx:barBeatSub
    local function timeSigAt(ppq)
      local active = timeSigs[1]
      for i = 2, #timeSigs do
        if timeSigs[i].ppq <= ppq then active = timeSigs[i]
        else break end
      end
      return active
    end

    local function tsRow(ts) return math.floor(ctx:ppqToRow(ts.ppq)) end

    function ctx:rowBeatInfo(row)
      local ts = timeSigAt(self:rowToPPQ(row))
      if not ts then return false, false end
      local rel = row - tsRow(ts)
      return rel % (rowPerBeat * ts.num) == 0, rel % rowPerBeat == 0
    end

    function ctx:barBeatSub(row)
      local bar = 1
      for i, ts in ipairs(timeSigs) do
        local rpbar   = rowPerBeat * ts.num
        local next_   = timeSigs[i + 1]
        local nextRow = next_ and tsRow(next_) or math.huge
        if row < nextRow then
          local rel = row - tsRow(ts)
          return bar + rel // rpbar,
            (rel % rpbar) // rowPerBeat + 1,
            rel % rowPerBeat + 1,
            ts
        end
        bar = bar + (nextRow - tsRow(ts)) // rpbar
      end
      return bar, 1, 1, timeSigs[1]
    end
  end

  return ctx
end

function newViewManager(tm, cm, cmgr)

  ---------- PRIVATE

  local resolution    = 240
  local rowPerBar     = 16
  local rowPPQs       = {}
  local length        = 0
  local timeSigs      = {}

  local scrollCol   = 1
  local scrollRow   = 0

  local gridWidth   = 0
  local gridHeight  = 0

  local grid = {
    cols         = {},
    chanFirstCol = {},
    chanLastCol  = {},
  }

  local vm = {}
  vm.grid = grid  -- live handle for rm; mutated in place on rebuild

  local ec, clipboard, ctx

  ---------- SHARED HELPERS

  ----- Note geometry (used by editing, adjust*, nudge, quantizeKeepRealised)

  local function overlapBounds(col, ppq, excludeEvt, allowOverlap)
    local off  = allowOverlap and cm:get('overlapOffset') * resolution or 0
    local pred = excludeEvt
      and function(e) return util.isNote(e) and e ~= excludeEvt end
      or util.isNote
    local prev = util.seek(col.events, 'before', ppq, pred)
    local next = util.seek(col.events, 'after',  ppq, pred)
    local minStart = prev and (prev.endppq + timing.delayToPPQ(prev.delay, resolution) - off) or 0
    local maxEnd   = next and (next.ppq    + timing.delayToPPQ(next.delay, resolution) + off) or length
    return minStart, maxEnd
  end

    local function delayRange(col, n)
        local minStart, maxEnd = overlapBounds(col, n.ppq, n, true)
        return timing.ppqToDelay(minStart - n.ppq, resolution), timing.ppqToDelay(maxEnd - n.endppq, resolution)
    end

  ----- Show events by column, used by lots of selection ops

  local function eventsByCol()
    local r1, r2, c1, c2, kind1, kind2 = ec:region()
    local singleNoteKind = (c1 == c2 and kind1 == kind2
      and grid.cols[c1] and grid.cols[c1].type == 'note') and kind1 or nil

    local result = {}
    for ci = c1, c2 do
      local col = grid.cols[ci]
      if not col then goto nextCol end

      local startPPQ, endPPQ = ctx:rowToPPQ(r1, col.midiChan), ctx:rowToPPQ(r2 + 1, col.midiChan)
      local locs = {}
      -- Keyed by event reference, not loc: notes and CCs use disjoint loc
      -- spaces, so a PA (cc loc=N) and a note (note loc=N) can collide.
      for evt in util.between(col.events, startPPQ, endPPQ) do
        locs[evt] = evt
      end

      local kind = col.type == 'note' and (singleNoteKind or 'pitch') or 'val'
      util.add(result, { col = col, locs = locs, kind = kind })
      ::nextCol::
    end
    return result
  end

  ----- Frames & timing

  -- An authoring frame comprises swing slot, per-column swing map,
  -- and rowPerBeat.
  local isFrameChange, currentFrame, releaseTransientFrame do
    local FRAME_KEYS = { swing = true, colSwing = true, rowPerBeat = true }

    function isFrameChange(change)
      return FRAME_KEYS[change.key] and change.level ~= 'transient'
    end

    function currentFrame(chan)
      return {
        swing    = cm:get('swing'),
        colSwing = cm:get('colSwing')[chan],
        rpb      = cm:get('rowPerBeat'),
      }
    end

    -- Drop the transient frame override (if any). Returns true if a
    -- frame was released, false otherwise.
    function releaseTransientFrame()
      local releasing = false
      for k in pairs(FRAME_KEYS) do
        if cm:getAt('transient', k) ~= nil then releasing = true; break end
      end
      if not releasing then return false end

      local oldRPB = cm:get('rowPerBeat')
      cm:assign('transient', {
                  swing      = util.REMOVE,
                  colSwing   = util.REMOVE,
                  rowPerBeat = util.REMOVE,
      })
      local newRPB = cm:get('rowPerBeat')
      if newRPB ~= oldRPB then
        ec:rescaleRow(oldRPB, newRPB)
        vm:rebuild(false)
      end
      return true
    end
  end

  -- Set grid to the cursor's frame, or release if already overriding.
  local function matchGridToCursor()
    if releaseTransientFrame() then return end

    local col = grid.cols[ec:col()]
    local evt = col and col.type == 'note' and col.cells and col.cells[ec:row()]
    if not (evt and evt.frame) then return end
    -- Rescale ec before the cm:assign so the rebuild it fires sees ec
    -- already aligned to the new rpb.
    local oldRPB = cm:get('rowPerBeat')
    if evt.frame.rpb ~= oldRPB then ec:rescaleRow(oldRPB, evt.frame.rpb) end
    local cs = cm:get('colSwing')
    cs[col.midiChan] = evt.frame.colSwing
    cm:assign('transient', {
      swing      = evt.frame.swing,
      colSwing   = cs,
      rowPerBeat = evt.frame.rpb,
    })
  end

  function vm:setRowPerBeat(n)
    n = util.clamp(n, 1, 32)
    if n == cm:get('rowPerBeat') then return end
    -- Release before cm:set: otherwise configCallback sees a non-transient
    -- frame-key write and rescales ec on top of our own rescaleRow below.
    -- Release may itself rescale; re-read so our rescale is from the
    -- post-release rpb (no-op if release already landed us at n).
    releaseTransientFrame()
    ec:rescaleRow(cm:get('rowPerBeat'), n)
    cm:set('track', 'rowPerBeat', n)
  end

  function vm:setSwingSlot(name)
    if name and name ~= '' then cm:set('take', 'swing', name)
    else cm:remove('take', 'swing') end
  end

  function vm:setSwingComposite(name, composite)
    if not name or name == '' then return end
    local lib = cm:getAt('project', 'swings') or {}
    lib[name] = composite
    cm:set('project', 'swings', lib)
  end

  local function cycleSwing()
    local stops = { 'off', 'classic-55', 'classic-58', 'classic-62', 'classic-67' }
    local cur = cm:get('swing') or 'off'
    local i = 1
    for k, v in ipairs(stops) do if v == cur then i = k; break end end
    local next = stops[(i % #stops) + 1]
    if next == 'off' then
      cm:remove('take', 'swing')
    else
      -- Seed into project lib on first use so the slot name resolves.
      local lib = cm:get('swings')
      if not lib[next] then
        local proj = cm:getAt('project', 'swings') or {}
        proj[next] = timing.presets[next]
        cm:set('project', 'swings', proj)
      end
      cm:set('take', 'swing', next)
    end
    util.print('swing: ' .. next)
  end

  local function cycleTuning()
    local names = { '12EDO', '19EDO', '31EDO', '53EDO' }
    local cur, i = cm:get('tuning'), 0
    for k, v in ipairs(names) do if v == cur then i = k; break end end
    cm:set('track', 'tuning', names[(i + 1) % (#names + 1)])
  end

  ----- Mute / solo

  local pushMute do
    local effectiveMuted = {}  -- cached for cheap per-cell render queries

    local function toggleChannelFlag(key, chan)
      local s = cm:get(key)
      s[chan] = (not s[chan]) or nil
      cm:set('take', key, s)
    end

    function pushMute()
      local m = cm:get('mutedChannels')
      local s = cm:get('soloedChannels')
      if next(s) then
        for c = 1, 16 do
          if s[c] then m[c] = nil
          else        m[c] = true end
        end
      end
      effectiveMuted = m
      if tm then tm:setMutedChannels(effectiveMuted) end
    end

    function vm:isChannelMuted(chan)            return cm:get('mutedChannels')[chan]  == true end
    function vm:isChannelSoloed(chan)           return cm:get('soloedChannels')[chan] == true end
    function vm:isChannelEffectivelyMuted(chan) return effectiveMuted[chan] == true end
    function vm:toggleChannelMute(chan)         toggleChannelFlag('mutedChannels',  chan) end
    function vm:toggleChannelSolo(chan)         toggleChannelFlag('soloedChannels', chan) end
  end

  ----- Audition

  local audition, killAudition do
    local auditionNote     = nil  -- { chan, pitch } (chan is 0-indexed for MIDI)
    local auditionTime     = 0    -- reaper.time_precise() when note was sent
    local AUDITION_TIMEOUT = 0.8  -- seconds

    function killAudition()
      if not auditionNote then return end
      reaper.StuffMIDIMessage(0, 0x80 | auditionNote.chan, auditionNote.pitch, 0)
      auditionNote = nil
    end

    function audition(pitch, vel, chan)
      killAudition()
      local midiChan = (chan or 1) - 1  -- internal 1-indexed → MIDI 0-indexed
      reaper.StuffMIDIMessage(0, 0x90 | midiChan, pitch, vel or 100)
      auditionNote = { chan = midiChan, pitch = pitch }
      auditionTime = reaper.time_precise()
    end

    function vm:tick()
      if auditionNote and reaper.time_precise() - auditionTime > AUDITION_TIMEOUT then
        killAudition()
      end
    end
  end

  ----- Viewport

  local followViewport do
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

    function followViewport()
      local maxRow = math.max(0, (grid.numRows or 1) - 1)
      local cRow, cCol = ec:row(), ec:col()

      -- Row follow (skip before gridHeight is set to avoid inverted bounds)
      if gridHeight > 0 then
        local maxScroll = math.max(0, maxRow - gridHeight + 1)
        scrollRow = util.clamp(scrollRow,
                               math.max(0, cRow - gridHeight + 1),
                               math.min(cRow, maxScroll))
      end

      scrollCol = util.clamp(scrollCol, 1, #grid.cols)
      if cCol < scrollCol then
        scrollCol = cCol
      elseif cCol > lastVisibleFrom(scrollCol) then
        while scrollCol < cCol do
          scrollCol = scrollCol + 1
          if cCol <= lastVisibleFrom(scrollCol) then break end
        end
      end
    end

    function vm:scroll()
      return scrollRow, scrollCol, lastVisibleFrom(scrollCol)
    end
  end

  ----- Editing

  local addNoteEvent do
    local hexDigit = {}
    for i = 0, 9 do hexDigit[string.byte(tostring(i))] = i end
    for i = 0, 5 do
      hexDigit[string.byte('a') + i] = 10 + i
      hexDigit[string.byte('A') + i] = 10 + i
    end

    function addNoteEvent(update)
      update.frame = currentFrame(update.chan)
      tm:addEvent('note', update)
    end

    local function placeNewNote(col, update)
      local last = util.seek(col.events, 'before', update.ppq, util.isNote)
      local next = util.seek(col.events, 'after',  update.ppq, util.isNote)
      if last and last.endppq >= update.ppq then
        tm:assignEvent('note', last, { endppq = update.ppq })
      end
      update.vel    = last and last.vel or cm:get('defaultVelocity')
      update.endppq = next and next.ppq or length
      update.lane   = col.lane
      addNoteEvent(update)
    end

    local function notePAEvents(col, pitch, startPPQ, endPPQ)
      local pas = {}
      for _, evt in ipairs(col.events) do
        if evt.type == 'pa' and evt.pitch == pitch
          and evt.ppq >= startPPQ and evt.ppq <= endPPQ then
          util.add(pas, evt)
        end
      end
      return pas
    end

    function vm:editEvent(col, evt, stop, char, half)
      if not col then return end
      local type = col.type
      local cursorPPQ = ctx:rowToPPQ(ec:row(), col.midiChan)

      local function commit(auditionPitch, auditionVel)
        tm:flush()
        ec:advance()
        killAudition()
        if auditionPitch then audition(auditionPitch, auditionVel or 100, col.midiChan) end
      end

      -- Off-grid write snaps intent to the cursor row
      local function snap(update)
        if not evt or evt.ppq == cursorPPQ then return update end
        update.ppq = cursorPPQ
        if evt.endppq then update.endppq = cursorPPQ + (evt.endppq - evt.ppq) end
        return update
      end

      if type == 'note' then

        if stop == 1 then
          local nk = cmgr:noteChars(char); if not nk then return end
          local pitch = util.clamp((cm:get('currentOctave') + 1 + nk[2]) * 12 + nk[1], 0, 127)
          local detune = 0
          local tuning = ctx:activeTuning()
          if tuning then pitch, detune = microtuning.snap(tuning, pitch, 0) end

          -- Existing note → repitch, snapping intent time to the cursor row.
          -- tm clears same-(chan, pitch) overlaps at the write boundary.
          if util.isNote(evt) then
            tm:assignEvent('note', evt, snap({ pitch = pitch, detune = detune }))
            return commit(pitch, evt.vel)
          end

          -- PA cell → wipe host's PA tail, then fall through
          if evt and evt.type == 'pa' then
            local host = util.seek(col.events, 'before', evt.ppq, util.isNote)
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

        elseif stop == 2 then
          if not util.isNote(evt) then return end
          local oct
          if char == string.byte('-') then oct = -1
          else
            local d = char - string.byte('0')
            if d < 0 or d > 9 then return end
            oct = d
          end
          local pitch = util.clamp((oct + 1) * 12 + evt.pitch % 12, 0, 127)
          tm:assignEvent('note', evt, { pitch = pitch })
          return commit(pitch, evt.vel)

        -- delay: signed decimal milli-QN, 3 digits, ±999
        elseif stop == 5 or stop == 6 or stop == 7 then
          if not util.isNote(evt) then return end
          local old = evt.delay

          local newDelay
          if char == string.byte('-') then
            if old == 0 then return end
            newDelay = -old
          else
            local d = char - string.byte('0')
            if d < 0 or d > 9 then return end
            local sign = old < 0 and -1 or 1
            local mag  = util.clamp(util.setDigit(math.abs(old), d, 7 - stop, 10, half), 0, 999)
            newDelay = sign * mag
          end

          local minD, maxD = delayRange(col, evt)
          newDelay = util.clamp(newDelay, math.ceil(minD), math.floor(maxD))
          tm:assignEvent('note', evt, { delay = newDelay })
          return commit()

        -- velocity nibble (on note) or PA value
        else
          local d = hexDigit[char]; if not d then return end
          local function newVel(old)
            return util.clamp(util.setDigit(old, d, 4 - stop, 16, half), 1, 127)
          end

          if evt and evt.type == 'pa' then
            tm:assignEvent('pa', evt, snap({ val = newVel(evt.val) }))
            return commit()
          end

          if evt then
            tm:assignEvent('note', evt, { vel = newVel(evt.vel) })
            return commit()
          end

          if cm:get('polyAftertouch') then
            local note = util.seek(col.events, 'before', cursorPPQ, util.isNote)
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

      -- non-note columns
      local update
      if util.oneOf('cc at pc', type) then
        local d = hexDigit[char]; if not d then return end
        update = { val = util.clamp(util.setDigit(evt and evt.val or 0, d, 2 - stop, 16, half), 0, 127) }
      elseif type == 'pb' then
        local old = evt and evt.val or 0
        if char == string.byte('-') then
          if old == 0 then return end
          update = { val = -old }
        else
          local d = char - string.byte('0')
          if d < 0 or d > 9 then return end
          local sign = old < 0 and -1 or 1
          update = { val = sign * util.setDigit(math.abs(old), d, 4 - stop, 10, half) }
        end
      else
        return
      end

      if evt then
        tm:assignEvent(type, evt, snap(update))
      else
        if type == 'cc' then util.assign(update, { cc = col.cc }) end
        util.assign(update, { ppq = cursorPPQ, chan = col.midiChan })
        tm:addEvent(type, update)
      end
      commit()
    end
  end

  ----- Interpolation

  local interpolate, interpolateValues do
    local interpolable = { cc = true, pb = true, at = true }
    local shapeCycle = { 'step', 'linear', 'slow', 'fast-start', 'fast-end' }

    local function nextShape(s)
      for i, n in ipairs(shapeCycle) do
        if n == s then return shapeCycle[(i % #shapeCycle) + 1] end
      end
      return 'linear'
    end

    local function cycleShape(col, A)
      if not A then return end
      tm:assignEvent(col.type, A, { shape = nextShape(A.shape or 'step') })
    end

    function interpolate()
      if ec:hasSelection() then
        local r1, r2 = ec:region()
        for col in ec:eachSelectedCol() do
          if interpolable[col.type] then
            local startPPQ, endPPQ = ctx:rowToPPQ(r1, col.midiChan), ctx:rowToPPQ(r2 + 1, col.midiChan)
            local prev
            for evt in util.between(col.events, startPPQ, endPPQ) do
              if prev then cycleShape(col, prev) end
              prev = evt
            end
          end
        end
        tm:flush()
        return
      end

      local col = grid.cols[ec:col()]
      if not (col and interpolable[col.type]) then return end
      local r = ec:row()
      local ghost = col.ghosts and col.ghosts[r]
      local A = ghost and ghost.fromEvt
        or (col.cells and col.cells[r])
        or util.seek(col.events, 'before', ctx:rowToPPQ(r + 1, col.midiChan))
      if A then cycleShape(col, A); tm:flush() end
    end

    -- Sample shape-cycled value events at every empty row between each pair.
    -- Returns nil for non-interpolable cols so callers can assign unconditionally.
    function interpolateValues(col)
      if not interpolable[col.type] then return end
      local events, chan, occupied = col.events, col.midiChan, col.cells
      local ghosts = {}
      for i = 1, #events - 1 do
        local A, B = events[i], events[i + 1]
        if A.shape and A.shape ~= 'step' then
          local rA = ctx:ppqToRow(A.ppq, chan)
          local rB = ctx:ppqToRow(B.ppq, chan)
          for y = util.round(rA) + 1, util.round(rB) - 1 do
            if y >= 0 and y < grid.numRows and not (occupied and occupied[y]) then
              local val = tm:interpolate(A, B, ctx:rowToPPQ(y, chan))
              ghosts[y] = { val = util.round(val), fromEvt = A, toEvt = B }
            end
          end
        end
      end
      return ghosts
    end
  end

  ----- Duration & position

  local noteOff, adjustDuration, adjustPosition do
    local function cursorNoteBefore()
      local col = grid.cols[ec:col()]
      if not (col and col.type == 'note') then return end
      local cursorPPQ = ctx:rowToPPQ(ec:row(), col.midiChan)
      return col, util.seek(col.events, 'at-or-before', cursorPPQ, util.isNote)
    end

    local function applyNoteOff(col, last, targetPPQ, undo)
      if undo then
        local next = util.seek(col.events, 'at-or-after', targetPPQ, util.isNote)
        tm:assignEvent('note', last, { endppq = next and next.ppq or length })
      elseif last.ppq >= targetPPQ then
        tm:deleteEvent('note', last)
      else
        local _, maxEnd = overlapBounds(col, last.ppq, last, true)
        tm:assignEvent('note', last, { endppq = util.clamp(targetPPQ, last.ppq + 1, maxEnd) })
      end
    end

    function noteOff()
      if ec:hasSelection() then
        local r1 = ec:region()
        local hits = {}
        for col in ec:eachSelectedCol() do
          if col.type == 'note' then
            local chan = col.midiChan
            local targetPPQ = ctx:rowToPPQ(r1, chan)
            local nextPPQ   = ctx:rowToPPQ(r1 + 1, chan)
            local last = util.seek(col.events, 'before', nextPPQ, util.isNote)
            if last then util.add(hits, { col = col, note = last, targetPPQ = targetPPQ }) end
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

      local col = grid.cols[ec:col()]
      if not (col and col.type == 'note' and ec:cursorKind() == 'pitch') then return false end
      local r = ec:row()
      local cursorPPQ     = ctx:rowToPPQ(r,     col.midiChan)
      local nextCursorPPQ = ctx:rowToPPQ(r + 1, col.midiChan)

      local last = util.seek(col.events, 'before', nextCursorPPQ, util.isNote)
      if not last then return end
      applyNoteOff(col, last, cursorPPQ, last.endppq == cursorPPQ)
      tm:flush()
    end

    local function adjustDurationCore(col, note, rowDelta)
      local chan = col.midiChan
      local newRow = util.clamp(ctx:ppqToRow(note.endppq, chan) + rowDelta, 0, grid.numRows)
            newRow = math.floor(newRow / rowDelta) * rowDelta
      local minPPQ = math.min(note.endppq, ctx:rowToPPQ(ctx:snapRow(note.ppq, chan) + 1, chan))
      local _, maxPPQ = overlapBounds(col, note.ppq, note, true)
      local newPPQ = util.clamp(ctx:rowToPPQ(newRow, chan), minPPQ, maxPPQ)
      tm:assignEvent('note', note, { endppq = newPPQ })
    end

    function adjustDuration(rowDelta)
      if ec:hasSelection() then
        for _, group in ipairs(eventsByCol()) do
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
      for _, g in ipairs(eventsByCol()) do
        if g.col.type == 'note' then
          local chan = g.col.midiChan
          local ns = {}
          for _, n in pairs(g.locs) do util.add(ns, n) end
          if #ns > 0 then
            table.sort(ns, function(a, b) return a.ppq < b.ppq end)
            if rowDelta > 0 then
              local _, maxEnd = overlapBounds(g.col, ns[#ns].ppq, ns[#ns], false)
              local room = math.floor(ctx:ppqToRow(maxEnd, chan) - ctx:snapRow(ns[#ns].endppq, chan))
              if room < rowDelta then return end
            else
              local minStart = overlapBounds(g.col, ns[1].ppq, ns[1], false)
              local room = math.ceil(ctx:ppqToRow(minStart, chan) - ctx:snapRow(ns[1].ppq, chan))
              if room > rowDelta then return end
            end
            util.add(runs, { col = g.col, notes = ns })
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
            ppq    = ctx:rowToPPQ(ctx:ppqToRow(n.ppq, chan)    + rowDelta, chan),
            endppq = ctx:rowToPPQ(ctx:ppqToRow(n.endppq, chan) + rowDelta, chan),
          })
        end
      end
      tm:flush()
      ec:shiftSelection(rowDelta)
    end

    function adjustPosition(rowDelta)
      if ec:hasSelection() then return adjustPositionMulti(rowDelta) end

      local col, note = cursorNoteBefore()
      if not col or not note then return end
      local chan = col.midiChan

      local absDelta = math.abs(rowDelta)
      local rawRow   = ctx:ppqToRow(note.ppq, chan) + rowDelta
      local reqRow   = (rowDelta > 0 and math.ceil(rawRow / absDelta) or math.floor(rawRow / absDelta)) * absDelta

      local curLen    = ctx:snapRow(note.endppq, chan) - ctx:snapRow(note.ppq, chan)
      local minLen    = math.min(absDelta, curLen)
      local minPPQ, maxEndPPQ = overlapBounds(col, note.ppq, note, false)
      local minRow    = ctx:ppqToRow(minPPQ, chan)
      local maxEndRow = ctx:ppqToRow(maxEndPPQ, chan)

      local newEndRow, newRow
      if rowDelta > 0 then
        newEndRow = math.min(reqRow + curLen, maxEndRow)
        newRow    = math.min(reqRow, newEndRow - minLen)
      else
        newRow    = math.max(reqRow, minRow)
        newEndRow = math.max(reqRow + curLen, newRow + minLen)
      end
      local newPPQ = ctx:rowToPPQ(newRow, chan)
      local newEndPPQ = ctx:rowToPPQ(newEndRow, chan)

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
  end

  ----- Reswing / quantize

  local reswingPresetChange do

    -- Every column, every event, as a groups list (for *-all variants).
    local function allGroups()
      local groups = {}
      for _, col in ipairs(grid.cols) do
        local locs = {}
        for _, e in ipairs(col.events) do locs[e.loc] = e end
        util.add(groups, { col = col, locs = locs })
      end
      return groups
    end

    -- Frame owner for reswing. Notes own themselves. CC/PB/AT/PC inherit
    -- from the most recent lane-1 note at-or-before their ppq on the same
    -- channel; PAs from the note they attach to (pitch match within span).
    -- Orphans (no lane-1 note / no host) return nil and are skipped.
    local function frameOwner(col, e)
      if util.isNote(e) then return e end
      local n1 = grid.lane1Col[col.midiChan]
      if not n1 then return end
      if e.type == 'pa' then
        for _, n in ipairs(n1.events) do
          if n.pitch == e.pitch and n.ppq <= e.ppq and e.ppq <= n.endppq then
            return n
          end
        end
        return
      end
      return util.seek(n1.events, 'at-or-before', e.ppq, util.isNote)
    end

    -- Authoring straight-PPQ-per-row for a given frame's rpb. Mirrors the
    -- rebuild-time formula at line ~1560.
    local function ppqPerRowOf(rpb)
      local denom = (timeSigs[1] and timeSigs[1].denom) or 4
      return resolution * 4 / (denom * rpb)
    end

    -- Recover intent from a stored realised PPQ, then rebuild under tgt.
    -- For on-grid notes in the auth frame, pin intent to the exact row
    -- so re-applying tgt doesn't drift them off-grid (see
    -- timing.recoverAuthoredRow).
    local function reswungPPQ(auth, tgt, frame, chan, ppq)
      local u = auth and auth.unapply(chan, ppq) or ppq
      if auth and frame then
        local ppqPerRow = ppqPerRowOf(frame.rpb)
        local r = timing.recoverAuthoredRow(
          function(p) return auth.apply(chan, p) end,
          ppqPerRow, ppq, util.round(u / ppqPerRow))
        if r then u = util.round(r * ppqPerRow) end
      end
      return math.min(length, util.round(tgt.apply(chan, u)))
    end

    -- opts: { include?, auth, target, restamp? }. auth nil means identity
    -- (legacy notes without a frame). Two passes — gather plans, then
    -- mutate — so writes in this batch don't disturb later reads of their
    -- owners' .frame.
    -- Writes past `length` make REAPER auto-extend the take's source on
    -- MIDI_Sort, which then leaks an extra row into the next rebuild
    -- (numRows is derived from source length). Clamp on the way out.
    local function reswingCore(groups, opts)
      local plans = {}
      for _, g in ipairs(groups) do
        local col, chan = g.col, g.col.midiChan
        for _, e in pairs(g.locs) do
          local owner = frameOwner(col, e)
          if owner and (not opts.include or opts.include(owner, chan)) then
            local auth  = opts.auth(owner.frame, chan)
            local tgt   = opts.target(owner.frame, chan)
            local frame = owner.frame
            local entry = { col = col, e = e, newPPQ = reswungPPQ(auth, tgt, frame, chan, e.ppq) }
            if util.isNote(e) then
              entry.newEndPPQ = reswungPPQ(auth, tgt, frame, chan, e.endppq)
              if opts.restamp then entry.newFrame = opts.restamp(chan) end
            end
            util.add(plans, entry)
          end
        end
      end
      -- Monotone reparameterisation: the end-state can't introduce new
      -- same-(chan, pitch) overlaps, so opt out of tm's per-write clamp.
      -- Without this, the first-processed of two legato siblings would
      -- see its endppq clipped against the second's still-old ppq.
      local trust = { trustGeometry = true }
      for _, p in ipairs(plans) do
        local e, u = p.e, {}
        if p.newPPQ ~= e.ppq then u.ppq = p.newPPQ end
        if util.isNote(e) then
          if p.newEndPPQ ~= e.endppq then u.endppq = p.newEndPPQ end
          if p.newFrame then u.frame = p.newFrame end
          if next(u) then tm:assignEvent('note', e, u, trust) end
        elseif next(u) then
          tm:assignEvent(p.col.type, e, u, trust)
        end
      end
      tm:flush()
    end

    local function reswingScope(groups)
      local curSnap = tm:swingSnapshot()
      local cache   = {}
      local function auth(frame, chan)
        if not frame then return nil end
        local hit = cache[frame]
        if hit then return hit end
        hit = tm:swingSnapshot({ swing = frame.swing, colSwing = { [chan] = frame.colSwing } })
        cache[frame] = hit
        return hit
      end
      reswingCore(groups, {
        auth    = auth,
        target  = function() return curSnap end,
        restamp = function(chan) return currentFrame(chan) end,
      })
    end

    -- Name unchanged (only the composite behind it moved), so no restamp.
    -- libOverride inlines both composites so this is independent of the
    -- library's current state.
    function reswingPresetChange(name, oldComp, newComp)
      local authCache, tgtCache = {}, {}
      local function snapWith(frame, chan, comp, cache)
        local hit = cache[frame]
        if hit then return hit end
        hit = tm:swingSnapshot({
          swing       = frame.swing,
          colSwing    = { [chan] = frame.colSwing },
          libOverride = { [name] = comp },
        })
        cache[frame] = hit
        return hit
      end
      reswingCore(allGroups(), {
        include = function(owner)
          local f = owner.frame
          return f and (f.swing == name or f.colSwing == name) or false
        end,
        auth   = function(frame, chan) return snapWith(frame, chan, oldComp, authCache) end,
        target = function(frame, chan) return snapWith(frame, chan, newComp, tgtCache)  end,
      })
    end

    local function quantizeScope(groups)
      for _, g in ipairs(groups) do
        local col, chan = g.col, g.col.midiChan
        for _, e in pairs(g.locs) do
          local sRow   = ctx:ppqToRow(e.ppq, chan)
          local newRow = util.round(sRow)
          local newPPQ = ctx:rowToPPQ(newRow, chan)
          if util.isNote(e) then
            local eRow      = ctx:ppqToRow(e.endppq, chan)
            local newEndRow = newRow + util.round((eRow - sRow))
            local newEndPPQ = ctx:rowToPPQ(newEndRow, chan)
            if newPPQ ~= e.ppq or newEndPPQ ~= e.endppq then
              tm:assignEvent('note', e, { ppq = newPPQ, endppq = newEndPPQ })
            end
          elseif newPPQ ~= e.ppq then
            tm:assignEvent(col.type, e, { ppq = newPPQ })
          end
        end
      end
      tm:flush()
    end

    -- Shift intent onto grid; delay absorbs the inverse so realised is
    -- preserved. When the required delay exceeds delayRange, clamp —
    -- realised still preserved, intent partially off-grid.
    local function quantizeKeepRealisedScope(groups)
      local clamped = 0
      for _, g in ipairs(groups) do
        local col, chan = g.col, g.col.midiChan
        for _, e in pairs(g.locs) do
          if util.isNote(e) then
            local targetPPQ = ctx:rowToPPQ(ctx:snapRow(e.ppq, chan), chan)
            if targetPPQ ~= e.ppq then
              local wantDelay  = e.delay + timing.ppqToDelay(e.ppq - targetPPQ, resolution)
              local dMin, dMax = delayRange(col, e)
              local newDelay   = util.clamp(wantDelay, dMin, dMax)
              local newPPQ     = util.round(e.ppq + timing.delayToPPQ(e.delay - newDelay, resolution))
              if newPPQ ~= e.ppq or newDelay ~= e.delay then
                if newDelay ~= wantDelay then clamped = clamped + 1 end
                local newEnd = newPPQ + (e.endppq - e.ppq)
                tm:assignEvent('note', e, { ppq = newPPQ, endppq = newEnd, delay = newDelay })
              end
            end
          else
            local newPPQ = ctx:rowToPPQ(ctx:snapRow(e.ppq, chan), chan)
            if newPPQ ~= e.ppq then tm:assignEvent(col.type, e, { ppq = newPPQ }) end
          end
        end
      end
      tm:flush()
      if clamped > 0 then
        reaper.ShowMessageBox(
          clamped .. ' note(s) partially quantized — delay clamped at overlap bound.',
          'quantize keep realised', 0)
      end
    end

    function vm:reswingSelection()              reswingScope(eventsByCol())              end
    function vm:reswingAll()                    reswingScope(allGroups())                 end
    function vm:quantizeSelection()             quantizeScope(eventsByCol())              end
    function vm:quantizeAll()                   quantizeScope(allGroups())                end
    function vm:quantizeKeepRealisedSelection() quantizeKeepRealisedScope(eventsByCol())  end
    function vm:quantizeKeepRealisedAll()       quantizeKeepRealisedScope(allGroups())    end
  end

  function vm:reswingPreset(name, oldComp, newComp)
    if not name or name == '' then return end
    reswingPresetChange(name, oldComp, newComp)
  end

  local insertRow, deleteRow do
    local function insertRowCore(col, topRow, numRows)
      local chan = col.midiChan
      local C = ctx:rowToPPQ(topRow, chan)
      local R = ctx:rowToPPQ(topRow + numRows, chan) - C

      local shifted = {}
      for e in util.between(col.events, C, length) do util.add(shifted, e) end
      for i = #shifted, 1, -1 do
        local e = shifted[i]
        local newPpq = e.ppq + R
        if newPpq >= length then
          tm:deleteEvent(col.type, e)
        elseif util.isNote(e) then
          tm:assignEvent('note', e, { ppq = newPpq, endppq = math.min(e.endppq + R, length) })
        else
          tm:assignEvent(col.type, e, { ppq = newPpq })
        end
      end

      if col.type == 'note' then
        local spanning = util.seek(col.events, 'before', C, util.isNote)
        if spanning and spanning.endppq > C then
          tm:assignEvent('note', spanning, { endppq = math.min(spanning.endppq + R, length) })
        end
      end
    end

    local function deleteRowCore(col, topRow, numRows)
      local chan = col.midiChan
      local C = ctx:rowToPPQ(topRow, chan)
      local D = ctx:rowToPPQ(topRow + numRows, chan)
      local R = D - C

      if col.type == 'note' then
        local spanning = util.seek(col.events, 'before', C, util.isNote)
        if spanning and spanning.endppq > C then
          local newEnd = spanning.endppq > D and spanning.endppq - R or C
          tm:assignEvent('note', spanning, { endppq = newEnd })
        end
      end

      local touched = {}
      for e in util.between(col.events, C, length) do util.add(touched, e) end
      for _, e in ipairs(touched) do
        if e.ppq < D then
          tm:deleteEvent(col.type, e)
        elseif util.isNote(e) then
          tm:assignEvent('note', e, { ppq = e.ppq - R, endppq = e.endppq - R })
        else
          tm:assignEvent(col.type, e, { ppq = e.ppq - R })
        end
      end
    end

    local function forEachRowOp(core, preSel)
      if ec:hasSelection() then
        if preSel then preSel() end
        local r1, r2 = ec:region()
        for col in ec:eachSelectedCol() do core(col, r1, r2 - r1 + 1) end
      else
        for _, col in ipairs(grid.cols) do core(col, ec:row(), 1) end
      end
      tm:flush()
    end

    function insertRow() forEachRowOp(insertRowCore) end
    function deleteRow() forEachRowOp(deleteRowCore, function() clipboard:copy() end) end
  end

  ----- Nudge

  local nudge do
    local function pitchStep(coarse)
      if not coarse then return 1 end
      local t = ctx:activeTuning()
      return t and t.octaveStep or 12
    end

    -- Coarse snap interval per column type. nil = no coarse (pc).
    local function valueInterval(col)
      if col.type == 'cc' or col.type == 'at' then return 8
      elseif col.type == 'pb'                 then return 100
      end
    end

    local function valueBounds(col)
      if col.type == 'pb' then local lim = cm:get('pbRange') * 100; return -lim, lim end
      return 0, 127
    end

    local function nudgePitch(col, note, dir, coarse, audible)
      local delta  = dir * pitchStep(coarse)
      local tuning = ctx:activeTuning()
      local pitch, detune
      if tuning then
        pitch, detune = microtuning.transposeStep(tuning, note.pitch, note.detune, delta)
      else
        pitch, detune = util.clamp(note.pitch + delta, 0, 127), note.detune
      end
      if pitch == note.pitch and detune == note.detune then return end
      tm:assignEvent('note', note, { pitch = pitch, detune = detune })
      if audible then audition(pitch, note.vel, col.midiChan) end
    end

    local function nudgeVel(note, dir, coarse)
      local newVel = util.nudgedScalar(note.vel, 1, 127, dir, coarse and 8 or nil)
      if newVel ~= note.vel then tm:assignEvent('note', note, { vel = newVel }) end
    end

    local function nudgeDelay(col, note, dir, coarse)
      local minD, maxD = delayRange(col, note)
      local old = note.delay
      local new = util.nudgedScalar(old, math.ceil(minD), math.floor(maxD), dir, coarse and 10 or nil)
      if new ~= old then tm:assignEvent('note', note, { delay = new }) end
    end

    local function nudgeValue(col, evt, dir, coarse)
      local lo, hi   = valueBounds(col)
      local newVal   = util.nudgedScalar(evt.val, lo, hi, dir, coarse and valueInterval(col) or nil)
      if newVal ~= evt.val then tm:assignEvent(col.type, evt, { val = newVal }) end
    end

    local function applyNudge(col, evt, kind, dir, coarse, audible)
      if     kind == 'val'   then nudgeValue(col, evt, dir, coarse)
      elseif kind == 'vel'   then nudgeVel(evt, dir, coarse)
      elseif kind == 'delay' then nudgeDelay(col, evt, dir, coarse)
      elseif kind == 'pitch' then nudgePitch(col, evt, dir, coarse, audible) end
    end

    -- First event in col that starts anywhere in the cursor row. For note
    -- columns, PAs are skipped.
    local function cursorRowEvent(col)
      if not col then return end
      local r = ec:row()
      local lo, hi = ctx:rowToPPQ(r, col.midiChan), ctx:rowToPPQ(r + 1, col.midiChan)
      local pred = col.type == 'note' and util.isNote or nil
      local evt = util.seek(col.events, 'at-or-after', lo, pred)
      if evt and evt.ppq < hi then return evt end
    end

    -- Column-typed nudge. Selection rule: if any note event is selected,
    -- transpose / velocity- / delay-nudge the notes and leave value events
    -- alone; otherwise nudge val on every value event. Solo cursor: first
    -- event in the cursor row, column- and kind-typed.
    function nudge(dir, coarse)
      if ec:hasSelection() then
        local groups = eventsByCol()

        local anyNote = false
        for _, g in ipairs(groups) do
          if g.col.type == 'note' then
            for _, e in pairs(g.locs) do
              if util.isNote(e) then anyNote = true; break end
            end
            if anyNote then break end
          end
        end

        for _, g in ipairs(groups) do
          local skip = g.kind == 'val' and anyNote
          if not skip then
            for _, e in pairs(g.locs) do
              if g.kind == 'val' or util.isNote(e) then
                applyNudge(g.col, e, g.kind, dir, coarse, false)
              end
            end
          end
        end
        tm:flush()
        return
      end

      local col = grid.cols[ec:col()]
      local evt = cursorRowEvent(col)
      if not evt then return end
      applyNudge(col, evt, ec:cursorKind(), dir, coarse, true)
      tm:flush()
    end
  end

  ----- Deletion

  local deleteEvent, deleteSelection do
    -- Delete notes; extend each predecessor that ended at-or-past a deleted run
    -- into the next survivor's start (or `length`). PAs are out of scope here.
    -- Fixups are computed before any mutation: tm:assignEvent's same-key clamp
    -- reads live state, so we must delete first and stretch second.
    local function queueDeleteNotes(col, locs)
      local fixups = {}
      local lastSurvivor, pendingFixup = nil, false
      for _, evt in ipairs(col.events) do
        if evt.type ~= 'pa' then
          if locs[evt] then
            if not pendingFixup and lastSurvivor and lastSurvivor.endppq >= evt.ppq then
              pendingFixup = true
            end
          else
            if pendingFixup then
              util.add(fixups, { evt = lastSurvivor, endppq = evt.ppq })
            end
            pendingFixup = false
            lastSurvivor = evt
          end
        end
      end
      if pendingFixup then
        util.add(fixups, { evt = lastSurvivor, endppq = length })
      end

      for _, evt in pairs(locs) do
        if evt.type ~= 'pa' then tm:deleteEvent('note', evt) end
      end
      for _, f in ipairs(fixups) do
        tm:assignEvent('note', f.evt, { endppq = f.endppq })
      end
    end

    -- Zero `delay` on each selected note. PAs have no delay.
    ---@diagnostic disable-next-line: unused-local
    local function queueResetDelays(col, locs)
      for _, evt in pairs(locs) do
        if evt.type ~= 'pa' and evt.delay ~= 0 then
          tm:assignEvent('note', evt, { delay = 0 })
        end
      end
    end

    -- Reset selected note vels to the prior event's vel (notes or PAs carry
    -- forward); delete selected PAs outright.
    local function queueResetVelocities(col, locs)
      local prevVel = cm:get('defaultVelocity')
      for _, evt in ipairs(col.events) do
        if locs[evt] then
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

    local DELETE_BY_KIND = {
      pitch = queueDeleteNotes,
      vel   = queueResetVelocities,
      delay = queueResetDelays,
      val   = queueDeleteCCs,
    }

    function deleteEvent()
      local col = grid.cols[ec:col()]
      if not col then return end
      local r = ec:row()
      local evt = col.cells and col.cells[r]
      if not evt then
        -- Delete on a ghost cell: unset interpolation on the governing event.
        local ghost = col.ghosts and col.ghosts[r]
        if ghost then
          tm:assignEvent(col.type, ghost.fromEvt, { shape = 'step' })
          tm:flush()
        end
        return
      end
      local kind = col.type == 'note' and ec:cursorKind() or 'val'
      DELETE_BY_KIND[kind](col, { [evt] = evt })
      tm:flush()
    end

    function deleteSelection()
      for _, g in ipairs(eventsByCol()) do
        DELETE_BY_KIND[g.kind](g.col, g.locs)
      end
      tm:flush()
      ec:selClear()
    end
  end

  local function deleteOrBackspace()
    if ec:isSticky() then deleteSelection()
    else ec:selClear(); deleteEvent(); ec:advance() end
  end

  ----- Duplicate

  -- Stamp the current selection (or cursor row) onto the adjacent block in
  -- the given direction (dir=1 below, dir=-1 above), overwriting what's there.
  -- Going up past row 0 trims the top of the clip — the start is cut off,
  -- not the end — so repeated upward stamps stay anchored at the cursor.
  local function duplicate(dir)
    local clip = clipboard:collect()
    if not clip then return end
    local r1, r2, c1, c2, kind1, kind2 = ec:region()
    local numRows   = r2 - r1 + 1
    local targetRow = dir > 0 and r2 + 1 or r1 - numRows
    local trim      = targetRow < 0 and -targetRow or 0
    targetRow       = math.max(targetRow, 0)
    local effRows   = numRows - trim
    if effRows <= 0 or targetRow >= (grid.numRows or 0) then return end

    if trim > 0 then clipboard:trimTop(clip, trim) end

    local savedRow, savedCol, savedStop = ec:pos()
    ec:setPos(targetRow, ec:regionStart())

    clipboard:pasteClip(clip)

    local shift = targetRow - r1
    ec:setPos(savedRow + shift, savedCol, savedStop)
    if ec:hasSelection() then
      ec:setSelection{ row1 = targetRow, row2 = targetRow + effRows - 1,
                       col1 = c1, col2 = c2, kind1 = kind1, kind2 = kind2 }
    end
  end

  ---------- PUBLIC

  function vm:ec()        return ec end
  function vm:clipboard() return clipboard end

  ----- Accessors for renderManager

  function vm:rowPerBar()      return rowPerBar end
  function vm:activeTuning()   return ctx:activeTuning() end
  function vm:noteProjection(evt) return ctx:noteProjection(evt) end
  function vm:rowBeatInfo(row) return ctx:rowBeatInfo(row) end
  function vm:barBeatSub(row) return ctx:barBeatSub(row) end
  function vm:timeSig()
    local ts = timeSigs[1] or { num = 4, denom = 4 }
    return ts.num, ts.denom
  end

  ----- Non-command callbacks from renderManager

  function vm:setGridSize(w, h)
    gridWidth, gridHeight = w, h
  end

  ----- Columns

  -- Applies to every unique channel covered by ec:eachSelectedCol
  -- (selection's channels, or the cursor's channel as 1×1 fallback).
  function vm:addExtraCol(type, cc)
    local extras = cm:get('extraColumns')
    local seen = {}
    for col in ec:eachSelectedCol() do
      local chan = col.midiChan
      if not seen[chan] then
        seen[chan] = true
        local want = extras[chan] or { notes = 0 }
        extras[chan] = want
        if type == 'note' then
          want.notes = want.notes + 1
        elseif type == 'cc' then
          want.ccs = want.ccs or {}
          want.ccs[cc] = true
        else
          ---@diagnostic disable-next-line: assign-type-mismatch
          want[type] = true
        end
      end
    end
    cm:set('take', 'extraColumns', extras)
  end

  function vm:hideExtraCol()
    local col = grid.cols[ec:col()]
    if not col then return end
    local chan = col.midiChan

    -- Note col with delay shown: strip the delay first; the column itself
    -- only goes on a subsequent hide.
    if col.type == 'note' then
      local lane = col.lane
      local nd = cm:get('noteDelay')
      local chanMap = nd[chan]
      if chanMap and chanMap[lane] then
        chanMap[lane] = nil
        nd[chan] = next(chanMap) and chanMap
        cm:set('take', 'noteDelay', next(nd) and nd)
        vm:rebuild()
        return
      end
    end

    if #col.events > 0 then return end

    local extras = cm:get('extraColumns')
    local want   = extras[chan] or { notes = 0 }
    extras[chan] = want

    if col.type == 'note' then
      local noteCols = {}
      for ci = grid.chanFirstCol[chan], grid.chanLastCol[chan] do
        local c = grid.cols[ci]
        if c.type == 'note' then util.add(noteCols, c) end
      end
      if #noteCols <= 1 then return end
      local k = col.lane

      -- Queue lane shifts for higher-lane notes.
      for lane = k + 1, #noteCols do
        for _, evt in ipairs(noteCols[lane].events) do
          tm:assignEvent('note', evt, { lane = lane - 1 })
        end
      end

      -- Shift noteDelay keys in this channel.
      local nd = cm:get('noteDelay')
      local chanMap = nd[chan]
      if chanMap then
        local newMap = {}
        for lane, v in pairs(chanMap) do
          if lane < k then newMap[lane] = v
          elseif lane > k then newMap[lane - 1] = v end
        end
        nd[chan] = next(newMap) and newMap
        cm:set('take', 'noteDelay', next(nd) and nd)
      end

      want.notes = #noteCols - 1
    elseif col.type == 'cc' then
      if want.ccs then
        want.ccs[col.cc] = nil
        if not next(want.ccs) then want.ccs = nil end
      end
    else
      want[col.type] = nil
    end

    if want.notes == 0 and not (want.pc or want.pb or want.at or want.ccs) then
      extras[chan] = nil
    end
    cm:set('take', 'extraColumns', next(extras) and extras)

    if col.type == 'note' then tm:flush() else vm:rebuild() end
  end

  -- Enables delay sub-col on every note col covered by
  -- ec:eachSelectedCol (selection's note cols, or cursor's col as fallback).
  function vm:showDelay()
    local nd = cm:get('noteDelay')
    local changed = false
    for col in ec:eachSelectedCol() do
      if col.type == 'note' then
        local chanMap = nd[col.midiChan] or {}
        if not chanMap[col.lane] then
          chanMap[col.lane] = true
          nd[col.midiChan] = chanMap
          changed = true
        end
      end
    end
    if changed then cm:set('take', 'noteDelay', nd) end
  end

  ----- Command table

  cmgr:registerAll{
    cut                     = function() clipboard:copy(); deleteSelection() end,
    delete                  = deleteOrBackspace,
    interpolate             = function() interpolate() end,
    deleteSel               = function() deleteSelection() end,
    duplicateDown           = function() duplicate( 1) end,
    duplicateUp             = function() duplicate(-1) end,
    inputOctaveUp           = function() cm:set('take', 'currentOctave', util.clamp(cm:get('currentOctave')+1, -1, 9)) end,
    inputOctaveDown         = function() cm:set('take', 'currentOctave', util.clamp(cm:get('currentOctave')-1, -1, 9)) end,
    noteOff                 = noteOff,
    growNote                = function() adjustDuration(1) end,
    shrinkNote              = function() adjustDuration(-1) end,
    nudgeBack               = function() adjustPosition(-1) end,
    nudgeForward            = function() adjustPosition(1) end,
    insertRow               = function() insertRow() end,
    deleteRow               = function() deleteRow() end,
    nudgeCoarseUp           = function() nudge( 1, true)  end,
    nudgeCoarseDown         = function() nudge(-1, true)  end,
    nudgeFineUp             = function() nudge( 1, false) end,
    nudgeFineDown           = function() nudge(-1, false) end,
    play                    = function() tm:play() end,
    playPause               = function() tm:playPause() end,
    playFromTop             = function() tm:playFrom(0) end,
    playFromCursor          = function()
      local col = grid.cols[ec:col()]
      tm:playFrom(ctx:rowToPPQ(ec:row(), col and col.midiChan))
    end,
    stop                    = function() tm:stop() end,
    addNoteCol              = function() vm:addExtraCol('note') end,
    hideExtraCol            = function() vm:hideExtraCol() end,
    doubleRPB               = function() vm:setRowPerBeat(cm:get('rowPerBeat') * 2) end,
    halveRPB                = function() vm:setRowPerBeat(math.floor(cm:get('rowPerBeat') / 2)) end,
    matchGridToCursor       = matchGridToCursor,
    cycleTuning             = cycleTuning,
    cycleSwing              = cycleSwing,
  }

  for i = 0, 9 do
    cmgr:register('advBy' .. i, function() cm:set('take', 'advanceBy', i) end)
  end

  ----- Rebuild

  local rebuilding = false

  function vm:rebuild(takeChanged)
    if not tm or rebuilding then return end
    rebuilding = true
    takeChanged = takeChanged or false

    local LABELS = {
      note = 'Note', cc = 'CC', pb = 'PB', at = 'AT', pa = 'PA', pc = 'PC',
    }

    if takeChanged then
      resolution = tm:resolution()
      length     = tm:length()
      timeSigs   = tm:timeSigs()
      ec:reset()
    end

    do
      local rpb = cm:get('rowPerBeat')
      -- Grid resolution is pinned to the first time sig's denominator;
      -- mid-item time sig changes affect bar/beat highlighting but not row size.
      local denom = timeSigs[1] and timeSigs[1].denom or 4
      local num   = timeSigs[1] and timeSigs[1].num or 4
      rowPerBar = rpb * num
      local ppqPerRow = (resolution * 4 / denom) / rpb

      grid.cols         = {}
      grid.chanFirstCol = {}
      grid.chanLastCol  = {}
      grid.lane1Col     = {}

      local noteDelayCfg = cm:get('noteDelay')

      -- `key` is the lane number for note columns, the cc number for cc
      -- columns, and nil for singletons (pb/at/pc).
      local function addGridCol(chan, type, key, events)
        local showDelay = type == 'note' and (noteDelayCfg[chan] or {})[key] or false

        local gridCol = {
          type      = type,
          cc        = type == 'cc'   and key or nil,
          lane      = type == 'note' and key or nil,
          label     = LABELS[type] or '',
          events    = events or {},
          showDelay = showDelay,
          width     = type == 'note' and (showDelay and 10 or 6)
                   or type == 'pb' and 4
                   or 2,
          midiChan  = chan,
          cells     = {},
        }
        ec:decorateCol(gridCol)
        util.add(grid.cols, gridCol)
        grid.chanFirstCol[chan] = grid.chanFirstCol[chan] or #grid.cols
        grid.chanLastCol[chan]  = #grid.cols
        if type == 'note' and key == 1 then grid.lane1Col[chan] = gridCol end
      end

      for chan, channel in tm:channels() do
        local c = channel.columns
        if c.pc then addGridCol(chan, 'pc', nil,  c.pc.events) end
        if c.pb then addGridCol(chan, 'pb', nil,  c.pb.events) end
        for lane, col in ipairs(c.notes) do addGridCol(chan, 'note', lane, col.events) end
        if c.at then addGridCol(chan, 'at', nil,  c.at.events) end
        local ccNums = {}
        for n in pairs(c.ccs) do util.add(ccNums, n) end
        table.sort(ccNums)
        for _, n in ipairs(ccNums) do addGridCol(chan, 'cc', n, c.ccs[n].events) end
      end

      rowPPQs = {}
      local r = 0
      while true do
        local ppq = util.round(r * ppqPerRow)
        if ppq >= length and r > 0 then break end
        rowPPQs[r] = ppq
        r = r + 1
      end

      local numRows = r
      grid.numRows = numRows

      -- Swing snapshot for this rebuild — resolved slots, T baked in.
      -- tm has already stripped delay from col.events, so evt.ppq is
      -- intent; unapply(chan, intentPPQ) → straight-grid PPQ.
      ctx = newViewContext{
        swing      = tm:swingSnapshot(),
        rowPPQs    = rowPPQs,
        length     = length,
        numRows    = numRows,
        rowPerBeat = rpb,
        ppqPerRow  = ppqPerRow,
        timeSigs   = timeSigs,
        tuning     = microtuning.findTuning(cm:get('tuning')),
      }

      for _, gridCol in ipairs(grid.cols) do
        gridCol.overflow = {}
        gridCol.offGrid  = {}
        if gridCol.type == 'note' then gridCol.tails = {} end
        local chan = gridCol.midiChan
        for _, evt in ipairs(gridCol.events) do
          local ppq      = evt.ppq or 0
          local authored = ctx:authoredRow(ppq, chan)
          local startRow = authored or ctx:ppqToRow(ppq, chan)
          local y        = authored or util.round(startRow)
          if y >= 0 and y < numRows then
            if gridCol.cells[y] then
              gridCol.overflow[y] = true
            else
              gridCol.cells[y] = evt
              if not authored then gridCol.offGrid[y] = true end
            end
          end
          if evt.endppq then
            local endAuth = ctx:authoredRow(evt.endppq, chan)
            util.add(gridCol.tails, {
              startRow = startRow,
              endRow   = endAuth or ctx:ppqToRow(evt.endppq, chan),
            })
          end
        end
      end

      for _, gridCol in ipairs(grid.cols) do
        gridCol.ghosts = interpolateValues(gridCol)
      end

      -- Layout changed but no cursor move; re-clamp + re-follow viewport.
      ec:clampPos(); followViewport()
    end
    pushMute()
    rebuilding = false
  end

  ----- Lifecycle

  do
    -- Mute/solo changes don't affect grid shape, so skip rebuild.
    local muteKeys = { mutedChannels = true, soloedChannels = true }

    -- Mirror tm's takeSwapped→rebuild dance: the flag is captured here and
    -- consumed by the next rebuild fire. tm guarantees the firing order.
    local pendingTakeSwap = false
    tm:subscribe('takeSwapped', function() pendingTakeSwap = true end)
    tm:subscribe('rebuild', function()
      vm:rebuild(pendingTakeSwap)
      pendingTakeSwap = false
    end)
    cm:subscribe('configChanged', function(change)
      -- The callback fired by releaseTransientFrame handles rebuild,
      -- so we return early to prevent double-dipping.
      if isFrameChange(change) and releaseTransientFrame() then return end
      if muteKeys[change.key] then pushMute(); return end
      vm:rebuild(false)
    end)
  end

  ----- Factory load

  ec = newEditCursor {
    grid       = grid,
    cm         = cm,
    rowPerBar  = function() return rowPerBar end,
    moveHook   = followViewport,
  }

  clipboard = newClipboard {
    ec = ec, grid = grid, tm = tm, cm = cm,
    addNoteEvent = addNoteEvent,
    getCtx       = function() return ctx end,
    getLength    = function() return length end,
  }

  ec:registerCommands(cmgr)
  clipboard:registerCommands(cmgr)

  -- Drop sticky selection after edits so the region stays visible but
  -- doesn't extend on the next cursor move.
  cmgr:doAfter({
    'nudgeCoarseUp', 'nudgeCoarseDown', 'nudgeFineUp', 'nudgeFineDown',
    'nudgeBack', 'nudgeForward', 'growNote', 'shrinkNote',
    'duplicateDown', 'duplicateUp', 'interpolate', 'insertRow',
    'deleteRow', 'noteOff',
  }, function() ec:unstick() end)

  cmgr:doAfter({ 'delete', 'deleteSel', 'cut' }, function() ec:selClear() end)

  cmgr:doBefore({
    'cursorDown', 'cursorUp', 'pageDown', 'pageUp',
    'goTop', 'goBottom', 'goLeft', 'goRight',
    'cursorRight', 'cursorLeft', 'selectDown', 'selectUp',
    'selectRight', 'selectLeft', 'selectClear', 'colRight',
    'colLeft', 'channelRight', 'channelLeft', 'delete',
  }, killAudition)

  vm:rebuild(true)
  return vm
end
