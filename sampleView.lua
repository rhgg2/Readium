-- See docs/sampleView.md for the model and API reference.
--
-- Take-independent view for sample mode. Slot list + browser key against
-- a REAPER track, not a take; continuum.lua's loop pushes the selected
-- track in via setTrack each tick. Browser root comes from cm
-- (`sampleBrowserRoot`); $HOME is the lazy fallback. loadSlot / previewSlot /
-- previewPath are the gmem-mailbox writers in continuum.lua; injecting them
-- keeps sv free of gmem vocabulary and testable without REAPER.

loadModule('fs')

-- Lazy-initialised on first draw so the module loads cleanly in the
-- pure-Lua test harness (where ImGui is unavailable). require is cached,
-- so the per-frame cost after first init is a table lookup.
local ImGui

local N_SLOTS = 64
local PLAY    = '\xe2\x96\xb6'  -- U+25B6 ▶

function newSampleView(cm, loadSlot, previewSlot, previewPath)
  local sv = {}
  local track         = nil
  local currentFolder = nil  -- folder whose files fill the middle pane
  local selectedFile  = nil  -- full path of the file selected in the middle pane

  local function browseRoot()
    return cm:get('sampleBrowserRoot') or os.getenv('HOME') or '/'
  end

  local function drawTree(ctx, path)
    for _, sub in ipairs(fs.listDirs(path)) do
      local subPath = fs.join(path, sub)
      local open = ImGui.TreeNode(ctx, sub)
      if ImGui.IsItemClicked(ctx) then
        currentFolder = subPath
      end
      if open then
        drawTree(ctx, subPath)
        ImGui.TreePop(ctx)
      end
    end
  end

  local function drawFiles(ctx, path)
    for _, file in ipairs(fs.listAudioFiles(path)) do
      local full = fs.join(path, file)
      if ImGui.SmallButton(ctx, PLAY .. '##' .. full) then
        sv:auditionPath(full)
      end
      ImGui.SameLine(ctx)
      local clicked = ImGui.Selectable(ctx, file, selectedFile == full,
                                       ImGui.SelectableFlags_AllowDoubleClick)
      if clicked then
        selectedFile = full
        if ImGui.IsMouseDoubleClicked(ctx, 0) then
          sv:loadSelectedIntoCurrent()
        end
      end
    end
  end

  local function drawSlots(ctx)
    local names   = cm:get('samplerNames') or {}
    local current = cm:get('currentSample')
    for idx = 0, N_SLOTS - 1 do
      if ImGui.SmallButton(ctx, PLAY .. '##slot' .. idx) then
        sv:auditionSlot(idx)
      end
      ImGui.SameLine(ctx)
      local label = string.format('[%02d] %s', idx, names[idx] or '(empty)')
      if ImGui.Selectable(ctx, label, idx == current) then
        cm:set('transient', 'currentSample', idx)
      end
    end
  end

  function sv:setTrack(t)        track = t        end
  function sv:getTrack()         return track     end
  function sv:setSelectedFile(p) selectedFile = p end
  function sv:getSelectedFile()  return selectedFile end

  function sv:loadSelectedIntoCurrent()
    if not selectedFile then return false end
    loadSlot(cm:get('currentSample'), selectedFile)
    return true
  end

  function sv:auditionPath(path)
    if not path then return false end
    previewPath(path)
    return true
  end

  function sv:auditionSlot(idx)
    previewSlot(idx, 1)
  end

  function sv:draw(ctx)
    if not ImGui then ImGui = require 'imgui' '0.10' end
    local root = browseRoot()

    if track then
      local _, name = reaper.GetTrackName(track)
      ImGui.Text(ctx, 'Track: ' .. (name ~= '' and name or '(unnamed)'))
    else
      ImGui.Text(ctx, 'No track selected')
    end
    ImGui.Separator(ctx)

    local availW, availH = ImGui.GetContentRegionAvail(ctx)
    local treeW  = math.max(220, availW * 0.25)
    local filesW = (availW - treeW) * 0.55

    if ImGui.BeginChild(ctx, '##sampleTree', treeW, availH,
                        ImGui.ChildFlags_Borders) then
      ImGui.TextDisabled(ctx, root)
      drawTree(ctx, root)
    end
    ImGui.EndChild(ctx)

    ImGui.SameLine(ctx)

    if ImGui.BeginChild(ctx, '##sampleFiles', filesW, availH,
                        ImGui.ChildFlags_Borders) then
      drawFiles(ctx, currentFolder or root)
    end
    ImGui.EndChild(ctx)

    ImGui.SameLine(ctx)

    if ImGui.BeginChild(ctx, '##sampleSlots', 0, availH,
                        ImGui.ChildFlags_Borders) then
      drawSlots(ctx)
    end
    ImGui.EndChild(ctx)
  end

  return sv
end
