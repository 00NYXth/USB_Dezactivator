<#
.SYNOPSIS
    USB Manager - management dispozitive USB
.NOTES
    Necesita PowerShell rulat ca Administrator
#>

#region Init
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Host "`n  [!] Ruleaza PowerShell ca Administrator." -ForegroundColor Red
    Write-Host "      (irm | iex nu se poate auto-eleva)`n" -ForegroundColor DarkGray
    return
}

$script:LogFile   = Join-Path $env:ProgramData "USBManager\usbmanager.log"
$script:StateFile = Join-Path $env:ProgramData "USBManager\state.json"
New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null

# Dispozitive care NU trebuie atinse
$script:ProtectedPatterns = @(
    'Root Hub', 'Host Controller', 'eXtensible', 'Composite Device.*Keyboard',
    'HID Keyboard', 'HID-compliant mouse', 'Hub USB'
)
$script:Whitelist = @()   # ex: @('VID_046D&PID_C52B')
#endregion

#region Helpers
function Write-Log {
    param([string]$Msg, [ValidateSet('INFO','WARN','ERROR','ACTION')][string]$Level='INFO')
    "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') [$Level] $Msg" | Add-Content $script:LogFile -Encoding UTF8
}

function Test-Protected {
    param($Device)
    foreach ($p in $script:ProtectedPatterns) {
        if ($Device.FriendlyName -match $p) { return $true }
    }
    foreach ($w in $script:Whitelist) {
        if ($Device.InstanceId -match [regex]::Escape($w)) { return $true }
    }
    # Nu dezactiva dispozitivul de input activ (tastatura/mouse curente)
    if ($Device.Class -in 'HIDClass','Keyboard','Mouse' -and $Device.Status -eq 'OK') {
        if ($Device.FriendlyName -match 'Keyboard|Mouse|Tastatura') { return $true }
    }
    return $false
}

function Get-USBDevices {
    param([string]$Filter, [switch]$IncludeHidden)

    $classes = @('USB','USBDevice','HIDClass','DiskDrive','WPD','Image','Media','Net','Bluetooth')
    $devs = Get-PnpDevice -PresentOnly:(!$IncludeHidden) -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'USB\*' -or $_.Class -eq 'USB' }

    $result = foreach ($d in $devs) {
        $vidpid = if ($d.InstanceId -match '(VID_[0-9A-F]{4}&PID_[0-9A-F]{4})') { $Matches[1] } else { '-' }
        [PSCustomObject]@{
            Status       = $d.Status
            Class        = $d.Class
            FriendlyName = if ($d.FriendlyName) { $d.FriendlyName } else { $d.Name }
            VidPid       = $vidpid
            InstanceId   = $d.InstanceId
            Protected    = $false
        }
    }

    $result = $result | ForEach-Object { $_.Protected = Test-Protected $_; $_ }

    if ($Filter) {
        $result = $result | Where-Object {
            $_.FriendlyName -like "*$Filter*" -or $_.VidPid -like "*$Filter*" -or $_.Class -like "*$Filter*"
        }
    }
    $result | Sort-Object Class, FriendlyName
}

function Show-Devices {
    param($Devices)
    if (-not $Devices) { Write-Host "  (niciun dispozitiv)" -ForegroundColor DarkGray; return }

    $fmt = "{0,-4} {1,-8} {2,-12} {3,-20} {4}"
    Write-Host ($fmt -f 'IDX','STARE','CLASA','VID/PID','NUME') -ForegroundColor DarkCyan
    Write-Host ("-" * 100) -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Devices.Count; $i++) {
        $d = $Devices[$i]
        $color = switch ($d.Status) {
            'OK'      { 'Green' }
            'Error'   { 'Red' }
            'Unknown' { 'DarkGray' }
            default   { 'Yellow' }
        }
        $name = $d.FriendlyName
        if ($name.Length -gt 45) { $name = $name.Substring(0,42) + '...' }
        $lock = if ($d.Protected) { '[P]' } else { '   ' }
        Write-Host ($fmt -f "$i$lock", $d.Status, $d.Class, $d.VidPid, $name) -ForegroundColor $color
    }
    Write-Host "`n  [P] = protejat (nu se poate dezactiva)" -ForegroundColor DarkGray
}

function Invoke-DeviceAction {
    param($Devices, [ValidateSet('Disable','Enable')][string]$Action)

    $input = Read-Host "  Index (poti da mai multe: 1,3,5 sau 2-6)"
    $indices = @()
    foreach ($part in $input -split ',') {
        $part = $part.Trim()
        if ($part -match '^(\d+)-(\d+)$') { $indices += ($Matches[1]..$Matches[2]) }
        elseif ($part -match '^\d+$')     { $indices += [int]$part }
    }
    $indices = $indices | Sort-Object -Unique | Where-Object { $_ -lt $Devices.Count }
    if (-not $indices) { Write-Host "  Index invalid." -ForegroundColor Red; Start-Sleep 1; return }

    foreach ($i in $indices) {
        $d = $Devices[$i]
        if ($Action -eq 'Disable' -and $d.Protected) {
            Write-Host "  [SKIP] $($d.FriendlyName) - protejat" -ForegroundColor Yellow
            Write-Log "Skip protejat: $($d.FriendlyName)" WARN
            continue
        }
        try {
            if ($Action -eq 'Disable') {
                Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop
            } else {
                Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop
            }
            Write-Host "  [OK] $Action -> $($d.FriendlyName)" -ForegroundColor Green
            Write-Log "$Action : $($d.FriendlyName) | $($d.InstanceId)" ACTION
        } catch {
            Write-Host "  [EROARE] $($d.FriendlyName): $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "Esec $Action pe $($d.InstanceId): $($_.Exception.Message)" ERROR
        }
    }
    Start-Sleep 2
}

function Set-USBStoragePolicy {
    param([ValidateSet('Block','Allow','Status')][string]$Mode)
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR'
    $cur = (Get-ItemProperty $key -Name Start -ErrorAction SilentlyContinue).Start

    switch ($Mode) {
        'Status' {
            $txt = if ($cur -eq 4) { 'BLOCAT' } else { 'PERMIS' }
            $col = if ($cur -eq 4) { 'Red' } else { 'Green' }
            Write-Host "  Stocare USB: $txt (Start=$cur)" -ForegroundColor $col
        }
        'Block' {
            Set-ItemProperty $key -Name Start -Value 4
            Write-Host "  Stocare USB BLOCATA." -ForegroundColor Red
            Write-Log "USBSTOR blocat (Start=4)" ACTION
        }
        'Allow' {
            Set-ItemProperty $key -Name Start -Value 3
            Write-Host "  Stocare USB PERMISA." -ForegroundColor Green
            Write-Log "USBSTOR permis (Start=3)" ACTION
        }
    }
    Start-Sleep 2
}

function Export-State {
    Get-USBDevices | Select-Object Status, FriendlyName, VidPid, InstanceId |
        ConvertTo-Json -Depth 3 | Set-Content $script:StateFile -Encoding UTF8
    Write-Host "  Stare salvata: $script:StateFile" -ForegroundColor Green
    Write-Log "Stare exportata" INFO
    Start-Sleep 2
}

function Restore-State {
    if (-not (Test-Path $script:StateFile)) {
        Write-Host "  Nu exista fisier de stare." -ForegroundColor Red; Start-Sleep 2; return
    }
    $saved = Get-Content $script:StateFile -Raw | ConvertFrom-Json
    foreach ($s in $saved) {
        $now = Get-PnpDevice -InstanceId $s.InstanceId -ErrorAction SilentlyContinue
        if (-not $now -or $now.Status -eq $s.Status) { continue }
        try {
            if ($s.Status -eq 'OK') { Enable-PnpDevice  -InstanceId $s.InstanceId -Confirm:$false -EA Stop }
            else                    { Disable-PnpDevice -InstanceId $s.InstanceId -Confirm:$false -EA Stop }
            Write-Host "  [RESTORE] $($s.FriendlyName) -> $($s.Status)" -ForegroundColor Cyan
            Write-Log "Restore: $($s.InstanceId) -> $($s.Status)" ACTION
        } catch {
            Write-Host "  [EROARE] $($s.FriendlyName)" -ForegroundColor Red
        }
    }
    Start-Sleep 2
}

function Enable-AllUSB {
    Write-Host "  Reactivez toate dispozitivele USB dezactivate..." -ForegroundColor Yellow
    $off = Get-PnpDevice -Class USB -Status Error, Unknown -EA SilentlyContinue
    $off += Get-PnpDevice | Where-Object { $_.InstanceId -like 'USB\*' -and $_.Status -ne 'OK' }
    foreach ($d in ($off | Sort-Object InstanceId -Unique)) {
        try {
            Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -EA Stop
            Write-Host "  [OK] $($d.FriendlyName)" -ForegroundColor Green
        } catch {}
    }
    Write-Log "Reactivare globala executata" ACTION
    Start-Sleep 2
}
#endregion

#region UI
$script:Filter = ''
$script:ShowHidden = $false

do {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║                   USB MANAGER  v2.0                          ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "  $env:COMPUTERNAME | $env:USERNAME | $(Get-Date -f 'dd.MM.yyyy HH:mm')" -ForegroundColor DarkGray
    if ($script:Filter) { Write-Host "  Filtru activ: '$script:Filter'" -ForegroundColor Yellow }
    Write-Host ""

    $devs = @(Get-USBDevices -Filter $script:Filter -IncludeHidden:$script:ShowHidden)
    Show-Devices $devs

    Write-Host ""
    Write-Host "  D" -ForegroundColor White -NoNewline; Write-Host " Dezactiveaza    " -NoNewline
    Write-Host "E" -ForegroundColor White -NoNewline; Write-Host " Activeaza    " -NoNewline
    Write-Host "A" -ForegroundColor White -NoNewline; Write-Host " Activeaza tot    " -NoNewline
    Write-Host "F" -ForegroundColor White -NoNewline; Write-Host " Filtru"
    Write-Host "  S" -ForegroundColor White -NoNewline; Write-Host " Politica stocare " -NoNewline
    Write-Host "X" -ForegroundColor White -NoNewline; Write-Host " Export stare " -NoNewline
    Write-Host "I" -ForegroundColor White -NoNewline; Write-Host " Import stare " -NoNewline
    Write-Host "H" -ForegroundColor White -NoNewline; Write-Host " Ascunse"
    Write-Host "  L" -ForegroundColor White -NoNewline; Write-Host " Log             " -NoNewline
    Write-Host "R" -ForegroundColor White -NoNewline; Write-Host " Refresh      " -NoNewline
    Write-Host "Q" -ForegroundColor White -NoNewline; Write-Host " Iesire"
    Write-Host ""

    $k = (Read-Host "  Optiune").ToUpper()

    switch ($k) {
        'D' { Invoke-DeviceAction $devs 'Disable' }
        'E' { Invoke-DeviceAction $devs 'Enable' }
        'A' { Enable-AllUSB }
        'F' { $script:Filter = Read-Host "  Text filtru (gol = reset)" }
        'H' { $script:ShowHidden = -not $script:ShowHidden }
        'X' { Export-State }
        'I' { Restore-State }
        'L' {
            Clear-Host
            Write-Host "`n  === ULTIMELE 40 INTRARI ===`n" -ForegroundColor Cyan
            if (Test-Path $script:LogFile) { Get-Content $script:LogFile -Tail 40 }
            else { Write-Host "  (log gol)" -ForegroundColor DarkGray }
            Write-Host ""
            Read-Host "  Enter pentru continuare"
        }
        'S' {
            Clear-Host
            Write-Host "`n  === POLITICA STOCARE USB ===`n" -ForegroundColor Cyan
            Set-USBStoragePolicy -Mode Status
            Write-Host "`n  1 = Blocheaza   2 = Permite   0 = Inapoi"
            switch (Read-Host "  Optiune") {
                '1' { Set-USBStoragePolicy -Mode Block }
                '2' { Set-USBStoragePolicy -Mode Allow }
            }
        }
    }
} while ($k -ne 'Q')

Write-Host "`n  La revedere.`n" -ForegroundColor Cyan
#endregion
