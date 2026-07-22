<#
    USB MANAGER
    Rulare:  irm https://raw.githubusercontent.com/00NYXth/USB_Dezactivator/main/usbtool.ps1 | iex
    Necesita PowerShell pornit ca Administrator.
#>

#region ---------- Initializare ----------
$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$script:Admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $script:Admin) {
    Write-Host ""
    Write-Host "   Trebuie sa pornesti PowerShell ca Administrator." -ForegroundColor Red
    Write-Host "   Click dreapta pe Start -> Terminal (Administrator)" -ForegroundColor DarkGray
    Write-Host ""
    return
}

$script:Root      = Join-Path $env:ProgramData 'USBManager'
$script:LogFile   = Join-Path $script:Root 'jurnal.log'
$script:StateFile = Join-Path $script:Root 'stare.json'
$script:NamesFile = Join-Path $script:Root 'denumiri.json'
$script:BackupDir = Join-Path $script:Root 'copii'
$script:PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null

$script:Protejate = @('Root Hub','Host Controller','eXtensible','HID Keyboard','HID-compliant mouse')
$script:Filtru    = ''
$script:Ascunse   = $false
#endregion

#region ---------- Aspect ----------
$C = @{
    Titlu  = 'Cyan';     Ok    = 'Green';   Rau  = 'Red'
    Atent  = 'Yellow';   Sters = 'DarkGray'; Alb = 'White'
    Accent = 'Magenta';  Info  = 'DarkCyan'
}

function Linie { param([int]$n=64,[string]$ch='─',[string]$col='DarkGray')
    Write-Host ("   " + ($ch * $n)) -ForegroundColor $col }

function Cadru {
    param([string]$Text,[string]$Sub='')
    $w = 64
    Write-Host ""
    Write-Host ("   ┌" + ("─"*$w) + "┐") -ForegroundColor $C.Titlu
    Write-Host ("   │" + (" "*$w) + "│") -ForegroundColor $C.Titlu
    $pad = [math]::Floor(($w - $Text.Length)/2)
    Write-Host "   │" -ForegroundColor $C.Titlu -NoNewline
    Write-Host ((" "*$pad) + $Text + (" "*($w-$pad-$Text.Length))) -ForegroundColor $C.Alb -NoNewline
    Write-Host "│" -ForegroundColor $C.Titlu
    if ($Sub) {
        $p2 = [math]::Floor(($w - $Sub.Length)/2)
        Write-Host "   │" -ForegroundColor $C.Titlu -NoNewline
        Write-Host ((" "*$p2) + $Sub + (" "*($w-$p2-$Sub.Length))) -ForegroundColor $C.Sters -NoNewline
        Write-Host "│" -ForegroundColor $C.Titlu
    }
    Write-Host ("   │" + (" "*$w) + "│") -ForegroundColor $C.Titlu
    Write-Host ("   └" + ("─"*$w) + "┘") -ForegroundColor $C.Titlu
}

function Sectiune { param([string]$T)
    Write-Host ""
    Write-Host "   ▌ " -ForegroundColor $C.Accent -NoNewline
    Write-Host $T -ForegroundColor $C.Alb
    Linie
}

function Tasta { param([string]$K,[string]$Desc,[int]$W=18)
    Write-Host "   " -NoNewline
    Write-Host " $K " -ForegroundColor Black -BackgroundColor Gray -NoNewline
    Write-Host (" " + $Desc.PadRight($W)) -ForegroundColor $C.Sters -NoNewline
}

function Mesaj {
    param([string]$T,[ValidateSet('ok','rau','atent','info')][string]$Tip='info')
    $s = @{ ok='  ✔ '; rau='  ✘ '; atent='  ▲ '; info='  › ' }[$Tip]
    $c = @{ ok=$C.Ok; rau=$C.Rau; atent=$C.Atent; info=$C.Info }[$Tip]
    Write-Host ""
    Write-Host ("  " + $s + $T) -ForegroundColor $c
}

function Pauza { param([int]$s=2) Start-Sleep -Seconds $s }
function Enter { Write-Host ""; Read-Host "   Apasa Enter" | Out-Null }
#endregion

#region ---------- Jurnal ----------
function Write-Log {
    param([string]$Msg,[ValidateSet('INFO','WARN','ERROR','ACTION')][string]$Level='INFO')
    try { "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') [$Level] $Msg" | Add-Content $script:LogFile -Encoding UTF8 } catch {}
}
#endregion

#region ---------- Dispozitive ----------
function Test-Protejat {
    param($D)
    foreach ($p in $script:Protejate) { if ($D.Nume -match $p) { return $true } }
    if ($D.Clasa -eq 'HIDClass' -and $D.Nume -match 'Keyboard|Mouse|Tastatura') { return $true }
    return $false
}

function Get-USBDevices {
    param([string]$Filtru,[switch]$Ascunse)
    $devs = Get-PnpDevice -PresentOnly:(!$Ascunse) -EA SilentlyContinue |
            Where-Object { $_.InstanceId -like 'USB\*' -or $_.Class -eq 'USB' }

    $r = foreach ($d in $devs) {
        $vp = if ($d.InstanceId -match '(VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4})') { $Matches[1].ToUpper() } else { '-' }
        $o = [PSCustomObject]@{
            Stare      = $d.Status
            Clasa      = $d.Class
            Nume       = if ($d.FriendlyName) { $d.FriendlyName } else { $d.Name }
            Cod        = $vp
            InstanceId = $d.InstanceId
            Protejat   = $false
        }
        $o.Protejat = Test-Protejat $o
        $o
    }
    if ($Filtru) {
        $r = $r | Where-Object { $_.Nume -like "*$Filtru*" -or $_.Cod -like "*$Filtru*" -or $_.Clasa -like "*$Filtru*" }
    }
    $r | Sort-Object Clasa, Nume
}

function Show-Devices {
    param($D)
    if (-not $D -or $D.Count -eq 0) { Write-Host "     (nimic de afisat)" -ForegroundColor $C.Sters; return }

    Write-Host ""
    Write-Host ("   {0,-6} {1,-9} {2,-12} {3,-22} {4}" -f '#','STARE','TIP','COD','DENUMIRE') -ForegroundColor $C.Info
    Linie

    $cls = ''
    for ($i=0; $i -lt $D.Count; $i++) {
        $x = $D[$i]
        if ($x.Clasa -ne $cls) { $cls = $x.Clasa; Write-Host "" }

        $col = switch ($x.Stare) { 'OK' {$C.Ok} 'Error' {$C.Rau} 'Unknown' {$C.Sters} default {$C.Atent} }
        $st  = switch ($x.Stare) { 'OK' {'MERGE '} 'Error' {'OPRIT '} 'Unknown' {'ABSENT'} default {$x.Stare} }
        $mark = if ($x.Protejat) { '*' } else { ' ' }
        $n = $x.Nume; if ($n.Length -gt 40) { $n = $n.Substring(0,37) + '...' }

        Write-Host "   " -NoNewline
        Write-Host ("{0,-3}{1}" -f $i, $mark) -ForegroundColor $C.Alb -NoNewline
        Write-Host ("  {0,-9}" -f $st) -ForegroundColor $col -NoNewline
        Write-Host ("{0,-12}" -f $x.Clasa) -ForegroundColor $C.Sters -NoNewline
        Write-Host ("{0,-22}" -f $x.Cod) -ForegroundColor $C.Info -NoNewline
        Write-Host $n -ForegroundColor $col
    }
    Write-Host ""
    Write-Host "   * = protejat, nu poate fi oprit" -ForegroundColor $C.Sters
}

function Citeste-Indici {
    param($D)
    $inp = Read-Host "   Numarul (ex: 3   sau  1,4,7   sau  2-6)"
    $idx = @()
    foreach ($p in ($inp -split ',')) {
        $p = $p.Trim()
        if ($p -match '^(\d+)-(\d+)$') { $idx += ([int]$Matches[1]..[int]$Matches[2]) }
        elseif ($p -match '^\d+$')     { $idx += [int]$p }
    }
    $idx | Sort-Object -Unique | Where-Object { $_ -ge 0 -and $_ -lt $D.Count }
}

function Actioneaza {
    param($D,[ValidateSet('Opreste','Porneste')][string]$Ce)
    $idx = @(Citeste-Indici $D)
    if (-not $idx) { Mesaj "Numar invalid." rau; Pauza 1; return }

    foreach ($i in $idx) {
        $x = $D[$i]
        if ($Ce -eq 'Opreste' -and $x.Protejat) {
            Mesaj "Sarit: $($x.Nume) - protejat" atent
            Write-Log "Sarit protejat: $($x.Nume)" WARN
            continue
        }
        try {
            if ($Ce -eq 'Opreste') { Disable-PnpDevice -InstanceId $x.InstanceId -Confirm:$false -EA Stop }
            else                   { Enable-PnpDevice  -InstanceId $x.InstanceId -Confirm:$false -EA Stop }
            Mesaj "$Ce -> $($x.Nume)" ok
            Write-Log "$Ce : $($x.Nume) | $($x.InstanceId)" ACTION
        } catch {
            Mesaj "$($x.Nume): $($_.Exception.Message)" rau
            Write-Log "Esec $Ce pe $($x.InstanceId): $($_.Exception.Message)" ERROR
        }
    }
    Pauza 2
}

function Porneste-Tot {
    Mesaj "Repornesc tot ce e oprit..." info
    $off = Get-PnpDevice -EA SilentlyContinue |
           Where-Object { $_.InstanceId -like 'USB\*' -and $_.Status -ne 'OK' }
    $n = 0
    foreach ($d in ($off | Sort-Object InstanceId -Unique)) {
        try { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -EA Stop
              Write-Host "     ✔ $($d.FriendlyName)" -ForegroundColor $C.Ok; $n++ } catch {}
    }
    Mesaj "$n dispozitive repornite." ok
    Write-Log "Repornire globala: $n" ACTION
    Pauza 2
}
#endregion

#region ---------- Stare salvata ----------
function Export-Stare {
    Get-USBDevices | Select-Object Stare,Nume,Cod,InstanceId |
        ConvertTo-Json -Depth 3 | Set-Content $script:StateFile -Encoding UTF8
    Mesaj "Salvat in $script:StateFile" ok
    Write-Log "Stare exportata" INFO; Pauza 2
}

function Import-Stare {
    if (-not (Test-Path $script:StateFile)) { Mesaj "Nu exista nicio stare salvata." rau; Pauza 2; return }
    $s = Get-Content $script:StateFile -Raw | ConvertFrom-Json
    foreach ($x in $s) {
        $now = Get-PnpDevice -InstanceId $x.InstanceId -EA SilentlyContinue
        if (-not $now -or $now.Status -eq $x.Stare) { continue }
        try {
            if ($x.Stare -eq 'OK') { Enable-PnpDevice  -InstanceId $x.InstanceId -Confirm:$false -EA Stop }
            else                   { Disable-PnpDevice -InstanceId $x.InstanceId -Confirm:$false -EA Stop }
            Write-Host "     ↺ $($x.Nume)" -ForegroundColor $C.Info
            Write-Log "Restaurat: $($x.InstanceId) -> $($x.Stare)" ACTION
        } catch {}
    }
    Mesaj "Stare restaurata." ok; Pauza 2
}
#endregion

#region ---------- Stick-uri ----------
function Set-USBStoragePolicy {
    param([ValidateSet('Block','Allow','Status')][string]$Mode)
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR'
    $cur = (Get-ItemProperty $k -Name Start -EA SilentlyContinue).Start
    switch ($Mode) {
        'Status' {
            $t = if ($cur -eq 4) { 'INTERZISE' } else { 'PERMISE' }
            $c = if ($cur -eq 4) { $C.Rau } else { $C.Ok }
            Write-Host $t -ForegroundColor $c
        }
        'Block' { Set-ItemProperty $k -Name Start -Value 4; Mesaj "Stick-urile sunt interzise." ok
                  Write-Log "USBSTOR blocat" ACTION; Pauza 2 }
        'Allow' { Set-ItemProperty $k -Name Start -Value 3; Mesaj "Stick-urile sunt permise." ok
                  Write-Log "USBSTOR permis" ACTION; Pauza 2 }
    }
}
#endregion

#region ---------- Intrari (hub-uri) ----------
function Get-Denumiri {
    if (Test-Path $script:NamesFile) { try { return (Get-Content $script:NamesFile -Raw | ConvertFrom-Json) } catch {} }
    return [PSCustomObject]@{}
}
function Set-Denumire {
    param($Id,$Nume)
    $d = Get-Denumiri
    $d | Add-Member -NotePropertyName $Id -NotePropertyValue $Nume -Force
    $d | ConvertTo-Json | Set-Content $script:NamesFile -Encoding UTF8
}

function Salveaza-Copie {
    $f = Join-Path $script:BackupDir "reguli_$(Get-Date -f 'yyyyMMdd_HHmmss').reg"
    reg export "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall" $f /y 2>$null | Out-Null
    Write-Log "Copie reguli -> $f" INFO
    return $f
}

function Get-GrupuriIntrari {
    $den = Get-Denumiri
    Get-PnpDevice -Class USB -EA SilentlyContinue |
        Where-Object { $_.FriendlyName -match 'Root Hub|Generic USB Hub|USB Hub' } |
        ForEach-Object {
            $kids = @((Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_Children' -EA SilentlyContinue).Data)
            $cheie = ($_.InstanceId -replace '[^A-Za-z0-9]','_')
            [PSCustomObject]@{
                Stare      = if ($_.Status -eq 'OK') { 'DESCHIS' } else { 'INCHIS' }
                Eticheta   = $den.$cheie
                Tehnic     = $_.FriendlyName
                Ocupate    = $kids.Count
                Cheie      = $cheie
                InstanceId = $_.InstanceId
            }
        } | Sort-Object Tehnic
}

function Meniu-Intrari {
    do {
        Clear-Host
        Cadru "INTRARILE USB" "grup de mufe = un rand"
        Write-Host "   Inchizi un grup -> mufele lui nu mai primesc nimic." -ForegroundColor $C.Sters
        Write-Host "   Poti baga orice, calculatorul nu reactioneaza." -ForegroundColor $C.Sters

        $g = @(Get-GrupuriIntrari)
        Write-Host ""
        Write-Host ("   {0,-5} {1,-10} {2,-36} {3}" -f '#','STARE','DENUMIRE','OCUPATE') -ForegroundColor $C.Info
        Linie
        for ($i=0; $i -lt $g.Count; $i++) {
            $x = $g[$i]
            $col = if ($x.Stare -eq 'DESCHIS') { $C.Ok } else { $C.Rau }
            $nume = if ($x.Eticheta) { $x.Eticheta } else { $x.Tehnic }
            if ($nume.Length -gt 34) { $nume = $nume.Substring(0,31)+'...' }
            Write-Host "   " -NoNewline
            Write-Host ("{0,-5}" -f $i) -ForegroundColor $C.Alb -NoNewline
            Write-Host ("{0,-10}" -f $x.Stare) -ForegroundColor $col -NoNewline
            Write-Host ("{0,-36}" -f $nume) -ForegroundColor $col -NoNewline
            Write-Host $x.Ocupate -ForegroundColor $C.Sters
            if ($x.Eticheta) { Write-Host ("         $($x.Tehnic)") -ForegroundColor $C.Sters }
        }

        Sectiune "Ce faci"
        Tasta 'I' 'Inchide grup'; Tasta 'D' 'Deschide grup'
        Write-Host ""
        Tasta 'N' 'Pune denumire'; Tasta '0' 'Inapoi'
        Write-Host "`n"
        $c = (Read-Host "   Alege").ToUpper()

        if ($c -eq 'N') {
            $n = Read-Host "   Numarul randului"
            if ($n -match '^\d+$' -and [int]$n -lt $g.Count) {
                $nm = Read-Host "   Denumire (ex: mufe fata / mufe spate)"
                if ($nm) { Set-Denumire $g[[int]$n].Cheie $nm }
            }
            continue
        }

        if ($c -in 'I','D') {
            $n = Read-Host "   Numarul randului"
            if (-not ($n -match '^\d+$') -or [int]$n -ge $g.Count) { continue }
            $x = $g[[int]$n]

            if ($c -eq 'I' -and $x.Tehnic -match 'eXtensible|Host Controller') {
                Mesaj "Asta e intrarea principala - ramai fara USB deloc. Nu o ating." rau
                Pauza 3; continue
            }

            $kids = @((Get-PnpDeviceProperty -InstanceId $x.InstanceId -KeyName 'DEVPKEY_Device_Children' -EA SilentlyContinue).Data)
            $risc = $kids | ForEach-Object { Get-PnpDevice -InstanceId $_ -EA SilentlyContinue } |
                    Where-Object { $_.Class -in 'HIDClass','Keyboard','Mouse' }

            if ($c -eq 'I' -and $risc) {
                Mesaj "Pe aceste mufe stau tastatura sau mouse-ul:" atent
                $risc | ForEach-Object { Write-Host "       - $($_.FriendlyName)" -ForegroundColor $C.Atent }
                Write-Host "       Ramai fara ele pana la repornire." -ForegroundColor $C.Atent
                if ((Read-Host "`n   Scrie DA daca esti sigur") -ne 'DA') { continue }
            }

            try {
                if ($c -eq 'I') { Disable-PnpDevice -InstanceId $x.InstanceId -Confirm:$false -EA Stop; $a='INCHIS' }
                else            { Enable-PnpDevice  -InstanceId $x.InstanceId -Confirm:$false -EA Stop; $a='DESCHIS' }
                Mesaj "Grupul este acum: $a" ok
                Write-Log "Grup intrari $a : $($x.InstanceId)" ACTION
            } catch { Mesaj $_.Exception.Message rau }
            Pauza 2
        }
    } while ($c -ne '0')
}
#endregion

#region ---------- Paza ----------
function Get-StarePaza {
    if (-not (Test-Path $script:PolicyKey)) { return 'OPRITA' }
    $p = Get-ItemProperty $script:PolicyKey -EA SilentlyContinue
    if ($p.DenyUnspecified -eq 1)   { return 'PORNITA' }
    if ($p.DenyDeviceClasses -eq 1) { return 'PORNITA partial' }
    return 'OPRITA'
}

function Porneste-Paza {
    Clear-Host
    Cadru "PAZA LA INTRARI"
    Write-Host "   Mufele raman sub curent, dar calculatorul refuza sa" -ForegroundColor $C.Atent
    Write-Host "   porneasca orice aparat nou bagat in ele." -ForegroundColor $C.Atent
    Write-Host ""
    Write-Host "   Aparatele conectate ACUM raman permise." -ForegroundColor $C.Atent

    $lista = Get-USBDevices | Where-Object { $_.Cod -ne '-' } | Sort-Object Cod -Unique
    Sectiune "Raman permise"
    $lista | ForEach-Object {
        Write-Host ("     {0,-24} " -f $_.Cod) -ForegroundColor $C.Info -NoNewline
        Write-Host $_.Nume -ForegroundColor $C.Sters
    }

    Mesaj "Daca tastatura si mouse-ul nu sunt in lista, le pierzi la repornire." atent
    if ((Read-Host "`n   Scrie DA ca sa pornesc paza") -ne 'DA') { return }

    $bk = Salveaza-Copie
    New-Item $script:PolicyKey -Force | Out-Null
    $k = "$script:PolicyKey\AllowDeviceIDs"
    Remove-Item $k -Recurse -Force -EA SilentlyContinue
    New-Item $k -Force | Out-Null
    $i = 1
    foreach ($x in $lista) { Set-ItemProperty $k -Name "$i" -Value "USB\$($x.Cod)"; $i++ }
    Set-ItemProperty $script:PolicyKey -Name 'AllowDeviceIDs'  -Value 1 -Type DWord
    Set-ItemProperty $script:PolicyKey -Name 'DenyUnspecified' -Value 1 -Type DWord
    gpupdate /force 2>&1 | Out-Null

    Mesaj "Paza pornita. Copie de siguranta: $bk" ok
    Write-Log "Paza pornita, $($lista.Count) aparate permise" ACTION
    Pauza 3
}

function Opreste-Paza {
    Salveaza-Copie | Out-Null
    Remove-Item $script:PolicyKey -Recurse -Force -EA SilentlyContinue
    gpupdate /force 2>&1 | Out-Null
    Mesaj "Paza oprita - orice aparat se poate conecta din nou." ok
    Write-Log "Paza oprita" ACTION; Pauza 2
}

function Meniu-Paza {
    do {
        Clear-Host
        Cadru "PAZA SI RESTRICTII"
        $st = Get-StarePaza
        $col = if ($st -eq 'OPRITA') { $C.Ok } else { $C.Rau }
        Write-Host "   Paza la intrari : " -ForegroundColor $C.Sters -NoNewline
        Write-Host $st -ForegroundColor $col
        Write-Host "   Stick-uri / HDD : " -ForegroundColor $C.Sters -NoNewline
        Set-USBStoragePolicy -Mode Status

        Sectiune "Ce faci"
        Tasta '1' 'Porneste paza'; Tasta '2' 'Opreste paza'
        Write-Host ""
        Tasta '3' 'Interzice stick'; Tasta '4' 'Permite stick'
        Write-Host ""
        Tasta '5' 'Adauga aparat'; Tasta '0' 'Inapoi'
        Write-Host "`n"

        switch (Read-Host "   Alege") {
            '1' { Porneste-Paza }
            '2' { Opreste-Paza }
            '3' { Set-USBStoragePolicy -Mode Block }
            '4' { Set-USBStoragePolicy -Mode Allow }
            '5' {
                $v = Read-Host "   Cod aparat (ex: VID_046D&PID_C52B)"
                if ($v) {
                    $k = "$script:PolicyKey\AllowDeviceIDs"
                    New-Item $k -Force | Out-Null
                    $n = ((Get-Item $k).Property | Measure-Object).Count + 1
                    Set-ItemProperty $k -Name "$n" -Value "USB\$v"
                    gpupdate /force 2>&1 | Out-Null
                    Mesaj "Adaugat pe lista." ok
                    Write-Log "Permise += USB\$v" ACTION; Pauza 2
                }
            }
            '0' { return }
        }
    } while ($true)
}
#endregion

#region ---------- Meniu principal ----------
function Bara-Sumar {
    param($D)
    $merge = @($D | Where-Object Stare -eq 'OK').Count
    $oprit = @($D | Where-Object Stare -ne 'OK').Count
    $paza  = Get-StarePaza
    $stor  = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -Name Start -EA SilentlyContinue).Start

    Write-Host "   " -NoNewline
    Write-Host " $merge merg " -ForegroundColor Black -BackgroundColor Green -NoNewline
    Write-Host " " -NoNewline
    if ($oprit -gt 0) { Write-Host " $oprit oprite " -ForegroundColor White -BackgroundColor DarkRed -NoNewline }
    else              { Write-Host " 0 oprite " -ForegroundColor Black -BackgroundColor Gray -NoNewline }
    Write-Host " " -NoNewline
    if ($paza -eq 'OPRITA') { Write-Host " paza off " -ForegroundColor Black -BackgroundColor Gray -NoNewline }
    else                    { Write-Host " PAZA ON " -ForegroundColor White -BackgroundColor DarkMagenta -NoNewline }
    Write-Host " " -NoNewline
    if ($stor -eq 4) { Write-Host " stick blocat " -ForegroundColor White -BackgroundColor DarkRed }
    else             { Write-Host " stick ok " -ForegroundColor Black -BackgroundColor Gray }
}

do {
    Clear-Host
    Cadru "USB MANAGER" "$env:COMPUTERNAME  ·  $env:USERNAME  ·  $(Get-Date -f 'dd.MM.yyyy HH:mm')"

    $devs = @(Get-USBDevices -Filtru $script:Filtru -Ascunse:$script:Ascunse)
    Bara-Sumar $devs

    if ($script:Filtru)  { Write-Host "`n   Filtru: '$script:Filtru'" -ForegroundColor $C.Atent }
    if ($script:Ascunse) { Write-Host "   Arat si aparatele deconectate" -ForegroundColor $C.Atent }

    Sectiune "Aparate USB"
    Show-Devices $devs

    Sectiune "Ce faci"
    Tasta 'O' 'Opreste aparat'; Tasta 'P' 'Porneste aparat'; Tasta 'T' 'Porneste tot'
    Write-Host ""
    Tasta 'I' 'Intrari USB';    Tasta 'K' 'Paza';            Tasta 'F' 'Filtru'
    Write-Host ""
    Tasta 'S' 'Salveaza stare'; Tasta 'R' 'Reface stare';    Tasta 'A' 'Arata ascunse'
    Write-Host ""
    Tasta 'J' 'Jurnal';         Tasta 'X' 'Reimprospateaza'; Tasta 'Q' 'Iesire'
    Write-Host "`n"

    $k = (Read-Host "   Alege").ToUpper()

    switch ($k) {
        'O' { Actioneaza $devs 'Opreste' }
        'P' { Actioneaza $devs 'Porneste' }
        'T' { Porneste-Tot }
        'I' { Meniu-Intrari }
        'K' { Meniu-Paza }
        'F' { $script:Filtru = Read-Host "   Text de cautat (gol = fara filtru)" }
        'A' { $script:Ascunse = -not $script:Ascunse }
        'S' { Export-Stare }
        'R' { Import-Stare }
        'J' {
            Clear-Host
            Cadru "JURNAL" "ultimele 40 de actiuni"
            if (Test-Path $script:LogFile) {
                Get-Content $script:LogFile -Tail 40 | ForEach-Object {
                    $c = if ($_ -match '\[ERROR\]') { $C.Rau }
                         elseif ($_ -match '\[WARN\]') { $C.Atent }
                         elseif ($_ -match '\[ACTION\]') { $C.Ok }
                         else { $C.Sters }
                    Write-Host "   $_" -ForegroundColor $c
                }
            } else { Write-Host "   (jurnal gol)" -ForegroundColor $C.Sters }
            Enter
        }
    }
} while ($k -ne 'Q')

Write-Host ""
Write-Host "   Gata. Jurnalul e in $script:LogFile" -ForegroundColor $C.Sters
Write-Host ""
#endregion
