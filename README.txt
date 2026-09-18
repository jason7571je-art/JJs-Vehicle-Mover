JJ's Vehicle Mover v0.16.21
=============================

For Car Dealer Simulator using UE4SS.

CONTROLS
F9  - Vehicle Mover ON/OFF
F10 - Compact UI Show/Hide
F6  - Diagnostic snapshot

WHAT IT DOES
- Persistent transporter unloading into available Automation bays.
- Waits safely when no Automation bay is available and resumes when space becomes free.
- Supports the integrated Side Parking -> Underground Garage workflow.
- Compact UI shows mover state, Automation occupancy, Underground status, transporter count and session progress.
- Uses targeted/cached discovery; no executable FindAllOf.

IMPORTANT IN-GAME SETUP
For each car that enters an Automation bay:
Scan Car -> Select Work -> Destination: Side Parking -> Start In-Game Automation.

INSTALLATION
1. Install and configure UE4SS for Car Dealer Simulator.
2. Close the game.
3. Run INSTALL.ps1, or manually copy the JJsVehicleMover folder into:
   Car Dealer Simulator\CarDealerSimulator\Binaries\Win64\ue4ss\Mods\
4. Start the game and load your save.
5. Use F9 to enable/disable the mover and F10 to show/hide the compact UI.

The included installer targets the default Steam installation path. If your game is installed elsewhere, use the manual installation method.

UNINSTALLATION
Close the game, then run UNINSTALL.ps1. If your game is installed in a non-default location, delete the JJsVehicleMover folder manually from ue4ss\Mods.

DIAGNOSTICS
Runtime state and diagnostics are written under:
%LOCALAPPDATA%\JJsVehicleMover

SAFETY / DESIGN
- Native in-game movement sequences are retained.
- No save-file editing.
- No executable FindAllOf.
- Underground readiness scanning is throttled and skipped during active Underground/Side transfers.

RELEASE STATUS
==============
v0.16.21 is the completed runtime-tested public release.

FINAL RUNTIME VERIFICATION
- Transporter -> Automation passed.
- Underground -> Automation filled the remaining bays to 9/9 with correct sequencing and no sideways/stranded retrieval.
- Side Parking -> Underground passed, including the player-exit grace protection.
- Full-capacity wait/resume passed: a returning Transporter received priority when space became available, then Underground feeding resumed automatically.
- F9 persistence, F10 single-instance UI/focus behavior, installer lifecycle, and automatic UI shutdown with the game passed.

RELEASE-SAFETY CHANGES
- Side Parking uses a 5-second driver-exit grace period and re-confirms the same car before Underground intake.
- Underground retrieval requires the native garage to be idle before another retrieval starts, with a 5-second secondary cooldown.
- Compact UI is single-instance and exits automatically after the game closes.
- Installer does not launch the UI and stores backups outside ue4ss\Mods.
- Existing proven Automation destination orientation is preserved.
- ZERO executable FindAllOf.
