-- Test runner. Usage: lua tests/run.lua [filter]

local info = debug.getinfo(1, 'S').source:match('^@?(.*)')
local testDir = info:match('^(.*)/[^/]+$') or '.'
local projectRoot = testDir:match('^(.*)/tests$') or testDir .. '/..'

package.path = projectRoot .. '/?.lua;'
            .. testDir     .. '/?.lua;'
            .. testDir     .. '/specs/?.lua;'
            .. package.path

local harness = require('harness')

local filter = arg[1]

local specs = {
  'harness_sanity_spec',
  'config_schema_spec',
  'util_edit_primitives_spec',
  'tm_rebuild_spec',
  'tm_tuning_spec',
  'tm_swing_spec',
  'vm_grid_spec',
  'vm_editing_spec',
  'view_context_spec',
  'edit_cursor_spec',
  'clipboard_spec',
  'vm_transient_frame_spec',
}

local pass, fail, failures = 0, 0, {}

for _, name in ipairs(specs) do
  local spec = require(name)
  for _, test in ipairs(spec) do
    local fullName = name .. ' :: ' .. test.name
    if not filter or fullName:find(filter, 1, true) then
      local ok, err = xpcall(function() test.run(harness) end, debug.traceback)
      if ok then
        pass = pass + 1
        io.write(string.format('  ok    %s\n', fullName))
      else
        fail = fail + 1
        failures[#failures + 1] = { name = fullName, err = err }
        io.write(string.format('  FAIL  %s\n', fullName))
      end
    end
  end
end

if #failures > 0 then
  io.write('\n=== failures ===\n')
  for _, f in ipairs(failures) do
    io.write('\n-- ' .. f.name .. '\n')
    io.write(tostring(f.err) .. '\n')
  end
end

io.write(string.format('\n%d passed, %d failed\n', pass, fail))
os.exit(fail > 0 and 1 or 0)
