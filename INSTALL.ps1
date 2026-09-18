$ErrorActionPreference = "Stop"
$GameMods = "C:\Program Files (x86)\Steam\steamapps\common\Car Dealer Simulator\CarDealerSimulator\Binaries\Win64\ue4ss\Mods"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Source = Join-Path $Here "JJsVehicleMover"
$Target = Join-Path $GameMods "JJsVehicleMover"

# v0.16.21: stop only stale JJ's Vehicle Mover Overlay.ps1 hosts before install.
# This prevents an old v0.16.17/v0.16.18 UI process surviving an upgrade.
try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'JJsVehicleMover.*Overlay\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch {}

if (!(Test-Path -LiteralPath $GameMods)) {
    Write-Host "Car Dealer Simulator UE4SS Mods folder was not found at the default Steam location." -ForegroundColor Red
    Write-Host "Install manually by copying the JJsVehicleMover folder into your game's ue4ss\\Mods folder." -ForegroundColor Yellow
    Read-Host "Press Enter to close"
    exit 1
}

if (Test-Path -LiteralPath $Target) {
    # IMPORTANT: never leave a backup mod inside ue4ss\Mods. UE4SS will load any
    # backup folder containing enabled.txt, which can run two movers at once.
    $BackupRoot = Join-Path $env:LOCALAPPDATA "JJsVehicleMover\InstallBackups"
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $Backup = Join-Path $BackupRoot ("JJsVehicleMover_Backup_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
    Copy-Item -LiteralPath $Target -Destination $Backup -Recurse -Force
    Remove-Item -LiteralPath $Target -Recurse -Force
    Write-Host "Previous JJsVehicleMover backed up safely OUTSIDE ue4ss\Mods:" -ForegroundColor Cyan
    Write-Host $Backup -ForegroundColor Cyan
}
Copy-Item -LiteralPath $Source -Destination $Target -Recurse -Force
Write-Host "JJ's Vehicle Mover v0.16.21 installed." -ForegroundColor Green
Write-Host "F9 = Mover ON/OFF | F10 = Compact UI Show/Hide | F6 = Diagnostic snapshot" -ForegroundColor Green
Write-Host "The Mover UI will start with the game; the installer does not launch it." -ForegroundColor Cyan
Read-Host "Press Enter to close"
