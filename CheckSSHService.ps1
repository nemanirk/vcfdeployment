# --- [1] Configuration & Credentials ---
$HostListFile = Read-Host "Enter the full path to your ESXi hosts txt file"

if (-not (Test-Path -Path $HostListFile)) {
    Write-Host "[ERROR] File not found: $HostListFile" -ForegroundColor Red
    exit
}

$User = "root"
$Password = Read-Host "Enter ESXi root password" -AsSecureString
$PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))

$Hosts = Get-Content $HostListFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

Write-Host "`n>>> VERIFYING SSH SERVICE STATUS <<<" -ForegroundColor Cyan

# --- [2] Execution Loop 

foreach ($HName in $Hosts) {
    try {
        Write-Host "`nConnecting to ${HName}..." -ForegroundColor Gray
        $conn = Connect-VIServer -Server $HName -User $User -Password $PlainPassword -ErrorAction Stop
        
        # Check current status using your specific syntax
        $sshStatus = Get-VMHost $HName | Get-VMHostService | Where-Object {$_.Key -eq "TSM-SSH"}
        
        Write-Host "Current Status on ${HName}: Running = $($sshStatus.Running) | Policy = $($sshStatus.Policy)" -ForegroundColor Yellow

        if ($sshStatus.Running -eq $false) {
            Write-Host "SSH is stopped. Starting service on ${HName}..." -ForegroundColor White
            
            # Start service using your specific syntax
            Get-VMHost $HName | Get-VMHostService | Where-Object {$_.Key -eq "TSM-SSH" -and $_.Running -eq $false} | Start-VMHostService -Confirm:$false | Out-Null
            
            Write-Host "[SUCCESS] SSH service started on ${HName}." -ForegroundColor Green
        } else {
            Write-Host "SSH service is already running on ${HName}." -ForegroundColor Green
        }

        Disconnect-VIServer -Server $conn -Confirm:$false
    } catch {
        Write-Host "[FAILED] Error processing ${HName}: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`n>>> SSH VERIFICATION COMPLETE <<<" -ForegroundColor Cyan
