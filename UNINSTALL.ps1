$ErrorActionPreference = "Stop"
$GameMods = "C:\Program Files (x86)\Steam\steamapps\common\Car Dealer Simulator\CarDealerSimulator\Binaries\Win64\ue4ss\Mods"
$Target = Join-Path $GameMods "JJsVehicleMover"
if (Test-Path -LiteralPath $Target) {
    Remove-Item -LiteralPath $Target -Recurse -Force
    Write-Host "JJ's Vehicle Mover removed." -ForegroundColor Green
} else {
    Write-Host "JJsVehicleMover is not installed at the default Steam location." -ForegroundColor Yellow
}
Read-Host "Press Enter to close"
