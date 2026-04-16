--------------------
-- newTrackerManager
--
-- Factory that attaches to a midiManager, parses its MIDI data into a
-- tracker-style data structure with channels and typed columns, and
-- rebuilds automatically whenever the underlying MIDI data changes.
--
-- CONSTRUCTION
--   local tm = newTrackerManager(mm)   -- attach to midiManager mm
--   local tm = newTrackerManager(nil)  -- create empty, call tm:attach(mm) later
--
-- LIFECYCLE
--   tm:attach(mm)     -- attach to a midiManager; triggers an immediate rebuild
--   tm:detach()       -- remove callback from the attached midiManager
--   tm:rebuild(changed) -- manually trigger a full rebuild
--
-- MESSAGING
--   tm:addCallback(fn)                -- register a callback
--   tm:removeCallback(fn)             -- unregister a callback
--     On rebuild, registered callbacks are called with the signature
--     fn(changed, tm), where changed is a table of the form
--     { take = bool, data = bool } forwarded from the midiManager.
--
-- CHANNEL DATA
--   tm:getChannel(chan)               -- returns the channel table for chan (1..16)
--   tm:channels()                     -- iterator: for chan, channel in tm:channels()
--
--   Each channel table contains:
--     chan    : number (1..16)
--     columns : array of column tables
--
--   Each column table contains:
--     type   : string ('note', 'cc', 'pb', 'at', 'pa', 'pc')
--     events : array of event tables, sorted by ppq
--     cc     : cc columns only — the CC number.
--
--   Note columns carry no identity beyond their position among note
--   columns in the channel. A note's "lane" is that position, persisted
--   per note under the 'lane' key. Lane counts are stable across
--   rebuilds: cfg.noteColumns[chan] stores a per-channel count, tm grows
--   it when allocation needs more lanes, and lanes only shrink via
--   explicit user action in viewManager.
--
--   Note column lanes are stable across rebuilds: the cfg key
--   'noteColumns' stores a per-channel count, and tm grows it when
--   allocation needs more lanes. Lanes only shrink via explicit user
--   action in viewManager.
--
-- GLOBAL DATA
--   tm:length()       -- take length in PPQ (delegated to midiManager)
--   tm:resolution()   -- PPQ per quarter note (delegated to midiManager)
--   tm:editCursor()   -- edit cursor position in PPQ relative to the take start
--------------------

loadModule('util')
loadModule('midiManager')

local function print(...)
  return util:print(...)
end

-- Canonical order of column kinds within a channel. The reading is a
-- performance timeline: program change sets up the sound, pitch bend
-- establishes a baseline, notes carry pitch, aftertouch adds expression,
-- cc carries modulation.
columnKindOrder = { 'pc', 'pb', 'note', 'at', 'cc' }

-- Canonicalise a column list: pc → pb → notes (preserving creation
-- order, i.e. lane order) → at → cc (by cc number). Returns a new list.
-- Exposed so viewManager can reuse the same rule on its grid-column slice.
function canonicaliseColumns(cols)
  local buckets = {}
  for _, t in ipairs(columnKindOrder) do buckets[t] = {} end
  for _, col in ipairs(cols) do
    local b = buckets[col.type]
    if b then util:add(b, col) end
  end
  table.sort(buckets.cc, function(a, b) return (a.cc or 0) < (b.cc or 0) end)
  local out = {}
  for _, t in ipairs(columnKindOrder) do
    for _, col in ipairs(buckets[t]) do util:add(out, col) end
  end
  return out
end

--------------------

function newTrackerManager(mm, cm)

  ---------- PRIVATE DATA & FUNCTIONS

  local channels = {}
  local fire  -- installed below, once tm exists

  local function cfg(key, default)
    if cm then
      local val = cm:get(key)
      if val ~= nil then return val end
    end
    return default
  end

  -- Deferred operation queue. Call deleteEvent/assignEvent/addEvent to
  -- collect mutations, then flush() to execute them all in one modify call.

  local queue = {}

  function deleteEvent(evtType, evtOrLoc)
    evt = type(evtOrLoc) == 'table' and evtOrLoc or { loc = evtOrLoc }
    util:add(queue, { op = 'delete', type = evtType, evt = evt })
  end

  function assignEvent(evtType, evtOrLoc, update)
    evt = type(evtOrLoc) == 'table' and evtOrLoc or { loc = evtOrLoc }
    util:add(queue, { op = 'assign', type = evtType, evt = evt, update = update })
  end

  function addEvent(evtType, evt)
    if evtType ~= 'note' then evt.msgType = evtType end
    util:add(queue, { op = 'add', type = evtType, evt = evt })
  end

  --------------------
  -- PA cascade: poly-aftertouch events are attached to their host note
  -- by (chan, pitch) within the host's closed interval [ppq, endppq].
  -- On host delete, resize, translate, or repitch, PAs move or die to
  -- match. Pb invariants are handled separately by the session, not
  -- here — PA is a different animal with a different attachment rule.
  --
  -- Runs as a pre-pass before dispatch, re-entering the queue via
  -- deleteEvent/assignEvent.
  --------------------

  local function firstNoteCol(channel)
    for _, col in ipairs(channel.columns) do
      if col.type == 'note' then return col end
    end
  end

  local function forEachAttachedPA(host, fn)
    for loc, cc in mm:ccs() do
      if cc.msgType == 'pa' and cc.chan == host.chan and cc.pitch == host.pitch
         and cc.ppq >= host.ppq and cc.ppq <= host.endppq then
        fn(loc, cc)
      end
    end
  end

  local function cascadePADelete(host)
    forEachAttachedPA(host, function(loc) deleteEvent('pa', loc) end)
  end

  local function cascadePAInterval(host, newPpq, newEnd)
    local dPpq  = newPpq - host.ppq
    local shift = (dPpq == newEnd - host.endppq) and dPpq or 0
    forEachAttachedPA(host, function(loc, cc)
      local newPPQ = cc.ppq + shift
      if newPPQ < newPpq or newPPQ > newEnd then deleteEvent('pa', loc)
      elseif shift ~= 0 then assignEvent('pa', loc, { ppq = newPPQ }) end
    end)
  end

  local function cascadePARepitch(host, newPitch)
    forEachAttachedPA(host, function(loc) assignEvent('pa', loc, { pitch = newPitch }) end)
  end

  -- Pre-pass: translate note ops into PA side-effects. Snapshots queue
  -- length so cascade-appended ops (never 'note') aren't reconsidered.
  local function cascadePAOps()
    for i = 1, #queue do
      local o = queue[i]
      if o.type == 'note' then
        local host = mm:getNote(o.evt.loc)
        if host then
          host.loc = o.evt.loc
          if o.op == 'delete' then
            cascadePADelete(host)
          elseif o.op == 'assign' then
            local u = o.update
            if u.ppq or u.endppq then
              cascadePAInterval(host, u.ppq or host.ppq, u.endppq or host.endppq)
            end
            if u.pitch and u.pitch ~= host.pitch then
              cascadePARepitch(host, u.pitch)
            end
          end
        end
      end
    end
  end

  --------------------
  -- PB <-> cents conversion. 
  --------------------

  local function centsToRaw(cents)
    local lim = cfg('pbRange', 2) * 100
    return util:clamp(math.floor(cents * 8192 / lim + 0.5), -8192, 8191)
  end

  local function rawToCents(raw)
    local lim = cfg('pbRange', 2) * 100
    return math.floor(raw / 8192 * lim + 0.5)
  end

  --------------------
  -- Session
  --
  -- Working model for a dispatch pass. Holds a lazy per-channel view
  -- of col-1 notes and pb events, provides fix/retune/reduce helpers
  -- and the Stage 2 editing ops from design/pitchbend.md. Each op
  -- reads the live state left by previous ops in the same batch, so
  -- the "all queried values taken from the pre-amend state" rule from
  -- the design is honoured *per op*, not per batch.
  --
  -- State items carry an optional loc (items loaded from mm) or are new
  -- (no loc). Mutations go through set(): loaded items fold into the
  -- matching assigns entry; new items are seen at commit via the live
  -- reference held by their adds entry. Deletions splice the item out of
  -- its chans list and either record a delete (loaded) or strike the
  -- corresponding adds entry (new).
  --
  -- adds/assigns/deletes are built inline as classifier ops run; commit
  -- consumes them directly with no further walk of chans. Passthrough
  -- queue entries (col-2+ notes, CC, PA, AT, PC, sysex) dispatch straight
  -- into these same tables.
  --
  -- pb.val is stored as logical cents throughout the session.
  --------------------

  local function newSession()
    local sn = {}
    local chans = {}        -- chans[c] = { notes = {...}, pbs = {...} }
    local adds = {}         -- { type, evt }  — for note/pb, evt is the live state item
    local assigns = {}      -- { type, loc, update }
    local deletes = {}      -- { type, loc }
    local pbAt, rawAt, insertPb  -- forward-decl'd for loadChan's preliminary pass

    -- Mutate a field. For loaded items, fold into (or create) the matching
    -- assigns entry; for new items the live item is already held by its
    -- adds entry, so the mutation is seen at commit automatically.
    local function set(item, type, k, v)
      item[k] = v
      if not item.loc then return end
      for _, e in ipairs(assigns) do
        if e.loc == item.loc and e.type == type then
          e.update[k] = v; return
        end
      end
      util:add(assigns, { type = type, loc = item.loc, update = { [k] = v } })
    end

    -- Splice an item out of its list. Loaded items yield a delete and strike
    -- any pending assign at that loc; new items are removed from adds.
    local function drop(list, i, type)
      local item = list[i]
      table.remove(list, i)
      if item.loc then
        util:add(deletes, { type = type, loc = item.loc })
        for j = #assigns, 1, -1 do
          local e = assigns[j]
          if e.loc == item.loc and e.type == type then table.remove(assigns, j) end
        end
      else
        for j = #adds, 1, -1 do
          if adds[j].evt == item then table.remove(adds, j); break end
        end
      end
    end

    local function loadChan(chan, wantPrelim)
      if chans[chan] then return chans[chan] end
      if wantPrelim == nil then wantPrelim = true end
      local notes, pbs = {}, {}
      for loc, n in mm:notes() do
        if n.chan == chan and (n.lane or 1) == 1 then
          util:add(notes, util:assign(n, { loc = loc }))
        end
      end
      for loc, cc in mm:ccs() do
        if cc.chan == chan and cc.msgType == 'pb' then
          util:add(pbs, { ppq = cc.ppq, chan = cc.chan, val = rawToCents(cc.val), loc = loc })
        end
      end
      table.sort(notes, function(a, b) return a.ppq < b.ppq end)
      table.sort(pbs,   function(a, b) return a.ppq < b.ppq end)
      chans[chan] = { notes = notes, pbs = pbs }

      -- Preliminary pass (design/pitchbend.md §Stage 2): anchor a pb at
      -- every col-1 note-on so retune ops have a clean [ppq, endppq)
      -- boundary. Redundant anchors fall away in reduce().
      if wantPrelim then
        for _, n in ipairs(notes) do
          if not pbAt(chan, n.ppq) then
            insertPb(chan, { ppq = n.ppq, chan = chan, val = rawAt(chan, n.ppq), msgType = 'pb', loc = loc })
          end
        end
      end

      return chans[chan]
    end

    -- Keep notes / pbs sorted after a mutation that may have changed ppq.
    local function resort(list)
      table.sort(list, function(a, b) return (a.ppq or 0) < (b.ppq or 0) end)
    end

    ----- Accessors: raw / logical / detune over the session state.

    local function owner(chan, P)
      return util:seek(loadChan(chan).notes, 'at-or-before', P,
        function(n) return n.endppq > P end)
    end

    local function detuneAt(chan, P)
      local n = owner(chan, P)
      return (n and n.detune) or 0
    end

    local function detuneBefore(chan, P)
      local n = util:seek(loadChan(chan).notes, 'before', P,
        function(n) return n.endppq >= P end)
      return (n and n.detune) or 0
    end

    function rawAt(chan, P)
      local pb = util:seek(loadChan(chan).pbs, 'at-or-before', P)
      return pb and pb.val or 0
    end

    local function rawBefore(chan, P)
      local pb = util:seek(loadChan(chan).pbs, 'before', P)
      return pb and pb.val or 0
    end

    function pbAt(chan, P)
      local pb = util:seek(loadChan(chan).pbs, 'at-or-before', P)
      return pb and pb.ppq == P and pb or nil
    end

    local function logicalAt(chan, P)   return rawAt(chan, P)     - detuneAt(chan, P) end
    local function logicalBefore(chan, P) return rawBefore(chan, P) - detuneBefore(chan, P) end

    ----- Mutation primitives over state (no mm side-effects yet).

    function insertPb(chan, pb)
      local pbs = loadChan(chan).pbs
      local i = 1
      while i <= #pbs and pbs[i].ppq < pb.ppq do i = i + 1 end
      table.insert(pbs, i, pb)
      util:add(adds, { type = 'pb', evt = pb })
    end

    ----- Helpers from the design doc.

    -- retune(P1, P2, Δ): shift every pb with ppq in [P1, P2) by Δ cents.
    local function retune(chan, P1, P2, delta)
      if delta == 0 then return end
      for _, pb in ipairs(loadChan(chan).pbs) do
        if pb.ppq >= P1 and pb.ppq < P2 then
          set(pb, 'pb', 'val', pb.val + delta)
        end
      end
    end

    -- reduce(chan): delete orphan pbs and interior no-ops, per invariants.
    local function reduce(chan)
      local pbs = loadChan(chan).pbs
      local i = 1
      while i <= #pbs do
        local pb = pbs[i]
        local gone = not owner(chan, pb.ppq)
                 or (logicalAt(chan, pb.ppq) == logicalBefore(chan, pb.ppq)
                 and detuneAt(chan, pb.ppq)  == detuneBefore(chan, pb.ppq))
        if gone then drop(pbs, i, 'pb') else i = i + 1 end
      end
    end

    -- First ppq > P at which logical changes, or +∞. Logical is a step
    -- function whose breakpoints lie at the union of pb ppqs and note
    -- boundaries (start or end). Walk that union in order and return
    -- the first ppq whose logical differs from logical(P).
    local function nextLogicalChange(chan, P)
      local ch = loadChan(chan)
      local curL = logicalAt(chan, P)
      local bps = {}
      for _, pb in ipairs(ch.pbs) do
        if pb.ppq > P then bps[pb.ppq] = true end
      end
      for _, n in ipairs(ch.notes) do
        if n.ppq    > P then bps[n.ppq]    = true end
        if n.endppq > P then bps[n.endppq] = true end
      end
      local sorted = {}
      for q in pairs(bps) do util:add(sorted, q) end
      table.sort(sorted)
      for _, q in ipairs(sorted) do
        if logicalAt(chan, q) ~= curL then return q end
      end
      return math.huge
    end

    ----- Stage 2 ops.

    function sn:setPb(chan, P, L)
      local Pp    = nextLogicalChange(chan, P)
      local delta = L - logicalAt(chan, P)
      if not pbAt(chan, P) then
        insertPb(chan, { ppq = P, chan = chan, val = rawAt(chan, P), msgType = 'pb' })
      end
      retune(chan, P, Pp, delta)
      reduce(chan)
    end

    function sn:deletePb(chan, P)
      if not pbAt(chan, P) then return end
      local Pp = nextLogicalChange(chan, P)
      retune(chan, P, Pp, logicalBefore(chan, P) - logicalAt(chan, P))
      reduce(chan)
    end

    function sn:addNote(n)
      local chan = n.chan
      if (n.lane or 1) ~= 1 then
        -- col-2+ notes never participate in pb ownership. Pass through.
        util:add(adds, { type = 'note', evt = n })
        return
      end
      local D = n.detune or 0
      if not pbAt(chan, n.ppq) then
        insertPb(chan, { ppq = n.ppq, chan = chan, val = logicalBefore(chan, n.ppq) + D, msgType = 'pb' })
      end
      local item = util:assign(n, { detune = D })
      util:add(loadChan(chan).notes, item)
      util:add(adds, { type = 'note', evt = item })
      resort(loadChan(chan).notes)
      reduce(chan)
    end

    function sn:deleteNote(item)
      local notes = loadChan(item.chan).notes
      for i, n in ipairs(notes) do
        if n == item then drop(notes, i, 'note'); break end
      end
      reduce(item.chan)
    end

    function sn:retuneNoteOp(item, D2)
      local D1 = item.detune or 0
      if D1 == D2 then return end
      retune(item.chan, item.ppq, item.endppq, D2 - D1)
      set(item, 'note', 'detune', D2)
      reduce(item.chan)
    end

    function sn:resizeNote(item, P1, P2)
      local chan = item.chan
      local L = logicalAt(chan, P1)
      set(item, 'note', 'ppq', P1)
      set(item, 'note', 'endppq', P2)
      if not pbAt(chan, P1) then
        insertPb(chan, { ppq = P1, chan = chan, val = (item.detune or 0) + L, msgType = 'pb' })
      end
      resort(loadChan(chan).notes)
      reduce(chan)
    end

    -- External setter used by classifyInto to apply metadata fields.
    function sn:setField(item, k, v) set(item, 'note', k, v) end

    -- Resolve a (type, loc) to a state item, loading the channel lazily.
    function sn:itemFor(type, loc)
      if type == 'note' then
        local n = mm:getNote(loc); if not n then return end
        if (n.lane or 1) ~= 1 then return end
        for _, it in ipairs(loadChan(n.chan).notes) do
          if it.loc == loc then return it end
        end
      elseif type == 'pb' then
        local cc = mm:getCC(loc); if not cc then return end
        for _, it in ipairs(loadChan(cc.chan).pbs) do
          if it.loc == loc then return it end
        end
      end
    end

    function sn:passthrough(o)
      if o.op == 'add' then
        util:add(adds, { type = o.type, evt = o.evt })
      elseif o.op == 'assign' then
        util:add(assigns, { type = o.type, loc = o.evt.loc, update = o.update })
      else
        util:add(deletes, { type = o.type, loc = o.evt.loc })
      end
    end

    -- Stage 1 rebuild over the full take. Used by tm:rebuild to bring a
    -- possibly invariant-violating mm state back to conformance. Three
    -- steps from design/pitchbend.md §Stage 1.
    function sn:runStage1()
      for c = 1, 16 do loadChan(c, false) end

      -- Step 1: default detune = 0 on col-1 notes missing it.
      for c = 1, 16 do
        for _, n in ipairs(chans[c].notes) do
          if n.detune == nil then set(n, 'note', 'detune', 0) end
        end
      end

      -- Step 2: reduce.
      for c = 1, 16 do reduce(c) end

      -- Step 3: add pbs at note starts where logical or detune transitions.
      for c = 1, 16 do
        local ordered = {}
        for _, n in ipairs(chans[c].notes) do util:add(ordered, n) end
        table.sort(ordered, function(a, b) return a.ppq < b.ppq end)
        for _, n in ipairs(ordered) do
          local P = n.ppq
          if not pbAt(c, P) then
            local lA, lB = logicalAt(c, P), logicalBefore(c, P)
            local dA, dB = detuneAt(c, P),  detuneBefore(c, P)
            if lA ~= lB or dA ~= dB then
              insertPb(c, { ppq = P, chan = c, val = lB + dA, msgType = 'pb' })
            end
          end
        end
      end
    end

    ----- Commit: walk state and emit mm mutations.

    function sn:commit()
      if #adds == 0 and #assigns == 0 and #deletes == 0 then return end

      for _, e in ipairs(assigns) do
        if e.type == 'pb' and e.update.val ~= nil then
          e.update.val = centsToRaw(e.update.val)
        end
      end

      for _, a in ipairs(adds) do
        if a.type == 'pb' then
          a.evt.val = centsToRaw(a.evt.val)
        end
      end

      table.sort(deletes, function(a, b) return a.loc > b.loc end)

      mm:modify(function()
        for _, o in ipairs(assigns) do
          if o.type == 'note' then mm:assignNote(o.loc, o.update)
          else mm:assignCC(o.loc, o.update) end
        end
        for _, o in ipairs(deletes) do
          if o.type == 'note' then mm:deleteNote(o.loc)
          else mm:deleteCC(o.loc) end
        end
        for _, a in ipairs(adds) do
          if a.type == 'note' then mm:addNote(a.evt)
          else mm:addCC(a.evt)
          end
        end
      end)
    end

    return sn
  end

  --------------------
  -- Classifier: translate queued high-level ops into Stage 2 session
  -- ops. Anything the session doesn't understand goes to passthrough.
  --
  -- Refusals:
  --   assignEvent('note', _, {chan=...})             — channel change
  --   assignEvent('note', _, {detune=..., ppq=...})  — combined retune+resize
  --   assignEvent('note', _, {detune=..., endppq=...})
  --   assignEvent('pb',   _, {ppq=...})              — pb move
  --------------------

  local METADATA_KEYS = { 'vel', 'pitch', 'lane' }

  local function classifyInto(sn)
    return function(o)
      local t, op = o.type, o.op

      if t == 'note' then
        if op == 'add' then
          sn:addNote(o.evt)
          return
        end
        if op == 'delete' then
          local item = sn:itemFor('note', o.evt.loc)
          if item then sn:deleteNote(item)
          else sn:passthrough(o) end  -- col-2+ or unknown
          return
        end
        if op == 'assign' then
          local u = o.update
          if u.chan then
            print('tm: refuse assignNote — chan change not allowed')
            return
          end
          local hasResize = u.ppq ~= nil or u.endppq ~= nil
          local hasRetune = u.detune ~= nil
          if hasResize and hasRetune then
            print('tm: refuse assignNote — combined resize+retune')
            return
          end
          local item = sn:itemFor('note', o.evt.loc)
          if not item then sn:passthrough(o); return end  -- col-2+

          if hasResize then
            sn:resizeNote(item, u.ppq or item.ppq, u.endppq or item.endppq)
          elseif hasRetune then
            sn:retuneNoteOp(item, u.detune)
          end
          -- Apply any metadata fields (vel, pitch, lane) directly.
          for _, k in ipairs(METADATA_KEYS) do
            if u[k] ~= nil then sn:setField(item, k, u[k]) end
          end
          return
        end
      end

      if t == 'pb' then
        if op == 'add' then
          sn:setPb(o.evt.chan, o.evt.ppq, o.evt.val or 0)
          return
        end
        if op == 'delete' then
          local cc = mm:getCC(o.evt.loc); if not cc then return end
          sn:deletePb(cc.chan, cc.ppq)
          return
        end
        if op == 'assign' then
          if o.update.ppq then
            print('tm: refuse assignPb — ppq change not allowed; delete and recreate')
            return
          end
          if o.update.val ~= nil then
            local cc = mm:getCC(o.evt.loc); if not cc then return end
            sn:setPb(cc.chan, cc.ppq, o.update.val)
          end
          return
        end
      end

      -- Everything else (pa, cc, at, pc, sysex) passes through.
      sn:passthrough(o)
    end
  end

  local flushing = false

  function flush()
    if #queue == 0 or flushing then return end
    flushing = true
    
    cascadePAOps()
    if #queue == 0 then return end
    local ops = queue
    queue = {}

    local sn = newSession()
    local classify = classifyInto(sn)
    for _, o in ipairs(ops) do classify(o) end
    sn:commit()

    flushing = false
  end
  
  --------------------
  -- Column creation
  --   note / pb / pc / at : no identifying field.
  --   cc                  : carries .cc = CC number.
  --------------------

  local function addColumn(channel, type, cc)
    return util:add(channel.columns, { type = type, cc = cc, events = {} })
  end

  local function noteColCount(channel)
    local n = 0
    for _, col in ipairs(channel.columns) do
      if col.type == 'note' then n = n + 1 end
    end
    return n
  end

  -- Singleton columns: pb, pc, at. One per channel.
  local function getOrCreateSingletonColumn(channel, colType)
    for _, col in ipairs(channel.columns) do
      if col.type == colType then return col end
    end
    return addColumn(channel, colType)
  end

  -- CC columns are keyed by cc number.
  local function getOrCreateCCColumn(channel, ccNum)
    for _, col in ipairs(channel.columns) do
      if col.type == 'cc' and col.cc == ccNum then return col end
    end
    return addColumn(channel, 'cc', ccNum)
  end

  --------------------
  -- Note-column allocation
  --
  -- Each note column can hold overlapping notes, but if a new note
  -- overlaps more than overlapThreshold ticks with two or more
  -- existing notes in that column, it spills to a new one.
  -- A second note at the same starting tick as an existing one
  -- will always be spilled.
  --------------------

  local function noteColumnAccepts(col, notePpq, noteEndPpq)
    local overlapThreshold = cfg('overlapOffset', 1/16) * mm:resolution()
    local dominated = 0
    for _, evt in ipairs(col.events) do
      if notePpq == evt.ppq then return false end
      if notePpq < evt.endppq and evt.ppq < noteEndPpq then
        local overlapAmount = math.min(evt.endppq, noteEndPpq) - math.max(evt.ppq, notePpq)
        if overlapAmount > overlapThreshold then
          return false
        end
        dominated = dominated + 1
      end
    end
    return dominated < 2
  end

  local function noteColAt(channel, lane)
    local n = 0
    for _, col in ipairs(channel.columns) do
      if col.type == 'note' then
        n = n + 1
        if n == lane then return col end
      end
    end
  end

  -- Returns (col, lane) where lane is the 1-indexed position among the
  -- channel's note columns.
  local function allocateNoteColumn(channel, note)
    if note.lane then
      local col = noteColAt(channel, note.lane)
      if col and noteColumnAccepts(col, note.ppq, note.endppq) then
        return col, note.lane
      end
      if not col then
        -- Preferred lane doesn't exist yet — grow until it does.
        while noteColCount(channel) < note.lane do addColumn(channel, 'note') end
        return noteColAt(channel, note.lane), note.lane
      end
      -- Exists but won't fit. Fall through to first-fit / spill.
    end
    local n = 0
    for _, col in ipairs(channel.columns) do
      if col.type == 'note' then
        n = n + 1
        if noteColumnAccepts(col, note.ppq, note.endppq) then return col, n end
      end
    end
    return addColumn(channel, 'note'), n + 1
  end

  --------------------
  -- Poly aftertouch: find the note column containing the target pitch
  --------------------

  local function findNoteColumnForPitch(channel, pitch, ppq_pos)
    for _, col in ipairs(channel.columns) do
      if col.type == 'note' then
        for _, evt in ipairs(col.events) do
          if evt.pitch == pitch and evt.ppq <= ppq_pos and evt.endppq > ppq_pos then
            return col
          end
        end
      end
    end
    for _, col in ipairs(channel.columns) do
      if col.type == 'note' then
        for _, evt in ipairs(col.events) do
          if evt.pitch == pitch then return col end
        end
      end
    end
    return nil
  end

  --------------------
  -- PUBLIC FUNCTIONS
  --------------------

  local tm = {}
  fire = util:installHooks(tm)

  --------------------
  -- Core rebuild
  --------------------

  local rebuilding = false

  -- argument tracks whether take and/or underlying data have changed
  function tm:rebuild(changed)
    if rebuilding then return end
    rebuilding = true

    changed = changed or { take = false, data = true }

    -- Seed each channel with the configured number of note columns. The
    -- allocator may grow this further when a lane-less note can't fit;
    -- we persist any growth back to cfg at the end of rebuild so the
    -- column count is stable across future rebuilds.
    local noteColsCfg = cfg('noteColumns', {}) or {}
    channels = {}
    for i = 1, 16 do
      channels[i] = { chan = i, columns = {} }
      for _ = 1, math.max(noteColsCfg[i] or 1, 1) do
        addColumn(channels[i], 'note')
      end
    end

    -- 1) Truncate overlapping notes on the same channel and pitch.
    --    The earlier note is clipped to end where the later one begins.
    --    Direct mm:modify — we're normalising a possibly invariant-
    --    violating state, so we deliberately bypass the session's
    --    stage-2 semantics (which assume invariants already hold).
    --    Stage 1 rebuild at step 3 will fix up pb ownership after.
    do
      local groups, work = {}, {}
      for loc, note in mm:notes() do
        local key = note.chan .. '|' .. note.pitch
        if not groups[key] then groups[key] = {} end
        util:add(groups[key], { loc = loc, ppq = note.ppq, endppq = note.endppq })
      end
      for _, group in pairs(groups) do
        table.sort(group, function(a, b) return a.ppq < b.ppq end)
        for i = 1, #group - 1 do
          if group[i].endppq > group[i + 1].ppq then
            util:add(work, { loc = group[i].loc, endppq = group[i + 1].ppq })
          end
        end
      end
      if #work > 0 then
        mm:modify(function()
          for _, w in ipairs(work) do mm:assignNote(w.loc, { endppq = w.endppq }) end
        end)
      end
    end

    -- 2) Assign notes to note columns. Rewrite 'lane' on any note whose
    --    persisted preference didn't match where it landed.
    for loc, note in mm:notes() do
      local channel = channels[note.chan]
      local col, lane = allocateNoteColumn(channel, note)
      if note.lane ~= lane then
        mm:assignNote(loc, { lane = lane })
      end
      util:assign(note, { loc = loc, chan = util.REMOVE, lane = util.REMOVE })
      col.events[#col.events + 1] = note
    end

    -- 2b) Persist any growth in per-channel note column counts, so a
    --     later rebuild after notes are deleted doesn't make lanes vanish.
    do
      local grew = false
      for i = 1, 16 do
        local n = noteColCount(channels[i])
        if n > (noteColsCfg[i] or 1) then
          noteColsCfg[i] = n
          grew = true
        end
      end
      if grew and cm then
        cm:set('take', 'noteColumns', noteColsCfg)
      end
    end

    -- 3) Pitchbend: reconcile against the design invariants, then build
    --    the logical pb display lane per channel from the reconciled mm
    --    state. Stage 1 runs three steps (default detunes, reduce, add
    --    boundary pbs) inside a session, then commits to mm in one
    --    modify; after commit mm reflects the invariant-satisfying state.
    do
      local sn = newSession()
      sn:runStage1()
      sn:commit()
    end

    local pbRange = cfg('pbRange', 2)
    for chan = 1, 16 do
      local channel = channels[chan]
      local col1    = firstNoteCol(channel)
      local notes   = (col1 and col1.events) or {}
      -- detune prevailing at ppq P using the latest-starting-note-wins
      -- rule on already-built col-1 notes. Closed on the right here only
      -- to match the pb's "just before event takes effect" semantics for
      -- display purposes.
      local function detuneAtP(P)
        local best
        for _, n in ipairs(notes) do
          if n.ppq <= P and P < n.endppq then
            if not best or n.ppq > best.ppq then best = n end
          end
        end
        return (best and best.detune) or 0
      end

      local events, anyNonZero, lastLogical = {}, false, 0
      for loc, cc in mm:ccs() do
        if cc.chan == chan and cc.msgType == 'pb' then
          local d = detuneAtP(cc.ppq)
          local currentCents = (cc.val / 8192) * pbRange * 100
          local logicalCents = math.floor(currentCents - d + 0.5)
          util:add(events, {
            loc    = loc,
            ppq    = cc.ppq,
            val    = logicalCents,
            rawVal = cc.val,
            detune = d,
            hidden = (logicalCents == lastLogical),
          })
          lastLogical = logicalCents
          if logicalCents ~= 0 then anyNonZero = true end
        end
      end
      if anyNonZero then
        local col = getOrCreateSingletonColumn(channel, 'pb')
        for _, e in ipairs(events) do util:add(col.events, e) end
      end
    end

    -- 4) CCs, aftertouch, program change
    for loc, cc in mm:ccs() do
      local channel = channels[cc.chan]

      if cc.msgType == 'pa' then
        -- Poly AT → attach to the note column owning that pitch (drop orphans)
        local noteCol = findNoteColumnForPitch(channel, cc.pitch, cc.ppq)
        if noteCol then
          util:add(noteCol.events,{
            ppq = cc.ppq, type = 'pa', pitch = cc.pitch, vel = cc.val, loc = loc
          })
        end
      elseif cc.msgType == 'cc' then
        local col = getOrCreateCCColumn(channel, cc.cc)
        util:add(col.events, { ppq = cc.ppq, val = cc.val, loc = loc })
      elseif cc.msgType == 'at' or cc.msgType == 'pc' then
        local col = getOrCreateSingletonColumn(channel, cc.msgType)
        util:add(col.events, { ppq = cc.ppq, val = cc.val, loc = loc })
      end
    end


    -- 5) Sort every column's events by ppq
    for _, chan in ipairs(channels) do
      for _, col in ipairs(chan.columns) do
        table.sort(col.events, function(a, b) return a.ppq < b.ppq end)
      end
    end

    -- 6) Canonicalise column order within each channel.
    for _, chan in ipairs(channels) do
      chan.columns = canonicaliseColumns(chan.columns)
    end
    
    rebuilding = false

    fire(changed, tm)
  end

  --- ACCESSORS
  
  function tm:getChannel(chan)
    return channels and channels[chan]
  end

  function tm:channels()
    local i = 0
    return function()
      i = i + 1
      local channel = channels[i]
      if channel then
        return i, channel
      end
    end
  end

  -- GLOBAL DATA ACCESSORS

  function tm:editCursor()
    if not (mm and mm:take()) then return end
    local editCursorTime = reaper.GetCursorPosition()
    return reaper.MIDI_GetPPQPosFromProjTime(mm:take(), editCursorTime)
  end

  function tm:length()
    return mm and mm:length()
  end

  function tm:resolution()
    return mm and mm:resolution()
  end

  function tm:timeSigs()
    return mm and mm:timeSigs() or {}
  end

  function tm:playFrom(ppq)
    if not (mm and mm:take()) then return end
    reaper.SetEditCurPos(reaper.MIDI_GetProjTimeFromPPQPos(mm:take(), ppq), false, false)
    reaper.Main_OnCommand(1007, 0)  -- Transport: Play
  end

  function tm:play()
    reaper.Main_OnCommand(1007, 0)
  end

  function tm:stop()
    reaper.Main_OnCommand(1016, 0)
  end

  function tm:playPause()
    reaper.Main_OnCommand(40073, 0)
  end

  -- DEFERRED QUEUE EXTERNAL INTERFACE

  function tm:deleteEvent(type, evt)
    deleteEvent(type, evt)
  end

  -- pb values flow through the queue as logical cents throughout; the
  -- session converts to raw at commit. No conversion at queue-entry.
  function tm:addEvent(type, evt)      addEvent(type, evt)             end
  function tm:assignEvent(type, evt, update) assignEvent(type, evt, update) end

  function tm:flush() flush() end

  --------------------
  -- Microtuning realisation
  --
  -- tm owns the demix between note intent (pitch + detune) and note
  -- realisation (raw pb events on the wire). The view layer speaks
  -- intent; tm keeps realisation in sync inside the dispatch session —
  -- no caller participates in the invariant.
  --
  -- retuneNote is a convenience: viewManager passes both pitch and
  -- detune in one update; the classifier splits into a retune op plus
  -- a metadata pitch assign.
  --------------------

  function tm:retuneNote(note, update)
    assignEvent('note', note, update)
  end

  -- LIFECYCLE

  local callback = function(changed, _mm)
    if changed.data or changed.take then
      tm:rebuild(changed)
    end
  end

  local configCallback = function(changed, _cm)
    if changed.config then
      tm:rebuild({ take = false, data = true })
    end
  end

  function tm:attach(newMM, newCM)
    if not (newMM and newCM) then return end

    self:detach()
    mm = newMM
    cm = newCM
    mm:addCallback(callback)
    cm:addCallback(configCallback)
    self:rebuild({ take = true, data = true })
  end

  function tm:detach()
    if mm then mm:removeCallback(callback) end
    if cm then cm:removeCallback(configCallback) end
  end

  -- FACTORY BODY
  
  if mm and cm then tm:attach(mm, cm) end
  return tm
end
