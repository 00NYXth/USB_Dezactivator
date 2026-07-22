<#
    ============================================================
     USB MANAGER  v3.0
     Gestionare aparate USB, intrari (hub-uri) si mufe fizice.

     Rulare locala:
        powershell -ExecutionPolicy Bypass -File .\usbtool.ps1
     Rulare din retea:
        irm https://raw.githubusercontent.com/00NYXth/USB_Dezactivator/main/usbtool.ps1 | iex

     Necesita PowerShell pornit ca Administrator.
    ============================================================
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
    Write-Host "   Click dreapta pe Start  ->  Terminal (Administrator)" -ForegroundColor DarkGray
    Write-Host ""
    return
}

$script:Root      = Join-Path $env:ProgramData 'USBManager'
$script:LogFile   = Join-Path $script:Root 'jurnal.log'
$script:StateFile = Join-Path $script:Root 'stare.json'
$script:NamesFile = Join-Path $script:Root 'denumiri.json'
$script:PortMap   = Join-Path $script:Root 'mufe.json'
$script:ConfigFile = Join-Path $script:Root 'setari.json'
$script:BackupDir = Join-Path $script:Root 'copii'
$script:PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
$script:StorKey   = 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR'
New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null

# ---- Protectie configurabila ----
# Nivel 2 (TOTAL)  : hub principal + orice tastatura/mouse USB   [implicit]
# Nivel 1 (MINIM)  : doar hub principal si controllerele
# Nivel 0 (OPRITA) : nimic protejat, raspunzi tu de tot

# Tot ce e sub 'Critic' NU se poate scoate niciodata din protectie -
# fara controller nu mai exista USB deloc, iar reactivarea cere reboot.
$script:Critic = @('Host Controller', 'eXtensible', 'Root Hub')

# Protectie suplimentara, activa doar pe nivelul 2
$script:ProtInput = @('HID Keyboard', 'HID-compliant mouse', 'Tastatura', 'Keyboard', 'Mouse')

function Get-Setari {
    if (Test-Path $script:ConfigFile) {
        try { return (Get-Content $script:ConfigFile -Raw | ConvertFrom-Json) } catch {}
    }
    return [PSCustomObject]@{ Nivel = 2; Exceptii = @() }
}

function Set-Setari {
    param($S)
    $S | ConvertTo-Json -Depth 3 | Set-Content $script:ConfigFile -Encoding UTF8
}

# Detecteaza daca masina e laptop. Pe laptop tastatura si touchpad-ul
# sunt de obicei interne (PS/2 sau I2C), nu pe USB - deci nivelul 1 e sigur.
function Test-Laptop {
    try {
        $t = (Get-CimInstance Win32_SystemEnclosure -EA SilentlyContinue).ChassisTypes
        return (@($t) | Where-Object { $_ -in 8,9,10,11,12,14,18,21,30,31,32 }).Count -gt 0
    } catch { return $false }
}

# Tastatura sau mouse-ul chiar stau pe USB? Daca nu, protectia nivel 2 e inutila.
function Test-InputPeUSB {
    $k = @(Get-PnpDevice -PresentOnly -EA SilentlyContinue |
           Where-Object { $_.InstanceId -like 'USB\*' -and
                          $_.Class -in 'HIDClass','Keyboard','Mouse' -and
                          $_.FriendlyName -match 'Keyboard|Mouse|Tastatura' })
    return ($k.Count -gt 0)
}

$script:Setari  = Get-Setari
$script:Filtru  = ''
$script:Ascunse = $false
#endregion


#region ---------- Aspect ----------
$C = @{
    Titlu = 'Cyan';     Ok    = 'Green';    Rau = 'Red'
    Atent = 'Yellow';   Sters = 'DarkGray'; Alb = 'White'
    Info  = 'DarkCyan'; Accent = 'Magenta'
}

function Linie { param([int]$n = 68, [string]$ch = '-', [string]$col = 'DarkGray')
    Write-Host ("   " + ($ch * $n)) -ForegroundColor $col }

function Cadru {
    param([string]$Text, [string]$Sub = '')
    $w = 68
    Write-Host ""
    Write-Host ("   +" + ("-" * $w) + "+") -ForegroundColor $C.Titlu
    $p = [math]::Max(0, [math]::Floor(($w - $Text.Length) / 2))
    Write-Host "   |" -ForegroundColor $C.Titlu -NoNewline
    Write-Host ((" " * $p) + $Text + (" " * [math]::Max(0, $w - $p - $Text.Length))) -ForegroundColor $C.Alb -NoNewline
    Write-Host "|" -ForegroundColor $C.Titlu
    if ($Sub) {
        $p2 = [math]::Max(0, [math]::Floor(($w - $Sub.Length) / 2))
        Write-Host "   |" -ForegroundColor $C.Titlu -NoNewline
        Write-Host ((" " * $p2) + $Sub + (" " * [math]::Max(0, $w - $p2 - $Sub.Length))) -ForegroundColor $C.Sters -NoNewline
        Write-Host "|" -ForegroundColor $C.Titlu
    }
    Write-Host ("   +" + ("-" * $w) + "+") -ForegroundColor $C.Titlu
}

function Sectiune { param([string]$T)
    Write-Host ""
    Write-Host "   " -NoNewline
    Write-Host " $T " -ForegroundColor Black -BackgroundColor DarkCyan
    Write-Host "" }

function Tasta { param([string]$K, [string]$Desc, [int]$W = 20)
    Write-Host "   " -NoNewline
    Write-Host " $K " -ForegroundColor Black -BackgroundColor Gray -NoNewline
    Write-Host (" " + $Desc.PadRight($W)) -ForegroundColor $C.Sters -NoNewline }

function Mesaj {
    param([string]$T, [ValidateSet('ok','rau','atent','info')][string]$Tip = 'info')
    $s = @{ ok = '[ok]  '; rau = '[!!]  '; atent = '[ ! ] '; info = '[..]  ' }[$Tip]
    $c = @{ ok = $C.Ok;    rau = $C.Rau;   atent = $C.Atent; info = $C.Info }[$Tip]
    Write-Host ""
    Write-Host ("   " + $s + $T) -ForegroundColor $c
}

function Pauza { param([int]$s = 2) Start-Sleep -Seconds $s }
function Enter { Write-Host ""; Read-Host "   Apasa Enter" | Out-Null }

function Intreaba-DaNu {
    param([string]$T)
    Write-Host ""
    $r = Read-Host "   $T (scrie DA pentru confirmare)"
    return ($r.Trim().ToUpper() -eq 'DA')
}
#endregion


#region ---------- Jurnal ----------
function Write-Log {
    param([string]$Msg, [ValidateSet('INFO','WARN','ERROR','ACTION')][string]$Level = 'INFO')
    try { "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss') [$Level] $Msg" | Add-Content $script:LogFile -Encoding UTF8 } catch {}
}
#endregion


#region ---------- Nucleu dispozitive ----------

# Forteaza Windows sa rescaneze arborele de dispozitive.
# Fara asta lista ramane veche dupa activare/dezactivare.
function Refresh-Pnp {
    param([int]$Asteapta = 1500)
    try { & pnputil /scan-devices 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds $Asteapta
}

# Returneaza: 'critic' (niciodata de atins), 'protejat' (dupa nivel), sau $null
function Get-TipProtectie {
    param($D)

    foreach ($p in $script:Critic) { if ($D.Nume -match $p) { return 'critic' } }

    if ($script:Setari.Nivel -le 0) { return $null }
    if ($script:Setari.Nivel -eq 1) { return $null }   # nivel 1 = doar critic

    # Nivel 2: si input-ul USB
    if ($D.InstanceId -in @($script:Setari.Exceptii)) { return $null }
    foreach ($p in $script:ProtInput) { if ($D.Nume -match $p) { return 'protejat' } }
    if ($D.Clasa -in 'HIDClass','Keyboard','Mouse' -and $D.Nume -match 'Keyboard|Mouse|Tastatura') { return 'protejat' }
    return $null
}

function Test-Protejat {
    param($D)
    return ($null -ne (Get-TipProtectie $D))
}

function Get-USBDevices {
    param([string]$Filtru, [switch]$Ascunse)

    $devs = Get-PnpDevice -PresentOnly:(-not $Ascunse) -EA SilentlyContinue |
            Where-Object { $_.InstanceId -like 'USB\*' -or $_.Class -eq 'USB' }

    $r = foreach ($d in $devs) {
        $vp = if ($d.InstanceId -match '(VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4})') { $Matches[1].ToUpper() } else { '-' }
        $o = [PSCustomObject]@{
            Stare      = $d.Status
            Clasa      = $d.Class
            Nume       = if ($d.FriendlyName) { $d.FriendlyName } else { $d.Name }
            Cod        = $vp
            Adancime   = ($d.InstanceId -split '\\').Count
            InstanceId = $d.InstanceId
            Protejat   = $false
            TipProt    = $null
        }
        $o.TipProt  = Get-TipProtectie $o
        $o.Protejat = ($null -ne $o.TipProt)
        $o
    }

    if ($Filtru) {
        $r = $r | Where-Object {
            $_.Nume -like "*$Filtru*" -or $_.Cod -like "*$Filtru*" -or $_.Clasa -like "*$Filtru*"
        }
    }
    @($r | Sort-Object Clasa, Nume)
}

# 'Error' = oprit manual. 'Unknown' = fantoma, deconectat fizic.
function Stare-Text {
    param($D)
    switch ($D.Stare) {
        'OK'       { return @{ T = 'MERGE';   C = $C.Ok } }
        'Error'    { return @{ T = 'OPRIT';   C = $C.Rau } }
        'Degraded' { return @{ T = 'PROBLEM'; C = $C.Atent } }
        'Unknown'  { return @{ T = 'ABSENT';  C = $C.Sters } }
        default    { return @{ T = "$($D.Stare)"; C = $C.Atent } }
    }
}

function Show-Devices {
    param($D)
    if (-not $D -or $D.Count -eq 0) {
        Write-Host "     (nimic de afisat)" -ForegroundColor $C.Sters
        return
    }

    Write-Host ("   {0,-6} {1,-9} {2,-13} {3,-22} {4}" -f '#','STARE','TIP','COD','DENUMIRE') -ForegroundColor $C.Info
    Linie

    $cls = ''
    for ($i = 0; $i -lt $D.Count; $i++) {
        $x = $D[$i]
        if ($x.Clasa -ne $cls) { $cls = $x.Clasa; Write-Host "" }

        $s = Stare-Text $x
        $mark = switch ($x.TipProt) { 'critic' { '!' } 'protejat' { '*' } default { ' ' } }
        $n = $x.Nume
        if ($n.Length -gt 38) { $n = $n.Substring(0, 35) + '...' }

        Write-Host "   " -NoNewline
        Write-Host ("{0,-3}{1}  " -f $i, $mark) -ForegroundColor $C.Alb   -NoNewline
        Write-Host ("{0,-9}" -f $s.T)           -ForegroundColor $s.C     -NoNewline
        Write-Host ("{0,-13}" -f $x.Clasa)      -ForegroundColor $C.Sters -NoNewline
        Write-Host ("{0,-22}" -f $x.Cod)        -ForegroundColor $C.Info  -NoNewline
        Write-Host $n -ForegroundColor $s.C
    }

    Write-Host ""
    Write-Host "   ! = critic, nu se poate opri niciodata (controller, hub principal)" -ForegroundColor $C.Sters
    Write-Host "   * = protejat de setarea curenta - se poate scoate din meniul  G" -ForegroundColor $C.Sters
}

function Citeste-Indici {
    param($D)
    $inp = Read-Host "   Numarul (ex: 3   sau  1,4,7   sau  2-6)"
    if ([string]::IsNullOrWhiteSpace($inp)) { return @() }

    $idx = @()
    foreach ($p in ($inp -split ',')) {
        $p = $p.Trim()
        if ($p -match '^(\d+)\s*-\s*(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -le $b) { $idx += ($a..$b) } else { $idx += ($b..$a) }
        }
        elseif ($p -match '^\d+$') { $idx += [int]$p }
    }
    @($idx | Sort-Object -Unique | Where-Object { $_ -ge 0 -and $_ -lt $D.Count })
}

function Actioneaza {
    param($D, [ValidateSet('Opreste','Porneste')][string]$Ce)

    $idx = @(Citeste-Indici $D)
    if ($idx.Count -eq 0) { Mesaj "Numar invalid sau lista goala." rau; Pauza 2; return }

    # La oprire: intai copiii, apoi parintii.
    # La pornire: intai parintii, apoi copiii (copilul nu exista pana nu merge parintele).
    $tinte = $idx | ForEach-Object { $D[$_] }
    if ($Ce -eq 'Opreste') { $tinte = @($tinte | Sort-Object Adancime -Descending) }
    else                   { $tinte = @($tinte | Sort-Object Adancime) }

    $ok = 0; $sarit = 0; $esec = 0
    Write-Host ""
    foreach ($x in $tinte) {
        if ($Ce -eq 'Opreste' -and $x.TipProt -eq 'critic') {
            Write-Host "     [sarit] $($x.Nume) - critic, nu se atinge" -ForegroundColor $C.Rau
            Write-Log "Sarit critic: $($x.Nume)" WARN
            $sarit++; continue
        }
        if ($Ce -eq 'Opreste' -and $x.TipProt -eq 'protejat') {
            Write-Host "     [sarit] $($x.Nume) - protejat (scoate-l din meniul G)" -ForegroundColor $C.Atent
            Write-Log "Sarit protejat: $($x.Nume)" WARN
            $sarit++; continue
        }
        if ($Ce -eq 'Porneste' -and $x.Stare -eq 'Unknown') {
            Write-Host "     [sarit] $($x.Nume) - deconectat fizic" -ForegroundColor $C.Sters
            $sarit++; continue
        }
        try {
            if ($Ce -eq 'Opreste') { Disable-PnpDevice -InstanceId $x.InstanceId -Confirm:$false -EA Stop }
            else                   { Enable-PnpDevice  -InstanceId $x.InstanceId -Confirm:$false -EA Stop }
            Write-Host "     [ok] $($x.Nume)" -ForegroundColor $C.Ok
            Write-Log "$Ce : $($x.Nume) | $($x.InstanceId)" ACTION
            $ok++
        } catch {
            Write-Host "     [!!] $($x.Nume) - $($_.Exception.Message)" -ForegroundColor $C.Rau
            Write-Log "Esec $Ce pe $($x.InstanceId): $($_.Exception.Message)" ERROR
            $esec++
        }
    }

    Refresh-Pnp
    Mesaj "Reusite: $ok   Sarite: $sarit   Esuate: $esec" ok
    Pauza 2
}

# Reporneste tot ce e oprit. Doua treceri: dupa prima apar copiii
# care erau ascunsi sub parinti opriti.
function Porneste-Tot {
    Mesaj "Caut ce este oprit..." info
    Write-Host ""

    $total = 0
    for ($runda = 1; $runda -le 3; $runda++) {
        $off = @(Get-PnpDevice -EA SilentlyContinue |
                 Where-Object { $_.InstanceId -like 'USB\*' -and $_.Status -eq 'Error' } |
                 Sort-Object @{ E = { ($_.InstanceId -split '\\').Count } }, InstanceId)

        if ($off.Count -eq 0) { break }
        if ($runda -gt 1) { Write-Host "     ...au aparut altele, continui" -ForegroundColor $C.Sters }

        $inRunda = 0
        foreach ($d in $off) {
            try {
                Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -EA Stop
                Write-Host "     [ok] $($d.FriendlyName)" -ForegroundColor $C.Ok
                $total++; $inRunda++
            } catch {
                Write-Host "     [!!] $($d.FriendlyName)" -ForegroundColor $C.Rau
            }
        }
        Refresh-Pnp
        if ($inRunda -eq 0) { break }
    }

    if ($total -eq 0) { Mesaj "Nu era nimic oprit." ok }
    else              { Mesaj "$total aparate repornite." ok }
    Write-Log "Repornire globala: $total" ACTION
    Pauza 2
}
#endregion


#region ---------- Stare salvata ----------
function Export-Stare {
    Get-USBDevices | Select-Object Stare, Nume, Cod, InstanceId |
        ConvertTo-Json -Depth 3 | Set-Content $script:StateFile -Encoding UTF8
    Mesaj "Stare salvata in $script:StateFile" ok
    Write-Log "Stare exportata" INFO
    Pauza 2
}

function Import-Stare {
    if (-not (Test-Path $script:StateFile)) { Mesaj "Nu exista nicio stare salvata." rau; Pauza 2; return }

    $s = @(Get-Content $script:StateFile -Raw | ConvertFrom-Json)
    $depornit = @($s | Where-Object { $_.Stare -eq 'OK' } | Sort-Object @{ E = { ($_.InstanceId -split '\\').Count } })
    $deoprit  = @($s | Where-Object { $_.Stare -ne 'OK' } | Sort-Object @{ E = { ($_.InstanceId -split '\\').Count } } -Descending)

    $n = 0
    Write-Host ""
    foreach ($x in $depornit) {
        $now = Get-PnpDevice -InstanceId $x.InstanceId -EA SilentlyContinue
        if (-not $now -or $now.Status -eq 'OK') { continue }
        try { Enable-PnpDevice -InstanceId $x.InstanceId -Confirm:$false -EA Stop
              Write-Host "     [pornit] $($x.Nume)" -ForegroundColor $C.Ok; $n++ } catch {}
    }
    Refresh-Pnp
    foreach ($x in $deoprit) {
        $now = Get-PnpDevice -InstanceId $x.InstanceId -EA SilentlyContinue
        if (-not $now -or $now.Status -ne 'OK') { continue }
        try { Disable-PnpDevice -InstanceId $x.InstanceId -Confirm:$false -EA Stop
              Write-Host "     [oprit]  $($x.Nume)" -ForegroundColor $C.Atent; $n++ } catch {}
    }

    Refresh-Pnp
    Mesaj "$n aparate readuse la starea salvata." ok
    Write-Log "Stare restaurata: $n modificari" ACTION
    Pauza 2
}
#endregion


#region ---------- Stick-uri si hard-uri externe ----------
function Get-StareStocare {
    $v = (Get-ItemProperty $script:StorKey -Name Start -EA SilentlyContinue).Start
    if ($v -eq 4) { return 'INTERZISE' } else { return 'PERMISE' }
}

function Set-Stocare {
    param([ValidateSet('Block','Allow')][string]$Mode)
    try {
        if ($Mode -eq 'Block') {
            Set-ItemProperty $script:StorKey -Name Start -Value 4 -EA Stop
            Mesaj "Stick-urile si hard-urile externe sunt interzise." ok
            Write-Log "USBSTOR blocat" ACTION
        } else {
            Set-ItemProperty $script:StorKey -Name Start -Value 3 -EA Stop
            Mesaj "Stick-urile si hard-urile externe sunt permise." ok
            Write-Log "USBSTOR permis" ACTION
        }
    } catch { Mesaj $_.Exception.Message rau }
    Pauza 2
}
#endregion


#region ---------- Intrari (hub-uri) ----------
function Get-Denumiri {
    if (Test-Path $script:NamesFile) {
        try { return (Get-Content $script:NamesFile -Raw | ConvertFrom-Json) } catch {}
    }
    return (New-Object PSObject)
}

function Set-Denumire {
    param($Id, $Nume)
    $d = Get-Denumiri
    $d | Add-Member -NotePropertyName $Id -NotePropertyValue $Nume -Force
    $d | ConvertTo-Json | Set-Content $script:NamesFile -Encoding UTF8
}

function Salveaza-Copie {
    $f = Join-Path $script:BackupDir "reguli_$(Get-Date -f 'yyyyMMdd_HHmmss').reg"
    & reg export "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall" $f /y 2>&1 | Out-Null
    Write-Log "Copie reguli -> $f" INFO
    return $f
}

function Get-GrupuriIntrari {
    $den = Get-Denumiri
    @(Get-PnpDevice -Class USB -EA SilentlyContinue |
        Where-Object { $_.FriendlyName -match 'Root Hub|Generic USB Hub|USB Hub' } |
        ForEach-Object {
            $kids = @((Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_Children' -EA SilentlyContinue).Data)
            $cheie = ($_.InstanceId -replace '[^A-Za-z0-9]', '_')
            [PSCustomObject]@{
                Stare      = if ($_.Status -eq 'OK') { 'DESCHIS' } else { 'INCHIS' }
                Eticheta   = $den.$cheie
                Tehnic     = $_.FriendlyName
                Ocupate    = $kids.Count
                Cheie      = $cheie
                InstanceId = $_.InstanceId
            }
        } | Sort-Object Tehnic)
}

function Meniu-Intrari {
    do {
        Clear-Host
        Cadru "INTRARILE USB" "un rand = un grup de mufe"
        Write-Host "   Inchizi un grup si mufele din el nu mai primesc nimic." -ForegroundColor $C.Sters
        Write-Host "   Poti baga orice acolo, calculatorul nu reactioneaza." -ForegroundColor $C.Sters

        $g = @(Get-GrupuriIntrari)
        Write-Host ""
        Write-Host ("   {0,-5} {1,-10} {2,-38} {3}" -f '#','STARE','DENUMIRE','OCUPATE') -ForegroundColor $C.Info
        Linie

        for ($i = 0; $i -lt $g.Count; $i++) {
            $x = $g[$i]
            $col = if ($x.Stare -eq 'DESCHIS') { $C.Ok } else { $C.Rau }
            $nume = if ($x.Eticheta) { $x.Eticheta } else { $x.Tehnic }
            if ($nume.Length -gt 36) { $nume = $nume.Substring(0, 33) + '...' }
            Write-Host "   " -NoNewline
            Write-Host ("{0,-5}"  -f $i)       -ForegroundColor $C.Alb   -NoNewline
            Write-Host ("{0,-10}" -f $x.Stare) -ForegroundColor $col     -NoNewline
            Write-Host ("{0,-38}" -f $nume)    -ForegroundColor $col     -NoNewline
            Write-Host $x.Ocupate -ForegroundColor $C.Sters
            if ($x.Eticheta) { Write-Host ("         $($x.Tehnic)") -ForegroundColor $C.Sters }
        }

        Sectiune "Ce faci"
        Tasta 'I' 'Inchide grup'; Tasta 'D' 'Deschide grup'
        Write-Host ""
        Tasta 'N' 'Pune denumire'; Tasta '0' 'Inapoi'
        Write-Host "`n"
        $c = (Read-Host "   Alege").Trim().ToUpper()

        if ($c -eq '0' -or $c -eq '') { return }

        if ($c -eq 'N') {
            $n = Read-Host "   Numarul randului"
            if ($n -match '^\d+$' -and [int]$n -lt $g.Count) {
                $nm = Read-Host "   Denumire (ex: mufe fata / mufe spate)"
                if ($nm) { Set-Denumire $g[[int]$n].Cheie $nm }
            }
            continue
        }

        if ($c -eq 'I' -or $c -eq 'D') {
            $n = Read-Host "   Numarul randului"
            if (-not ($n -match '^\d+$') -or [int]$n -ge $g.Count) { continue }
            $x = $g[[int]$n]

            if ($c -eq 'I' -and $x.Tehnic -match 'eXtensible|Host Controller') {
                Mesaj "Asta e intrarea principala. Ai ramane fara USB deloc. Nu o ating." rau
                Pauza 3; continue
            }

            if ($c -eq 'I') {
                $kids = @((Get-PnpDeviceProperty -InstanceId $x.InstanceId -KeyName 'DEVPKEY_Device_Children' -EA SilentlyContinue).Data)
                $risc = @($kids | ForEach-Object { Get-PnpDevice -InstanceId $_ -EA SilentlyContinue } |
                          Where-Object { $_.Class -in 'HIDClass','Keyboard','Mouse' })
                if ($risc.Count -gt 0) {
                    Mesaj "Pe aceste mufe stau tastatura sau mouse-ul:" atent
                    $risc | ForEach-Object { Write-Host "       - $($_.FriendlyName)" -ForegroundColor $C.Atent }
                    Write-Host "       Ramai fara ele pana la repornirea calculatorului." -ForegroundColor $C.Atent
                    if (-not (Intreaba-DaNu "Continui?")) { continue }
                }
            }

            try {
                if ($c -eq 'I') { Disable-PnpDevice -InstanceId $x.InstanceId -Confirm:$false -EA Stop; $a = 'INCHIS' }
                else            { Enable-PnpDevice  -InstanceId $x.InstanceId -Confirm:$false -EA Stop; $a = 'DESCHIS' }
                Refresh-Pnp
                Mesaj "Grupul este acum: $a" ok
                Write-Log "Grup intrari $a : $($x.InstanceId)" ACTION
            } catch { Mesaj $_.Exception.Message rau }
            Pauza 2
        }
    } while ($true)
}
#endregion


#region ---------- Mufe fizice ----------
function Get-PortInfo {
    param([string]$InstanceId)
    $loc = (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_LocationInfo' -EA SilentlyContinue).Data
    $port = $null; $hub = $null
    if ($loc -match 'Port_#(\d+)') { $port = [int]$Matches[1] }
    if ($loc -match 'Hub_#(\d+)')  { $hub  = [int]$Matches[1] }
    $cheie = $null
    if ($null -ne $port) { $cheie = "H$hub-P$port" }
    [PSCustomObject]@{ Port = $port; Hub = $hub; Loc = $loc; Cheie = $cheie }
}

function Get-Mufe {
    if (Test-Path $script:PortMap) {
        try { return (Get-Content $script:PortMap -Raw | ConvertFrom-Json) } catch {}
    }
    return (New-Object PSObject)
}

function Set-Mufa {
    param($Cheie, $Nume)
    $m = Get-Mufe
    $m | Add-Member -NotePropertyName $Cheie -NotePropertyValue $Nume -Force
    $m | ConvertTo-Json | Set-Content $script:PortMap -Encoding UTF8
}

function Arata-Mufe {
    Clear-Host
    Cadru "MUFELE SI CE ESTE IN ELE"
    $map = Get-Mufe

    $dev = Get-PnpDevice -PresentOnly -EA SilentlyContinue |
           Where-Object { $_.InstanceId -like 'USB\*' -and $_.InstanceId -notmatch 'ROOT_HUB' }

    $lista = foreach ($d in $dev) {
        $pi = Get-PortInfo $d.InstanceId
        if (-not $pi.Cheie) { continue }
        [PSCustomObject]@{
            Mufa  = if ($map.($pi.Cheie)) { $map.($pi.Cheie) } else { '(fara nume)' }
            Cheie = $pi.Cheie
            Stare = $d.Status
            Nume  = $d.FriendlyName
        }
    }
    $randuri = @($lista | Group-Object Cheie | ForEach-Object { $_.Group[0] } | Sort-Object Cheie)

    Write-Host ""
    Write-Host ("   {0,-24} {1,-10} {2,-9} {3}" -f 'MUFA','PORT','STARE','CE ESTE IN EA') -ForegroundColor $C.Info
    Linie

    if ($randuri.Count -eq 0) {
        Write-Host "     (nimic conectat sau Windows nu raporteaza portul)" -ForegroundColor $C.Sters
    }
    foreach ($r in $randuri) {
        $col = if ($r.Stare -eq 'OK') { $C.Ok } else { $C.Rau }
        $st  = if ($r.Stare -eq 'OK') { 'MERGE' } else { 'OPRIT' }
        $n = $r.Nume; if ($n.Length -gt 32) { $n = $n.Substring(0, 29) + '...' }
        Write-Host ("   {0,-24} " -f $r.Mufa) -ForegroundColor $C.Alb   -NoNewline
        Write-Host ("{0,-10} " -f $r.Cheie)   -ForegroundColor $C.Info  -NoNewline
        Write-Host ("{0,-9}" -f $st)          -ForegroundColor $col     -NoNewline
        Write-Host $n -ForegroundColor $C.Sters
    }

    $numite  = @($map.PSObject.Properties.Name)
    $ocupate = @($randuri | ForEach-Object { $_.Cheie })
    $libere  = @($numite | Where-Object { $_ -notin $ocupate })
    if ($libere.Count -gt 0) {
        Write-Host ""
        Write-Host "   Mufe cunoscute, dar goale acum:" -ForegroundColor $C.Atent
        foreach ($l in $libere) { Write-Host ("     {0,-10} {1}" -f $l, $map.$l) -ForegroundColor $C.Sters }
    }

    Write-Host ""
    Write-Host "   Mufele in care nu ai bagat niciodata nimic nu apar - Windows" -ForegroundColor $C.Sters
    Write-Host "   nu stie ca exista. Foloseste maparea ca sa le inregistrezi." -ForegroundColor $C.Sters
    Enter
}

function Mapare-Mufe {
    Clear-Host
    Cadru "MAPARE MUFE FIZICE" "ai nevoie de un stick USB"
    Write-Host "   Bagi stick-ul intr-o mufa, scriptul vede pe ce port a intrat," -ForegroundColor $C.Sters
    Write-Host "   tu ii dai un nume (ex: fata stanga), apoi il scoti si repeti." -ForegroundColor $C.Sters

    do {
        Write-Host ""
        Linie
        Write-Host "   Scoate stick-ul din toate mufele, apoi apasa Enter." -ForegroundColor $C.Info
        Read-Host | Out-Null

        $inainte = @(Get-PnpDevice -PresentOnly -EA SilentlyContinue |
                     Where-Object { $_.InstanceId -like 'USB\*' } |
                     Select-Object -ExpandProperty InstanceId)

        Write-Host "   Acum baga stick-ul in mufa pe care vrei sa o denumesti." -ForegroundColor $C.Ok
        Write-Host "   Astept 30 de secunde..." -ForegroundColor $C.Sters

        $nou = $null
        for ($t = 0; $t -lt 60; $t++) {
            Start-Sleep -Milliseconds 500
            $acum = @(Get-PnpDevice -PresentOnly -EA SilentlyContinue |
                      Where-Object { $_.InstanceId -like 'USB\*' })
            $dif = @($acum | Where-Object { $_.InstanceId -notin $inainte })
            if ($dif.Count -gt 0) {
                $nou = $dif | Where-Object { (Get-PortInfo $_.InstanceId).Cheie } | Select-Object -First 1
                if (-not $nou) { $nou = $dif[0] }
                break
            }
        }

        if (-not $nou) {
            Mesaj "Nu am detectat nimic. Incearca din nou." rau
        } else {
            $pi = Get-PortInfo $nou.InstanceId
            Mesaj "Detectat: $($nou.FriendlyName)" ok
            Write-Host "     Port logic : $($pi.Cheie)" -ForegroundColor $C.Info
            Write-Host "     Detaliu    : $($pi.Loc)"   -ForegroundColor $C.Sters

            if (-not $pi.Cheie) {
                Mesaj "Windows nu raporteaza portul pentru acest aparat. Incearca alt stick." atent
            } else {
                $nume = Read-Host "`n   Cum se numeste mufa asta (ex: fata stanga)"
                if ($nume) {
                    Set-Mufa $pi.Cheie $nume
                    Mesaj "Salvat: $($pi.Cheie) = $nume" ok
                    Write-Log "Mufa mapata: $($pi.Cheie) = $nume" ACTION
                }
            }
        }

        Write-Host ""
        $c = Read-Host "   Mai mapezi o mufa? (D = da, orice altceva = gata)"
    } while ($c.Trim().ToUpper() -eq 'D')
}

function Meniu-Mufe {
    do {
        Clear-Host
        Cadru "MUFE FIZICE"
        Write-Host "   Windows nu stie ce mufa e unde pe carcasa. Ii spui tu o data," -ForegroundColor $C.Sters
        Write-Host "   apoi le vezi cu numele lor." -ForegroundColor $C.Sters

        Sectiune "Ce faci"
        Tasta '1' 'Vezi mufele'; Tasta '2' 'Mapeaza mufele'
        Write-Host ""
        Tasta '0' 'Inapoi'
        Write-Host "`n"

        $c = (Read-Host "   Alege").Trim()
        switch ($c) {
            '1' { Arata-Mufe }
            '2' { Mapare-Mufe }
            default { return }
        }
    } while ($true)
}
#endregion


#region ---------- Protectie ----------
function Nume-Nivel {
    param([int]$N)
    switch ($N) {
        0 { return 'OPRITA - nimic protejat' }
        1 { return 'MINIMA - doar controllerul' }
        2 { return 'TOTALA - controller + tastatura/mouse' }
        default { return "necunoscut ($N)" }
    }
}

function Meniu-Protectie {
    do {
        Clear-Host
        Cadru "PROTECTIE" "ce nu are voie scriptul sa opreasca"

        $niv = [int]$script:Setari.Nivel
        $col = switch ($niv) { 0 { $C.Rau } 1 { $C.Atent } default { $C.Ok } }
        Write-Host ""
        Write-Host "   Nivel curent : " -ForegroundColor $C.Sters -NoNewline
        Write-Host (Nume-Nivel $niv) -ForegroundColor $col

        $exc = @($script:Setari.Exceptii)
        Write-Host "   Exceptii     : " -ForegroundColor $C.Sters -NoNewline
        Write-Host "$($exc.Count) aparate scoase manual" -ForegroundColor $C.Info

        # Sfat in functie de masina
        Write-Host ""
        $eLaptop = Test-Laptop
        $inputUSB = Test-InputPeUSB
        if ($eLaptop) {
            Write-Host "   Masina pare LAPTOP." -ForegroundColor $C.Info
            if (-not $inputUSB) {
                Write-Host "   Tastatura si touchpad-ul sunt interne, nu pe USB." -ForegroundColor $C.Sters
                Write-Host "   Nivelul 1 e sigur aici - nu ai ce pierde." -ForegroundColor $C.Ok
            } else {
                Write-Host "   Ai totusi tastatura sau mouse pe USB - atentie la nivelul 1." -ForegroundColor $C.Atent
            }
        } else {
            Write-Host "   Masina pare DESKTOP." -ForegroundColor $C.Info
            if ($inputUSB) {
                Write-Host "   Tastatura sau mouse-ul sunt pe USB. Daca le oprești, ramai" -ForegroundColor $C.Atent
                Write-Host "   fara ele pana la repornire. Tine nivelul 2." -ForegroundColor $C.Atent
            } else {
                Write-Host "   Nu vad tastatura pe USB - probabil e PS/2. Nivelul 1 e ok." -ForegroundColor $C.Ok
            }
        }

        Sectiune "Ce faci"
        Tasta '1' 'Nivel TOTAL';    Tasta '2' 'Nivel MINIM'
        Write-Host ""
        Tasta '3' 'Nivel OPRIT';    Tasta '4' 'Scoate un aparat'
        Write-Host ""
        Tasta '5' 'Vezi exceptiile'; Tasta '6' 'Sterge exceptiile'
        Write-Host ""
        Tasta '0' 'Inapoi'
        Write-Host "`n"

        $c = (Read-Host "   Alege").Trim()
        switch ($c) {
            '1' {
                $script:Setari.Nivel = 2; Set-Setari $script:Setari
                Mesaj "Protectie TOTALA. Tastatura si mouse-ul USB sunt blocate." ok
                Write-Log "Nivel protectie -> 2" ACTION; Pauza 2
            }
            '2' {
                Write-Host ""
                Write-Host "   Nivelul MINIM lasa doar controllerul protejat." -ForegroundColor $C.Atent
                Write-Host "   Vei putea opri inclusiv tastatura si mouse-ul de pe USB." -ForegroundColor $C.Atent
                if (Test-InputPeUSB) {
                    Write-Host "   ATENTIE: chiar ai input pe USB acum." -ForegroundColor $C.Rau
                }
                if (Intreaba-DaNu "Trec pe nivel MINIM?") {
                    $script:Setari.Nivel = 1; Set-Setari $script:Setari
                    Mesaj "Protectie MINIMA." ok
                    Write-Log "Nivel protectie -> 1" ACTION
                }
                Pauza 2
            }
            '3' {
                Write-Host ""
                Write-Host "   Fara protectie poti opri orice, inclusiv aparate de care" -ForegroundColor $C.Rau
                Write-Host "   depinzi ca sa mai poti folosi calculatorul." -ForegroundColor $C.Rau
                Write-Host "   Controllerul ramane blocat oricum - altfel nu mai exista USB." -ForegroundColor $C.Sters
                if (Intreaba-DaNu "Chiar opresc protectia?") {
                    $script:Setari.Nivel = 0; Set-Setari $script:Setari
                    Mesaj "Protectie OPRITA. Ai grija ce oprești." atent
                    Write-Log "Nivel protectie -> 0" ACTION
                }
                Pauza 2
            }
            '4' {
                Clear-Host
                Cadru "SCOATE UN APARAT DIN PROTECTIE"
                $lista = @(Get-USBDevices | Where-Object { $_.TipProt -eq 'protejat' })
                if ($lista.Count -eq 0) {
                    Mesaj "Niciun aparat protejat de setarea curenta." info; Pauza 2; continue
                }
                Write-Host ""
                for ($i = 0; $i -lt $lista.Count; $i++) {
                    Write-Host ("   {0,-4} {1,-22} {2}" -f $i, $lista[$i].Cod, $lista[$i].Nume) -ForegroundColor $C.Info
                }
                Write-Host ""
                $n = Read-Host "   Numarul aparatului"
                if ($n -match '^\d+$' -and [int]$n -lt $lista.Count) {
                    $x = $lista[[int]$n]
                    $e = @($script:Setari.Exceptii)
                    if ($x.InstanceId -notin $e) { $e += $x.InstanceId }
                    $script:Setari.Exceptii = $e
                    Set-Setari $script:Setari
                    Mesaj "Scos din protectie: $($x.Nume)" ok
                    Write-Log "Exceptie adaugata: $($x.InstanceId)" ACTION
                }
                Pauza 2
            }
            '5' {
                Clear-Host
                Cadru "APARATE SCOASE DIN PROTECTIE"
                $e = @($script:Setari.Exceptii)
                Write-Host ""
                if ($e.Count -eq 0) { Write-Host "   (niciunul)" -ForegroundColor $C.Sters }
                foreach ($id in $e) {
                    $d = Get-PnpDevice -InstanceId $id -EA SilentlyContinue
                    $nm = if ($d) { $d.FriendlyName } else { '(deconectat)' }
                    Write-Host ("   {0}" -f $nm) -ForegroundColor $C.Info
                    Write-Host ("      $id") -ForegroundColor $C.Sters
                }
                Enter
            }
            '6' {
                if (Intreaba-DaNu "Sterg toate exceptiile?") {
                    $script:Setari.Exceptii = @()
                    Set-Setari $script:Setari
                    Mesaj "Exceptii sterse. Protectia revine la normal." ok
                    Write-Log "Exceptii sterse" ACTION
                }
                Pauza 2
            }
            default { return }
        }
    } while ($true)
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
    Write-Host "   Mufele raman sub curent, dar calculatorul refuza sa porneasca" -ForegroundColor $C.Atent
    Write-Host "   orice aparat nou bagat in ele. Cele conectate acum raman permise." -ForegroundColor $C.Atent

    $lista = @(Get-USBDevices | Where-Object { $_.Cod -ne '-' } | Sort-Object Cod -Unique)

    Sectiune "Raman permise"
    foreach ($x in $lista) {
        Write-Host ("     {0,-24} " -f $x.Cod) -ForegroundColor $C.Info -NoNewline
        Write-Host $x.Nume -ForegroundColor $C.Sters
    }

    $areInput = @($lista | Where-Object { $_.Nume -match 'Keyboard|Mouse|Input|Tastatura' }).Count
    if ($areInput -eq 0) {
        Mesaj "Nu vad tastatura sau mouse in lista. Risti sa le pierzi la repornire." rau
    }

    if (-not (Intreaba-DaNu "Pornesc paza?")) { return }

    $bk = Salveaza-Copie
    New-Item $script:PolicyKey -Force | Out-Null
    $k = "$script:PolicyKey\AllowDeviceIDs"
    Remove-Item $k -Recurse -Force -EA SilentlyContinue
    New-Item $k -Force | Out-Null

    $i = 1
    foreach ($x in $lista) { Set-ItemProperty $k -Name "$i" -Value "USB\$($x.Cod)"; $i++ }
    Set-ItemProperty $script:PolicyKey -Name 'AllowDeviceIDs'  -Value 1 -Type DWord
    Set-ItemProperty $script:PolicyKey -Name 'DenyUnspecified' -Value 1 -Type DWord
    & gpupdate /force 2>&1 | Out-Null

    Mesaj "Paza pornita. Copie de siguranta: $bk" ok
    Write-Log "Paza pornita, $($lista.Count) aparate permise" ACTION
    Pauza 3
}

function Opreste-Paza {
    Salveaza-Copie | Out-Null
    Remove-Item $script:PolicyKey -Recurse -Force -EA SilentlyContinue
    & gpupdate /force 2>&1 | Out-Null
    Mesaj "Paza oprita. Orice aparat se poate conecta din nou." ok
    Write-Log "Paza oprita" ACTION
    Pauza 2
}

function Arata-Permise {
    Clear-Host
    Cadru "APARATE PERMISE"
    $k = "$script:PolicyKey\AllowDeviceIDs"
    if (-not (Test-Path $k)) { Write-Host "`n   (lista goala)" -ForegroundColor $C.Sters; Enter; return }

    $p = Get-Item $k
    Write-Host ""
    foreach ($n in ($p.Property | Sort-Object { [int]$_ })) {
        Write-Host ("   {0,-4} {1}" -f $n, $p.GetValue($n)) -ForegroundColor $C.Info
    }
    Enter
}

function Meniu-Paza {
    do {
        Clear-Host
        Cadru "PAZA SI RESTRICTII"

        $st   = Get-StarePaza
        $colP = if ($st -eq 'OPRITA') { $C.Ok } else { $C.Rau }
        $stoc = Get-StareStocare
        $colS = if ($stoc -eq 'PERMISE') { $C.Ok } else { $C.Rau }

        Write-Host ""
        Write-Host "   Paza la intrari : " -ForegroundColor $C.Sters -NoNewline
        Write-Host $st -ForegroundColor $colP
        Write-Host "   Stick-uri / HDD : " -ForegroundColor $C.Sters -NoNewline
        Write-Host $stoc -ForegroundColor $colS

        Sectiune "Ce faci"
        Tasta '1' 'Porneste paza';   Tasta '2' 'Opreste paza'
        Write-Host ""
        Tasta '3' 'Interzice stick'; Tasta '4' 'Permite stick'
        Write-Host ""
        Tasta '5' 'Adauga aparat';   Tasta '6' 'Vezi lista permise'
        Write-Host ""
        Tasta '0' 'Inapoi'
        Write-Host "`n"

        $c = (Read-Host "   Alege").Trim()
        switch ($c) {
            '1' { Porneste-Paza }
            '2' { Opreste-Paza }
            '3' { Set-Stocare -Mode Block }
            '4' { Set-Stocare -Mode Allow }
            '5' {
                $v = (Read-Host "   Cod aparat (ex: VID_046D&PID_C52B)").Trim()
                if ($v -match '^VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4}$') {
                    $k = "$script:PolicyKey\AllowDeviceIDs"
                    New-Item $k -Force | Out-Null
                    $n = @((Get-Item $k).Property).Count + 1
                    Set-ItemProperty $k -Name "$n" -Value "USB\$($v.ToUpper())"
                    & gpupdate /force 2>&1 | Out-Null
                    Mesaj "Adaugat pe lista." ok
                    Write-Log "Permise += USB\$v" ACTION
                } else { Mesaj "Cod invalid. Format: VID_XXXX&PID_XXXX" rau }
                Pauza 2
            }
            '6' { Arata-Permise }
            default { return }
        }
    } while ($true)
}
#endregion


#region ---------- Meniu principal ----------
function Bara-Sumar {
    param($D)
    $merge = @($D | Where-Object { $_.Stare -eq 'OK' }).Count
    $oprit = @($D | Where-Object { $_.Stare -eq 'Error' }).Count
    $paza  = Get-StarePaza
    $stoc  = Get-StareStocare

    Write-Host "   " -NoNewline
    Write-Host " $merge merg " -ForegroundColor Black -BackgroundColor Green -NoNewline
    Write-Host " " -NoNewline
    if ($oprit -gt 0) { Write-Host " $oprit oprite " -ForegroundColor White -BackgroundColor DarkRed -NoNewline }
    else              { Write-Host " 0 oprite "      -ForegroundColor Black -BackgroundColor Gray    -NoNewline }
    Write-Host " " -NoNewline
    if ($paza -eq 'OPRITA') { Write-Host " paza oprita "  -ForegroundColor Black -BackgroundColor Gray        -NoNewline }
    else                    { Write-Host " PAZA PORNITA " -ForegroundColor White -BackgroundColor DarkMagenta -NoNewline }
    Write-Host " " -NoNewline
    if ($stoc -eq 'INTERZISE') { Write-Host " stick blocat " -ForegroundColor White -BackgroundColor DarkRed -NoNewline }
    else                       { Write-Host " stick permis " -ForegroundColor Black -BackgroundColor Gray    -NoNewline }
    Write-Host " " -NoNewline
    switch ([int]$script:Setari.Nivel) {
        0 { Write-Host " FARA PROTECTIE " -ForegroundColor White -BackgroundColor DarkRed }
        1 { Write-Host " protectie minima " -ForegroundColor Black -BackgroundColor DarkYellow }
        default { Write-Host " protectie totala " -ForegroundColor Black -BackgroundColor Gray }
    }
}

function Arata-Jurnal {
    Clear-Host
    Cadru "JURNAL" "ultimele 40 de actiuni"
    Write-Host ""
    if (Test-Path $script:LogFile) {
        Get-Content $script:LogFile -Tail 40 | ForEach-Object {
            $c = if     ($_ -match '\[ERROR\]')  { $C.Rau }
                 elseif ($_ -match '\[WARN\]')   { $C.Atent }
                 elseif ($_ -match '\[ACTION\]') { $C.Ok }
                 else                            { $C.Sters }
            Write-Host "   $_" -ForegroundColor $c
        }
    } else { Write-Host "   (jurnal gol)" -ForegroundColor $C.Sters }
    Enter
}

do {
    Clear-Host
    Cadru "USB MANAGER  v3.0" "$env:COMPUTERNAME  -  $env:USERNAME  -  $(Get-Date -f 'dd.MM.yyyy HH:mm')"

    $devs = Get-USBDevices -Filtru $script:Filtru -Ascunse:$script:Ascunse
    Bara-Sumar $devs

    if ($script:Filtru)  { Write-Host "`n   Filtru activ: '$script:Filtru'" -ForegroundColor $C.Atent }
    if ($script:Ascunse) { Write-Host "   Arat si aparatele deconectate fizic" -ForegroundColor $C.Atent }

    Sectiune "Aparate USB"
    Show-Devices $devs

    Sectiune "Ce faci"
    Tasta 'O' 'Opreste aparat';    Tasta 'P' 'Porneste aparat'; Tasta 'T' 'Porneste tot'
    Write-Host ""
    Tasta 'I' 'Intrari USB';       Tasta 'M' 'Mufe fizice';     Tasta 'K' 'Paza'
    Write-Host ""
    Tasta 'G' 'Protectie';         Tasta 'S' 'Salveaza stare';  Tasta 'R' 'Reface stare'
    Write-Host ""
    Tasta 'F' 'Filtru';            Tasta 'A' 'Arata deconectate'; Tasta 'J' 'Jurnal'
    Write-Host ""
    Tasta 'X' 'Reincarca';         Tasta 'Q' 'Iesire'
    Write-Host "`n"

    $k = (Read-Host "   Alege").Trim().ToUpper()

    switch ($k) {
        'O' { Actioneaza $devs 'Opreste' }
        'P' { Actioneaza $devs 'Porneste' }
        'T' { Porneste-Tot }
        'I' { Meniu-Intrari }
        'M' { Meniu-Mufe }
        'K' { Meniu-Paza }
        'G' { Meniu-Protectie }
        'S' { Export-Stare }
        'R' { Import-Stare }
        'F' { $script:Filtru = (Read-Host "   Text de cautat (gol = fara filtru)").Trim() }
        'A' { $script:Ascunse = -not $script:Ascunse }
        'J' { Arata-Jurnal }
        'X' { Refresh-Pnp 500 }
    }
} while ($k -ne 'Q')

Write-Host ""
Write-Host "   Jurnalul este in $script:LogFile" -ForegroundColor $C.Sters
Write-Host ""
#endregion
