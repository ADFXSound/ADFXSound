--[[
 * ReaScript Name: ADFX_Helper; create markers intervals and align selected items to them
 * About: Automatically aligns selected items with equal spacing and creates markers at each item position
 * Author: ADFX 
 * Author URI: adfxsound.com
 * Repository URI: https://raw.githubusercontent.com/ADearing01/ADFXSound/master/index.xml
 * REAPER: 7.34
 * Extensions: SWS/S&M 2.14.0.3
 * Version: 1.1
--]]
--[[
 * Changelog:
 * v1.1 (2025-03-10)
  + Added grid snapping for markers and items
 * v1.0 (2025-03-05)
  + Initial Release
--]]

function findNextDownbeat(position)
  -- Get time signature 
  local _, bpm, _, _ = reaper.TimeMap2_GetDividedBpmAtTime(0, position)
  
  -- Get measure information at position
  local _, measures, cml, fullbeats, cdenom = reaper.TimeMap2_timeToBeats(0, position)
  
  -- If we're not on beat 1, find the next measure start
  if fullbeats % cdenom ~= 0 then
    -- Get the next measure start time
    local next_measure = measures + 1
    local next_downbeat_time = reaper.TimeMap2_beatsToTime(0, next_measure * cdenom, 0)
    return next_downbeat_time
  end
  
  -- Already on a downbeat (beat 1)
  return position
end

function main()
  -- Store the initial edit cursor position to restore later
  local initial_cursor_pos = reaper.GetCursorPosition()
  
  -- Check if any items are selected
  local num_selected_items = reaper.CountSelectedMediaItems(0)
  if num_selected_items == 0 then
    reaper.ShowMessageBox("No items selected. Please select some items.", "Error", 0)
    return
  end
  
  -- Begin undo block
  reaper.Undo_BeginBlock()
  
  -- Get all selected items and their properties
  local items = {}
  for i = 0, num_selected_items - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    
    -- Get item name if available
    local item_name = ""
    if take then
      item_name = reaper.GetTakeName(take)
    end
    
    -- Add item to our list
    table.insert(items, {
      item = item,
      position = item_pos,
      length = item_length,
      name = item_name
    })
  end
  
  -- Sort items by their original positions
  table.sort(items, function(a, b) return a.position < b.position end)
  
  -- Get the time signature
  local _, _, _, qn_per_measure = reaper.TimeMap_GetTimeSigAtTime(0, 0)
  
  -- Start the first item at the first downbeat from its current position
  local start_position = findNextDownbeat(items[1].position)
  
  -- Position for the first item
  local current_pos = start_position
  
  -- Reposition each item and create markers
  for i, item_data in ipairs(items) do
    -- Set the new position for this item
    reaper.SetMediaItemInfo_Value(item_data.item, "D_POSITION", current_pos)
    
    -- Create a marker at this item position
    local marker_name = "Item " .. i
    if item_data.name ~= "" then
      marker_name = item_data.name -- Use item/take name if available
    end
    
    -- Create marker at the exact same position
    local marker_idx = reaper.AddProjectMarker(0, false, current_pos, 0, marker_name, -1)
    
    -- Calculate the position for the next item
    -- Find the next downbeat after this item's end
    local item_end = current_pos + item_data.length
    current_pos = findNextDownbeat(item_end)
  end
  
  -- Update the display
  reaper.UpdateArrange()
  
  -- Restore cursor position
  reaper.SetEditCurPos(initial_cursor_pos, false, false)
  
  -- End undo block
  reaper.Undo_EndBlock("Align Items to Downbeats and Create Markers", -1)
end

-- Execute the script
main()