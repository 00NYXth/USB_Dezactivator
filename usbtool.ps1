<#
================================================================================
  PORT MANAGER  v1.0
  Gestioneaza (opreste / porneste) porturile si dispozitivele fizice ale unui
  PC/laptop: USB, video (inclusiv iesiri HDMI prin adaptor/monitor), retea,
  audio si stocare.

  Mecanism: Get-PnpDevice / Disable-PnpDevice / Enable-PnpDevice
  Necesita: Windows PowerShell 5.1+ si drepturi de Administrator
           (scriptul se auto-eleveaza singur daca nu are).

  NOTA despre HDMI: nu exista un "port HDMI" separat pe care sa il stingi.
  HDMI este o iesire a placii video. Poti dezactiva:
    - monitorul detectat pe acea iesire (clasa Monitor), sau
    - intreg adaptorul video (clasa Display) - dar asta stinge tot ecranul.
  Scriptul iti arata ambele optiuni; alegi tu ce oprești.
================================================================================
#>

#region ---------- Auto-elevare la Administrator --------------------------------
$identitate = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal  = New-Object Security.Principal.WindowsPrincipal($identitate)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Am nevoie de drepturi de Administrator. Repornesc elevat..." -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
            -Verb RunAs
    } catch {
        Write-Host "Nu am putut porni elevat: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host "Apasa Enter ca sa inchizi"
    }
    exit
}
#endregion

#region ---------- Stare globala ------------------------------------------------
$script:LogFile   = Join-Path $env:USERPROFILE 'PortManager.log'
$script:Filtru    = ''         # text de cautat in nume
$script:Ascunse   = $false     # arata si dispozitivele deconectate fizic
$script:Categorie = 'USB'      # categoria curenta afisata

# Categorii -> clase PnP care le compun
$script:Categorii = [ordered]@{
    'USB'      = @('USB','USBDevice','HIDClass')
    'Video'    = @('Display','Monitor')
    'Retea'    = @('Net')
    'Audio'    = @('AudioEndpoint','MEDIA')
    'Stocare'  = @('DiskDrive','USBSTOR')
}

$script:C = @{
    Titlu = 'Cyan'; Ok = 'Green'; Rau = 'Red'; Atent = 'Yellow'
    Sters = 'DarkGray'; Text = 'Gray'; Accent = 'Magenta'
}
#endregion

#region ---------- Utilitare de afisare -----------------------------------------
function Cadru {
    param([string]$Titlu, [string]$Subtitlu)
    $lat = 78
    Write-Host ('=' * $lat) -ForegroundColor $script:C.Titlu
    Write-Host ('  ' + $Titlu) -ForegroundColor $script:C.Titlu
    if ($Subtitlu) { Write-Host ('  ' + $Subtitlu) -ForegroundColor $script:C.Sters }
    Write-Host ('=' * $lat) -ForegroundColor $script:C.Titlu
}

function Sectiune {
    param([string]$Text)
    Write-Host ''
    Write-Host ('-- ' + $Text + ' ' + ('-' * [Math]::Max(0, 72 - $Text.Length))) -ForegroundColor $script:C.Accent
}

function Tasta {
    param([string]$Cheie, [string]$Descriere)
    Write-Host ('   [' + $Cheie + '] ') -ForegroundColor $script:C.Ok -NoNewline
    Write-Host $Descriere.PadRight(22) -ForegroundColor $script:C.Text -NoNewline
}

function Jurnal {
    param([string]$Mesaj)
    $linie = ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Mesaj)
    Add-Content -Path $script:LogFile -Value $linie -Encoding UTF8
}
#endregion

#region ---------- Interogare dispozitive ---------------------------------------
function Get-Dispozitive {
    param(
        [string]  $Categorie,
        [string]  $Filtru,
        [switch]  $Ascunse
    )
    $clase = $script:Categorii[$Categorie]
    if (-not $clase) { return @() }

    $lista = Get-PnpDevice -Class $clase -ErrorAction SilentlyContinue

    if (-not $Ascunse) {
        # doar cele prezente fizic (conectate)
        $lista = $lista | Where-Object { $_.Present }
    }
    if ($Filtru) {
        $lista = $lista | Where-Object { $_.FriendlyName -like "*$Filtru*" }
    }

    $lista | Sort-Object Status, FriendlyName
}

function Bara-Sumar {
    param($Devs)
    $total    = @($Devs).Count
    $active   = @($Devs | Where-Object { $_.Status -eq 'OK' }).Count
    $oprite   = @($Devs | Where-Object { $_.Status -eq 'Error' -or $_.Status -eq 'Disabled' }).Count
    Write-Host ''
    Write-Host ('   Categorie: ')  -NoNewline -ForegroundColor $script:C.Text
    Write-Host $script:Categorie   -NoNewline -ForegroundColor $script:C.Titlu
    Write-Host ('    Total: {0}   Active: ' -f $total) -NoNewline -ForegroundColor $script:C.Text
    Write-Host $active -NoNewline -ForegroundColor $script:C.Ok
    Write-Host ('   Oprite: ') -NoNewline -ForegroundColor $script:C.Text
    Write-Host $oprite -ForegroundColor $script:C.Rau
}

function Show-Devices {
    param($Devs)
    if (@($Devs).Count -eq 0) {
        Write-Host '   (niciun dispozitiv in aceasta categorie/filtru)' -ForegroundColor $script:C.Sters
        return
    }
    $i = 0
    foreach ($d in $Devs) {
        $i++
        switch ($d.Status) {
            'OK'       { $cul = $script:C.Ok;   $stare = 'ACTIV ' }
            'Error'    { $cul = $script:C.Rau;  $stare = 'OPRIT ' }
            'Disabled' { $cul = $script:C.Rau;  $stare = 'OPRIT ' }
            'Unknown'  { $cul = $script:C.Sters;$stare = 'DECON.' }
            default    { $cul = $script:C.Atent;$stare = ($d.Status).PadRight(6) }
        }
        $nr   = ('{0,3}.' -f $i)
        $nume = $d.FriendlyName
        if ($nume.Length -gt 52) { $nume = $nume.Substring(0,49) + '...' }
        Write-Host ("  $nr ") -NoNewline -ForegroundColor $script:C.Text
        Write-Host ("[$stare] ") -NoNewline -ForegroundColor $cul
        Write-Host $nume -ForegroundColor $script:C.Text
    }
}
#endregion

#region ---------- Actiuni pe dispozitive ---------------------------------------
function Alege-Dispozitiv {
    param($Devs)
    $raspuns = (Read-Host '   Numarul dispozitivului (gol = anuleaza)').Trim()
    if ($raspuns -eq '') { return $null }
    $idx = 0
    if (-not [int]::TryParse($raspuns, [ref]$idx)) {
        Write-Host '   Numar invalid.' -ForegroundColor $script:C.Rau; return $null
    }
    if ($idx -lt 1 -or $idx -gt @($Devs).Count) {
        Write-Host '   Numar in afara listei.' -ForegroundColor $script:C.Rau; return $null
    }
    return $Devs[$idx - 1]
}

function Actioneaza {
    param($Devs, [ValidateSet('Opreste','Porneste')] [string]$Ce)
    $d = Alege-Dispozitiv $Devs
    if (-not $d) { return }

    $nume = $d.FriendlyName
    if ($Ce -eq 'Opreste') {
        $confirm = (Read-Host "   Sigur OPRESTI '$nume'? (d/N)").Trim().ToLower()
        if ($confirm -ne 'd') { Write-Host '   Anulat.' -ForegroundColor $script:C.Atent; return }
        try {
            Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop
            Write-Host "   OPRIT: $nume" -ForegroundColor $script:C.Rau
            Jurnal "OPRIT   [$($script:Categorie)] $nume  ($($d.InstanceId))"
        } catch {
            Write-Host "   Eroare la oprire: $($_.Exception.Message)" -ForegroundColor $script:C.Rau
            Jurnal "EROARE-OPRIRE $nume : $($_.Exception.Message)"
        }
    } else {
        try {
            Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop
            Write-Host "   PORNIT: $nume" -ForegroundColor $script:C.Ok
            Jurnal "PORNIT  [$($script:Categorie)] $nume  ($($d.InstanceId))"
        } catch {
            Write-Host "   Eroare la pornire: $($_.Exception.Message)" -ForegroundColor $script:C.Rau
            Jurnal "EROARE-PORNIRE $nume : $($_.Exception.Message)"
        }
    }
}

function Porneste-Tot {
    $confirm = (Read-Host '   Pornesti TOATE dispozitivele oprite din aceasta categorie? (d/N)').Trim().ToLower()
    if ($confirm -ne 'd') { return }
    $oprite = Get-Dispozitive -Categorie $script:Categorie -Ascunse |
              Where-Object { $_.Status -eq 'Error' -or $_.Status -eq 'Disabled' }
    if (@($oprite).Count -eq 0) { Write-Host '   Nimic de pornit.' -ForegroundColor $script:C.Atent; return }
    foreach ($d in $oprite) {
        try {
            Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop
            Write-Host "   PORNIT: $($d.FriendlyName)" -ForegroundColor $script:C.Ok
            Jurnal "PORNIT-TOT [$($script:Categorie)] $($d.FriendlyName)"
        } catch {
            Write-Host "   Esuat: $($d.FriendlyName) - $($_.Exception.Message)" -ForegroundColor $script:C.Rau
        }
    }
}
#endregion

#region ---------- Salvare / Refacere stare -------------------------------------
function Export-Stare {
    $cale = Join-Path $env:USERPROFILE ('PortManager_stare_{0}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $tot = foreach ($cat in $script:Categorii.Keys) {
        Get-Dispozitive -Categorie $cat -Ascunse | Select-Object `
            @{n='Categorie';e={$cat}}, FriendlyName, InstanceId, Status
    }
    $tot | ConvertTo-Json -Depth 4 | Set-Content -Path $cale -Encoding UTF8
    Write-Host "   Stare salvata in: $cale" -ForegroundColor $script:C.Ok
    Jurnal "EXPORT stare -> $cale"
}

function Import-Stare {
    $cale = (Read-Host '   Calea fisierului .json de refacut').Trim('"',' ')
    if (-not (Test-Path $cale)) { Write-Host '   Fisier inexistent.' -ForegroundColor $script:C.Rau; return }
    $stare = Get-Content $cale -Raw | ConvertFrom-Json
    foreach ($item in $stare) {
        $curent = Get-PnpDevice -InstanceId $item.InstanceId -ErrorAction SilentlyContinue
        if (-not $curent) { continue }
        $vreaOprit = ($item.Status -eq 'Error' -or $item.Status -eq 'Disabled')
        $eOprit    = ($curent.Status -eq 'Error' -or $curent.Status -eq 'Disabled')
        try {
            if     ($vreaOprit -and -not $eOprit) { Disable-PnpDevice -InstanceId $item.InstanceId -Confirm:$false -ErrorAction Stop; Write-Host "   Opresc: $($item.FriendlyName)" -ForegroundColor $script:C.Rau }
            elseif (-not $vreaOprit -and $eOprit) { Enable-PnpDevice  -InstanceId $item.InstanceId -Confirm:$false -ErrorAction Stop; Write-Host "   Pornesc: $($item.FriendlyName)" -ForegroundColor $script:C.Ok }
        } catch {
            Write-Host "   Esuat: $($item.FriendlyName) - $($_.Exception.Message)" -ForegroundColor $script:C.Rau
        }
    }
    Jurnal "IMPORT stare <- $cale"
}

function Arata-Jurnal {
    if (-not (Test-Path $script:LogFile)) { Write-Host '   Jurnalul e gol.' -ForegroundColor $script:C.Atent; return }
    Write-Host ''
    Get-Content $script:LogFile -Tail 20 | ForEach-Object {
        Write-Host ('   ' + $_) -ForegroundColor $script:C.Sters
    }
    Read-Host "`n   Enter ca sa revii"
}

function Schimba-Categorie {
    Write-Host ''
    $chei = @($script:Categorii.Keys)
    for ($i=0; $i -lt $chei.Count; $i++) {
        Write-Host ("   [{0}] {1}" -f ($i+1), $chei[$i]) -ForegroundColor $script:C.Text
    }
    $r = (Read-Host '   Alege categoria').Trim()
    $idx = 0
    if ([int]::TryParse($r, [ref]$idx) -and $idx -ge 1 -and $idx -le $chei.Count) {
        $script:Categorie = $chei[$idx-1]
    }
}
#endregion

#region ---------- Bucla principala ---------------------------------------------
do {
    Clear-Host
    Cadru "PORT MANAGER  v1.0" "$env:COMPUTERNAME  -  $env:USERNAME  -  $(Get-Date -f 'dd.MM.yyyy HH:mm')"

    $devs = Get-Dispozitive -Categorie $script:Categorie -Filtru $script:Filtru -Ascunse:$script:Ascunse
    Bara-Sumar $devs

    if ($script:Filtru)  { Write-Host "   Filtru activ: '$script:Filtru'" -ForegroundColor $script:C.Atent }
    if ($script:Ascunse) { Write-Host "   Arat si aparatele deconectate fizic"  -ForegroundColor $script:C.Atent }
    if ($script:Categorie -eq 'Video') {
        Write-Host "   ! HDMI = oprești monitorul de pe iesire sau adaptorul video, nu 'portul'." -ForegroundColor $script:C.Sters
    }

    Sectiune "Dispozitive [$script:Categorie]"
    Show-Devices $devs

    Sectiune "Ce faci"
    Tasta 'O' 'Opreste aparat'; Tasta 'P' 'Porneste aparat'; Tasta 'T' 'Porneste tot'; Write-Host ''
    Tasta 'C' 'Schimba categoria'; Tasta 'F' 'Filtru';       Tasta 'A' 'Arata deconectate'; Write-Host ''
    Tasta 'S' 'Salveaza stare';  Tasta 'R' 'Reface stare';   Tasta 'J' 'Jurnal'; Write-Host ''
    Tasta 'X' 'Reincarca';       Tasta 'Q' 'Iesire'; Write-Host "`n"

    $k = (Read-Host '   Alege').Trim().ToUpper()

    switch ($k) {
        'O' { Actioneaza $devs 'Opreste' }
        'P' { Actioneaza $devs 'Porneste' }
        'T' { Porneste-Tot }
        'C' { Schimba-Categorie }
        'F' { $script:Filtru = (Read-Host '   Text de cautat (gol = fara filtru)').Trim() }
        'A' { $script:Ascunse = -not $script:Ascunse }
        'S' { Export-Stare }
        'R' { Import-Stare }
        'J' { Arata-Jurnal }
        'X' { }  # reincarca = pur si simplu reia bucla
        'Q' { }
        default { }
    }

    if ($k -ne 'Q' -and $k -notin @('C','F','A','X','J')) {
        Read-Host "`n   Enter ca sa continui" | Out-Null
    }

} while ($k -ne 'Q')

Write-Host ''
Write-Host "   Jurnalul este in $script:LogFile" -ForegroundColor $script:C.Sters
Write-Host ''
#endregion
