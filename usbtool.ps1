#region Blocare intrari USB
$script:PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
$script:BackupDir = Join-Path $env:ProgramData "USBManager\backup"
$script:NamesFile = Join-Path $env:ProgramData "USBManager\denumiri.json"
New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null

# Denumiri prietenoase pentru grupuri de intrari, salvate de utilizator
function Get-Denumiri {
    if (Test-Path $script:NamesFile) {
        try { return (Get-Content $script:NamesFile -Raw | ConvertFrom-Json) } catch {}
    }
    return [PSCustomObject]@{}
}
function Set-Denumire {
    param($Id, $Nume)
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
            $kids = @((Get-PnpDeviceProperty -InstanceId $_.InstanceId `
                      -KeyName 'DEVPKEY_Device_Children' -EA SilentlyContinue).Data)
            $cheie = ($_.InstanceId -replace '[^A-Za-z0-9]','_')
            $eticheta = if ($den.$cheie) { $den.$cheie } else { $null }
            [PSCustomObject]@{
                Stare      = if ($_.Status -eq 'OK') { 'DESCHIS' } else { 'INCHIS' }
                Eticheta   = $eticheta
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
        Write-Host "`n  === INTRARILE USB ALE CALCULATORULUI ===`n" -ForegroundColor Cyan
        Write-Host "  Fiecare rand = un grup de mufe. Il inchizi, mufele din el nu mai" -ForegroundColor DarkGray
        Write-Host "  primesc nimic - poti baga orice, calculatorul nu reactioneaza.`n" -ForegroundColor DarkGray

        $g = @(Get-GrupuriIntrari)
        for ($i=0; $i -lt $g.Count; $i++) {
            $x = $g[$i]
            $col = if ($x.Stare -eq 'DESCHIS') { 'Green' } else { 'Red' }
            $nume = if ($x.Eticheta) { $x.Eticheta } else { $x.Tehnic }
            Write-Host ("  [{0}] {1,-8} {2,-34} ocupate: {3}" -f $i,$x.Stare,$nume,$x.Ocupate) -ForegroundColor $col
            if ($x.Eticheta) { Write-Host ("       ($($x.Tehnic))") -ForegroundColor DarkGray }
        }

        Write-Host "`n  I = inchide intrari   D = deschide intrari" -ForegroundColor White
        Write-Host "  N = pune denumire     0 = inapoi`n" -ForegroundColor White
        $c = (Read-Host "  Alege").ToUpper()

        if ($c -eq 'N') {
            $n = Read-Host "  Numarul randului"
            if ($n -match '^\d+$' -and [int]$n -lt $g.Count) {
                $nume = Read-Host "  Cum se numeste (ex: 'mufe fata', 'mufe spate stanga')"
                Set-Denumire $g[[int]$n].Cheie $nume
            }
            continue
        }

        if ($c -in 'I','D') {
            $n = Read-Host "  Numarul randului"
            if (-not ($n -match '^\d+$') -or [int]$n -ge $g.Count) { continue }
            $x = $g[[int]$n]

            if ($c -eq 'I' -and $x.Tehnic -match 'eXtensible|Host Controller') {
                Write-Host "`n  [!] Asta e intrarea principala. Daca o inchizi, ramai fara" -ForegroundColor Red
                Write-Host "      niciun USB pe calculator. Nu o ating." -ForegroundColor Red
                Start-Sleep 3; continue
            }

            $kids = @((Get-PnpDeviceProperty -InstanceId $x.InstanceId -KeyName 'DEVPKEY_Device_Children' -EA SilentlyContinue).Data)
            $risc = $kids | ForEach-Object { Get-PnpDevice -InstanceId $_ -EA SilentlyContinue } |
                    Where-Object { $_.Class -in 'HIDClass','Keyboard','Mouse' }

            if ($c -eq 'I' -and $risc) {
                Write-Host "`n  [!] Pe aceste mufe stau chiar tastatura sau mouse-ul:" -ForegroundColor Yellow
                $risc | ForEach-Object { Write-Host "      - $($_.FriendlyName)" -ForegroundColor Yellow }
                Write-Host "`n      Daca inchizi, ramai fara ele pana la repornire." -ForegroundColor Yellow
                if ((Read-Host "`n  Scrie DA daca esti sigur") -ne 'DA') { continue }
            }

            try {
                if ($c -eq 'I') { Disable-PnpDevice -InstanceId $x.InstanceId -Confirm:$false -EA Stop; $a='INCHIS' }
                else            { Enable-PnpDevice  -InstanceId $x.InstanceId -Confirm:$false -EA Stop; $a='DESCHIS' }
                Write-Host "`n  Gata - intrarile sunt acum: $a" -ForegroundColor Green
                Write-Log "Grup intrari $a : $($x.InstanceId)" ACTION
            } catch {
                Write-Host "`n  Nu a mers: $($_.Exception.Message)" -ForegroundColor Red
            }
            Start-Sleep 2
        }
    } while ($c -ne '0')
}
#endregion

#region Paza - refuza aparate straine
function Get-StarePaza {
    if (-not (Test-Path $script:PolicyKey)) { return 'OPRITA' }
    $p = Get-ItemProperty $script:PolicyKey -EA SilentlyContinue
    if ($p.DenyUnspecified -eq 1)  { return 'PORNITA' }
    if ($p.DenyDeviceClasses -eq 1){ return 'PORNITA partial' }
    return 'OPRITA'
}

function Porneste-Paza {
    Clear-Host
    Write-Host "`n  === PAZA LA INTRARI ===`n" -ForegroundColor Cyan
    Write-Host "  Mufele raman sub curent, dar calculatorul refuza sa mai" -ForegroundColor Yellow
    Write-Host "  porneasca orice aparat nou bagat in ele.`n" -ForegroundColor Yellow
    Write-Host "  Aparatele conectate ACUM sunt trecute pe lista celor cunoscute" -ForegroundColor Yellow
    Write-Host "  si vor merge in continuare.`n" -ForegroundColor Yellow

    $cunoscute = Get-USBDevices | Where-Object { $_.VidPid -ne '-' } |
                 Select-Object -ExpandProperty VidPid -Unique

    Write-Host "  Raman permise:" -ForegroundColor Green
    Get-USBDevices | Where-Object { $_.VidPid -ne '-' } |
        Sort-Object VidPid -Unique |
        ForEach-Object { Write-Host ("    {0,-24} {1}" -f $_.VidPid, $_.FriendlyName) -ForegroundColor DarkGray }

    Write-Host "`n  [!] Daca lista de mai sus nu contine tastatura si mouse-ul," -ForegroundColor Red
    Write-Host "      rischi sa ramai fara ele dupa repornire." -ForegroundColor Red
    if ((Read-Host "`n  Scrie DA ca sa pornesc paza") -ne 'DA') { return }

    $bk = Salveaza-Copie
    New-Item $script:PolicyKey -Force | Out-Null
    $lista = "$script:PolicyKey\AllowDeviceIDs"
    Remove-Item $lista -Recurse -Force -EA SilentlyContinue
    New-Item $lista -Force | Out-Null

    $i = 1
    foreach ($vp in $cunoscute) { Set-ItemProperty $lista -Name "$i" -Value "USB\$vp"; $i++ }
    Set-ItemProperty $script:PolicyKey -Name 'AllowDeviceIDs'  -Value 1 -Type DWord
    Set-ItemProperty $script:PolicyKey -Name 'DenyUnspecified' -Value 1 -Type DWord
    gpupdate /force 2>&1 | Out-Null

    Write-Host "`n  Paza e pornita. Copie de siguranta: $bk" -ForegroundColor Green
    Write-Log "Paza pornita, $($cunoscute.Count) aparate cunoscute" ACTION
    Start-Sleep 3
}

function Opreste-Paza {
    Salveaza-Copie | Out-Null
    Remove-Item $script:PolicyKey -Recurse -Force -EA SilentlyContinue
    gpupdate /force 2>&1 | Out-Null
    Write-Host "`n  Paza e oprita - orice aparat se poate conecta din nou." -ForegroundColor Green
    Write-Log "Paza oprita" ACTION
    Start-Sleep 2
}

function Meniu-Paza {
    do {
        Clear-Host
        $st = Get-StarePaza
        $col = if ($st -eq 'OPRITA') { 'Green' } else { 'Red' }
        Write-Host "`n  === PAZA SI RESTRICTII ===`n" -ForegroundColor Cyan
        Write-Host "  Paza la intrari: " -NoNewline; Write-Host $st -ForegroundColor $col
        Write-Host "  Stick-uri si HDD: " -NoNewline; Set-USBStoragePolicy -Mode Status

        Write-Host "`n  1 = Porneste paza (refuza aparate noi)"
        Write-Host "  2 = Opreste paza"
        Write-Host "  3 = Interzice stick-uri si hard-uri externe"
        Write-Host "  4 = Permite stick-uri si hard-uri externe"
        Write-Host "  5 = Trece un aparat pe lista celor permise"
        Write-Host "  0 = Inapoi`n"

        switch (Read-Host "  Alege") {
            '1' { Porneste-Paza }
            '2' { Opreste-Paza }
            '3' { Set-USBStoragePolicy -Mode Block }
            '4' { Set-USBStoragePolicy -Mode Allow }
            '5' {
                $v = Read-Host "  Codul aparatului (ex: VID_046D&PID_C52B)"
                $lista = "$script:PolicyKey\AllowDeviceIDs"
                New-Item $lista -Force | Out-Null
                $n = ((Get-Item $lista).Property | Measure-Object).Count + 1
                Set-ItemProperty $lista -Name "$n" -Value "USB\$v"
                gpupdate /force 2>&1 | Out-Null
                Write-Host "  Adaugat pe lista." -ForegroundColor Green
                Write-Log "Lista permise += USB\$v" ACTION
                Start-Sleep 2
            }
            '0' { return }
        }
    } while ($true)
}
#endregion
