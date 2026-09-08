# ADFXSound Sound Design Pad v0.8.42

## Installation

Copy the entire **ADFXSound Sound Design Pad** folder into your REAPER `Scripts` directory, then add/run:

`ADFX_Helper; sound design pad.lua`

Keep the folder structure intact. The main Lua script now resolves its supporting files from the bundled subfolders automatically.

## Folder structure

```text
ADFXSound Sound Design Pad/
├─ ADFX_Helper; sound design pad.lua
├─ README.md
├─ Assets/
│  └─ ADFX_LOGO_BG_BANNER_CLEAR.png
└─ Bridge/
   ├─ Start Wacom Bridge.bat
   └─ SDPP_WacomBridge.ps1
```

## v0.8.42

- Reorganized the tool into one self-contained **ADFXSound Sound Design Pad** folder.
- Moved the ADFX SOUND logo into `Assets/`.
- Moved the Windows Wacom bridge launcher and PowerShell bridge into `Bridge/`.
- Updated the Lua paths so **START BRIDGE** and the logo work from the new subfolders.
- Runtime Wacom bridge state files remain in `%TEMP%`, as before.
- Presets remain in REAPER's existing `Data/Sound Design Paint Pad Presets` location so existing presets continue to work.
- No functional routing, modulation, tablet-response, preset format, or UI-control changes from v0.8.36.


## v0.8.42
- Fixed Start Bridge path resolution after folder reorganization.
- Uses REAPER runtime action context so Bridge and Assets resolve correctly in both plain Lua and luac54 bytecode releases.
