# Requires the VMware PowerCLI module to be installed.
# ⚠️ This script REQUIRES PSCP.EXE (from the PuTTY suite) to be in your system's PATH.

# 0. CLEANUP 
# ---
if ($global:DefaultVIServer) {
    Write-Host "Disconnecting existing sessions..." -ForegroundColor Gray
    Disconnect-VIServer -Server * -Force -Confirm:$false
}

# 1. Configuration Variables
# ---
$targetVLAN = 1110

$sshUser = "root"
$plainPassword = "VMw@re1!" # Hardcoded as requested

# Convert plain text password to SecureString for PowerCLI credentials
$securePass = ConvertTo-SecureString $plainPassword -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($sshUser, $securePass)

# 2. Load Host List
# ---
$hostListPath = Read-Host "Enter the full path to the hostnames text file (e.g., C:\temp\hosts.txt)"
if (-not (Test-Path $hostListPath)) {
    Write-Error "File not found: $hostListPath"
    exit
}
$Hosts = Get-Content $hostListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

Write-Host "Starting batch upgrade for $($Hosts.Count) hosts..." -ForegroundColor Cyan

# 3. Iterate Through Each Host
# ---
foreach ($esxiHostName in $Hosts) {
    Write-Host "`n********************************************************" -ForegroundColor Magenta
    Write-Host " PROCESSING HOST: $esxiHostName" -ForegroundColor Magenta
    Write-Host "********************************************************" -ForegroundColor Magenta

    # Clear host-specific variables to prevent carry-over
    Clear-Variable -Name "hostvariable", "scratchconfig", "connection" -ErrorAction SilentlyContinue

    try {
        Write-Host "Connecting to $esxiHostName..."
        $connection = Connect-VIServer -Server $esxiHostName -Credential $cred -ErrorAction Stop
        Write-Host "Connection successful." -ForegroundColor Green
    } catch {
        Write-Warning "Failed to connect to $esxiHostName. Skipping to next host."
        continue
    }

    # 4. Get Host Object and Change VLAN ID
    # ---
    try {
        $hostvariable = Get-VMHost -Name $esxiHostName -ErrorAction Stop
        Write-Host "Setting VLAN ID to $targetVLAN on 'VM Network'..."
        Get-VirtualPortGroup -Name "VM Network" -VMHost $hostvariable | 
            Set-VirtualPortGroup -VLanId $targetVLAN -Confirm:$false
    } catch {
        Write-Warning "Failed to set VLAN ID for $esxiHostName."
    }

}

Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host " BATCH EXECUTION COMPLETE" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
