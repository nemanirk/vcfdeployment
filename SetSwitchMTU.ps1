# --- [1] Configuration & Credentials ---
$HostListFile = Read-Host "Enter the full path to your ESXi hosts txt file"

# Validation: Check if file exists
if (-not (Test-Path -Path $HostListFile)) {
    Write-Host "[ERROR] File not found: $HostListFile" -ForegroundColor Red
    exit
}

$User = "root"
$Password = Read-Host "Enter ESXi root password" -AsSecureString
$PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))

$TargetMTU = 9000
$vSwitchName = "vSwitch0"
$Hosts = Get-Content $HostListFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

Write-Host "`n>>> STARTING MTU VALIDATION AND UPDATE <<<" -ForegroundColor Cyan

# --- [2] Execution Loop ---
foreach ($HName in $Hosts) {
    try {
        Write-Host "Connecting to $HName..." -ForegroundColor Gray
        $connection = Connect-VIServer -Server $HName -User $User -Password $PlainPassword -ErrorAction Stop
        
        $vmhost = Get-VMHost -Name $HName
        $vSwitch = Get-VirtualSwitch -VMHost $vmhost -Name $vSwitchName

        if ($vSwitch.Mtu -ne $TargetMTU) {
            Write-Host "Updating MTU on $HName from $($vSwitch.Mtu) to $TargetMTU..." -ForegroundColor Yellow
            
            # Apply the MTU change
            $vmhost | Get-VirtualSwitch -Name $vSwitchName | Set-VirtualSwitch -Mtu $TargetMTU -Confirm:$false
            
            Write-Host "MTU successfully updated on $HName." -ForegroundColor Green
        } else {
            Write-Host "MTU on $HName is already $TargetMTU. No action needed." -ForegroundColor Green
        }

        Disconnect-VIServer -Server $connection -Confirm:$false
    } catch {
        Write-Host "[FAILED] Could not process host $HName : $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`n>>> MTU UPDATE PROCESS COMPLETE <<<" -ForegroundColor Cyan
