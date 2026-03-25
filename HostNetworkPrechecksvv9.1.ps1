#-----------Network Validation Report (Master Optimized)-------------------
# 1. Sets vSwitch0 MTU to 9000 (if not already set).
# 2. Adds vmnic1 to vSwitch0 and tests Mgmt redundancy.
# 3. Pings in a "Ring Topology" (1 peer each) for speed.
# 4. Cleans up temp artifacts and resets vSwitch0 MTU to 1500
# 5. Ensures SSH is Running at the end of the script.
# 6. Calculates and displays total execution time.
#---------------------------------------------------------

$StartTime = Get-Date

# --- [0] Main Menu ---
Write-Host "`n===============================================" -ForegroundColor Cyan
Write-Host " VCF NETWORK PRE-CHECK UTILITY"
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "1. Bring up management Domain (Manually provide vMotion & VSAN Network)"
Write-Host "2. Add additional workloads (uses SDDC Network pool)"
Write-Host "3. Exit"
$MenuChoice = Read-Host "`nSelect an option (1, 2, or 3)"

if ($MenuChoice -eq "3") { Write-Host "Exiting script..." -ForegroundColor Yellow; exit }

$NetworkConfigs = @()

# --- [1] SDDC Manager Authentication or Manual Input ---
if ($MenuChoice -eq "2") {
    $sddcFqdn = Read-Host "Enter SDDC Manager FQDN"
    $sddcUser = Read-Host "Enter SDDC Manager username"
    $sddcPass = Read-Host "Enter SDDC Manager password" -AsSecureString
    $PlainSddcPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sddcPass))
    $networkPoolName = Read-Host "Enter network pool name"

    function Get-SddcAuthToken {
        param ($Fqdn, $User, $Pass)
        $TokenUrl = "https://$Fqdn/v1/tokens"
        $Body = @{ username = $User; password = $Pass } | ConvertTo-Json
        try {
            $Resp = Invoke-RestMethod -Uri $TokenUrl -Method Post -Body $Body -ContentType "application/json" -SkipCertificateCheck
            return $Resp.accessToken
        } catch { throw "SDDC Auth Failed: $($_.Exception.Message)" }
    }

    Write-Host "`nAuthenticating with SDDC Manager..." -ForegroundColor Cyan
    $Token = Get-SddcAuthToken -Fqdn $sddcFqdn -User $sddcUser -Pass $PlainSddcPass
    $AuthHeader = @{ "Authorization" = "Bearer $Token"; "Content-Type" = "application/json" }

    $PoolsUrl = "https://$sddcFqdn/v1/network-pools"
    $ApiResponse = Invoke-RestMethod -Uri $PoolsUrl -Method Get -Headers $AuthHeader -SkipCertificateCheck
    $TargetPool = $ApiResponse.elements | Where-Object { $_.name -eq $networkPoolName }
    if (-not $TargetPool) { Write-Host "ERROR: Pool $networkPoolName not found." -ForegroundColor Red; exit }
    $PoolId = $TargetPool.id

    $NetDetailsUrl = "https://$sddcFqdn/v1/network-pools/$PoolId/networks"
    $NetResponse = Invoke-RestMethod -Uri $NetDetailsUrl -Method Get -Headers $AuthHeader -SkipCertificateCheck

    foreach ($net in $NetResponse.elements) {
        $NetworkConfigs += [PSCustomObject]@{
            Name    = $net.type
            VLAN    = $net.vlanId
            Mask    = $net.mask
            Gateway = $net.gateway
            FreeIps = $net.freeIps
        }
    }
}
elseif ($MenuChoice -eq "1") {
    Write-Host "`n--- Manual Network Configuration (Management Domain Bring-up) ---" -ForegroundColor Cyan
    Write-Host "`n--- Manual vMotion Network Configuration ---" -ForegroundColor Cyan
    $vmoVlan    = Read-Host "Enter vMotion VLAN ID"
    $vmoGateway = Read-Host "Enter vMotion Gateway IP"
    $vmoMask    = Read-Host "Enter vMotion Subnet Mask"
    $vmoStart   = Read-Host "Enter vMotion Free IP Start"
    $vmoEnd     = Read-Host "Enter vMotion Free IP End"
    $vmoBase    = $vmoStart.Substring(0, $vmoStart.LastIndexOf('.') + 1)
    $vmoIps     = foreach ($o in ([int]$vmoStart.Split('.')[-1])..([int]$vmoEnd.Split('.')[-1])) { "${vmoBase}$o" }
    $NetworkConfigs += [PSCustomObject]@{ Name = "vMotion"; VLAN = $vmoVlan; Mask = $vmoMask; Gateway = $vmoGateway; FreeIps = $vmoIps }

    Write-Host "`n--- Manual VSAN Network Configuration ---" -ForegroundColor Cyan
    $vsanVlan    = Read-Host "Enter vSAN VLAN ID"
    $vsanGateway = Read-Host "Enter vSAN Gateway IP"
    $vsanMask    = Read-Host "Enter vSAN Subnet Mask"
    $vsanStart   = Read-Host "Enter vSAN Free IP Start"
    $vsanEnd     = Read-Host "Enter vSAN Free IP End"
    $vsanBase    = $vsanStart.Substring(0, $vsanStart.LastIndexOf('.') + 1)
    $vsanIps     = foreach ($o in ([int]$vsanStart.Split('.')[-1])..([int]$vsanEnd.Split('.')[-1])) { "${vsanBase}$o" }
    $NetworkConfigs += [PSCustomObject]@{ Name = "vSAN"; VLAN = $vsanVlan; Mask = $vsanMask; Gateway = $vsanGateway; FreeIps = $vsanIps }
}

# --- [TEP Manual Input] ---
Write-Host "`n--- Manual TEP Network Configuration ---" -ForegroundColor Cyan
$tepVlan    = Read-Host "Enter TEP VLAN ID"
$tepGateway = Read-Host "Enter TEP Gateway IP"
$tepMask    = Read-Host "Enter TEP Subnet Mask"
$tepStart    = Read-Host "Enter TEP Free IP Start"
$tepEnd      = Read-Host "Enter TEP Free IP End"

$tepBase    = $tepStart.Substring(0, $tepStart.LastIndexOf('.') + 1)
$startOctet = [int]$tepStart.Split('.')[-1]
$endOctet   = [int]$tepEnd.Split('.')[-1]
$tepIps     = foreach ($o in $startOctet..$endOctet) { "${tepBase}$o" }

$NetworkConfigs += [PSCustomObject]@{ Name = "NSX_TEP"; VLAN = $tepVlan; Mask = $tepMask; Gateway = $tepGateway; FreeIps = $tepIps }

# --- [Gateway Ping Choice] ---
$PingGwChoice = Read-Host "`nDo you want to ping vMotion and vSAN gateways? (y/n)"

# --- [2] User Input & File Validation ---
$HostListFile = Read-Host "`nEnter the full path to your ESXi hosts txt file"
if (-not (Test-Path -Path $HostListFile)) { Write-Host "[ERROR] File not found: $HostListFile" -ForegroundColor Red; exit }

$Hosts = Get-Content $HostListFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
if ($Hosts.Count -eq 0) { Write-Host "[ERROR] The host file is empty." -ForegroundColor Red; exit }

foreach ($Net in $NetworkConfigs) {
    if ($Net.FreeIps.Count -lt $Hosts.Count) {
        Write-Host "`n[ERROR] Not enough free IPs for network: $($Net.Name)" -ForegroundColor Red
        Write-Host "Required: $($Hosts.Count) | Available: $($Net.FreeIps.Count)" -ForegroundColor Yellow
        exit
    }
}

$User = "root"
$Password = Read-Host "Enter ESXi root password" -AsSecureString
$PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))

$vSwitchName = "vSwitch0"; $DummyPGName = "TEMP-PRECHECK-PG"; $MTU_Target = 8900
$TestResults = New-Object System.Collections.Generic.List[PSObject]
$ConnectionMap = @{} ; $MgmtIpMap = [ordered]@{}

# --- [3] Connect and Initial MTU Check ---
Write-Host "`n>>> CONNECTING AND VERIFYING MTU 9000 <<<" -ForegroundColor Cyan
$firstHost = $true
foreach ($HName in $Hosts) {
    try {
        $IP = [System.Net.Dns]::GetHostAddresses($HName).IPAddressToString | Select-Object -First 1
        $MgmtIpMap[$HName] = $IP
        $conn = Connect-VIServer -Server $IP -User $User -Password $PlainPassword -ErrorAction Stop
        $ConnectionMap[$HName] = $conn
        $vmhost = Get-VMHost -Server $conn
        $vSwitch = Get-VirtualSwitch -VMHost $vmhost -Name $vSwitchName
        if ($vSwitch.Mtu -ne 9000) {
            Write-Host "Updating MTU on ${HName} to 9000..." -ForegroundColor Yellow
            $vSwitch | Set-VirtualSwitch -Mtu 9000 -Confirm:$false | Out-Null
        }
        $firstHost = $false
    } catch { 
        if ($firstHost) { Write-Host "`n[FATAL ERROR] Failed to connect to first host." -ForegroundColor Red; exit }
        else { Write-Warning "Could not connect to $HName" }
    }
}

# --- [4] Management Network Redundancy ---
Write-Host "`n>>> VALIDATING MANAGEMENT NETWORK REDUNDANCY (vmk0) <<<" -ForegroundColor Cyan -BackgroundColor DarkBlue
foreach ($HName in $Hosts) {
    $conn = $ConnectionMap[$HName]
    if ($conn) {
        $vmhost = Get-VMHost -Server $conn
        $vSwitch = Get-VirtualSwitch -VMHost $vmhost -Name $vSwitchName
        if ($vSwitch.Nic -notcontains "vmnic1") {
            $vmnic1 = Get-VMHostNetworkAdapter -VMHost $vmhost -Physical -Name "vmnic1"
            Add-VirtualSwitchPhysicalNetworkAdapter -VirtualSwitch $vSwitch -VMHostPhysicalNic $vmnic1 -Confirm:$false | Out-Null
        }
        $mgmtPG = Get-VirtualPortGroup -VMHost $vmhost | Where-Object { $_.Name -eq (Get-VMHostNetworkAdapter -VMHost $vmhost -Name "vmk0").PortGroupName }
        $mgmtPG | Get-NicTeamingPolicy | Set-NicTeamingPolicy -MakeNicActive "vmnic1" -MakeNicStandby "vmnic0" -Confirm:$false | Out-Null
    }
}
Start-Sleep -Seconds 15

for ($i = 0; $i -lt $Hosts.Count; $i++) {
    $Source = $Hosts[$i]; $DestIP = $MgmtIpMap[$Hosts[($i + 1) % $Hosts.Count]]
    if ($ConnectionMap[$Source]) {
        $vmhost = Get-VMHost -Server $ConnectionMap[$Source]; $esxcli = Get-EsxCli -VMHost $vmhost -V2
        $params = $esxcli.network.diag.ping.CreateArgs(); $params.host = $DestIP; $params.count = 2
        try { $res = @($esxcli.network.diag.ping.Invoke($params)) | Select-Object -First 1; $status = ($res.Summary.received -gt 0) ? "PASS" : "FAIL" } catch { $status = "ERROR" }
        $TestResults.Add([PSCustomObject]@{ Network="Management"; VLAN="Mgmt"; Source=$Source; DestinationType="Peer"; DestinationIP=$DestIP; Uplink="vmnic1"; Status=$status })
        Write-Host "MGMT: ${Source} -> ${DestIP} via vmnic1: ${status}"
    }
}

Write-Host "Restoring Mgmt to vmnic0 Active..." -ForegroundColor Yellow
foreach ($HName in $Hosts) {
    $conn = $ConnectionMap[$HName]
    if ($conn) {
        $vmhost = Get-VMHost -Server $conn
        $mgmtPGName = (Get-VMHostNetworkAdapter -VMHost $vmhost -Name "vmk0").PortGroupName
        Get-VirtualPortGroup -VMHost $vmhost -Name $mgmtPGName | Get-NicTeamingPolicy | Set-NicTeamingPolicy -MakeNicActive "vmnic0" -MakeNicStandby "vmnic1" -Confirm:$false | Out-Null
    }
}

# --- [5] Iterative Traffic Testing ---
foreach ($Net in $NetworkConfigs) {
    Write-Host "`n>>> SETUP PHASE: $($Net.Name) (VLAN $($Net.VLAN)) <<<" -ForegroundColor Cyan -BackgroundColor DarkBlue
    $HostNetworkMap = [ordered]@{}
    for ($i=0; $i -lt $Hosts.Count; $i++) {
        $ESXi = $Hosts[$i]; $TargetIP = $Net.FreeIps[$i]; $HostNetworkMap[$ESXi] = $TargetIP
        $conn = $ConnectionMap[$ESXi]
        if ($conn) {
            try {
                $vmhost = Get-VMHost -Server $conn
                $vSwitch = Get-VirtualSwitch -VMHost $vmhost -Name $vSwitchName
                Write-Host "Creating $DummyPGName on $ESXi..." -ForegroundColor Gray
                New-VirtualPortGroup -VirtualSwitch $vSwitch -Name $DummyPGName -VLanID $Net.VLAN | Out-Null
                Write-Host "Configuring $DummyPGName on $ESXi [VLAN: $($Net.VLAN) | IP: $TargetIP]..." -ForegroundColor Yellow
                Get-VirtualPortGroup -VMHost $vmhost -Name $DummyPGName | Get-NicTeamingPolicy | Set-NicTeamingPolicy -LoadBalancingPolicy ExplicitFailover -MakeNicActive "vmnic0" -MakeNicStandby "vmnic1" -Confirm:$false | Out-Null
                New-VMHostNetworkAdapter -VMHost $vmhost -VirtualSwitch $vSwitchName -PortGroup $DummyPGName -IP $TargetIP -SubnetMask $Net.Mask -Mtu $MTU_Target -Confirm:$false | Out-Null
            } catch { Write-Warning "Setup failed for $ESXi" }
        }
    }

    function Run-PingTestInternal {
        param($Active, $Standby, $NetObj, $TargetMap, $GwChoice)
        Write-Host "`n --- TEST: ${Active} ACTIVE | Network: $($NetObj.Name) ---" -ForegroundColor Cyan
        foreach ($h in $Hosts) { 
            if ($ConnectionMap[$h]) { Get-VirtualPortGroup -VMHost (Get-VMHost -Server $ConnectionMap[$h]) -Name $DummyPGName | Get-NicTeamingPolicy | Set-NicTeamingPolicy -MakeNicActive $Active -MakeNicStandby $Standby -Confirm:$false | Out-Null }
        }
        Start-Sleep -Seconds 10
        for ($i = 0; $i -lt $Hosts.Count; $i++) {
            $Source = $Hosts[$i]; $DestIP = $TargetMap[$Hosts[($i + 1) % $Hosts.Count]]
            if ($ConnectionMap[$Source]) {
                $vmhost = Get-VMHost -Server $ConnectionMap[$Source]; $esxcli = Get-EsxCli -VMHost $vmhost -V2
                $params = $esxcli.network.diag.ping.CreateArgs(); $params.host = $DestIP; $params.interface = "vmk1"; $params.size = 8872; $params.df = $true
                try { $res = @($esxcli.network.diag.ping.Invoke($params)) | Select-Object -First 1; $status = ($res.Summary.received -gt 0) ? "PASS" : "FAIL" } catch { $status = "ERROR" }
                $TestResults.Add([PSCustomObject]@{ Network=$NetObj.Name; VLAN=$NetObj.VLAN; Source=$Source; DestinationType="Peer"; DestinationIP=$DestIP; Uplink=$Active; Status=$status })
                Write-Host "${Source} -> ${DestIP} via ${Active}: ${status}"

                $ShouldPingGW = ($NetObj.Name -eq "NSX_TEP") -or ($GwChoice -eq "y" -and ($NetObj.Name -match "vMotion|vSAN"))
                if ($NetObj.Gateway -and $ShouldPingGW) {
                    $gParams = $esxcli.network.diag.ping.CreateArgs(); $gParams.host = $NetObj.Gateway; $gParams.interface = "vmk1"; $gParams.size = 8872; $gParams.df = $true
                    try { $gRes = @($esxcli.network.diag.ping.Invoke($gParams)) | Select-Object -First 1; $gStatus = ($gRes.Summary.received -gt 0) ? "PASS" : "FAIL" } catch { $gStatus = "ERROR" }
                    $TestResults.Add([PSCustomObject]@{ Network="$($NetObj.Name)_GW"; VLAN=$NetObj.VLAN; Source=$Source; DestinationType="Gateway"; DestinationIP=$NetObj.Gateway; Uplink=$Active; Status=$gStatus })
                    Write-Host "${Source} -> Gateway ($($NetObj.Gateway)) via ${Active}: ${gStatus}"
                }
            }
        }
    }

    Run-PingTestInternal -Active "vmnic0" -Standby "vmnic1" -NetObj $Net -TargetMap $HostNetworkMap -GwChoice $PingGwChoice
    Run-PingTestInternal -Active "vmnic1" -Standby "vmnic0" -NetObj $Net -TargetMap $HostNetworkMap -GwChoice $PingGwChoice

    foreach ($ESXi in $Hosts) {
        if ($ConnectionMap[$ESXi]) {
            try {
                $vmhost = Get-VMHost -Server $ConnectionMap[$ESXi]
                $vmk = Get-VMHostNetworkAdapter -VMHost $vmhost | Where-Object { $_.PortGroupName -eq $DummyPGName }
                if ($vmk) { 
                    Write-Host "Removing vmk adapter ($($vmk.Name)) from $ESXi..." -ForegroundColor Gray
                    $vmhost | Get-VMHostNetworkAdapter -VMKernel -Name $vmk.Name | Remove-VMHostNetworkAdapter -Confirm:$false | Out-Null 
                }
                Write-Host "Deleting temporary PortGroup ($DummyPGName) from $ESXi..." -ForegroundColor Gray
                Get-VirtualPortGroup -VMHost $vmhost -Name $DummyPGName | Remove-VirtualPortGroup -Confirm:$false | Out-Null
            } catch { }
        }
    }
}

# --- [6] Final Global Cleanup ---
Write-Host "`n[FINAL CLEANUP] Starting Cleanup and Service Verification..." -ForegroundColor Cyan
foreach ($ESXi in $Hosts) {
    try {
        $conn = $ConnectionMap[$ESXi]
        if ($conn) {
            $vmhost = Get-VMHost -Server $conn
            $vSwitch = Get-VirtualSwitch -VMHost $vmhost -Name $vSwitchName
            $OldMtu = $vSwitch.Mtu
            
            # --- Restoration of specific output format ---
            Write-Host "Resetting vSwitch0 from vSwitch0 on $ESXi ..." -ForegroundColor Gray
            $vSwitch | Set-VirtualSwitch -Mtu 1500 -Confirm:$false | Out-Null
            Write-Host "vSwitch0                $OldMtu       1500" -ForegroundColor Gray

            $sshStatus = Get-VMHostService -VMHost $vmhost | Where-Object {$_.Key -eq "TSM-SSH"}
            if ($sshStatus.Running -eq $false) { Start-VMHostService -HostService $sshStatus -Confirm:$false | Out-Null }
            
            $mgmtPGName = (Get-VMHostNetworkAdapter -VMHost $vmhost -Name "vmk0").PortGroupName
            Get-VirtualPortGroup -VMHost $vmhost -Name $mgmtPGName | Get-NicTeamingPolicy | Set-NicTeamingPolicy -MakeNicActive "vmnic0" -Confirm:$false | Out-Null
            
            if ($vSwitch.Nic -contains "vmnic1") { 
                # Re-restored specific cleanup message
                Write-Host "Removing vmnic1 from vSwitch0 on $ESXi..." -ForegroundColor Gray
                $vmhost | Get-VMHostNetworkAdapter -Physical -Name "vmnic1" | Remove-VirtualSwitchPhysicalNetworkAdapter -Confirm:$false | Out-Null 
            }
            
            Disconnect-VIServer -Server $conn -Confirm:$false | Out-Null
        }
    } catch { Write-Warning "Cleanup failed for $ESXi" }
}

$EndTime = Get-Date
$Duration = $EndTime - $StartTime
$ReportPath = Join-Path -Path $PSScriptRoot -ChildPath "SDDC_Validation_Report_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
$TestResults | Export-Csv -Path $ReportPath -NoTypeInformation

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " VALIDATION COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Report Path  : $ReportPath"
Write-Host "Total Time   : $($Duration.Minutes) Minutes, $($Duration.Seconds) Seconds" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
