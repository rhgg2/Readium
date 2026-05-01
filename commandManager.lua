-- See docs/commandManager.md for the model and API reference.

local layouts = {
  qwerty = {
    { 'z','s','x','d','c','v','g','b','h','n','j','m',',','l','.' },
    { 'q','2','w','3','e','r','5','t','6','y','7','u','i','9','o','0','p' },
  },
  colemak = {
    { 'z','r','x','s','c','v','d','b','h','k','n','m',',','i','.' },
    { 'q','2','w','3','f','p','5','g','6','j','7','l','u','9','y','0',';' },
  },
  dvorak = {
    { ';','o','q','e','j','k','i','x','d','b','h','m','w','n','v' },
    { "'", '2',',','3','.','p','5','y','6','f','7','g','c','9','r','0','l' },
  },
  azerty = {
    { 'w','s','x','d','c','v','g','b','h','n','j',',',';','l',':' },
    { 'a',233,'z','"','e','r','(','t','-','y',232,'u','i',231,'o',224,'p' },
  },
}

-- Fold layouts into a flat per-layout LUT so it stays in sync with the
-- declaration above. noteChars looks up by character code.
local chars = {}
for name, layout in pairs(layouts) do
  local t = {}
  for octOff, row in ipairs(layout) do
    for semi, ch in ipairs(row) do
      local code = type(ch) == 'number' and ch or string.byte(ch)
      t[code] = { semi - 1, octOff - 1 }
    end
  end
  chars[name] = t
end

function newCommandManager(cm)
  local mgr = {
    commands = {},
    keymap   = {},
    layouts  = layouts,
  }

  function mgr:register(name, fn)
    self.commands[name] = fn
  end

  function mgr:registerAll(tbl)
    for name, fn in pairs(tbl) do self.commands[name] = fn end
  end

  function mgr:wrap(name, wrapper)
    local orig = self.commands[name]
    if not orig then return end
    self.commands[name] = wrapper(orig)
  end

  function mgr:doBefore(name, before)
    if type(name) == 'table' then
      for _, n in ipairs(name) do self:doBefore(n, before) end
      return
    end
    self:wrap(name, function(orig)
      return function ()
        before()
        return orig()
      end
    end)
  end

  function mgr:doAfter(name, after)
    if type(name) == 'table' then
      for _, n in ipairs(name) do self:doAfter(n, after) end
      return
    end
    self:wrap(name, function(orig)
      return function ()
        local r, s = orig()
        after()
        return r, s
      end
    end)
  end

  function mgr:bind(name, keys)
    self.keymap[name] = keys
  end

  function mgr:bindAll(tbl)
    for name, keys in pairs(tbl) do self.keymap[name] = keys end
  end

  function mgr:invoke(name, ...)
    local fn = self.commands[name]
    if fn then return fn(...) end
  end

  -- Re-read noteLayout on each call so a config change takes effect
  -- without rebuilding vm.
  function mgr:noteChars(char)
    return chars[cm:get('noteLayout')][char]
  end

  function mgr:installDefaultKeymap(ImGui)
    self:bindAll{
      cursorUp       = { ImGui.Key_UpArrow,    {ImGui.Key_P, ImGui.Mod_Super} },
      cursorDown     = { ImGui.Key_DownArrow,  {ImGui.Key_N, ImGui.Mod_Super} },
      cursorLeft     = { ImGui.Key_LeftArrow,  {ImGui.Key_B, ImGui.Mod_Super} },
      cursorRight    = { ImGui.Key_RightArrow, {ImGui.Key_F, ImGui.Mod_Super} },
      goTop          = { ImGui.Key_Home,       {ImGui.Key_Comma, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
      goBottom       = { ImGui.Key_End,        {ImGui.Key_Period, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
      pageUp         = { ImGui.Key_PageUp },
      pageDown       = { ImGui.Key_PageDown },
      colLeft        = { {ImGui.Key_B, ImGui.Mod_Ctrl} },
      colRight       = { {ImGui.Key_F, ImGui.Mod_Ctrl} },
      channelLeft    = { {ImGui.Key_Tab, ImGui.Mod_Shift} },
      channelRight   = { ImGui.Key_Tab },
      noteOff        = { ImGui.Key_1 },
      shrinkNote     = { {ImGui.Key_LeftBracket, ImGui.Mod_Shift} },
      growNote       = { {ImGui.Key_RightBracket, ImGui.Mod_Shift} },
      nudgeBack      = { ImGui.Key_LeftBracket },
      nudgeForward   = { ImGui.Key_RightBracket },
      insertRow      = { {ImGui.Key_DownArrow, ImGui.Mod_Ctrl} },
      deleteRow      = { {ImGui.Key_UpArrow, ImGui.Mod_Ctrl} },
      delete         = { ImGui.Key_Period },
      interpolate    = { {ImGui.Key_I, ImGui.Mod_Ctrl} },
      selectUp       = { {ImGui.Key_UpArrow, ImGui.Mod_Shift} },
      selectDown     = { {ImGui.Key_DownArrow, ImGui.Mod_Shift} },
      selectLeft     = { {ImGui.Key_LeftArrow, ImGui.Mod_Shift} },
      selectRight    = { {ImGui.Key_RightArrow, ImGui.Mod_Shift} },
      cycleBlock     = { {ImGui.Key_Space, ImGui.Mod_Super} },
      cycleVBlock    = { {ImGui.Key_O, ImGui.Mod_Super} },
      swapBlockEnds  = { {ImGui.Key_GraveAccent, ImGui.Mod_Ctrl} },
      selectClear    = { {ImGui.Key_G, ImGui.Mod_Super} },
      cut            = { {ImGui.Key_W, ImGui.Mod_Super}, {ImGui.Key_X, ImGui.Mod_Ctrl} },
      copy           = { {ImGui.Key_W, ImGui.Mod_Ctrl}, {ImGui.Key_C, ImGui.Mod_Ctrl} },
      paste          = { {ImGui.Key_Y, ImGui.Mod_Super}, {ImGui.Key_V, ImGui.Mod_Ctrl} },
      duplicateDown  = { {ImGui.Key_D, ImGui.Mod_Ctrl} },
      duplicateUp    = { {ImGui.Key_D, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
      deleteSel      = { ImGui.Key_Delete },
      nudgeCoarseUp  = { {ImGui.Key_Equal, ImGui.Mod_Ctrl} },
      nudgeCoarseDown = { {ImGui.Key_Minus, ImGui.Mod_Ctrl} },
      nudgeFineUp    = { {ImGui.Key_Equal, ImGui.Mod_Shift} },
      nudgeFineDown  = { {ImGui.Key_Minus, ImGui.Mod_Shift} },
      addNoteCol     = { {ImGui.Key_N, ImGui.Mod_Ctrl} },
      addTypedCol    = { {ImGui.Key_T, ImGui.Mod_Ctrl} },
      doubleRPB      = { {ImGui.Key_Equal, ImGui.Mod_Super} },
      halveRPB       = { {ImGui.Key_Minus, ImGui.Mod_Super} },
      setRPB         = { {ImGui.Key_Z, ImGui.Mod_Super} },
      matchGridToCursor = { {ImGui.Key_M, ImGui.Mod_Super} },
      hideExtraCol   = { {ImGui.Key_H, ImGui.Mod_Ctrl} },
      inputOctaveUp   = { {ImGui.Key_8, ImGui.Mod_Shift} },
      inputOctaveDown = { ImGui.Key_Slash },
      playPause      = { ImGui.Key_Space },
      playFromTop    = { ImGui.Key_F6 },
      playFromCursor = { ImGui.Key_F7 },
      stop           = { ImGui.Key_F8 },
      quit           = { ImGui.Key_Enter },
      openTemperPicker = { {ImGui.Key_T, ImGui.Mod_Super} },
      openSwingPicker  = { {ImGui.Key_S, ImGui.Mod_Super} },
      openSwingEditor = { {ImGui.Key_E, ImGui.Mod_Super} },
      reswing                = { {ImGui.Key_R, ImGui.Mod_Ctrl} },
      quantize               = { {ImGui.Key_Q, ImGui.Mod_Ctrl} },
      quantizeKeepRealised   = { {ImGui.Key_Q, ImGui.Mod_Ctrl, ImGui.Mod_Shift} },
    }
    for i = 0, 9 do
      self:bind('advBy' .. i, { {ImGui.Key_0 + i, ImGui.Mod_Ctrl} })
    end
  end

  return mgr
end
