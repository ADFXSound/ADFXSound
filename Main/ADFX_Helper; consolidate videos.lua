--[[
ADFX - Consolidate Video to MP4 v13

SAFE AUTOMATIC-IMPORT ARCHITECTURE

Manually duplicate the same video item, place copies end-to-end, select
all copies, then run this script.

1. FFmpeg creates ONE consolidated MP4.
2. REAPER's native Insert Media dialog is used for the import.
3. A hidden PowerShell helper fills the finished MP4 path and activates
   Open automatically.
4. The original duplicated items are removed immediately before the
   native import, so there is no post-import media deletion.

The resulting MP4 is ready to use with ADFX Export Video + Audio.

FFmpeg path is hard-coded below.
]]

local TITLE = "ADFX Consolidate Video to MP4 v13"

------------------------------------------------------------
-- HARD-CODED FFMPEG PATH
------------------------------------------------------------

local FFMPEG =
    [[C:\Users\Mr_Doctor_M1\AppData\Roaming\REAPER\Scripts\ADFX\ffmpeg.exe]]

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local proj = reaper.EnumProjects(-1, "")
if not proj then return end

local function msg(text, buttons)
    return reaper.ShowMessageBox(
        text,
        TITLE,
        buttons or 0
    )
end

local function exists(path)
    return path and path ~= "" and reaper.file_exists(path)
end

local function quote(s)
    s = tostring(s or "")
    return '"' .. s:gsub('"', '\\"') .. '"'
end

local function bounds(item)
    local pos =
        reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len =
        reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    return pos, pos + len, len
end

local function video_source(item)
    local take = reaper.GetActiveTake(item)
    if not take then return nil end

    local src =
        reaper.GetMediaItemTake_Source(take)
    if not src then return nil end

    local filename =
        reaper.GetMediaSourceFileName(src, "")
    if not filename or filename == "" then return nil end

    local typ =
        reaper.GetMediaSourceType(src, "")

    local ext =
        filename:match("%.([^%.]+)$")
    ext = ext and ext:lower() or ""

    local video_ext = {
        mp4=true, mov=true, m4v=true, avi=true,
        mkv=true, webm=true, wmv=true,
        mpg=true, mpeg=true, m2v=true,
        mts=true, m2ts=true, ts=true
    }

    if typ ~= "VIDEO" and not video_ext[ext] then
        return nil
    end

    local offset =
        reaper.GetMediaItemTakeInfo_Value(
            take, "D_STARTOFFS"
        )

    local rate =
        reaper.GetMediaItemTakeInfo_Value(
            take, "D_PLAYRATE"
        )

    if rate <= 0 then rate = 1 end

    return {
        filename = filename,
        offset = offset,
        rate = rate
    }
end

local function project_dir()
    local path = reaper.GetProjectPath("")
    if path and path ~= "" then return path end
    return reaper.GetResourcePath()
end

local function item_name(item)
    local take = reaper.GetActiveTake(item)
    local name = ""

    if take then
        local ok, value =
            reaper.GetSetMediaItemTakeInfo_String(
                take, "P_NAME", "", false
            )
        if ok then name = value or "" end
    end

    name = name:gsub("%.[^%.]+$", "")
    name = name:gsub('[<>:"/\\|%?%*]', "_")
    name = name:gsub("[%c]", "_")

    if name == "" then
        name = "ADFX_Consolidated_Video"
    end

    return name
end

local function output_path(base)
    return project_dir() .. "\\" .. base .. ".mp4"
end

------------------------------------------------------------
-- Validate selection
------------------------------------------------------------

local count =
    reaper.CountSelectedMediaItems(proj)

if count < 2 then
    msg(
        "Select at least TWO video items.\n\n" ..
        "Manually duplicate the video, place the copies end-to-end, " ..
        "select them all, and run this script."
    )
    return
end

local items = {}
local track = nil

for i = 0, count - 1 do

    local item =
        reaper.GetSelectedMediaItem(proj, i)

    local src =
        video_source(item)

    if not src then
        msg(
            "Every selected item must contain video."
        )
        return
    end

    local item_track =
        reaper.GetMediaItem_Track(item)

    if not track then
        track = item_track
    elseif track ~= item_track then
        msg(
            "All selected video items must be on the same track."
        )
        return
    end

    items[#items + 1] = {
        item = item,
        src = src
    }
end

------------------------------------------------------------
-- Sort
------------------------------------------------------------

table.sort(
    items,
    function(a, b)
        return reaper.GetMediaItemInfo_Value(
            a.item, "D_POSITION"
        ) <
        reaper.GetMediaItemInfo_Value(
            b.item, "D_POSITION"
        )
    end
)

------------------------------------------------------------
-- Same source + contiguous + rate 1
------------------------------------------------------------

local first_file =
    items[1].src.filename

local sequence_start
local sequence_end

for i, entry in ipairs(items) do

    if entry.src.filename ~= first_file then
        msg(
            "All selected items must be duplicates of the SAME " ..
            "source video."
        )
        return
    end

    if math.abs(entry.src.rate - 1.0) > 0.000001 then
        msg(
            "All selected video items must have playback rate 1.0."
        )
        return
    end

    local pos, finish, len =
        bounds(entry.item)

    if len <= 0 then
        msg("A selected video item has zero duration.")
        return
    end

    if i == 1 then
        sequence_start = pos
    else
        local _, previous_end =
            bounds(items[i - 1].item)

        if math.abs(pos - previous_end) > 0.0001 then
            msg(
                "The selected video items are not contiguous.\n\n" ..
                "Place the duplicates directly end-to-end."
            )
            return
        end
    end

    sequence_end = finish
end

local total_duration =
    sequence_end - sequence_start

------------------------------------------------------------
-- Validate FFmpeg
------------------------------------------------------------

if not exists(FFMPEG) then
    msg(
        "FFmpeg was not found:\n\n" ..
        FFMPEG ..
        "\n\nEdit FFMPEG at the top of the script."
    )
    return
end

------------------------------------------------------------
-- Output files
------------------------------------------------------------

local output =
    output_path(
        item_name(items[1].item)
    )

local log_file =
    output .. ".ffmpeg.log"

local done_marker =
    output .. ".adfx_done"

local worker =
    output .. ".adfx_worker.vbs"

os.remove(log_file)
os.remove(done_marker)
os.remove(worker)

------------------------------------------------------------
-- FFmpeg command
------------------------------------------------------------

local source_start =
    items[1].src.offset

local ffmpeg_command =
    quote(FFMPEG) ..
    " -y -stream_loop -1" ..
    " -ss " ..
    string.format("%.6f", source_start) ..
    " -i " ..
    quote(first_file) ..
    " -t " ..
    string.format("%.6f", total_duration) ..
    " -an" ..
    " -c:v libx264" ..
    " -preset medium" ..
    " -crf 18" ..
    " -pix_fmt yuv420p" ..
    " -movflags +faststart" ..
    " " ..
    quote(output) ..
    " > " ..
    quote(log_file) ..
    " 2>&1"

------------------------------------------------------------
-- Hidden FFmpeg worker
--
-- IMPORTANT:
-- WScript.Shell.Run does NOT process shell redirection (">" and
-- "2>&1") when given a raw command line. That was the reason v12
-- could launch without actually producing the MP4.
--
-- We therefore invoke cmd.exe INSIDE the hidden VBScript.
-- The CMD window remains hidden, while CMD handles the redirection.
------------------------------------------------------------

local wf =
    io.open(worker, "wb")

if not wf then
    msg(
        "Could not create the temporary FFmpeg worker file."
    )
    return
end

local function vbs_quote(value)
    return '"' ..
        tostring(value)
            :gsub('"','""') ..
        '"'
end

local hidden_command =
    'cmd.exe /d /c ' ..
    vbs_quote(ffmpeg_command)

wf:write('Option Explicit\r\n')
wf:write('Dim sh, fso, rc\r\n')
wf:write('Set sh = CreateObject("WScript.Shell")\r\n')
wf:write('Set fso = CreateObject("Scripting.FileSystemObject")\r\n')
wf:write('rc = sh.Run(' ..
    vbs_quote(hidden_command) ..
    ', 0, True)\r\n')
wf:write('If rc = 0 Then\r\n')
wf:write('  If fso.FileExists(' ..
    vbs_quote(output) ..
    ') Then\r\n')
wf:write('    fso.CreateTextFile(' ..
    vbs_quote(done_marker) ..
    ', True).Write "DONE"\r\n')
wf:write('  End If\r\n')
wf:write('End If\r\n')
wf:write('Set fso = Nothing\r\n')
wf:write('Set sh = Nothing\r\n')
wf:close()

------------------------------------------------------------
-- INITIAL CONFIRMATION
------------------------------------------------------------

local answer =
    msg(
        "VIDEO CONSOLIDATION\n\n" ..
        "Source item name:\n" ..
        item_name(items[1].item) ..
        "\n\n" ..
        "Items: " ..
        tostring(#items) ..
        "\n" ..
        "Combined duration: " ..
        string.format("%.3f", total_duration) ..
        " seconds\n\n" ..
        "Output:\n" ..
        output ..
        "\n\n" ..
        "The duplicated video items will be removed automatically " ..
        "after the MP4 is ready and before the new MP4 is imported.\n\n" ..
        "Continue?",
        1
    )

if answer ~= 1 then
    os.remove(worker)
    return
end

------------------------------------------------------------
-- Launch hidden FFmpeg worker
------------------------------------------------------------

local launch =
    'wscript.exe //B //Nologo ' ..
    quote(worker)

reaper.ExecProcess(
    launch,
    5000
)

------------------------------------------------------------
-- Status
------------------------------------------------------------

msg(
    "FFmpeg encoding has started.\n\n" ..
    "Output:\n" ..
    output ..
    "\n\n" ..
    "The command window is hidden.\n" ..
    "The script will automatically import the finished MP4 " ..
    "and remove the duplicated source items.",
    0
)

------------------------------------------------------------
-- IMPORTANT
--
-- No gfx window and no InsertMedia().
--
-- The previous crash-prone versions used REAPER's InsertMedia API
-- after FFmpeg completed. v9 avoids that API completely.
--
-- We still provide a visible status message immediately. The script
-- remains alive via defer and reports completion when done.
------------------------------------------------------------

------------------------------------------------------------
-- Monitor
------------------------------------------------------------

local start_time =
    reaper.time_precise()

local timeout =
    900

local finished = false

local function monitor()

    if finished then return end

    if exists(done_marker) and
       exists(output) then

        finished = true

        os.remove(done_marker)
        os.remove(worker)

        --------------------------------------------------------
        -- IMPORTANT:
        -- The native file dialog is still used because it is the
        -- stable import path that worked in v11.
        --
        -- Before opening it, remove the original duplicated items.
        -- This means there is NO post-import video-item manipulation,
        -- which is the operation that caused the earlier REAPER crash.
        --------------------------------------------------------

        local helper =
            output .. ".adfx_import.ps1"

        local ps = io.open(helper, "wb")

        if not ps then
            msg(
                "MP4 created successfully, but the automatic import " ..
                "helper could not be created.\n\n" ..
                output
            )
            return
        end

        local ps_code = [[
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class ADFXWin32 {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")]
  public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

  [DllImport("user32.dll")]
  public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string cls, string title);

  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, string lParam);

  [DllImport("user32.dll")]
  public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern IntPtr SetFocus(IntPtr hWnd);

  public const uint WM_SETTEXT = 0x000C;
  public const uint WM_COMMAND = 0x0111;
  public const int IDOK = 1;

  public static IntPtr FindReaperDialog() {
    IntPtr found = IntPtr.Zero;

    EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
      uint pid;
      GetWindowThreadProcessId(hWnd, out pid);

      try {
        var p = System.Diagnostics.Process.GetProcessById((int)pid);
        if (!p.ProcessName.ToLower().Contains("reaper"))
          return true;
      } catch {
        return true;
      }

      StringBuilder cls = new StringBuilder(256);
      GetClassName(hWnd, cls, cls.Capacity);

      if (cls.ToString() == "#32770") {
        found = hWnd;
        return false;
      }

      return true;
    }, IntPtr.Zero);

    return found;
  }

  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
}
"@

$target = '__ADFX_OUTPUT__'
$deadline = (Get-Date).AddSeconds(30)

while ((Get-Date) -lt $deadline) {
    $dlg = [ADFXWin32]::FindReaperDialog()

    if ($dlg -ne [IntPtr]::Zero) {
        [ADFXWin32]::SetForegroundWindow($dlg)

        $edit = [ADFXWin32]::FindWindowEx(
            $dlg,
            [IntPtr]::Zero,
            "Edit",
            $null
        )

        if ($edit -ne [IntPtr]::Zero) {
            [ADFXWin32]::SetFocus($edit)

            [ADFXWin32]::SendMessage(
                $edit,
                [ADFXWin32]::WM_SETTEXT,
                [IntPtr]::Zero,
                $target
            )

            Start-Sleep -Milliseconds 150

            # IDOK = 1. This directly activates the dialog's Open/OK
            # command instead of making the user select the file.
            [ADFXWin32]::SendMessage(
                $dlg,
                [ADFXWin32]::WM_COMMAND,
                [IntPtr][ADFXWin32]::IDOK,
                [IntPtr]::Zero
            )

            Start-Sleep -Milliseconds 250

            if ([ADFXWin32]::FindReaperDialog() -eq [IntPtr]::Zero) {
                exit 0
            }
        }
    }

    Start-Sleep -Milliseconds 100
}

exit 1
]]

        ps_code =
            ps_code:gsub(
                "__ADFX_OUTPUT__",
                output:gsub("\\","\\"):gsub("'","''")
            )

        ps:write(ps_code)
        ps:close()

        local ps_cmd =
            'powershell.exe -NoProfile -ExecutionPolicy Bypass ' ..
            '-WindowStyle Hidden -File ' ..
            quote(helper)

        reaper.ExecProcess(
            ps_cmd,
            1000
        )

        --------------------------------------------------------
        -- Set insertion point and target track.
        --------------------------------------------------------

        reaper.SetEditCurPos(
            sequence_start,
            false,
            false
        )

        reaper.SetOnlyTrackSelected(
            track
        )

        --------------------------------------------------------
        -- DELETE THE DUPLICATES BEFORE IMPORT.
        --
        -- This is the critical safety change:
        -- there is no DeleteTrackMediaItem() after the video has
        -- been imported.
        --------------------------------------------------------

        reaper.Undo_BeginBlock()

        for i = #items, 1, -1 do
            reaper.DeleteTrackMediaItem(
                track,
                items[i].item
            )
        end

        reaper.Undo_EndBlock(
            "ADFX Remove Duplicated Video Items",
            -1
        )

        --------------------------------------------------------
        -- Native import. The helper automatically enters the MP4
        -- path and presses Open.
        --------------------------------------------------------

        reaper.Main_OnCommand(
            40018,
            0
        )

        os.remove(helper)

        finished = true

        msg(
            "VIDEO CONSOLIDATION COMPLETE\n\n" ..
            "Output:\n" ..
            output ..
            "\n\n" ..
            "The consolidated MP4 was imported automatically.\n" ..
            "The duplicated source video items were removed from " ..
            "the timeline.\n\n" ..
            "No post-import video-item manipulation was performed.",
            0
        )

        return
    end

    if reaper.time_precise() -
       start_time > timeout then

        finished = true
        os.remove(worker)

        msg(
            "FFmpeg did not finish within 15 minutes.\n\n" ..
            "The original items were not changed.\n\n" ..
            "FFmpeg log:\n" ..
            log_file
        )

        return
    end

    reaper.defer(monitor)
end

reaper.defer(monitor)
