#-----------Network Validation Report (Master Optimized v3.7)-------------------
$StartTime = Get-Date

# --- [0] Main Menu with Validation ---
while ($true) {
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host " VCF NETWORK PRE-CHECK UTILITY"
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "1. Bring up management Domain (Manual vMotion/vSAN)"
    Write-Host "2. Add additional workloads (SDDC Pool)"
    Write-Host "3. Exit"
    $MenuChoice = Read-Host "`nSelect an option (1, 2, or 3)"

    if ($MenuChoice -match "^[1-3]$") { break }
    Write-Host "[Invalid Input] Please enter 1, 2, or 3." -ForegroundColor Red
}

if ($MenuChoice -eq "3") { exit }

# --- [0.1] NIC Configuration Selection with Validation ---
while ($true) {
    Write-Host "`nSelect Number of Physical NICs:" -ForegroundColor Cyan
    Write-Host "1. Default (2 nics: vmnic0, vmnic1)"
    Write-Host "2. Multiple nics"
    $NicChoice = Read-Host "`nSelect an option (1 or 2)"

    if ($NicChoice -match "^[1-2]$") { break }
    Write-Host "[Invalid Input] Please enter 1 or 2." -ForegroundColor Red
}

$NicMap = @{}
if ($NicChoice -eq "2") {
    $NicMap["Mgmt"]    = Read-Host "Additional nic for Mgmt Network (e.g., vmnic2)"
    $NicMap["vMotion"] = (Read-Host "NICS for VMotion Network (e.g., vmnic2,vmnic3)").Split(',').Trim()
    $NicMap["vSAN"]    = (Read-Host "NICS for VSAN Network (e.g., vmnic4,vmnic5)").Split(',').Trim()
    $NicMap["NSX_TEP"] = (Read-Host "NICS for NSX_TEP Network (e.g., vmnic6,vmnic7)").Split(',').Trim()
} else {
    $NicMap["Mgmt"]    = "vmnic1"
    $NicMap["vMotion"] = @("vmnic0", "vmnic1")
    $NicMap["vSAN"]    = @("vmnic0", "vmnic1")
    $NicMap["NSX_TEP"] = @("vmnic0", "vmnic1")
}

$AllRequiredNics = ($NicMap.Values | ForEach-Object { $_ }) | Select-Object -Unique | Where-Object { $_ -ne "" }
$NetworkConfigs = @()

# --- [1] Network Data Retrieval ---
if ($MenuChoice -eq "2") {
    $sddcFqdn = Read-Host "Enter SDDC Manager FQDN"
    $sddcUser = Read-Host "Enter SDDC Manager username"
    $sddcPass = Read-Host "Enter SDDC Manager password" -AsSecureString
    $PlainSddcPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sddcPass))
    $networkPoolName = Read-Host "Enter network pool name"

    function Get-SddcAuthToken {
        param ($Fqdn, $User, $Pass)
        try {
            $TokenUrl = "https://${Fqdn}/v1/tokens"
            $Body = @{ username = $User; password = $Pass } | ConvertTo-Json
            $Resp = Invoke-RestMethod -Uri $TokenUrl -Method Post -Body $Body -ContentType "application/json" -SkipCertificateCheck
            return $Resp.accessToken
        } catch {
            if ($_.Exception.Message -match "401" -or $_.ErrorDetails.Message -match "IDENTITY_UNAUTHORIZED_ENTITY") {
                Write-Host "`n[FATAL ERROR] SDDC Manager Credentials: User '${User}' is not authorized." -ForegroundColor Red
            } else {
                Write-Host "`n[FATAL ERROR] Failed to connect to SDDC Manager: $($_.Exception.Message)" -ForegroundColor Red
            }
            exit
        }
    }

    $Token = Get-SddcAuthToken -Fqdn $sddcFqdn -User $sddcUser -Pass $PlainSddcPass
    $AuthHeader = @{ "Authorization" = "Bearer ${Token}"; "Content-Type" = "application/json" }
    
    $PoolsUrl = "https://${sddcFqdn}/v1/network-pools"
    $ApiResponse = Invoke-RestMethod -Uri $PoolsUrl -Method Get -Headers $AuthHeader -SkipCertificateCheck
    $TargetPool = $ApiResponse.elements | Where-Object { $_.name -eq $networkPoolName }
    
    if ($null -eq $TargetPool) {
        Write-Host "`n[FATAL ERROR] Network Pool '${networkPoolName}' not found in SDDC Manager." -ForegroundColor Red
        $ApiResponse.elements | ForEach-Object { Write-Host " - $($_.name)" }
        exit
    }

    try {
        $NetDetailsUrl = "https://${sddcFqdn}/v1/network-pools/$($TargetPool.id)/networks"
        $NetResponse = Invoke-RestMethod -Uri $NetDetailsUrl -Method Get -Headers $AuthHeader -SkipCertificateCheck
        
        foreach ($net in $NetResponse.elements) {
            $NetworkConfigs += [PSCustomObject]@{ Name=$net.type; VLAN=$net.vlanId; Mask=$net.mask; Gateway=$net.gateway; FreeIps=$net.freeIps; Nics=$NicMap[$net.type] }
        }
    } catch {
        Write-Host "`n[FATAL ERROR] Could not retrieve network details for pool: $($TargetPool.name)" -ForegroundColor Red
        exit
    }
}
elseif ($MenuChoice -eq "1") {
    Write-Host "`n--- Manual Network Configuration ---" -ForegroundColor Cyan
    foreach ($type in @("vMotion", "vSAN")) {
        Write-Host "--- ${type} Configuration ---" -ForegroundColor Cyan
        $vlan = Read-Host "VLAN ID"; $gw = Read-Host "Gateway"; $mask = Read-Host "Mask"; $start = Read-Host "IP Start"; $end = Read-Host "IP End"
        $base = $start.Substring(0, $start.LastIndexOf('.') + 1)
        $ips = foreach ($o in ([int]$start.Split('.')[-1])..([int]$end.Split('.')[-1])) { "${base}${o}" }
        $NetworkConfigs += [PSCustomObject]@{ Name=$type; VLAN=$vlan; Mask=$mask; Gateway=$gw; FreeIps=$ips; Nics=$NicMap[$type] }
    }
}

Write-Host "`n--- Manual TEP Configuration ---" -ForegroundColor Cyan
$tVlan = Read-Host "TEP VLAN"; $tGw = Read-Host "TEP Gateway"; $tMask = Read-Host "TEP Mask"; $tStart = Read-Host "TEP IP Start"; $tEnd = Read-Host "TEP IP End"
$tBase = $tStart.Substring(0, $tStart.LastIndexOf('.') + 1)
$tIps = foreach ($o in ([int]$tStart.Split('.')[-1])..([int]$tEnd.Split('.')[-1])) { "${tBase}${o}" }
$NetworkConfigs += [PSCustomObject]@{ Name="NSX_TEP"; VLAN=$tVlan; Mask=$tMask; Gateway=$tGw; FreeIps=$tIps; Nics=$NicMap["NSX_TEP"] }

$PingGwChoice = Read-Host "`nDo you want to ping vMotion and vSAN gateways? (y/n)"
$EdgePingChoice = Read-Host "Do you want to ping Edge TEPs? (y/n)"
if ($EdgePingChoice -eq "y") {
    $EdgeTEPs = @()
    $EdgeTEPs += Read-Host "Enter Edge Node 1 - TEP IP 1"
    $EdgeTEPs += Read-Host "Enter Edge Node 1 - TEP IP 2"
    $EdgeTEPs += Read-Host "Enter Edge Node 2 - TEP IP 1"
    $EdgeTEPs += Read-Host "Enter Edge Node 2 - TEP IP 2"
}

$HostListFile = Read-Host "`nEnter path to ESXi hosts file"
if (-not (Test-Path -Path $HostListFile)) { Write-Host "[ERROR] File not found: ${HostListFile}" -ForegroundColor Red; exit }
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
$ESXiPassSecure = Read-Host "Enter ESXi root password" -AsSecureString
$PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ESXiPassSecure))

$vSwitchName = "vSwitch0"; $DummyPGName = "TEMP-PRECHECK-PG"; $MTU_Target = 8900
$TestResults = New-Object System.Collections.Generic.List[PSObject]
$ConnectionMap = @{} ; $MgmtIpMap = [ordered]@{}

# --- [3] Connect & Physical NIC Validation ---
Write-Host "`n>>> CONNECTING AND VALIDATING HARDWARE <<<" -ForegroundColor Cyan
foreach ($HName in $Hosts) {
    try {
        $IP = [System.Net.Dns]::GetHostAddresses($HName).IPAddressToString | Select-Object -First 1
        $MgmtIpMap[$HName] = $IP
        $conn = try { Connect-VIServer -Server $IP -User $User -Password $PlainPassword -ErrorAction Stop } catch {
            Write-Host "`n[FATAL ERROR] Could not connect to ${HName}: $($_.Exception.Message)" -ForegroundColor Red
            exit
        }
        $ConnectionMap[$HName] = $conn
        $vmhost = Get-VMHost -Server $conn
        $AvailableNicNames = (Get-VMHostNetworkAdapter -VMHost $vmhost -Physical).Name
        foreach ($ReqNic in $AllRequiredNics) {
            if ($AvailableNicNames -notcontains $ReqNic) {
                Write-Host "`n[FATAL ERROR] Host: ${HName} is missing required NIC: ${ReqNic}" -ForegroundColor Red
                exit
            }
        }
        $vSwitch = Get-VirtualSwitch -VMHost $vmhost -Name $vSwitchName
        if ($vSwitch.Mtu -ne 9000) {
            Write-Host "Updating MTU on ${HName} to 9000..." -ForegroundColor Yellow
            $vSwitch | Set-VirtualSwitch -Mtu 9000 -Confirm:$false | Out-Null
        }
        foreach ($nicName in ($AllRequiredNics | Where-Object { $_ -ne "vmnic0" })) {
            if ($vSwitch.Nic -notcontains $nicName) {
                Add-VirtualSwitchPhysicalNetworkAdapter -VirtualSwitch $vSwitch -VMHostPhysicalNic (Get-VMHostNetworkAdapter -VMHost $vmhost -Physical -Name $nicName) -Confirm:$false | Out-Null
            }
        }
    } catch { Write-Warning "Problem connecting to ${HName}" }
}

# --- [4] Management Redundancy Test ---
$targetMgmtNic = $NicMap["Mgmt"]
Write-Host "`n>>> VALIDATING MANAGEMENT NETWORK REDUNDANCY (vmk0) <<<" -ForegroundColor Cyan -BackgroundColor DarkBlue
foreach ($HName in $Hosts) {
    if ($ConnectionMap[$HName]) {
        $vmhost = Get-VMHost -Server $ConnectionMap[$HName]
        $pgName = (Get-VMHostNetworkAdapter -VMHost $vmhost -Name "vmk0").PortGroupName
        Get-VirtualPortGroup -VMHost $vmhost -Name $pgName | Get-NicTeamingPolicy | Set-NicTeamingPolicy -MakeNicActive $targetMgmtNic -MakeNicStandby "vmnic0" -Confirm:$false | Out-Null
    }
}
Start-Sleep -Seconds 10
for ($i = 0; $i -lt $Hosts.Count; $i++) {
    $Source = $Hosts[$i]; $DestIP = $MgmtIpMap[$Hosts[($i + 1) % $Hosts.Count]]
    if ($ConnectionMap[$Source]) {
        $esxcli = Get-EsxCli -VMHost (Get-VMHost -Server $ConnectionMap[$Source]) -V2
        $p = $esxcli.network.diag.ping.CreateArgs(); $p.host = $DestIP; $p.count = 2
        $res = try { $esxcli.network.diag.ping.Invoke($p) | Select-Object -First 1 } catch { $null }
        $status = ($res.Summary.received -gt 0) ? "PASS" : "FAIL"
        $TestResults.Add([PSCustomObject]@{ Network="Management"; Source=$Source; DestinationIP=$DestIP; Uplink=$targetMgmtNic; Status=$status })
        Write-Host "MGMT: ${Source} -> ${DestIP} via ${targetMgmtNic}: ${status}"
    }
}

Write-Host "Restoring Mgmt to vmnic0 Active..." -ForegroundColor Yellow
foreach ($HName in $Hosts) {
    if ($ConnectionMap[$HName]) {
        $vmhost = Get-VMHost -Server $ConnectionMap[$HName]
        $pgName = (Get-VMHostNetworkAdapter -VMHost $vmhost -Name "vmk0").PortGroupName
        Get-VirtualPortGroup -VMHost $vmhost -Name $pgName | Get-NicTeamingPolicy | Set-NicTeamingPolicy -MakeNicActive "vmnic0" -MakeNicStandby $targetMgmtNic -Confirm:$false | Out-Null
    }
}

# --- [5] Traffic Testing ---
foreach ($Net in $NetworkConfigs) {
    Write-Host "`n>>> SETUP PHASE: $($Net.Name) (VLAN $($Net.VLAN)) <<<" -ForegroundColor Cyan -BackgroundColor DarkBlue
    $activeNic = $Net.Nics[0]
    $standbyNic = if ($Net.Nics.Count -gt 1) { $Net.Nics[1] } else { $null }

    for ($i=0; $i -lt $Hosts.Count; $i++) {
        $ESXi = $Hosts[$i]; $TargetIP = $Net.FreeIps[$i]
        if ($ConnectionMap[$ESXi]) {
            $vmhost = Get-VMHost -Server $ConnectionMap[$ESXi]
            $vSwitch = Get-VirtualSwitch -VMHost $vmhost -Name $vSwitchName
            Write-Host "Creating ${DummyPGName} on ${ESXi}..." -ForegroundColor Gray
            New-VirtualPortGroup -VirtualSwitch $vSwitch -Name $DummyPGName -VLanID $Net.VLAN -Confirm:$false | Out-Null
            Write-Host "Configuring ${DummyPGName} on ${ESXi} [VLAN: $($Net.VLAN) | IP: ${TargetIP}]..." -ForegroundColor Yellow
            
            # --- TEP GATEWAY OVERRIDE LOGIC (ESXCLI V2) ---
            if ($Net.Name -eq "NSX_TEP") {
                $esxcli = Get-EsxCli -VMHost $vmhost -V2
                # Step 1: Create Interface
                $addArgs = $esxcli.network.ip.interface.add.CreateArgs()
                $addArgs.interfacename = "vmk1"
                $addArgs.portgroupname = $DummyPGName
                $addArgs.mtu = $MTU_Target
                $esxcli.network.ip.interface.add.Invoke($addArgs) | Out-Null
                
                # Step 2: Set IP and Gateway
                $ipArgs = $esxcli.network.ip.interface.ipv4.set.CreateArgs()
                $ipArgs.interfacename = "vmk1"
                $ipArgs.type = "static"
                $ipArgs.ipv4 = $TargetIP
                $ipArgs.netmask = $Net.Mask
                $ipArgs.gateway = $Net.Gateway
                $esxcli.network.ip.interface.ipv4.set.Invoke($ipArgs) | Out-Null
            } else {
                New-VMHostNetworkAdapter -VMHost $vmhost -VirtualSwitch $vSwitchName -PortGroup $DummyPGName -IP $TargetIP -SubnetMask $Net.Mask -Mtu $MTU_Target -Confirm:$false | Out-Null
            }
        }
    }

    function Run-PingSubTest {
        param($Act, $Stb, $NetObj)
        Write-Host "`n --- TEST: ${Act} ACTIVE | Network: $($NetObj.Name) ---" -ForegroundColor Cyan
        foreach ($h in $Hosts) { if ($ConnectionMap[$h]) { Get-VirtualPortGroup -VMHost (Get-VMHost -Server $ConnectionMap[$h]) -Name $DummyPGName | Get-NicTeamingPolicy | Set-NicTeamingPolicy -MakeNicActive $Act -MakeNicStandby $Stb -Confirm:$false | Out-Null } }
        Start-Sleep -Seconds 10
        for ($i = 0; $i -lt $Hosts.Count; $i++) {
            $Src = $Hosts[$i]; $Dst = $NetObj.FreeIps[($i + 1) % $Hosts.Count]
            if ($ConnectionMap[$Src]) {
                $esxcli = Get-EsxCli -VMHost (Get-VMHost -Server $ConnectionMap[$Src]) -V2
                $p = $esxcli.network.diag.ping.CreateArgs(); $p.host = $Dst; $p.interface = "vmk1"; $p.size = 8872; $p.df = $true
                $resHost = try { if (($esxcli.network.diag.ping.Invoke($p) | Select-Object -First 1).Summary.received -gt 0) { "PASS" } else { "FAIL" } } catch { "ERROR" }
                $TestResults.Add([PSCustomObject]@{ Network=$NetObj.Name; Source=$Src; DestinationIP=$Dst; Uplink=$Act; Status=$resHost })
                Write-Host "  Host: ${Src} -> ${Dst}: ${resHost}"

                $ShouldPingGW = ($NetObj.Name -eq "NSX_TEP") -or ($PingGwChoice -eq "y" -and ($NetObj.Name -match "vMotion|vSAN"))
                if ($ShouldPingGW) {
                    $pgw = $esxcli.network.diag.ping.CreateArgs(); $pgw.host = $NetObj.Gateway; $pgw.interface = "vmk1"; $pgw.size = 8872; $pgw.df = $true
                    $resGw = try { if (($esxcli.network.diag.ping.Invoke($pgw) | Select-Object -First 1).Summary.received -gt 0) { "PASS" } else { "FAIL" } } catch { "ERROR" }
                    $TestResults.Add([PSCustomObject]@{ Network="$($NetObj.Name)_GW"; Source=$Src; DestinationIP=$NetObj.Gateway; Uplink=$Act; Status=$resGw })
                    Write-Host "  GW:   ${Src} -> $($NetObj.Gateway): ${resGw}"
                }

                if ($NetObj.Name -eq "NSX_TEP" -and $EdgePingChoice -eq "y") {
                    foreach ($Et in $EdgeTEPs) {
                        $pe = $esxcli.network.diag.ping.CreateArgs(); $pe.host = $Et; $pe.interface = "vmk1"; $pe.size = 8872; $pe.df = $true
                        $resEt = try { if (($esxcli.network.diag.ping.Invoke($pe) | Select-Object -First 1).Summary.received -gt 0) { "PASS" } else { "FAIL" } } catch { "ERROR" }
                        $TestResults.Add([PSCustomObject]@{ Network="Edge_TEP"; Source=$Src; DestinationIP=$Et; Uplink=$Act; Status=$resEt })
                        Write-Host "  Edge: ${Src} -> ${Et}: ${resEt}"
                    }
                }
            }
        }
    }

    Run-PingSubTest -Act $activeNic -Stb $standbyNic -NetObj $Net
    if ($standbyNic) { Run-PingSubTest -Act $standbyNic -Stb $activeNic -NetObj $Net }

    foreach ($h in $Hosts) {
        if ($ConnectionMap[$h]) {
            $vmh = Get-VMHost -Server $ConnectionMap[$h]
            $vmk = Get-VMHostNetworkAdapter -VMHost $vmh | Where { $_.PortGroupName -eq $DummyPGName }
            Write-Host "Removing vmk adapter ($($vmk.Name)) from ${h}..." -ForegroundColor Gray
            $vmh | Get-VMHostNetworkAdapter -VMKernel -Name $vmk.Name | Remove-VMHostNetworkAdapter -Confirm:$false | Out-Null
            Write-Host "Deleting temporary PortGroup (${DummyPGName}) from ${h}..." -ForegroundColor Gray
            Get-VirtualPortGroup -VMHost $vmh -Name $DummyPGName | Remove-VirtualPortGroup -Confirm:$false | Out-Null
        }
    }
}

# --- [6] Final Cleanup ---
Write-Host "`n>>> FINAL CLEANUP <<<" -ForegroundColor Cyan
foreach ($ESXi in $Hosts) {
    if ($ConnectionMap[$ESXi]) {
        $vmhost = Get-VMHost -Server $ConnectionMap[$ESXi]
        $vSwitch = Get-VirtualSwitch -VMHost $vmhost -Name $vSwitchName
        $OldMtu = $vSwitch.Mtu
        Write-Host "Resetting vSwitch0 MTU on ${ESXi} to 1500..." -ForegroundColor Gray
        $vSwitch | Set-VirtualSwitch -Mtu 1500 -Confirm:$false | Out-Null
        Write-Host "vSwitch0                ${OldMtu}       1500" -ForegroundColor Gray

        foreach ($nic in ($AllRequiredNics | Where-Object { $_ -ne "vmnic0" })) {
            if ($vSwitch.Nic -contains $nic) {
                Write-Host "Removing ${nic} from vSwitch0 on ${ESXi}..." -ForegroundColor Gray
                $vmhost | Get-VMHostNetworkAdapter -Physical -Name $nic | Remove-VirtualSwitchPhysicalNetworkAdapter -Confirm:$false | Out-Null
            }
        }
        Disconnect-VIServer -Server $ConnectionMap[$ESXi] -Confirm:$false | Out-Null
    }
}
$ReportPath = Join-Path -Path $PSScriptRoot -ChildPath "SDDC_Validation_Report_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
$TestResults | Export-Csv -Path $ReportPath -NoTypeInformation

# --- [7] Verification Summary ---
Write-Host "`n===============================================" -ForegroundColor Cyan
Write-Host " VERIFICATION SUMMARY"
Write-Host "===============================================" -ForegroundColor Cyan
$TestResults | Group-Object Status | Select-Object Name, Count | Format-Table -AutoSize
Write-Host "`nVALIDATION COMPLETE | Report: ${ReportPath}" -ForegroundColor Green
Write-Host "===============================================" -ForegroundColor Cyan
