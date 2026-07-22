# usbtool.ps1
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

function Get-USBDevices {
    Get-PnpDevice -Class USB | Select-Object Status, FriendlyName, InstanceId
}

function Disable-USBDevice($id) { Disable-PnpDevice -InstanceId $id -Confirm:$false }
function Enable-USBDevice($id)  { Enable-PnpDevice  -InstanceId $id -Confirm:$false }

do {
    Clear-Host
    Write-Host "=== USB Manager ===" -ForegroundColor Cyan
    $devs = @(Get-USBDevices)
    for ($i=0; $i -lt $devs.Count; $i++) {
        $c = if ($devs[$i].Status -eq 'OK') {'Green'} else {'Red'}
        Write-Host ("[{0}] {1} - {2}" -f $i, $devs[$i].Status, $devs[$i].FriendlyName) -ForegroundColor $c
    }
    Write-Host "`nD=dezactivare  E=activare  R=refresh  Q=iesire"
    $k = Read-Host "Optiune"
    switch ($k.ToUpper()) {
        'D' { $n = Read-Host "Index"; Disable-USBDevice $devs[$n].InstanceId }
        'E' { $n = Read-Host "Index"; Enable-USBDevice  $devs[$n].InstanceId }
        'Q' { break }
    }
} while ($k.ToUpper() -ne 'Q')
