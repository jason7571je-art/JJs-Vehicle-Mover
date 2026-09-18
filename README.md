# JJ's Vehicle Mover

**JJ's Vehicle Mover v1.2.0** for **Car Dealer Simulator**  
Created by **JJ's Mods**

JJ's Vehicle Mover is a UE4SS-based vehicle movement and automation helper for Car Dealer Simulator.

## Nexus Mods Security Review

This repository contains the source files corresponding to the **JJ's Vehicle Mover v1.2.0** Nexus Mods release.

The mod does **not** include a compiled executable. The main in-game mod logic is written in **Lua** for UE4SS.

The release also contains PowerShell and VBScript files used for installation, removal, and the optional external overlay UI.

## Included Script Files

- `JJsVehicleMover/Scripts/main.lua` - Main UE4SS Vehicle Mover logic.
- `JJsVehicleMover/Overlay.ps1` - Optional external Vehicle Mover overlay UI.
- `JJsVehicleMover/LaunchOverlay.vbs` - Starts the PowerShell overlay without leaving a PowerShell console window visible over the game.
- `INSTALL.ps1` - Installs the `JJsVehicleMover` folder into the game's UE4SS Mods directory. It can also stop an existing JJ's Vehicle Mover overlay process when necessary during an upgrade.
- `UNINSTALL.ps1` - Removes JJ's Vehicle Mover from the UE4SS Mods directory.
- `JJsVehicleMover/enabled.txt` - Enables the UE4SS mod.

`LaunchOverlay.vbs` invokes the included `Overlay.ps1` script. Its purpose is to launch the optional UI cleanly without leaving a console window open. It is not a compiled program.

## Release Verification

Nexus Mods release version:

**v1.2.0**

SHA-256 of the exact v1.2.0 Nexus release ZIP:

```text
1493D4868A086A57D8EC229646F20B3889E87AF7EE06411F2E35B64F80955E9B
```

This hash identifies the release package associated with the source published in this repository.

## Installation

See `README.txt` and `INSTALL.ps1` for the installation information supplied with the release.

## Project Notes

JJ's Vehicle Mover uses the game's native vehicle and automation systems where practical.

This public repository contains the files relevant to the released mod. Development diagnostics, experimental builds, protected baselines, third-party mods, and unrelated Car Dealer Companion development files are not included.

## Author

**JJ's Mods**
