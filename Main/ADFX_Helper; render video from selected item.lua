--[[
ADFX - EXPORT VIDEO + AUDIO v17
================================

ONE-STOP VIDEO EXPORTER

Architecture:
    REAPER project
        |
        |-- render master audio -> temporary WAV
        |
        |-- obtain source video file from the REAPER video item
        |
        `-- FFmpeg mux/encode -> final MP4

This deliberately avoids REAPER's video render sink. REAPER's current
ReaScript API documents "evaw" as the default WAV sink and exposes
RENDER_BOUNDSFLAG / STARTPOS / ENDPOS / FILE / PATTERN for scripted
audio rendering.

Requirements:
    - Windows
    - REAPER
    - FFmpeg at DEFAULT_FFMPEG_PATH below, or available in PATH

SUPPORTED VIDEO SOURCE:
    A normal file-based video media item in the project.

SOURCE MODES:
    ITEM       = selected video item bounds
    SELECTION  = current time selection
    REGION     = first selected region

VIDEO:
    H.264 / libx264
    CRF
    preset
    source frame rate is preserved by default

AUDIO:
    REAPER master mix -> temporary WAV
    FFmpeg AAC encode
    configurable bitrate

IMPORTANT:
    This version intentionally does NOT use:
        RENDER_FORMAT = PMFF / FFMP
        PCM_Sink_ShowConfig
        RENDER_TARGETS
    for video rendering.

That avoids the invalid-video-sink configuration problem encountered
in previous versions.
]]

local TITLE = "ADFX Export Video"
local EXTSTATE = "ADFX_EXPORT_V18"

-- ============================================================
-- HARD-CODED FFMPEG PATH
-- ============================================================
-- This is the default shown every time the exporter opens.
-- Change this one line if ffmpeg.exe moves.
local DEFAULT_FFMPEG_PATH =
    [[C:\Users\Mr_Doctor_M1\AppData\Roaming\REAPER\Scripts\ADFX\ffmpeg.exe]]

local proj = reaper.EnumProjects(-1, "")
if not proj then return end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function getS(key)
    local ok, value =
        reaper.GetSetProjectInfo_String(
            proj, key, "", false
        )
    if ok and value then return value end
    return ""
end

local function setS(key, value)
    reaper.GetSetProjectInfo_String(
        proj, key, value or "", true
    )
end

local function getV(key)
    return reaper.GetSetProjectInfo(
        proj, key, 0, false
    )
end

local function setV(key, value)
    reaper.GetSetProjectInfo(
        proj, key, value, true
    )
end

local function clean(s)
    s = tostring(s or "")
    s = s:gsub("[<>:\"/\\|%?%*]", "_")
    s = s:gsub("[%c]", "_")
    s = s:gsub("^%s+", "")
    s = s:gsub("%s+$", "")
    s = s:gsub("%.+$", "")
    if s == "" then s = "Export" end
    return s
end

local function quote_cmd(s)
    -- Windows command-line quoting for normal filesystem paths.
    s = tostring(s or "")
    s = s:gsub('"', '""')
    return '"' .. s .. '"'
end

local function file_exists(pathname)
    return pathname and pathname ~= "" and reaper.file_exists(pathname)
end

local function project_name()
    local n = getS("PROJECT_NAME")
    if n == "" then n = "REAPER_Project" end
    n = n:match("([^/\\]+)$") or n
    n = n:gsub("%.[^%.]+$", "")
    return clean(n)
end

------------------------------------------------------------
-- Persistent settings
------------------------------------------------------------

local function load_setting(key, default)
    local ok, value =
        reaper.GetProjExtState(
            proj, EXTSTATE, key
        )
    if ok == 1 and value ~= "" then
        return value
    end
    return default
end

local function save_setting(key, value)
    reaper.SetProjExtState(
        proj, EXTSTATE, key, tostring(value or "")
    )
end

------------------------------------------------------------
-- Find FFmpeg
------------------------------------------------------------

local function find_ffmpeg()
    -- Hard-coded path takes priority. This means the GUI always opens
    -- with the same known-good FFmpeg executable instead of relying on
    -- project ExtState or repeatedly browsing for it.
    if DEFAULT_FFMPEG_PATH ~= "" and
       file_exists(DEFAULT_FFMPEG_PATH) then
        return DEFAULT_FFMPEG_PATH
    end

    -- Fall back to the previously saved project setting.
    local saved =
        load_setting("ffmpeg", "")

    if file_exists(saved) then
        return saved
    end

    -- Finally try Windows PATH.
    local result =
        reaper.ExecProcess(
            'where ffmpeg.exe',
            5000
        )

    if result and result ~= "" then
        local first =
            result:match("([^\r\n]+)")

        if first and file_exists(first) then
            return first
        end
    end

    -- Leave the field blank if none of the above exists.
    return ""
end


------------------------------------------------------------
-- Video source discovery
------------------------------------------------------------

local function source_file_for_item(item)
    if not item then return nil end

    local take =
        reaper.GetActiveTake(item)

    if not take then return nil end

    local source =
        reaper.GetMediaItemTake_Source(take)

    if not source then return nil end

    local source_type =
        reaper.GetMediaSourceType(source)

    local filename =
        reaper.GetMediaSourceFileName(source)

    if not filename or filename == "" then
        return nil
    end

    local lower_type =
        (source_type or ""):lower()

    local lower_file =
        filename:lower()

    local video_ext =
        lower_file:match("%.([%w]+)$")

    local known_video =
        video_ext == "mp4" or
        video_ext == "mov" or
        video_ext == "m4v" or
        video_ext == "mkv" or
        video_ext == "avi" or
        video_ext == "webm" or
        video_ext == "wmv" or
        video_ext == "mts" or
        video_ext == "m2ts" or
        video_ext == "ts"

    if lower_type:find("video", 1, true) or known_video then
        return {
            item = item,
            take = take,
            source = source,
            filename = filename,
            source_type = source_type or ""
        }
    end

    return nil
end

local function find_video_item_at_time(t)
    local count =
        reaper.CountMediaItems(proj)

    for i = 0, count - 1 do
        local item =
            reaper.GetMediaItem(proj, i)

        local pos =
            reaper.GetMediaItemInfo_Value(
                item, "D_POSITION"
            )

        local len =
            reaper.GetMediaItemInfo_Value(
                item, "D_LENGTH"
            )

        if t >= pos and t < pos + len then
            local video =
                source_file_for_item(item)

            if video then
                return video
            end
        end
    end

    return nil
end

local function find_selected_video_item()
    local count =
        reaper.CountSelectedMediaItems(proj)

    for i = 0, count - 1 do
        local item =
            reaper.GetSelectedMediaItem(proj, i)

        local video =
            source_file_for_item(item)

        if video then
            return video
        end
    end

    return nil
end

------------------------------------------------------------
-- Selected video items
------------------------------------------------------------

local function get_selected_video_items()
    local result = {}
    local count = reaper.CountSelectedMediaItems(proj)

    for i = 0, count - 1 do
        local item = reaper.GetSelectedMediaItem(proj, i)
        local video = source_file_for_item(item)

        if video then
            local pos =
                reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local len =
                reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

            local take = video.take
            local ok, name =
                reaper.GetSetMediaItemTakeInfo_String(
                    take, "P_NAME", "", false
                )

            if not ok or not name or name == "" then
                name = "Video_" .. tostring(i + 1)
            end

            name = clean(name:gsub("%.[^%.]+$", ""))

            result[#result + 1] = {
                video = video,
                start_pos = pos,
                end_pos = pos + len,
                name = name
            }
        end
    end

    table.sort(result, function(a, b)
        return a.start_pos < b.start_pos
    end)

    return result
end

------------------------------------------------------------
-- Selected regions
------------------------------------------------------------

local function get_selected_regions()
    local result = {}
    local idx = 0

    while true do
        local retval, isrgn, a, b, name, id =
            reaper.EnumProjectMarkers3(proj, idx)

        if retval == 0 then break end

        if isrgn then
            local marker =
                reaper.GetRegionOrMarker(
                    proj, idx, ""
                )

            if marker then
                local selected =
                    reaper.GetRegionOrMarkerInfo_Value(
                        proj,
                        marker,
                        "B_UISEL"
                    )

                if selected and selected > 0.5 then
                    result[#result + 1] = {
                        start_pos = a,
                        end_pos = b,
                        name = name or "",
                        id = id
                    }
                end
            end
        end

        idx = idx + 1
    end

    return result
end

------------------------------------------------------------
-- Item bounds
------------------------------------------------------------

local function selected_item_bounds()
    local count =
        reaper.CountSelectedMediaItems(proj)

    if count == 0 then
        return nil, nil
    end

    local a = math.huge
    local b = -math.huge

    for i = 0, count - 1 do
        local item =
            reaper.GetSelectedMediaItem(proj, i)

        local pos =
            reaper.GetMediaItemInfo_Value(
                item, "D_POSITION"
            )

        local len =
            reaper.GetMediaItemInfo_Value(
                item, "D_LENGTH"
            )

        a = math.min(a, pos)
        b = math.max(b, pos + len)
    end

    if a == math.huge or b <= a then
        return nil, nil
    end

    return a, b
end

------------------------------------------------------------
-- Source timing
------------------------------------------------------------

local function get_video_source_timing(video, project_start)
    local item = video.item
    local take = video.take

    local item_pos =
        reaper.GetMediaItemInfo_Value(
            item, "D_POSITION"
        )

    local playrate =
        reaper.GetMediaItemTakeInfo_Value(
            take, "D_PLAYRATE"
        )

    if playrate <= 0 then
        playrate = 1
    end

    local startoffs =
        reaper.GetMediaItemTakeInfo_Value(
            take, "D_STARTOFFS"
        )

    -- FFmpeg input timestamp corresponding to the requested project time.
    local offset =
        startoffs +
        (project_start - item_pos) * playrate

    return offset, playrate
end

------------------------------------------------------------
-- Initial values
------------------------------------------------------------

local regions = get_selected_regions()

local selection_a, selection_b =
    reaper.GetSet_LoopTimeRange(
        false, false, 0, 0, false
    )

local item_a, item_b =
    selected_item_bounds()

local initial_source = "ITEM"
local initial_name = project_name()

local initial_a = item_a
local initial_b = item_b

if #regions > 0 then
    initial_source = "REGION"
    initial_a = regions[1].start_pos
    initial_b = regions[1].end_pos
    initial_name = regions[1].name

    if initial_name == "" then
        initial_name =
            "Region_" .. tostring(regions[1].id)
    end

elseif selection_b > selection_a then
    initial_source = "SELECTION"
    initial_a = selection_a
    initial_b = selection_b
    initial_name =
        project_name() .. "_Selection"

elseif item_a then
    initial_source = "ITEM"

    local item =
        reaper.GetSelectedMediaItem(proj, 0)

    local take =
        item and reaper.GetActiveTake(item)

    if take then
        local ok, n =
            reaper.GetSetMediaItemTakeInfo_String(
                take, "P_NAME", "", false
            )

        if ok and n and n ~= "" then
            initial_name =
                n:gsub("%.[^%.]+$", "")
        end
    end
else
    reaper.ShowMessageBox(
        "Nothing to export.\n\n" ..
        "Select a video item, make a time selection, " ..
        "or select a region.",
        TITLE,
        0
    )
    return
end

initial_name = clean(initial_name)

------------------------------------------------------------
-- Defaults
------------------------------------------------------------

local ffmpeg =
    find_ffmpeg()

local output_dir =
    load_setting(
        "output_dir",
        reaper.GetProjectPath("")
    )

local crf =
    load_setting("crf", "18")

local preset =
    load_setting("preset", "medium")

local audio_bitrate =
    load_setting("audio_bitrate", "320k")

local overwrite =
    load_setting("overwrite", "YES")

------------------------------------------------------------
-- UI
------------------------------------------------------------

local W = 900
local H = 590

local fields = {
    initial_source,
    output_dir,
    initial_name,
    ffmpeg,
    crf,
    preset,
    audio_bitrate,
    overwrite
}

local labels = {
    "Source",
    "Output directory",
    "Output filename",
    "FFmpeg executable",
    "H.264 CRF",
    "H.264 preset",
    "AAC bitrate",
    "Overwrite existing"
}

local active = 1
local mouse_last = 0
local action = nil
local cursor = 0
local selection_anchor = nil

-- Full text-edit state for the active field.
-- cursor is a Lua string byte index represented as a character position.
-- selection_anchor is nil when there is no selection.
local cursor = 0
local selection_anchor = nil
local clipboard_available = true
local text_dragging = false
local text_drag_field = nil

gfx.init(TITLE, W, H, 0)

------------------------------------------------------------
-- Clipboard + text editing
------------------------------------------------------------

local function utf8_len(str)
    -- Count UTF-8 code points by counting bytes that are NOT
    -- continuation bytes. The previous implementation counted
    -- continuation bytes, which made an ASCII path appear to have
    -- a length of 1 and caused only the first character to be editable.
    if not str or str == "" then
        return 0
    end

    local _, count =
        str:gsub("[^\128-\191]", "")

    return count
end

local function char_to_byte(str, char_pos)
    if char_pos <= 0 then return 1 end
    local byte = 1
    local count = 0

    while byte <= #str and count < char_pos do
        local c = str:byte(byte)
        if c < 128 then
            byte = byte + 1
        elseif c < 224 then
            byte = byte + 2
        elseif c < 240 then
            byte = byte + 3
        else
            byte = byte + 4
        end
        count = count + 1
    end

    return byte
end

local function get_selection()
    if selection_anchor == nil or selection_anchor == cursor then
        return nil, nil
    end

    local a = math.min(selection_anchor, cursor)
    local b = math.max(selection_anchor, cursor)

    return a, b
end

local function delete_selection()
    local a, b = get_selection()
    if not a then return false end

    local str = fields[active]
    local ba = char_to_byte(str, a)
    local bb = char_to_byte(str, b)

    fields[active] =
        str:sub(1, ba - 1) ..
        str:sub(bb)

    cursor = a
    selection_anchor = nil
    return true
end

local function insert_text(text)
    if not text or text == "" then return end

    delete_selection()

    local str = fields[active]
    local byte = char_to_byte(str, cursor)

    fields[active] =
        str:sub(1, byte - 1) ..
        text ..
        str:sub(byte)

    cursor = cursor + utf8_len(text)
end

local function delete_back()
    if delete_selection() then return end
    if cursor <= 0 then return end

    local str = fields[active]
    local a = char_to_byte(str, cursor - 1)
    local b = char_to_byte(str, cursor)

    fields[active] =
        str:sub(1, a - 1) ..
        str:sub(b)

    cursor = cursor - 1
end

local function delete_forward()
    if delete_selection() then return end

    local str = fields[active]
    local n = utf8_len(str)

    if cursor >= n then return end

    local a = char_to_byte(str, cursor)
    local b = char_to_byte(str, cursor + 1)

    fields[active] =
        str:sub(1, a - 1) ..
        str:sub(b)
end

local function base64_encode(str)
    local alphabet =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    local out = {}
    local bytes = {str:byte(1, #str)}

    for i = 1, #bytes, 3 do
        local a = bytes[i]
        local b = bytes[i + 1]
        local c = bytes[i + 2]

        local n = (a or 0) * 65536 +
                  (b or 0) * 256 +
                  (c or 0)

        local x1 = math.floor(n / 262144) % 64 + 1
        local x2 = math.floor(n / 4096) % 64 + 1
        local x3 = math.floor(n / 64) % 64 + 1
        local x4 = n % 64 + 1

        out[#out + 1] = alphabet:sub(x1, x1)
        out[#out + 1] = alphabet:sub(x2, x2)

        if b then
            out[#out + 1] = alphabet:sub(x3, x3)
        else
            out[#out + 1] = "="
        end

        if c then
            out[#out + 1] = alphabet:sub(x4, x4)
        else
            out[#out + 1] = "="
        end
    end

    return table.concat(out)
end

local function clipboard_temp_path()
    local resource =
        reaper.GetResourcePath()

    return resource ..
        "\\ADFX_v15_clipboard.tmp"
end

local function copy_selection()
    local a, b = get_selection()
    if not a then return end

    local str = fields[active]
    local ba = char_to_byte(str, a)
    local bb = char_to_byte(str, b)
    local selected = str:sub(ba, bb - 1)

    -- Write the selection to a temporary UTF-8 file first. This avoids
    -- Windows command-line quoting problems with paths and punctuation.
    local temp = clipboard_temp_path()

    local f = io.open(temp, "wb")
    if not f then return end
    f:write(selected)
    f:close()

    local cmd =
        "powershell.exe -NoProfile -NonInteractive -Command " ..
        "\"Set-Clipboard -Value (Get-Content -Raw -Encoding UTF8 '" ..
        temp:gsub("'", "''") ..
        "')\""

    reaper.ExecProcess(cmd, 5000)
    os.remove(temp)
end

local function paste_clipboard()
    local temp = clipboard_temp_path()

    -- Ask PowerShell for the raw clipboard contents and put them in a
    -- file. ExecProcess stdout can contain implementation-specific
    -- status characters, so we deliberately do NOT use stdout here.
    local cmd =
        "powershell.exe -NoProfile -NonInteractive -Command " ..
        "\"Get-Clipboard -Raw | Set-Content -NoNewline -Encoding UTF8 '" ..
        temp:gsub("'", "''") ..
        "'\""

    reaper.ExecProcess(cmd, 5000)

    local f = io.open(temp, "rb")
    if not f then return end

    local text = f:read("*a")
    f:close()
    os.remove(temp)

    if text and text ~= "" then
        text = text:gsub("^\239\187\191", "")
        text = text:gsub("^\226\128\139", "")
        text = text:gsub("^\226\128\140", "")
        text = text:gsub("^\226\128\141", "")
        text =
            text:gsub("\r\n", " "):gsub("\n", " "):gsub("\r", " ")

        insert_text(text)
    end
end

local function select_all()
    cursor = utf8_len(fields[active])
    selection_anchor = 0
end

local function cursor_from_mouse(field_index, mx)
    gfx.setfont(1, "Arial", 14)
    local str = fields[field_index]
    local best = 0
    local best_dist = math.huge

    for p = 0, utf8_len(str) do
        local byte = char_to_byte(str, p)
        local before = str:sub(1, byte - 1)
        local px = 230 + gfx.measurestr(before)
        local dist = math.abs(mx - px)
        if dist < best_dist then
            best_dist = dist
            best = p
        end
    end

    return best
end

local function set_active_field(index)
    active = index
    cursor = utf8_len(fields[active])
    selection_anchor = nil
end

cursor = utf8_len(fields[active])

------------------------------------------------------------
-- UI helpers
------------------------------------------------------------

local function draw_text(x, y, s, size, r, g, b)
    gfx.setfont(1, "Arial", size or 15)
    gfx.set(r or 1, g or 1, b or 1, 1)
    gfx.x = x
    gfx.y = y
    gfx.drawstr(s or "")
end

local function inside(x, y, w, h, mx, my)
    return mx >= x and mx <= x + w and
           my >= y and my <= y + h
end

local function draw_button(x, y, w, h, label, primary)
    if primary then
        gfx.set(0.08, 0.34, 0.60, 1)
    else
        gfx.set(0.15, 0.15, 0.15, 1)
    end

    gfx.rect(x, y, w, h, 1)

    gfx.set(0.45, 0.45, 0.45, 1)
    gfx.rect(x, y, w, h, 0)

    draw_text(
        x + 12,
        y + 10,
        label,
        14,
        1, 1, 1
    )
end

local function draw()
    gfx.set(0.065, 0.065, 0.065, 1)
    gfx.rect(0, 0, W, H, 1)

    draw_text(
        25, 20,
        TITLE,
        25,
        1, 1, 1
    )

    draw_text(
        25, 55,
        "REAPER audio mix + FFmpeg video encoding/muxing",
        13,
        0.60, 0.60, 0.60
    )

    for i = 1, #fields do
        local y = 88 + (i - 1) * 48

        draw_text(
            25, y + 8,
            labels[i],
            14,
            0.80, 0.80, 0.80
        )

        if i == active then
            -- Bright active-field background so it is unmistakable
            -- which field currently receives keyboard input.
            gfx.set(0.08, 0.20, 0.30, 1)
        else
            gfx.set(0.045, 0.045, 0.045, 1)
        end

        gfx.rect(220, y, 650, 32, 1)

        gfx.set(0.40, 0.40, 0.40, 1)
        gfx.rect(220, y, 650, 32, 0)

        -- Selection highlight for the active text field.
        if i == active then
            local sa, sb = get_selection()
            if sa then
                gfx.set(0.18, 0.42, 0.62, 1)
                gfx.setfont(1, "Arial", 14)

                local str = fields[i]
                local ba = char_to_byte(str, sa)
                local bb = char_to_byte(str, sb)

                local before = str:sub(1, ba - 1)
                local selected = str:sub(ba, bb - 1)

                local x1 = 230 + gfx.measurestr(before)
                local sw = gfx.measurestr(selected)

                gfx.rect(
                    x1,
                    y + 4,
                    sw,
                    24,
                    1
                )
            end
        end

        draw_text(
            230, y + 7,
            fields[i],
            14,
            1, 1, 1
        )

        -- Draw the caret at the actual cursor position.
        if i == active then
            gfx.setfont(1, "Arial", 14)

            local str = fields[i]
            local byte = char_to_byte(str, cursor)
            local before = str:sub(1, byte - 1)
            local tw = gfx.measurestr(before)

            gfx.set(0.20, 0.85, 1.00, 1)
            gfx.rect(
                230 + tw + 2,
                y + 4,
                2,
                24,
                1
            )
        end
    end

    draw_button(
        25, 490,
        180, 44,
        "BROWSE FOLDER",
        false
    )

    draw_button(
        220, 490,
        180, 44,
        "BROWSE FFMPEG",
        false
    )

    draw_button(
        415, 490,
        155, 44,
        "REFRESH SOURCE",
        false
    )

    draw_button(
        665, 490,
        100, 44,
        "EXPORT",
        true
    )

    draw_button(
        775, 490,
        95, 44,
        "CANCEL",
        false
    )

    draw_text(
        590, 555,
        "EDITING: " .. labels[active],
        12,
        0.20, 0.75, 1.00
    )

    draw_text(
        25, 555,
        "ITEM mode: one MP4 per selected video item  |  Mouse text selection + clipboard  |  H.264 + AAC",
        12,
        0.50, 0.50, 0.50
    )

    -- Use an I-beam while the mouse is over an editable field.
    local over_field = false
    for i = 1, #fields do
        local fy = 88 + (i - 1) * 48
        if inside(220, fy, 650, 32, gfx.mouse_x, gfx.mouse_y) then
            over_field = true
            break
        end
    end

    if over_field then
        gfx.setcursor(1)
    else
        gfx.setcursor(0)
    end

    gfx.update()
end

------------------------------------------------------------
-- Browse folder
------------------------------------------------------------

local function browse_folder()
    local ok, path =
        reaper.GetUserFileName(
            3,
            "Choose Export Directory",
            fields[2],
            ""
        )

    if ok and path and path ~= "" then
        fields[2] =
            path:gsub("[/\\]+$", "")

        -- The folder dialog replaces the field contents. Reset the
        -- text-editor cursor to the END of the newly returned path.
        -- Without this, the cursor remains at its old position, which
        -- makes only the old portion of the field editable.
        active = 2
        cursor = utf8_len(fields[2])
        selection_anchor = nil
    end
end

------------------------------------------------------------
-- Browse ffmpeg
------------------------------------------------------------

local function browse_ffmpeg()
    local ok, path =
        reaper.GetUserFileName(
            1,
            "Choose ffmpeg.exe",
            fields[4],
            "FFmpeg executable|ffmpeg.exe|Executable files|*.exe|All files|*.*"
        )

    if ok and path and path ~= "" then
        fields[4] = path

        -- Same reset for the FFmpeg path field after browsing.
        active = 4
        cursor = utf8_len(fields[4])
        selection_anchor = nil
    end
end

------------------------------------------------------------
-- Refresh source
------------------------------------------------------------

local function refresh_source()
    local r = get_selected_regions()

    local sa, sb =
        reaper.GetSet_LoopTimeRange(
            false, false, 0, 0, false
        )

    local ia, ib =
        selected_item_bounds()

    if #r > 0 then
        fields[1] = "REGION"

        local n = r[1].name

        if n == "" then
            n =
                "Region_" .. tostring(r[1].id)
        end

        fields[3] = clean(n)

    elseif sb > sa then
        fields[1] = "SELECTION"
        fields[3] =
            project_name() .. "_Selection"

    elseif ia then
        fields[1] = "ITEM"

        local item =
            reaper.GetSelectedMediaItem(proj, 0)

        local take =
            item and reaper.GetActiveTake(item)

        if take then
            local ok, n =
                reaper.GetSetMediaItemTakeInfo_String(
                    take,
                    "P_NAME",
                    "",
                    false
                )

            if ok and n and n ~= "" then
                fields[3] =
                    clean(
                        n:gsub("%.[^%.]+$", "")
                    )
            end
        end
    end
end

------------------------------------------------------------
-- Mouse
------------------------------------------------------------

local function click(mx, my)

    text_dragging = false
    text_drag_field = nil

    for i = 1, #fields do
        local y = 88 + (i - 1) * 48

        if inside(
            220, y, 650, 32,
            mx, my
        ) then
            set_active_field(i)

            cursor = cursor_from_mouse(i, mx)
            selection_anchor = cursor
            text_dragging = true
            text_drag_field = i
            return
        end
    end

    if inside(
        25, 490, 180, 44,
        mx, my
    ) then
        browse_folder()
        return
    end

    if inside(
        220, 490, 180, 44,
        mx, my
    ) then
        browse_ffmpeg()
        return
    end

    if inside(
        415, 490, 155, 44,
        mx, my
    ) then
        refresh_source()
        return
    end

    if inside(
        665, 490, 100, 44,
        mx, my
    ) then
        action = "export"
        return
    end

    if inside(
        775, 490, 95, 44,
        mx, my
    ) then
        action = "cancel"
        return
    end
end

------------------------------------------------------------
-- Keyboard
------------------------------------------------------------

local function key(ch)

    if ch == 27 then
        action = "cancel"
        return
    end

    -- Windows Ctrl shortcuts arrive from gfx.getchar() as control
    -- characters: Ctrl+A=1, Ctrl+C=3, Ctrl+V=22, Ctrl+X=24.
    if ch == 1 then
        select_all()
        return
    elseif ch == 3 then
        copy_selection()
        return
    elseif ch == 22 then
        paste_clipboard()
        return
    elseif ch == 24 then
        copy_selection()
        delete_selection()
        return
    elseif ch == 26 then
        return
    end

    -- gfx does not expose reliable Shift state through getchar on all
    -- REAPER builds, so basic cursor movement remains non-shifted.
    local shift = false

    -- Tab moves between fields.
    if ch == 9 then
        set_active_field(
            active < #fields and active + 1 or 1
        )
        return
    end

    if ch == 13 then
        return
    end

    -- Backspace.
    if ch == 8 then
        delete_back()
        return
    end

    -- Delete is commonly reported as 6579564 in REAPER gfx.
    if ch == 6579564 then
        delete_forward()
        return
    end

    -- Left/right/Home/End are handled by REAPER gfx special-key codes.
    if ch == 1818584692 then -- left
        local n = utf8_len(fields[active])
        if shift and selection_anchor == nil then
            selection_anchor = cursor
        elseif not shift then
            selection_anchor = nil
        end
        cursor = math.max(0, cursor - 1)
        return
    end

    if ch == 1919379572 then -- right
        local n = utf8_len(fields[active])
        if shift and selection_anchor == nil then
            selection_anchor = cursor
        elseif not shift then
            selection_anchor = nil
        end
        cursor = math.min(n, cursor + 1)
        return
    end

    if ch == 1752132965 then -- home
        if shift and selection_anchor == nil then
            selection_anchor = cursor
        elseif not shift then
            selection_anchor = nil
        end
        cursor = 0
        return
    end

    if ch == 6647396 then -- end
        if shift and selection_anchor == nil then
            selection_anchor = cursor
        elseif not shift then
            selection_anchor = nil
        end
        cursor = utf8_len(fields[active])
        return
    end

    if ch >= 32 and ch <= 126 then
        insert_text(string.char(ch))
    end
end

------------------------------------------------------------
-- GUI loop
------------------------------------------------------------

local function gui()
    draw()

    local ch = gfx.getchar()

    if ch < 0 then
        action = "cancel"
    elseif ch > 0 then
        key(ch)
    end

    local cap = gfx.mouse_cap

    local down = (cap & 1) ~= 0
    local was_down = (mouse_last & 1) ~= 0

    if down and not was_down then
        click(gfx.mouse_x, gfx.mouse_y)

    elseif down and was_down and text_dragging then
        local i = text_drag_field
        if i then
            local y = 88 + (i - 1) * 48
            active = i

            if gfx.mouse_y < y then
                cursor = 0
            elseif gfx.mouse_y > y + 32 then
                cursor = utf8_len(fields[i])
            else
                cursor = cursor_from_mouse(i, gfx.mouse_x)
            end
        end

    elseif not down and was_down then
        text_dragging = false
        text_drag_field = nil
    end

    mouse_last = cap

    if not action then
        reaper.defer(gui)
        return
    end

    gfx.quit()

    if action == "export" then
        reaper.defer(export)
    end
end

------------------------------------------------------------
-- Normalize user-entered Windows paths
------------------------------------------------------------

local function normalize_path_input(value)
    value = tostring(value or "")

    -- Remove UTF-8 BOM / zero-width characters. These can be invisible
    -- in the GUI but make a pasted Windows path invalid.
    value = value:gsub("^\239\187\191", "")
    value = value:gsub("^\226\128\139", "")
    value = value:gsub("^\226\128\140", "")
    value = value:gsub("^\226\128\141", "")

    value = value:gsub("^%s+", "")
    value = value:gsub("%s+$", "")
    value = value:gsub('^"(.*)"$', "%1")
    value = value:gsub("/", "\\")

    if #value > 3 then
        value = value:gsub("\\+$", "")
    end

    return value
end

------------------------------------------------------------
-- Export
------------------------------------------------------------

function export()

    local source_mode =
        fields[1]:upper():gsub("%s+", "")

    -- Always use the actual editable field contents. Normalize them
    -- so pasted paths and Browse-generated paths are equivalent.
    local output_dir =
        normalize_path_input(fields[2])

    local default_filename =
        clean(fields[3])

    local ffmpeg_path =
        normalize_path_input(fields[4])

    local crf = tonumber(fields[5])
    local preset = fields[6]
    local audio_bitrate = fields[7]

    if source_mode ~= "ITEM" and
       source_mode ~= "SELECTION" and
       source_mode ~= "REGION" then
        reaper.ShowMessageBox(
            "Source must be ITEM, SELECTION, or REGION.",
            TITLE, 0
        )
        return
    end

    if output_dir == "" then
        reaper.ShowMessageBox(
            "Output directory is empty.", TITLE, 0
        )
        return
    end

    if not crf or crf < 0 or crf > 51 then
        reaper.ShowMessageBox(
            "H.264 CRF must be between 0 and 51.",
            TITLE, 0
        )
        return
    end

    preset = preset ~= "" and preset or "medium"
    audio_bitrate =
        audio_bitrate ~= "" and audio_bitrate or "320k"

    output_dir = normalize_path_input(output_dir)
    ffmpeg_path = normalize_path_input(ffmpeg_path)

    if not file_exists(ffmpeg_path) then
        reaper.ShowMessageBox(
            "FFmpeg path is not valid.\n\n" ..
            "The script received:\n" ..
            ffmpeg_path ..
            "\n\nUse Browse FFmpeg or paste the full path.",
            TITLE, 0
        )
        return
    end

    reaper.RecursiveCreateDirectory(output_dir, 0)

    -- Verify the directory can actually be used by opening a temporary
    -- file. This catches invisible BOM/clipboard characters in pasted
    -- paths instead of silently continuing.
    local probe =
        output_dir ..
        "\\.ADFX_path_test_" ..
        tostring(math.floor(reaper.time_precise() * 1000)) ..
        ".tmp"

    local pf = io.open(probe, "wb")
    if not pf then
        reaper.ShowMessageBox(
            "Output directory is not accessible.\n\n" ..
            "The script received:\n" ..
            output_dir,
            TITLE, 0
        )
        return
    end
    pf:close()
    os.remove(probe)

    --------------------------------------------------------
    -- Build export jobs.
    --
    -- ITEM mode: EACH selected video item becomes a separate
    -- export. This is the new v11 behavior.
    --------------------------------------------------------

    local jobs = {}

    if source_mode == "ITEM" then

        local selected_videos =
            get_selected_video_items()

        if #selected_videos == 0 then
            reaper.ShowMessageBox(
                "No file-based video items are selected.",
                TITLE, 0
            )
            return
        end

        -- Build the jobs first, then make filenames unique.
        -- Multiple selected items can legitimately have the same take
        -- name (for example several cuts named "Video"). Without this
        -- step, FFmpeg would overwrite the previous MP4 and it would
        -- look like only one video was exported.
        local used_names = {}

        for item_index, entry in ipairs(selected_videos) do
            local base_name = clean(entry.name)
            local unique_name = base_name

            local n = used_names[base_name] or 0
            n = n + 1
            used_names[base_name] = n

            if n > 1 then
                unique_name =
                    base_name ..
                    "_" ..
                    string.format("%02d", n)
            end

            jobs[#jobs + 1] = {
                a = entry.start_pos,
                b = entry.end_pos,
                video = entry.video,
                filename = unique_name,
                source_name = entry.name,
                item_index = item_index
            }
        end

    elseif source_mode == "REGION" then

        local r = get_selected_regions()

        if #r == 0 then
            reaper.ShowMessageBox(
                "No selected region.", TITLE, 0
            )
            return
        end

        local a = r[1].start_pos
        local b = r[1].end_pos
        local video = find_video_item_at_time(a)

        if not video then
            reaper.ShowMessageBox(
                "No file-based video item was found at the selected region.",
                TITLE, 0
            )
            return
        end

        local name = r[1].name
        if name == "" then
            name = "Region_" .. tostring(r[1].id)
        end

        jobs[#jobs + 1] = {
            a = a,
            b = b,
            video = video,
            filename = clean(name)
        }

    else

        local a, b =
            reaper.GetSet_LoopTimeRange(
                false, false, 0, 0, false
            )

        if b <= a then
            reaper.ShowMessageBox(
                "No time selection.", TITLE, 0
            )
            return
        end

        local video = find_video_item_at_time(a)

        if not video then
            reaper.ShowMessageBox(
                "No file-based video item was found at the export range.",
                TITLE, 0
            )
            return
        end

        jobs[#jobs + 1] = {
            a = a,
            b = b,
            video = video,
            filename = default_filename
        }
    end

    --------------------------------------------------------
    -- Validate all jobs before changing/rendering anything.
    --------------------------------------------------------

    for _, job in ipairs(jobs) do

        if job.b <= job.a then
            reaper.ShowMessageBox(
                "One of the export items has an invalid duration.",
                TITLE, 0
            )
            return
        end

        local video_item = job.video.item
        local item_pos =
            reaper.GetMediaItemInfo_Value(
                video_item, "D_POSITION"
            )
        local item_len =
            reaper.GetMediaItemInfo_Value(
                video_item, "D_LENGTH"
            )

        if job.a < item_pos - 0.000001 or
           job.b > item_pos + item_len + 0.000001 then
            reaper.ShowMessageBox(
                "An export range extends outside its source video item.",
                TITLE, 0
            )
            return
        end

        local _, playrate =
            get_video_source_timing(job.video, job.a)

        if math.abs(playrate - 1.0) > 0.000001 then
            reaper.ShowMessageBox(
                "A selected video item has a playback rate of " ..
                tostring(playrate) ..
                ".\n\nv11 currently requires normal 1.0x video playback rate.",
                TITLE, 0
            )
            return
        end
    end

    --------------------------------------------------------
    -- Save REAPER render settings once.
    --------------------------------------------------------

    local old_bounds = getV("RENDER_BOUNDSFLAG")
    local old_start = getV("RENDER_STARTPOS")
    local old_end = getV("RENDER_ENDPOS")
    local old_rate = getV("RENDER_SRATE")
    local old_channels = getV("RENDER_CHANNELS")
    local old_settings = getV("RENDER_SETTINGS")
    local old_file = getS("RENDER_FILE")
    local old_pattern = getS("RENDER_PATTERN")
    local old_format = getS("RENDER_FORMAT")
    local old_add = getV("RENDER_ADDTOPROJ")

    local completed = 0
    local failures = {}
    local completed_files = {}

    --------------------------------------------------------
    -- Render each selected video item independently.
    --------------------------------------------------------

    for job_index, job in ipairs(jobs) do

        local a = job.a
        local b = job.b
        local duration = b - a
        local job_filename = clean(job.filename)

        -- Temporary WAV and final MP4 live together.
        local temp_audio =
            output_dir ..
            "\\" ..
            job_filename ..
            "_ADFX_TEMP_" ..
            tostring(job_index) ..
            ".wav"

        local final_mp4 =
            output_dir ..
            "\\" ..
            job_filename ..
            ".mp4"

        -- If two different source names sanitize to the same filename,
        -- avoid overwriting an earlier job in this batch.
        if fields[8]:upper() ~= "NO" then
            local collision = 2
            local candidate = final_mp4

            while file_exists(candidate) and collision < 1000 do
                candidate =
                    output_dir ..
                    "\\" ..
                    job_filename ..
                    "_" ..
                    string.format("%02d", collision) ..
                    ".mp4"
                collision = collision + 1
            end

            final_mp4 = candidate
        end

        ----------------------------------------------------
        -- Render REAPER master audio for this item.
        ----------------------------------------------------

        setV("RENDER_BOUNDSFLAG", 0)
        setV("RENDER_STARTPOS", a)
        setV("RENDER_ENDPOS", b)

        local project_sr = getV("PROJECT_SRATE")
        if project_sr <= 0 then project_sr = 48000 end

        setV("RENDER_SRATE", project_sr)
        setV("RENDER_CHANNELS", 2)
        setV("RENDER_SETTINGS", 0)
        setV("RENDER_ADDTOPROJ", 0)

        setS("RENDER_FORMAT", "evaw")
        setS("RENDER_FILE", output_dir .. "\\")
        setS(
            "RENDER_PATTERN",
            job_filename ..
            "_ADFX_TEMP_" ..
            tostring(job_index)
        )

        reaper.Main_OnCommand(41824, 0)

        if not file_exists(temp_audio) then
            failures[#failures + 1] =
                job_filename ..
                " (REAPER WAV render failed)"
        else

            ------------------------------------------------
            -- Get video source offset for this item.
            ------------------------------------------------

            local video_offset =
                get_video_source_timing(
                    job.video, a
                )

            local overwrite_flag =
                (fields[8]:upper() == "NO")
                and "-n"
                or "-y"

            ------------------------------------------------
            -- FFmpeg: source video + REAPER WAV -> MP4.
            ------------------------------------------------

            local cmd =
                quote_cmd(ffmpeg_path) ..
                " " ..
                overwrite_flag ..
                " -hide_banner -loglevel error" ..
                " -ss " ..
                string.format("%.6f", video_offset) ..
                " -i " ..
                quote_cmd(job.video.filename) ..
                " -i " ..
                quote_cmd(temp_audio) ..
                " -map 0:v:0 -map 1:a:0" ..
                " -t " ..
                string.format("%.6f", duration) ..
                " -c:v libx264" ..
                " -preset " .. preset ..
                " -crf " .. tostring(math.floor(crf)) ..
                " -pix_fmt yuv420p" ..
                " -c:a aac" ..
                " -b:a " .. audio_bitrate ..
                " -movflags +faststart" ..
                " " ..
                quote_cmd(final_mp4)

            local ffmpeg_result =
                reaper.ExecProcess(cmd, 0)

            os.remove(temp_audio)

            if file_exists(final_mp4) then
                completed = completed + 1
                completed_files[#completed_files + 1] =
                    final_mp4
            else
                failures[#failures + 1] =
                    job_filename ..
                    " (FFmpeg failed: " ..
                    tostring(ffmpeg_result or "") ..
                    ")"
            end
        end
    end

    --------------------------------------------------------
    -- Restore user's REAPER render settings.
    --------------------------------------------------------

    setV("RENDER_BOUNDSFLAG", old_bounds)
    setV("RENDER_STARTPOS", old_start)
    setV("RENDER_ENDPOS", old_end)
    setV("RENDER_SRATE", old_rate)
    setV("RENDER_CHANNELS", old_channels)
    setV("RENDER_SETTINGS", old_settings)
    setV("RENDER_ADDTOPROJ", old_add)

    setS("RENDER_FILE", old_file)
    setS("RENDER_PATTERN", old_pattern)
    setS("RENDER_FORMAT", old_format)

    --------------------------------------------------------
    -- Save persistent settings.
    --------------------------------------------------------

    save_setting("output_dir", output_dir)
    save_setting("ffmpeg", ffmpeg_path)
    save_setting("crf", crf)
    save_setting("preset", preset)
    save_setting("audio_bitrate", audio_bitrate)
    save_setting("overwrite", fields[8])

    --------------------------------------------------------
    -- Result.
    --------------------------------------------------------

    local message =
        "EXPORT COMPLETE\n\n" ..
        "Videos exported: " ..
        tostring(completed) ..
        " / " ..
        tostring(#jobs)

    if #completed_files > 0 then
        message =
            message ..
            "\n\nCreated:\n" ..
            table.concat(completed_files, "\n")
    end

    if #failures > 0 then
        message =
            message ..
            "\n\nFailures:\n" ..
            table.concat(failures, "\n")
    end

    reaper.ShowMessageBox(
        message,
        TITLE,
        0
    )
end

------------------------------------------------------------
-- Start
------------------------------------------------------------

gui()
