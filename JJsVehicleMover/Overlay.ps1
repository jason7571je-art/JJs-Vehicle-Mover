$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase

# v0.16.21: one overlay process only. A stale overlay from a previous game/session
# must never survive and become a second F10 window.
$createdNew=$false
$script:instanceMutex=New-Object System.Threading.Mutex($true,'Local\JJsVehicleMover_Overlay_SingleInstance',[ref]$createdNew)
if(-not $createdNew){ exit 0 }

$Root = Join-Path $env:LOCALAPPDATA "JJsVehicleMover"
$StatePath = Join-Path $Root 'vehicle_mover_ui_state.json'
$CommandPath = Join-Path $Root 'vehicle_mover_ui_command.txt'
New-Item -ItemType Directory -Force -Path $Root | Out-Null

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="JJ's Vehicle Mover" Width="390" Height="675"
 WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" Background="Transparent" Topmost="True" ShowInTaskbar="True">
 <Border CornerRadius="14" BorderBrush="#465464" BorderThickness="1" Padding="12">
  <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#F3141B23" Offset="0"/><GradientStop Color="#F30D1218" Offset="1"/></LinearGradientBrush></Border.Background>
  <Grid>
   <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
   <Grid Grid.Row="0" Margin="0,0,0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <StackPanel><TextBlock Text="JJ's Vehicle Mover" Foreground="White" FontWeight="Bold" FontSize="22"/><TextBlock Text="Repair &amp; Photo  |  v0.16.21" Foreground="#8997A6" FontSize="11" Margin="0,2,0,0"/></StackPanel>
    <Border Grid.Column="1" x:Name="StatusPill" Background="#54232A" CornerRadius="14" Padding="12,6" VerticalAlignment="Center"><TextBlock x:Name="StatusText" Text="OFF" Foreground="#FF7B86" FontWeight="Bold" FontSize="12"/></Border>
   </Grid>
   <Border Grid.Row="1" Background="#19232E" BorderBrush="#263545" BorderThickness="1" CornerRadius="9" Padding="12" Margin="0,0,0,10"><StackPanel><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="AUTOMATION" Foreground="#B8C4D0" FontWeight="Bold" FontSize="11"/><TextBlock Grid.Column="1" Text="LIVE CAPACITY" Foreground="#718092" FontSize="9" FontWeight="Bold"/></Grid><Grid Margin="0,8,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><ProgressBar x:Name="AutoBar" Height="12" Minimum="0" Maximum="9" Value="0" VerticalAlignment="Center"/><TextBlock Grid.Column="1" x:Name="AutoCount" Text="0 / 9" Foreground="White" FontWeight="Bold" Margin="12,0,0,0"/></Grid></StackPanel></Border>
   <Border Grid.Row="2" Background="#151E27" BorderBrush="#314153" BorderThickness="1" CornerRadius="9" Padding="12" Margin="0,0,0,10"><StackPanel><TextBlock Text="UNDERGROUND GARAGE" Foreground="#B8C4D0" FontWeight="Bold" FontSize="11"/><Grid Margin="0,8,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="STORED" Foreground="#748396" FontSize="9" FontWeight="Bold"/><TextBlock x:Name="UGStoredText" Text="0" Foreground="White" FontSize="18" FontWeight="Bold"/></StackPanel><StackPanel Grid.Column="1"><TextBlock Text="FINISHED" Foreground="#748396" FontSize="9" FontWeight="Bold"/><TextBlock x:Name="UGFinishedText" Text="0" Foreground="#79E39A" FontSize="18" FontWeight="Bold"/></StackPanel><StackPanel Grid.Column="2"><TextBlock Text="NEEDS WORK" Foreground="#748396" FontSize="9" FontWeight="Bold"/><TextBlock x:Name="UGNeedsText" Text="0" Foreground="#F0C76A" FontSize="18" FontWeight="Bold"/></StackPanel></Grid></StackPanel></Border>
   <Border Grid.Row="3" Background="#1B2632" BorderBrush="#3B5268" BorderThickness="1" CornerRadius="9" Padding="12" Margin="0,0,0,10"><StackPanel><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Border Width="4" Background="#5C7D9C" CornerRadius="2" Margin="0,0,9,0"/><StackPanel Grid.Column="1"><TextBlock Text="CURRENT ACTIVITY" Foreground="#AEB8C4" FontWeight="Bold" FontSize="10"/><TextBlock x:Name="CurrentText" Text="Waiting for Vehicle Mover..." Foreground="White" FontSize="14" FontWeight="SemiBold" Margin="0,4,0,0" TextWrapping="Wrap"/></StackPanel></Grid></StackPanel></Border>
   <Grid Grid.Row="4" Margin="0,0,0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Border Background="#18212B" CornerRadius="9" Padding="12"><StackPanel><TextBlock Text="TRANSPORTER" Foreground="#AEB8C4" FontWeight="Bold" FontSize="10"/><TextBlock x:Name="TransporterText" Text="0 cars" Foreground="White" FontSize="17" FontWeight="Bold" Margin="0,4,0,0"/></StackPanel></Border><Border Grid.Column="2" Background="#18212B" CornerRadius="9" Padding="12"><StackPanel><TextBlock Text="COMPLETED" Foreground="#AEB8C4" FontWeight="Bold" FontSize="10"/><TextBlock x:Name="CompletedText" Text="0" Foreground="#79E39A" FontSize="17" FontWeight="Bold" Margin="0,4,0,0"/></StackPanel></Border></Grid>
   <Border Grid.Row="5" Background="#151D26" CornerRadius="9" Padding="12" Margin="0,0,0,10"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="SESSION -&gt; AUTOMATION" Foreground="#AEB8C4" FontWeight="Bold" FontSize="10"/><TextBlock x:Name="MovedText" Text="0" Foreground="White" FontSize="17" FontWeight="Bold" Margin="0,4,0,0"/></StackPanel><StackPanel Grid.Column="1"><TextBlock Text="SIDE -&gt; UNDERGROUND" Foreground="#AEB8C4" FontWeight="Bold" FontSize="10"/><TextBlock x:Name="SideText" Text="0" Foreground="White" FontSize="17" FontWeight="Bold" Margin="0,4,0,0"/></StackPanel></Grid></Border>
   <Border Grid.Row="6" Background="#2A2418" BorderBrush="#7A6429" BorderThickness="1" CornerRadius="9" Padding="11" Margin="0,0,0,9"><StackPanel><TextBlock Text="IN-GAME AUTOMATION SETUP REQUIRED" Foreground="#F0D77A" FontWeight="Bold" FontSize="11"/><TextBlock Text="For each car that enters an Automation bay:" Foreground="#D8DEE6" FontSize="11" Margin="0,4,0,0"/><TextBlock Text="Scan Car -> Select Work -> Destination: Side Parking -> Start In-Game Automation" Foreground="White" FontSize="11" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,2,0,0"/></StackPanel></Border>
   <TextBlock Grid.Row="7" x:Name="CacheText" Text="Game cache: waiting" Foreground="#7F8D9D" FontSize="10" Margin="2,0,0,9"/>
   <Button Grid.Row="8" x:Name="ToggleButton" Content="TURN MOVER ON" IsEnabled="True" Height="46" FontWeight="Bold" FontSize="14" Background="#1F7A46" Foreground="White" BorderThickness="0" Cursor="Hand"/>
   <TextBlock Grid.Row="9" Text="F9  |  Mover ON/OFF        F10  |  Show/Hide" Foreground="#718092" HorizontalAlignment="Center" FontSize="10" Margin="0,9,0,1"/>
  </Grid>
 </Border>
</Window>
'@
$reader = New-Object System.Xml.XmlNodeReader $xaml
$w = [Windows.Markup.XamlReader]::Load($reader)
$names='StatusPill','StatusText','AutoBar','AutoCount','UGStoredText','UGFinishedText','UGNeedsText','CurrentText','TransporterText','CompletedText','MovedText','SideText','CacheText','ToggleButton'
foreach($n in $names){ Set-Variable -Name $n -Value $w.FindName($n) -Scope Script }
$w.Add_MouseLeftButtonDown({ if($_.ButtonState -eq 'Pressed'){ $w.DragMove() } })

$script:lastEnabled=$false
$ToggleButton.Add_Click({ Set-Content -LiteralPath $CommandPath -Value 'TOGGLE' -Encoding ASCII })

function Refresh-State {
 if(!(Test-Path -LiteralPath $StatePath)){ $CurrentText.Text='Waiting for Vehicle Mover...'; return }
 try { $s=Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json } catch { return }
 $script:lastEnabled=[bool]$s.enabled
 $StatusText.Text=if($s.enabled){'ON'}else{'OFF'}
 $StatusPill.Background=if($s.enabled){[Windows.Media.BrushConverter]::new().ConvertFromString('#174E31')}else{[Windows.Media.BrushConverter]::new().ConvertFromString('#54232A')}
 $StatusText.Foreground=if($s.enabled){[Windows.Media.BrushConverter]::new().ConvertFromString('#79E39A')}else{[Windows.Media.BrushConverter]::new().ConvertFromString('#FF7B86')}
 $AutoBar.Value=[double]$s.automationUsed; $AutoCount.Text="$($s.automationUsed) / 9"
 $CurrentText.Text=[string]$s.status
 $TransporterText.Text="$($s.transporterCars) cars"
 $UGStoredText.Text=[string]$s.undergroundStored
 $UGFinishedText.Text=[string]$s.undergroundFinished
 $UGNeedsText.Text=[string]$s.undergroundNeedsWork
 $CompletedText.Text=[string]$s.completedThisSession
 $MovedText.Text=[string]$s.sentToAutomation
 $SideText.Text=[string]$s.sideStoredThisSession
 $CacheText.Text="Game cache: " + $(if($s.cacheReady){'ready'}else{'waiting'}) + "   -   Updated $($s.updated)"
 $ToggleButton.Content=if($s.enabled){'TURN MOVER OFF'}else{'TURN MOVER ON'}
 $ToggleButton.Background=if($s.enabled){[Windows.Media.BrushConverter]::new().ConvertFromString('#A9363F')}else{[Windows.Media.BrushConverter]::new().ConvertFromString('#1F7A46')}
}

$script:uiHidden=$false
$script:hotkeyRegistered=$false
$script:f10WasDown=$false
$script:hwnd=[IntPtr]::Zero
$script:source=$null
$script:allowRealClose=$false
$script:gameWasSeen=$false
$HOTKEY_UI=91617
$VK_F10=0x79

# Same proven Windows hotkey architecture used by Car Dealer Companion:
# RegisterHotKey on the real WPF HWND, WM_HOTKEY HwndSource hook, Hide/Show,
# and a persistent WPF Dispatcher. GetAsyncKeyState is only a fallback if
# Windows refuses the native registration.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class JJVMHotKey {
 [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd,int id,uint mods,uint vk);
 [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd,int id);
 [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

function Show-MoverOverlay {
 $w.Show()
 if($w.WindowState -eq [Windows.WindowState]::Minimized){$w.WindowState=[Windows.WindowState]::Normal}
 $w.Topmost=$true
 [void]$w.Activate()
 $script:uiHidden=$false
}
function Hide-MoverOverlay {
 $script:uiHidden=$true
 [void]$w.Hide()
 # Give keyboard/mouse focus straight back to Car Dealer Simulator after F10 hides
 # the overlay, avoiding the extra click previously needed to resume driving.
 try {
  $game=Get-Process -Name 'CarDealerSimulator-Win64-Shipping' -ErrorAction SilentlyContinue | Select-Object -First 1
  if($null -ne $game -and $game.MainWindowHandle -ne [IntPtr]::Zero){
   [void][JJVMHotKey]::SetForegroundWindow($game.MainWindowHandle)
  }
 } catch {}
}
function Toggle-MoverOverlay {
 if($script:uiHidden -or -not $w.IsVisible){Show-MoverOverlay}else{Hide-MoverOverlay}
}

$w.Add_SourceInitialized({
 try{
  $helper=New-Object System.Windows.Interop.WindowInteropHelper($w)
  $script:hwnd=$helper.Handle
  $script:hotkeyRegistered=[bool][JJVMHotKey]::RegisterHotKey($script:hwnd,$HOTKEY_UI,0,$VK_F10)
  $script:source=[System.Windows.Interop.HwndSource]::FromHwnd($script:hwnd)
  [void]$script:source.AddHook({
   param($a,$m,$wp,$lp,[ref]$handled)
   if($m -eq 0x0312 -and $wp.ToInt32() -eq $HOTKEY_UI){
    Toggle-MoverOverlay
    $handled.Value=$true
   }
   return [IntPtr]::Zero
  })
 }catch{}
})

# Companion-style fallback only when RegisterHotKey fails.
$f10FallbackTimer=New-Object System.Windows.Threading.DispatcherTimer
$f10FallbackTimer.Interval=[TimeSpan]::FromMilliseconds(120)
$f10FallbackTimer.Add_Tick({
 try{
  if(-not $script:hotkeyRegistered){
   $down=(([JJVMHotKey]::GetAsyncKeyState($VK_F10) -band 0x8000) -ne 0)
   if($down -and -not $script:f10WasDown){Toggle-MoverOverlay}
   $script:f10WasDown=$down
  }
 }catch{}
})
$f10FallbackTimer.Start()

$timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({ Refresh-State }); $timer.Start()

# Tie overlay lifetime to the game. Once the game has been observed running,
# closing the game closes this overlay and releases F10 instead of leaving a
# hidden/stale v0.16.x process behind.
$gameWatch=New-Object Windows.Threading.DispatcherTimer
$gameWatch.Interval=[TimeSpan]::FromSeconds(1)
$gameWatch.Add_Tick({
 try {
  $game=Get-Process -Name 'CarDealerSimulator-Win64-Shipping' -ErrorAction SilentlyContinue | Select-Object -First 1
  if($null -ne $game){ $script:gameWasSeen=$true }
  elseif($script:gameWasSeen){
   $script:allowRealClose=$true
   $gameWatch.Stop(); $f10FallbackTimer.Stop(); $timer.Stop()
   $w.Close()
  }
 } catch {}
})
$gameWatch.Start()

$w.Add_Closing({param($s,$e); if(-not $script:allowRealClose){$e.Cancel=$true; Hide-MoverOverlay}})
$w.Add_Closed({
 try{if($script:hwnd -ne [IntPtr]::Zero){[void][JJVMHotKey]::UnregisterHotKey($script:hwnd,$HOTKEY_UI)}}catch{}
 try{if($null -ne $script:instanceMutex){$script:instanceMutex.ReleaseMutex();$script:instanceMutex.Dispose()}}catch{}
})

Refresh-State
[void]$w.Show()
[void]$w.Activate()
[void][System.Windows.Threading.Dispatcher]::Run()
