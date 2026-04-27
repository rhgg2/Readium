-- In-memory stand-in for midiManager. Upholds the public contract as
-- documented in midiManager.lua, minus the REAPER plumbing: events live
-- in plain Lua tables, locations are reassigned after every modify to
-- mirror the post-reload renumbering that tm relies on.

loadModule('util')

local INTERNALS = { idx = true, uuidIdx = true }

local function cloneShallow(t, exclude)
  if not t then return nil end
  local out = {}
  for k, v in pairs(t) do
    if not (exclude and exclude[k]) then out[k] = v end
  end
  return out
end

local noteCmp = function(a, b)
  if a.ppq   ~= b.ppq   then return a.ppq   < b.ppq   end
  if a.chan  ~= b.chan  then return a.chan  < b.chan  end
  return a.pitch < b.pitch
end

local ccCmp = function(a, b)
  if a.ppq     ~= b.ppq     then return a.ppq     < b.ppq     end
  if a.chan    ~= b.chan    then return a.chan    < b.chan    end
  if a.msgType ~= b.msgType then return (a.msgType or '') < (b.msgType or '') end
  return (a.cc or a.pitch or 0) < (b.cc or b.pitch or 0)
end

function newMidiManager(opts)
  opts = opts or {}
  -- Accept either a take token (real mm signature) or an options table.
  if type(opts) ~= 'table' then opts = { take = opts } end

  local noteList, ccList = {}, {}
  local noteByLoc, ccByLoc = {}, {}
  local lock        = false
  local take        = opts.take or 'fake-take'
  local resolution  = opts.resolution or 240
  local length      = opts.length or 3840
  local timeSigs    = opts.timeSigs or { { ppq = 0, num = 4, denom = 4 } }
  local maxUuid     = 0
  local fire

  -- Mirrors midiManager.lua's ccEventFields. A field outside this set is
  -- metadata; carve-out + first-stamp logic depends on the distinction.
  local ccEventFields = {
    idx = true, uuidIdx = true, ppq = true, msgType = true, chan = true,
    cc = true, pitch = true, val = true,
    muted = true, shape = true, tension = true, uuid = true,
  }

  local mm = {}
  fire = util.installHooks(mm)

  local function assertLock()
    assert(lock, 'Error! You must call modification functions via modify()!')
  end

  local function reindex()
    table.sort(noteList, noteCmp)
    table.sort(ccList,   ccCmp)
    noteByLoc, ccByLoc = {}, {}
    for i, n in ipairs(noteList) do noteByLoc[i] = n; n.idx = i - 1 end
    for i, c in ipairs(ccList)   do ccByLoc[i]   = c; c.idx = i - 1 end
  end

  -- LIFECYCLE

  function mm:load(newTake)
    if not newTake then return end
    local takeSwapped = take ~= newTake
    take = newTake
    -- A real load() would reparse from REAPER; the fake keeps its existing
    -- in-memory state. Tests that want a fresh buffer use mm:seed().
    if takeSwapped then fire('takeSwapped', nil) end
    fire('reload', nil)
  end

  function mm:reload()
    fire('reload', nil)
  end

  -- TEST-ONLY HELPERS

  function mm:seed(seed)
    noteList, ccList = {}, {}
    if seed.resolution then resolution = seed.resolution end
    if seed.length     then length     = seed.length     end
    if seed.timeSigs   then timeSigs   = seed.timeSigs   end
    for _, n in ipairs(seed.notes or {}) do noteList[#noteList + 1] = util.clone(n) end
    for _, c in ipairs(seed.ccs   or {}) do ccList[#ccList + 1]     = util.clone(c) end
    -- Track the high-water uuid across pre-seeded notes/ccs so subsequent
    -- allocations don't collide.
    for _, e in ipairs(noteList) do if e.uuid and e.uuid > maxUuid then maxUuid = e.uuid end end
    for _, e in ipairs(ccList)   do if e.uuid and e.uuid > maxUuid then maxUuid = e.uuid end end
    reindex()
    fire('takeSwapped', nil)
    fire('reload', nil)
  end

  function mm:dump()
    local function each(list)
      local out = {}
      for i, e in ipairs(list) do out[i] = util.clone(e) end
      return out
    end
    return { notes = each(noteList), ccs = each(ccList) }
  end

  -- LOCKING

  function mm:modify(fn)
    assert(not lock, 'modify() is not re-entrant')
    lock = true
    local ok, err = pcall(fn)
    lock = false
    reindex()
    fire('reload', nil)
    if not ok then error(err, 2) end
  end

  -- NOTES

  function mm:getNote(loc) return cloneShallow(noteByLoc[loc], INTERNALS) end

  function mm:notes()
    local i = 0
    return function()
      i = i + 1
      local n = noteByLoc[i]
      if n then return i, cloneShallow(n, INTERNALS) end
    end
  end

  function mm:addNote(t)
    assertLock()
    assert(t.ppq and t.endppq and t.chan and t.pitch and t.vel,
      'Error! Underspecified new note')
    local n = util.clone(t)
    if not n.muted then n.muted = nil end
    noteList[#noteList + 1] = n
    return #noteList  -- imprecise until reindex; tm discards it
  end

  function mm:deleteNote(loc)
    assertLock()
    local n = noteByLoc[loc]
    if not n then return end
    for i, e in ipairs(noteList) do
      if e == n then table.remove(noteList, i); break end
    end
    noteByLoc[loc] = nil
  end

  function mm:assignNote(loc, t)
    -- Metadata-only writes bypass the lock, matching the real mm's carve-out.
    local structural = t.ppq or t.endppq or t.pitch or t.vel or t.chan or t.muted ~= nil
    if not structural then
      local n = noteByLoc[loc]
      if not n then return end
      util.assign(n, t)
      return
    end
    assertLock()
    local n = noteByLoc[loc]
    if not n then return end
    util.assign(n, t)
    if n.muted == false then n.muted = nil end
  end

  -- CCs

  function mm:getCC(loc) return cloneShallow(ccByLoc[loc], INTERNALS) end

  function mm:ccs()
    local i = 0
    return function()
      i = i + 1
      local c = ccByLoc[i]
      if c then return i, cloneShallow(c, INTERNALS) end
    end
  end

  function mm:addCC(t)
    assertLock()
    if t.msgType == nil then t.msgType = 'cc' end
    assert(t.ppq and t.chan and t.val, 'Error! Underspecified new cc event')
    local c = util.clone(t)
    if not c.muted then c.muted = nil end
    if c.shape ~= 'bezier' then c.tension = nil end
    ccList[#ccList + 1] = c
    return #ccList
  end

  function mm:deleteCC(loc)
    assertLock()
    local c = ccByLoc[loc]
    if not c then return end
    for i, e in ipairs(ccList) do
      if e == c then table.remove(ccList, i); break end
    end
    ccByLoc[loc] = nil
  end

  function mm:assignCC(loc, t)
    local c = ccByLoc[loc]
    if not c then return end

    local hasStructural = t.ppq or t.msgType or t.chan or t.cc or t.pitch
                          or t.val or t.muted ~= nil or t.shape or t.tension
    local hasMetadata = false
    for k in pairs(t) do
      if not ccEventFields[k] then hasMetadata = true; break end
    end

    -- Lockless carve-out: metadata-only on a uuid'd cc — mirrors the real
    -- mm's assignCC carve-out.
    if not hasStructural and c.uuid then
      util.assign(c, t)
      return
    end

    assertLock()
    util.assign(c, t)
    if c.muted == false then c.muted = nil end
    if c.msgType ~= 'cc' then c.cc    = nil end
    if c.msgType ~= 'pa' then c.pitch = nil end
    if c.shape   ~= 'bezier' then c.tension = nil end

    -- First metadata stamp: allocate a uuid. Real mm also inserts a sidecar
    -- sysex; the fake just tracks the identity.
    if hasMetadata and not c.uuid then
      maxUuid = maxUuid + 1
      c.uuid  = maxUuid
    end
  end

  -- TAKE DATA

  function mm:take()       return take end
  function mm:resolution() return resolution end
  function mm:length()     return length end
  function mm:timeSigs()   return util.clone(timeSigs, nil, true) or {} end

  -- Curve semantics mirror midiManager.lua (kept in sync by hand; the real
  -- module isn't loaded under the test harness).
  local BEZIER = {
    { 0.2794, 0.4636,    0.4636 }, { 0.3442, 0.7704,    0.3384 },
    { 0.4020, 0.9849,    0.2466 }, { 0.4642, 1.1455,    0.1812 },
    { 0.5326, 1.2647,    0.1353 }, { 0.6059, 1.3532,    0.1011 },
    { 0.6820, 1.4199,    0.0738 }, { 0.7604, 1.4714,    0.0515 },
    { 0.8397, 1.5116,    0.0321 }, { 0.9198, 1.5441,    0.0154 },
    { 1.0000, math.pi/2, 0      },
  }
  local function bezierSample(tau, t)
    if t <= 0 then return 0 end
    if t >= 1 then return 1 end
    local fi = util.clamp(math.abs(tau), 0, 1) * 10
    local i = math.min(math.floor(fi), 9)
    local f = fi - i
    local r0, r1 = BEZIER[i+1], BEZIER[i+2]
    local h  = r0[1] + (r1[1] - r0[1]) * f
    local tL = r0[2] + (r1[2] - r0[2]) * f
    local tS = r0[3] + (r1[3] - r0[3]) * f
    local t1, t2 = tS, tL
    if tau < 0 then t1, t2 = tL, tS end
    local ax, ay = h*math.cos(t1),     h*math.sin(t1)
    local bx, by = 1 - h*math.cos(t2), 1 - h*math.sin(t2)
    local lo, hi = 0, 1
    for _ = 1, 20 do
      local s = (lo + hi) * 0.5
      local u = 1 - s
      local x = 3*u*u*s*ax + 3*u*s*s*bx + s*s*s
      if x < t then lo = s else hi = s end
    end
    local s = (lo + hi) * 0.5
    local u = 1 - s
    return 3*u*u*s*ay + 3*u*s*s*by + s*s*s
  end
  local function curveSample(shape, tension, t)
    if     shape == 'step'       then return t >= 1 and 1 or 0
    elseif shape == 'linear'     then return t
    elseif shape == 'slow'       then return t*t*(3 - 2*t)
    elseif shape == 'fast-start' then local u = 1 - t; return 1 - u*u*u
    elseif shape == 'fast-end'   then return t*t*t
    elseif shape == 'bezier'     then return bezierSample(tension or 0, t)
    end
  end
  function mm:interpolate(A, B, ppq)
    if not A.shape or A.shape == 'step' then return A.val end
    local span = B.ppq - A.ppq
    if span == 0 then return A.val end
    local t = (ppq - A.ppq) / span
    return (A.val or 0) + curveSample(A.shape, A.tension, t) * ((B.val or 0) - (A.val or 0))
  end

  return mm
end
