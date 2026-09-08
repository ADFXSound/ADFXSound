--[[
 * ReaScript Name: ADFX_Helper; renamer tool
 * About: A quick way to rename with or with sequential numbers, simple 
 * Author: ADFX
 * Author URI: adfxsound.com
 * Repository URI: https://raw.githubusercontent.com/ADearing01/ADFXSound/master/index.xml
 * REAPER: 7.34
 * Extensions: SWS/S&M 2.14.0.3
 * Version: 1.3
--]]

--[[
 * Changelog:
 * v1.3 (2025-01-13)
  + Fixed Tab key toggle for checkbox - now works consistently with mouse click
 * v1.2 (2025-03-12)
  + Modified to ignore existing sequential numbering patterns (_01, _02, etc.) when displaying the name template
 * v1.1 (2025-03-11)
  + Modified to ignore file extensions completely when renaming
 * v1.0 (2025-03-07)
  + Initial Release
--]]

function ShowImGuiMessageBox(message, title)
  -- Create ImGui context for error message
  local ctx = reaper.ImGui_CreateContext and reaper.ImGui_CreateContext('ADFX Message')
  
  if not ctx then
    -- Fallback to standard message box if ImGui not available
    reaper.ShowMessageBox(message, title, 0)
    return
  end
  
  local window_open = true
  
  function error_loop()
    -- Use fixed position and size for simplicity
    local window_width, window_height = 200, 120
    
    -- Set window position to center of screen (approximate)
    -- Use a fixed position that should work on most screens
    reaper.ImGui_SetNextWindowPos(ctx, 400, 300, reaper.ImGui_Cond_FirstUseEver())
    reaper.ImGui_SetNextWindowSize(ctx, window_width, window_height, reaper.ImGui_Cond_Always())
    
    local WINDOW_FLAGS = reaper.ImGui_WindowFlags_NoCollapse() | 
                         reaper.ImGui_WindowFlags_NoResize() |
                         reaper.ImGui_WindowFlags_AlwaysAutoResize()
    
    local visible, open = reaper.ImGui_Begin(ctx, title, true, WINDOW_FLAGS)
    
    if visible then
      -- Add spacing to center content vertically
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Spacing(ctx)
      
      -- Display the message
      reaper.ImGui_Text(ctx, message)
      
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Spacing(ctx)
      
      -- OK button
      if reaper.ImGui_Button(ctx, "OK", 100, 30) then
        window_open = false
      end
      
      -- Also close on Enter or Escape
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter()) or 
         reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
        window_open = false
      end
      
      reaper.ImGui_End(ctx)
    end
    
    if open and window_open then
      reaper.defer(error_loop)
    else
      if reaper.ImGui_DestroyContext then
        reaper.ImGui_DestroyContext(ctx)
      end
    end
  end
  
  reaper.defer(error_loop)
end

-- Function to remove file extension from item name
function RemoveFileExtension(filename)
  -- Common audio/video file extensions
  local extensions = {".wav", ".mp3", ".aif", ".aiff", ".flac", ".ogg", ".m4a", ".mp4", ".mov", ".avi", ".wmv"}
  
  -- Check for each extension
  for _, ext in ipairs(extensions) do
    local ext_pos = string.find(filename:lower(), ext:lower() .. "$")
    if ext_pos then
      return filename:sub(1, ext_pos-1)
    end
  end
  
  -- No recognized extension found
  return filename
end

-- Function to remove sequential numbering like "_01", "_02", etc.
function RemoveSequentialNumbering(name)
  -- Pattern to match "_01", "_02", etc. at the end of the string
  -- This pattern matches an underscore followed by exactly 2 digits at the end of the string
  local pattern = "_%d%d$"
  
  -- Check if the name has this pattern at the end
  if string.match(name, pattern) then
    -- Find the position of the last underscore
    local underscore_pos = string.find(name, "_[^_]*$")
    if underscore_pos then
      -- Return everything before the last underscore
      return string.sub(name, 1, underscore_pos - 1)
    end
  end
  
  -- If no match or no underscore found, return the original name
  return name
end

function main()
  -- Check if any items are selected
  local item_count = reaper.CountSelectedMediaItems(0)
  if item_count == 0 then
    ShowImGuiMessageBox("No items selected!", "Error")
    return
  end
  
  -- Get the name of the first selected item (if it exists)
  local first_item = reaper.GetSelectedMediaItem(0, 0)
  local first_take = reaper.GetActiveTake(first_item)
  local existing_name = ""
  
  if first_take then
    -- Get the existing name
    local _, take_name = reaper.GetSetMediaItemTakeInfo_String(first_take, "P_NAME", "", false)
    if take_name and take_name ~= "" then
      -- Remove extension from name if present
      existing_name = RemoveFileExtension(take_name)
      -- Remove sequential numbering like "_01" if present
      existing_name = RemoveSequentialNumbering(existing_name)
    end
  end
  
  -- Get last used values from ExtState or use defaults
  local name_template = existing_name
  if name_template == "" then
    name_template = reaper.GetExtState("ADFXRenameItemsTool", "name_template") or "Item"
  end
  
  -- Always default to adding numbers (true)
  local add_numbers_str = reaper.GetExtState("ADFXRenameItemsTool", "add_numbers")
  if add_numbers_str == "" or add_numbers_str == nil then
    add_numbers_str = "true"
  end
  local add_numbers = add_numbers_str == "true"
  
  -- Check for required extension
  local ctx = reaper.ImGui_CreateContext and reaper.ImGui_CreateContext('ADFX Renamer')
  
  if not ctx then
    -- Fallback to simple dialog if ImGui is not available
    local retval, user_input = reaper.GetUserInputs("ADFX Item Rename Tool", 2,
                              "Name template:,Add numbering (1=Yes, 0=No):extrawidth=100",
                              name_template .. "," .. (add_numbers and "1" or "0"))
    
    if not retval then return end -- User cancelled
    
    -- Parse inputs
    local comma_pos = string.find(user_input, ",", 1, true)
    if not comma_pos then
      ShowImGuiMessageBox("Invalid input!", "Error")
      return
    end
    
    name_template = string.sub(user_input, 1, comma_pos - 1)
    local number_option = string.sub(user_input, comma_pos + 1)
    add_numbers = (number_option == "1")
    
    -- Save and perform rename
    SaveSettingsAndRename(name_template, add_numbers, item_count)
    return
  end
  
  -- IMGUI Implementation (styled like ADFX launcher) - SCALED UP
  local WINDOW_FLAGS = reaper.ImGui_WindowFlags_NoCollapse()
  
  -- Set up config values to match ADFX launcher - SCALED UP
  local config = {
    window_width = 550,  -- Increased from 400
    window_height = 170, -- Increased from 110
    spacing = 12,        -- Increased from 8
    window_title = "ADFX Renamer Tool",
    bg_color = 3355443   -- Similar to script launcher
  }
  
  -- Variables to track state
  local window_open = true
  local first_frame = true  -- Track if this is the first frame

  function loop()
    local visible, open = reaper.ImGui_Begin(ctx, config.window_title, true, WINDOW_FLAGS)
    if visible then
      -- Set window size
      reaper.ImGui_SetWindowSize(ctx, config.window_width, config.window_height, reaper.ImGui_Cond_FirstUseEver())
      
      -- Name template input with spacing
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Text(ctx, "Name:")
      reaper.ImGui_SameLine(ctx)
      
      -- Set an ID for the input field so we can focus it
      local input_id = "##name"
      
      -- Increase input text size
      reaper.ImGui_SetNextItemWidth(ctx, config.window_width - 150) -- Wider input field
      local changed, new_name = reaper.ImGui_InputText(ctx, input_id, name_template)
      if changed then name_template = new_name end
      
      -- Set focus to the input field on the first frame
      if first_frame then
        reaper.ImGui_SetItemDefaultFocus(ctx)
        reaper.ImGui_SetKeyboardFocusHere(ctx, -1)  -- Focus the previous widget
        first_frame = false
      end
      
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Spacing(ctx)
      
      -- Handle Tab key toggle BEFORE the checkbox
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Tab()) then
        add_numbers = not add_numbers
      end
      
      -- Render checkbox as display only - ignore its return value completely
      -- We pass add_numbers to show current state visually
      reaper.ImGui_Checkbox(ctx, "Add sequential numbering (_01, _02, etc.)", add_numbers)
      
      -- Detect mouse click on checkbox separately (only left mouse button)
      if reaper.ImGui_IsItemClicked(ctx, 0) then
        add_numbers = not add_numbers
      end
      
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Spacing(ctx)
      
      -- Check for Enter key to confirm
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter()) and not reaper.ImGui_IsWindowAppearing(ctx) then
        -- Save settings and perform rename
        SaveSettingsAndRename(name_template, add_numbers, item_count)
        window_open = false
      end
      
      -- Check for Escape key to cancel
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
        window_open = false
      end
      
      reaper.ImGui_End(ctx)
    end
    
    if open and window_open then
      reaper.defer(loop)
    else
      -- Only call DestroyContext if it exists
      if reaper.ImGui_DestroyContext then
        reaper.ImGui_DestroyContext(ctx)
      end
      
      -- The X button in the corner will simply close without saving
    end
  end
  
  reaper.defer(loop)
end

function SaveSettingsAndRename(name_template, add_numbers, item_count)
  -- Save values to ExtState for next time
  reaper.SetExtState("ADFXRenameItemsTool", "name_template", name_template, true)
  reaper.SetExtState("ADFXRenameItemsTool", "add_numbers", add_numbers and "true" or "false", true)
  
  -- Perform renaming on all selected items
  for i = 0, item_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    if item then
      local take = reaper.GetActiveTake(item)
      
      if take then
        -- Create new name with base + numbering if enabled
        local new_name = name_template
        
        -- Add numbering if enabled (using two digits as requested)
        if add_numbers then
          -- Format with leading zero for 2-digit numbering
          local number_str = string.format("%02d", i + 1)
          new_name = new_name .. "_" .. number_str
        end
        
        -- Set the new name (no extension)
        reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", new_name, true)
      end
    end
  end
  
  -- Update the UI
  reaper.UpdateArrange()
end

-- Run the script
reaper.Undo_BeginBlock()
main()
reaper.Undo_EndBlock("ADFX Renamer Tool", -1)
