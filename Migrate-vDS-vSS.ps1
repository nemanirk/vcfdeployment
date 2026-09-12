# ==============================================================================
# SCRIPT: vDS to vSS Migration (Audit, Replicate, Remove NICs, Migrate VMKs)
# ==============================================================================
# Requires: VMware.PowerCLI module

# --- [ HELPER FUNCTION: UNIVERSAL LOGGER ] ---
function Write-Log {
    param (
        [string]$Message,
        [string]$Color = "White"
    )
    # Print to console
    Write-Host $Message -ForegroundColor $Color
    
    # Append to log file if defined
    if ($global:LogFilePath) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$timestamp] $Message" | Out-File -FilePath $global:LogFilePath -Append
    }
}

# --- [ HELPER FUNCTION: STRICT Y/N VALIDATION ] ---
function Read-YesNo {
    param ([string]$PromptMessage)
    $userInput = ""
    do {
        $userInput = (Read-Host $PromptMessage).Trim().ToLower()
        if ($userInput -notin @('y', 'n')) {
            Write-Host "  [!] Invalid input. Please enter exactly 'y' or 'n'." -ForegroundColor Red
        }
    } while ($userInput -notin @('y', 'n'))
    
    Write-Log "  [USER INPUT] Question: '$PromptMessage' | Answer: '$userInput'" "DarkGray"
    return $userInput
}

# --- [ HELPER FUNCTION: VALIDATE MULTIPLE NIC NAMES & CONFIRM ] ---
function Read-NicNames {
    param ([array]$ValidNics)
    $selectedNics = @()
    $confirmed = $false
    
    do {
        $userInput = (Read-Host "Enter the exact name(s) of the vmnic(s) to remove (comma-separated, e.g., vmnic1, vmnic2)").Trim()
        if ([string]::IsNullOrWhiteSpace($userInput)) { continue }
        
        # Split by comma, trim spaces, and make lowercase
        $parsedNics = $userInput -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne "" }
        
        # Check for invalid entries
        $invalidNics = $parsedNics | Where-Object { $_ -notin $ValidNics }
        
        if ($invalidNics.Count -gt 0) {
            Write-Host "  [!] Invalid input. The following NIC(s) are not attached to this vDS: $($invalidNics -join ', ')" -ForegroundColor Red
            Write-Host "      Valid options for this switch: $($ValidNics -join ', ')" -ForegroundColor Yellow
            continue
        }
        
        # Display confirmation prompt
        $nicListStr = $parsedNics -join ', '
        $confirm = Read-YesNo -PromptMessage "  -> You selected: [$nicListStr]. Are you sure you want to proceed with these? (y/n)"
        
        if ($confirm -eq 'y') {
            $selectedNics = $parsedNics
            $confirmed = $true
            Write-Log "  [USER INPUT] Selected NIC(s): '$nicListStr'" "DarkGray"
        } else {
            Write-Host "  [INFO] Selection cancelled. Please re-enter the NIC(s)." -ForegroundColor Yellow
        }
        
    } while (-not $confirmed)
    
    return @($selectedNics)
}

# --- [ HELPER FUNCTION: VALIDATE VSS NAME ] ---
function Read-VssName {
    param ([array]$ValidVssList)
    $vssName = ""
    do {
        $vssName = (Read-Host "Enter the name of the target Standard Switch").Trim()
        if ($vssName -notin $ValidVssList) {
            Write-Host "  [!] Invalid selection. Please choose from: $($ValidVssList -join ', ')" -ForegroundColor Red
        }
    } while ($vssName -notin $ValidVssList)
    
    Write-Log "  [USER INPUT] Selected Switch: '$vssName'" "DarkGray"
    return $vssName
}

# --- [ 1. CONNECT TO VCENTER ] ---
if ($global:DefaultVIServers) {
    $global:DefaultVIServers | Disconnect-VIServer -Force -Confirm:$false -ErrorAction SilentlyContinue
}
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

$vcServer = Read-Host "Enter vCenter Server FQDN or IP"
$vcConn = Connect-VIServer -Server $vcServer -Force -WarningAction SilentlyContinue

if (-not $vcConn) {
    Write-Error "[FATAL] Failed to connect to vCenter."
    exit
}

# --- [ 2. GATHER CLUSTER & DEFINE LOGGING ] ---
$clusterName = Read-Host "Enter the target Cluster name"
$fileTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$global:LogFilePath = ".\$($clusterName)_vDS_Migration_Audit_$fileTimestamp.txt"

@"
======================================================================
 ADVANCED vDS AUDIT & MIGRATION LOG
 Cluster    : $clusterName
 vCenter    : $vcServer
 Generated  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
======================================================================
"@ | Out-File -FilePath $global:LogFilePath -Force

Write-Log "`n>>> Target Cluster: $clusterName" "Cyan"

$cluster = Get-Cluster -Name $clusterName -Server $vcConn -ErrorAction Stop
$hosts = Get-VMHost -Location $cluster -Server $vcConn | Where-Object { $_.ConnectionState -eq "Connected" }

if ($hosts.Count -eq 0) {
    Write-Log "[FATAL] No connected hosts found in cluster '$clusterName'." "Red"
    Disconnect-VIServer -Server $vcConn -Confirm:$false
    exit
}

$vdsList = $hosts | Get-VDSwitch -Server $vcConn | Select-Object -Unique

if (-not $vdsList) {
    Write-Log "[WARNING] No Distributed Switches found attached to the hosts in '$clusterName'." "Yellow"
    Disconnect-VIServer -Server $vcConn -Confirm:$false
    exit
}

# --- [ 2.1. LOCATE VCENTER VM DETAILS & PROTECT ACTIVE NICS ] ---
Write-Log "`n>>> Locating vCenter Server VM & Active Uplinks..." "Cyan"
$vcUuid = $vcConn.ExtensionData.Content.About.InstanceUuid
$vcVm = Get-View -ViewType VirtualMachine -Filter @{"Config.InstanceUuid" = $vcUuid}

if ($vcVm) {
    $vcHostView = Get-View -Id $vcVm.Runtime.Host -Property Name, Config.Network.ProxySwitch, Config.Network.Vswitch, Config.Network.Portgroup
    $vcDsView = Get-View -Id $vcVm.Datastore[0] -Property Name
    
    Write-Log "  [INFO] vCenter VM Name : $($vcVm.Name)" "Green"
    Write-Log "  [INFO] Running on Host : $($vcHostView.Name)" "Green"
    Write-Log "  [INFO] Stored on DS    : $($vcDsView.Name)" "Green"
    Write-Log "  [INFO] --- vCenter Network Connections ---" "Gray"
    
    foreach ($netMoRef in $vcVm.Network) {
        $netView = Get-View -Id $netMoRef
        
        if ($netView -is [VMware.Vim.DistributedVirtualPortgroup]) {
            $vdsUuid = (Get-View -Id $netView.Config.DistributedVirtualSwitch -Property Uuid).Uuid
            $activeUplinks = $netView.Config.DefaultPortConfig.UplinkTeamingPolicy.UplinkPortOrder.ActiveUplinkPort
            
            $proxy = $vcHostView.Config.Network.ProxySwitch | Where-Object { $_.DvsUuid -eq $vdsUuid }
            $vcActivePnics = @()
            
            if ($proxy) {
                foreach ($uplinkName in $activeUplinks) {
                    $portMapping = $proxy.UplinkPort | Where-Object { $_.Key -eq $uplinkName }
                    if ($portMapping) {
                        $portKey = $portMapping.Value
                        $pnicSpec = $proxy.Spec.Backing.PnicSpec | Where-Object { $_.UplinkPortKey -eq $portKey }
                        if ($pnicSpec) {
                            $vcActivePnics += $pnicSpec.PnicDevice
                        }
                    }
                }
            }
            
            $activeNicsStr = if ($vcActivePnics.Count -gt 0) { $vcActivePnics -join ', ' } else { "None / Disconnected" }
            Write-Log "  [INFO] Network : $($netView.Name) (vDS)" "Green"
            Write-Log "         -> ACTIVE VMNICS : $activeNicsStr" "Magenta"
            
        } 
        elseif ($netView -is [VMware.Vim.Network] -or $netView.GetType().Name -eq 'Network') {
            $pgName = $netView.Name
            $targetPg = $vcHostView.Config.Network.Portgroup | Where-Object { $_.Spec.Name -eq $pgName }
            if ($targetPg) {
                $vswitch = $vcHostView.Config.Network.Vswitch | Where-Object { $_.Name -eq $targetPg.Spec.VswitchName }
                if ($vswitch) {
                    $pnics = $vswitch.Pnic | ForEach-Object { $_ -replace '^.*-', '' }
                    $activeNicsStr = if ($pnics) { $pnics -join ', ' } else { "None / Disconnected" }
                    Write-Log "  [INFO] Network : $pgName (vSS)" "Green"
                    Write-Log "         -> ACTIVE VMNICS : $activeNicsStr" "Magenta"
                }
            }
        }
    }
    Write-Log "  [CAUTION] Do NOT remove the above active vmnics during Phase 2 to prevent vCenter disconnection." "Red"
} else {
    Write-Log "  [WARNING] Could not automatically locate the vCenter VM (May not be managed by this instance)." "Yellow"
}

$clusterVmkPgs = @()
foreach ($h in $hosts) {
    $clusterVmkPgs += Get-VMHostNetworkAdapter -VMHost $h -VMKernel -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PortGroupName
}
$clusterVmkPgs = $clusterVmkPgs | Select-Object -Unique

# ==============================================================================
# PHASE 1: AUDIT & REPLICATE TO STANDARD SWITCHES (VM PORTGROUPS ONLY)
# ==============================================================================
Write-Log "`n===========================================================" "White"
Write-Log ">>> PHASE 1: vDS AUDIT & STANDARD SWITCH REPLICATION" "Green"
Write-Log "===========================================================" "White"

foreach ($vds in $vdsList) {
    Write-Log "`n-----------------------------------------------------------" "White"
    Write-Log " FOUND vDS: $($vds.Name)" "Cyan"
    Write-Log "-----------------------------------------------------------" "White"
    
    $dpgs = Get-VDPortgroup -VDSwitch $vds -Server $vcConn | Where-Object { $_.IsUplink -eq $false } | Sort-Object Name
    
    $createVss = Read-YesNo -PromptMessage "`nDo you want to create a Standard Switch to replicate '$($vds.Name)'? (y/n)"
    
    if ($createVss -eq 'y') {
        $vssName = Read-Host "Enter the name for the new Standard Switch (e.g., vSwitch1)"
        $repPg = Read-YesNo -PromptMessage "Do you want to replicate the VM portgroups? (y/n)"
        
        Write-Log "`n>>> Starting replication across cluster hosts..." "Cyan"
        
        foreach ($h in $hosts) {
            $vdsPgNames = $dpgs | Select-Object -ExpandProperty Name
            $attachedNics = Get-VMHostNetworkAdapter -VMHost $h -DistributedSwitch $vds -Physical -ErrorAction SilentlyContinue
            $attachedVmks = Get-VMHostNetworkAdapter -VMHost $h -VMKernel -ErrorAction SilentlyContinue | Where-Object { $_.PortGroupName -in $vdsPgNames }
            
            if ($attachedNics -or $attachedVmks) {
                $vss = Get-VirtualSwitch -VMHost $h -Name $vssName -ErrorAction SilentlyContinue
                if (-not $vss) {
                    Write-Log " [Host: $($h.Name)] Creating Standard Switch: $vssName" "Yellow"
                    $vss = New-VirtualSwitch -VMHost $h -Name $vssName -Confirm:$false
                } else {
                    Write-Log " [Host: $($h.Name)] Standard Switch '$vssName' already exists. Skipping creation." "DarkGray"
                }

                if ($repPg -eq 'y') {
                    $vmOnlyPgs = $dpgs | Where-Object { $_.Name -notin $clusterVmkPgs }
                    
                    foreach ($dpg in $vmOnlyPgs) {
                        $vlanId = 0
                        if ($dpg.VlanConfiguration.GetType().Name -match "SingleVlan") { $vlanId = $dpg.VlanConfiguration.VlanId } 
                        elseif ($dpg.VlanConfiguration.GetType().Name -match "TrunkVlan") { $vlanId = 4095 }

                        $newPgName = "$($dpg.Name)-vss"
                        $existingPg = Get-VirtualPortGroup -VirtualSwitch $vss -Name $newPgName -ErrorAction SilentlyContinue
                        
                        if (-not $existingPg) {
                            Write-Log "   -> Creating VM Portgroup: $newPgName (VLAN: $vlanId)" "Green"
                            New-VirtualPortGroup -VirtualSwitch $vss -Name $newPgName -VLanId $vlanId -Confirm:$false | Out-Null
                        } else {
                            Write-Log "   -> VM Portgroup '$newPgName' already exists on $vssName. Skipping." "DarkGray"
                        }
                    }
                }
            }
        }
    } else {
        Write-Log "Skipping replication for $($vds.Name)..." "DarkGray"
    }
}

# ==============================================================================
# PHASE 2: PHYSICAL NIC REMOVAL VIA API (MULTI-NIC SUPPORTED)
# ==============================================================================
Write-Log "`n===========================================================" "White"
Write-Log ">>> PHASE 2: PHYSICAL NIC (UPLINK) REMOVAL" "Green"
Write-Log "===========================================================" "White"

$freedNicsList = @()

foreach ($vds in $vdsList) {
    Write-Log "`n-----------------------------------------------------------" "White"
    Write-Log ">>> Physical NIC Availability for vDS: $($vds.Name)" "Cyan"
    
    $hostNicMap = @{}
    $attachedHosts = @()
    $allUniqueNics = @()

    foreach ($h in $hosts) {
        $attachedNics = Get-VMHostNetworkAdapter -VMHost $h -DistributedSwitch $vds -Physical -ErrorAction SilentlyContinue
        
        if ($attachedNics) {
            $nicNames = $attachedNics.Name -join ", "
            $hostNicMap[$h.Name] = @($attachedNics.Name)
            $attachedHosts += $h
            $allUniqueNics += $attachedNics.Name
            Write-Log "  - $($h.Name) : $nicNames" "DarkGray"
        }
    }

    if ($hostNicMap.Keys.Count -eq 0) {
        Write-Log "  No hosts currently have physical adapters on this vDS." "Yellow"
        continue
    }

    $validNicOptions = $allUniqueNics | Select-Object -Unique | ForEach-Object { $_.ToLower() }
    $removeNic = Read-YesNo -PromptMessage "`nDo you want to safely remove vmnic(s) from '$($vds.Name)'? (y/n)"
    
    if ($removeNic -eq 'y') {
        # Fetch array of validated NICs
        $targetNics = Read-NicNames -ValidNics $validNicOptions
        $targetNicsStr = $targetNics -join ', '
        
        $removeAllHosts = Read-YesNo -PromptMessage "`nDo you want to remove [$targetNicsStr] from ALL hosts simultaneously? (y/n - 'n' will prompt per host)"
        
        Write-Log "`n>>> Processing detachment of [$targetNicsStr] for vDS '$($vds.Name)'..." "Cyan"
        $successfullyFreed = $false

        foreach ($hName in $hostNicMap.Keys) {
            # Check if this host has ANY of the target NICs
            $intersection = $hostNicMap[$hName] | Where-Object { $_ -in $targetNics }
            
            if ($intersection.Count -gt 0) {
                if ($removeAllHosts -eq 'n') {
                    $removeThisHost = Read-YesNo -PromptMessage "   -> [HOST: $hName] Remove [$targetNicsStr]? (y/n)"
                    if ($removeThisHost -eq 'n') {
                        Write-Log "      [SKIPPED] Left intact on $hName." "DarkGray"
                        continue
                    }
                } else {
                    Write-Log "   -> [HOST: $hName] Processing detachment..." "Yellow"
                }
                
                $hObj = $attachedHosts | Where-Object { $_.Name -eq $hName }
                $vds.ExtensionData.UpdateViewData("Config")
                
                $hostMoRef = $hObj.ExtensionData.MoRef
                $spec = New-Object VMware.Vim.DVSConfigSpec
                $tgthost = New-Object VMware.Vim.DistributedVirtualSwitchHostMemberConfigSpec
                $tgthost.Host = $hostMoRef
                $tgthost.Operation = "edit"

                $hostConfig = $vds.ExtensionData.Config.Host | Where-Object { $_.Config.Host.Value -eq $hostMoRef.Value }
                $currentBacking = $hostConfig.Config.Backing

                $tgthost.Backing = New-Object VMware.Vim.DistributedVirtualSwitchHostMemberPnicBacking
                # Filter out ALL selected NICs
                $tgthost.Backing.PnicSpec = @($currentBacking.PnicSpec | Where-Object { $_.PnicDevice -notin $targetNics })

                $spec.Host = $tgthost
                $spec.ConfigVersion = $vds.ExtensionData.Config.ConfigVersion

                try {
                    $taskMoRef = $vds.ExtensionData.ReconfigureDvs_Task($spec)
                    $task = Get-View $taskMoRef
                    
                    while ("running", "queued" -contains $task.Info.State) {
                        Start-Sleep -Seconds 2
                        $task.UpdateViewData("Info")
                    }
                    
                    if ($task.Info.State -eq "success") {
                        Write-Log "      [SUCCESS] Removed [$targetNicsStr]." "Green"
                        $successfullyFreed = $true
                    } else {
                        Write-Log "      [FAILED] $($task.Info.Error.LocalizedMessage)" "Red"
                    }
                }
                catch {
                    Write-Log "      [ERROR] $_" "Red"
                }
            }
        }
        if ($successfullyFreed) {
            foreach ($nic in $targetNics) {
                if ($nic -notin $freedNicsList) { $freedNicsList += $nic }
            }
        }
    }
}

# ==============================================================================
# PHASE 2.5: ASSIGN FREED NICS TO STANDARD SWITCH
# ==============================================================================
if ($freedNicsList.Count -gt 0) {
    Write-Log "`n===========================================================" "White"
    Write-Log ">>> PHASE 2.5: UPLINK ASSIGNMENT" "Green"
    Write-Log "===========================================================" "White"

    foreach ($freedNic in $freedNicsList) {
        $attachNic = Read-YesNo -PromptMessage "`nDo you want to assign the newly freed '$freedNic' as an uplink to a Standard Switch now? (y/n)"
        
        if ($attachNic -eq 'y') {
            $allVss = @()
            foreach ($h in $hosts) {
                $allVss += Get-VirtualSwitch -VMHost $h -Standard -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
            }
            $uniqueVss = $allVss | Select-Object -Unique

            if ($uniqueVss.Count -eq 0) {
                Write-Log "  [!] No Standard Switches found. Create one first." "Red"
                continue
            }

            Write-Log "  Available Standard Switches: $($uniqueVss -join ', ')" "Cyan"
            $targetVssName = Read-VssName -ValidVssList $uniqueVss

            Write-Log "`n>>> Assigning $freedNic to $targetVssName..." "Cyan"
            foreach ($h in $hosts) {
                $vssObj = Get-VirtualSwitch -VMHost $h -Name $targetVssName -ErrorAction SilentlyContinue
                $freePnicObj = Get-VMHostNetworkAdapter -VMHost $h -Physical -Name $freedNic -ErrorAction SilentlyContinue
                
                if ($vssObj -and $freePnicObj) {
                    try {
                        $existingUplinks = Get-VirtualSwitch -VMHost $h -Name $targetVssName | Get-VMHostNetworkAdapter -Physical -ErrorAction SilentlyContinue
                        if ($existingUplinks.Name -contains $freedNic) {
                            Write-Log "   -> [HOST: $($h.Name)] $freedNic is already attached to $targetVssName. Skipping." "DarkGray"
                        } else {
                            Add-VirtualSwitchPhysicalNetworkAdapter -VirtualSwitch $vssObj -VMHostPhysicalNic $freePnicObj -Confirm:$false | Out-Null
                            Write-Log "   -> [HOST: $($h.Name)] [SUCCESS] Attached $freedNic to $targetVssName." "Green"
                        }
                    } catch {
                        Write-Log "   -> [HOST: $($h.Name)] [FAILED] $($_.Exception.Message)" "Red"
                    }
                }
            }
        }
    }
}

# ==============================================================================
# PHASE 3: VMKERNEL ADAPTER MIGRATION
# ==============================================================================
Write-Log "`n===========================================================" "White"
Write-Log ">>> PHASE 3: VMKERNEL ADAPTER MIGRATION" "Green"
Write-Log "===========================================================" "White"

foreach ($vds in $vdsList) {
    Write-Log "`n-----------------------------------------------------------" "White"
    Write-Log ">>> VMkernel Adapters attached to vDS: $($vds.Name)" "Cyan"
    
    $vdsPgs = Get-VDPortgroup -VDSwitch $vds | Select-Object -ExpandProperty Name
    $allVdsVmks = @()
    
    foreach ($h in $hosts) {
        $vmks = Get-VMHostNetworkAdapter -VMHost $h -VMKernel -ErrorAction SilentlyContinue | Where-Object { $_.PortGroupName -in $vdsPgs }
        if ($vmks) { $allVdsVmks += $vmks }
    }

    if ($allVdsVmks.Count -eq 0) {
        Write-Log "  No VMkernel adapters found on this vDS." "Yellow"
        continue
    }

    $migrateVmks = Read-YesNo -PromptMessage "`nDo you want to migrate VMkernel adapters from '$($vds.Name)' to a Standard Switch? (y/n)"
    
    if ($migrateVmks -eq 'y') {
        $allVss = @()
        foreach ($h in $hosts) {
            $allVss += Get-VirtualSwitch -VMHost $h -Standard -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        }
        $uniqueVss = $allVss | Select-Object -Unique

        if ($uniqueVss.Count -eq 0) {
            Write-Log "  [!] No Standard Switches found on the hosts. Cannot migrate." "Red"
            continue
        }

        Write-Log "`nAvailable Standard Switches for Migration: $($uniqueVss -join ', ')" "Cyan"
        $targetVssName = Read-VssName -ValidVssList $uniqueVss

        foreach ($h in $hosts) {
            $hostVmks = Get-VMHostNetworkAdapter -VMHost $h -VMKernel -ErrorAction SilentlyContinue | Where-Object { $_.PortGroupName -in $vdsPgs }
            if (-not $hostVmks) { continue }

            $orderedVmks = $hostVmks | Sort-Object {
                if ($_.ManagementTrafficEnabled) { 1 }
                elseif ($_.VMotionEnabled) { 2 }
                elseif ($_.VsanTrafficEnabled) { 3 }
                else { 4 }
            }

            foreach ($vmk in $orderedVmks) {
                $trafficTypes = @()
                if ($vmk.ManagementTrafficEnabled) { $trafficTypes += "Management" }
                if ($vmk.VMotionEnabled) { $trafficTypes += "vMotion" }
                if ($vmk.VsanTrafficEnabled) { $trafficTypes += "vSAN" }
                if ($vmk.FaultToleranceLoggingEnabled) { $trafficTypes += "FT" }
                $trafficStr = if ($trafficTypes) { $trafficTypes -join ", " } else { "Other/Data" }

                $moveThis = Read-YesNo -PromptMessage "   -> [HOST: $($h.Name)] Migrate $($vmk.DeviceName) ($trafficStr) [PortGroup: $($vmk.PortGroupName)]? (y/n)"
                
                if ($moveThis -eq 'y') {
                    $targetVssObj = Get-VirtualSwitch -VMHost $h -Name $targetVssName -Standard -ErrorAction SilentlyContinue
                    $targetPgObj = Get-VirtualPortGroup -VirtualSwitch $targetVssObj -Name $vmk.PortGroupName -ErrorAction SilentlyContinue

                    if (-not $targetPgObj) {
                        Write-Log "      Port Group '$($vmk.PortGroupName)' not found on $targetVssName. Creating it dynamically..." "Yellow"
                        $sourceVdsPg = Get-VDPortgroup -VDSwitch $vds -Name $vmk.PortGroupName
                        
                        $vlanId = 0
                        if ($sourceVdsPg.VlanConfiguration.GetType().Name -match "SingleVlan") { $vlanId = $sourceVdsPg.VlanConfiguration.VlanId } 
                        elseif ($sourceVdsPg.VlanConfiguration.GetType().Name -match "TrunkVlan") { $vlanId = 4095 }
                        
                        $targetPgObj = New-VirtualPortGroup -VirtualSwitch $targetVssObj -Name $vmk.PortGroupName -VlanId $vlanId -Confirm:$false
                    }

                    if ($targetPgObj) {
                        try {
                            $vmkAdapterToMove = Get-VMHostNetworkAdapter -VMHost $h -Name $vmk.DeviceName
                            $netSys = Get-View $h.ExtensionData.ConfigManager.NetworkSystem
                            $nicSpec = $vmkAdapterToMove.ExtensionData.Spec
                            
                            $nicSpec.DistributedVirtualPort = $null
                            $nicSpec.Portgroup = $targetPgObj.Name
                            
                            $netSys.UpdateVirtualNic($vmkAdapterToMove.Name, $nicSpec)
                            Write-Log "      [SUCCESS] Migrated $($vmk.DeviceName) to $targetVssName." "Green"
                        } catch {
                            Write-Log "      [FAILED] $($_.Exception.Message)" "Red"
                        }
                    } else {
                        Write-Log "      [FAILED] Could not find or create Target PortGroup." "Red"
                    }
                } else {
                    Write-Log "      [SKIPPED] Left intact on $($h.Name)." "DarkGray"
                }
            }
        }
    } else {
        Write-Log "Skipping VMkernel migration for $($vds.Name)..." "DarkGray"
    }
}

# ==============================================================================
# PHASE 4: FINAL CLEANUP (REMAINING UPLINK MIGRATION)
# ==============================================================================
Write-Log "`n===========================================================" "White"
Write-Log ">>> PHASE 4: FINAL CLEANUP (REMAINING UPLINK MIGRATION)" "Green"
Write-Log "===========================================================" "White"

foreach ($vds in $vdsList) {
    Write-Log "`n-----------------------------------------------------------" "White"
    Write-Log ">>> Checking for leftover Physical NICs on vDS: $($vds.Name)" "Cyan"
    
    $hostNicMap = @{}
    $attachedHosts = @()
    $allUniqueNics = @()

    foreach ($h in $hosts) {
        $attachedNics = Get-VMHostNetworkAdapter -VMHost $h -DistributedSwitch $vds -Physical -ErrorAction SilentlyContinue
        
        if ($attachedNics) {
            $nicNames = $attachedNics.Name -join ", "
            $hostNicMap[$h.Name] = @($attachedNics.Name)
            $attachedHosts += $h
            $allUniqueNics += $attachedNics.Name
            Write-Log "  - $($h.Name) : $nicNames" "DarkGray"
        }
    }

    if ($hostNicMap.Keys.Count -eq 0) {
        Write-Log "  No physical adapters remaining on this vDS. It is fully cleared." "Green"
        continue
    }

    $validNicOptions = $allUniqueNics | Select-Object -Unique | ForEach-Object { $_.ToLower() }
    $removeNic = Read-YesNo -PromptMessage "`nDo you want to safely remove leftover vmnic(s) from '$($vds.Name)'? (y/n)"
    
    if ($removeNic -eq 'y') {
        $targetNics = Read-NicNames -ValidNics $validNicOptions
        $targetNicsStr = $targetNics -join ', '
        
        $removeAllHosts = Read-YesNo -PromptMessage "`nDo you want to remove [$targetNicsStr] from ALL hosts simultaneously? (y/n - 'n' will prompt per host)"
        
        Write-Log "`n>>> Processing final detachment of [$targetNicsStr] for vDS '$($vds.Name)'..." "Cyan"
        $successfullyFreed = $false

        foreach ($hName in $hostNicMap.Keys) {
            $intersection = $hostNicMap[$hName] | Where-Object { $_ -in $targetNics }
            
            if ($intersection.Count -gt 0) {
                if ($removeAllHosts -eq 'n') {
                    $removeThisHost = Read-YesNo -PromptMessage "   -> [HOST: $hName] Remove [$targetNicsStr]? (y/n)"
                    if ($removeThisHost -eq 'n') {
                        Write-Log "      [SKIPPED] Left intact on $hName." "DarkGray"
                        continue
                    }
                } else {
                    Write-Log "   -> [HOST: $hName] Processing detachment..." "Yellow"
                }
                
                $hObj = $attachedHosts | Where-Object { $_.Name -eq $hName }
                $vds.ExtensionData.UpdateViewData("Config")
                
                $hostMoRef = $hObj.ExtensionData.MoRef
                $spec = New-Object VMware.Vim.DVSConfigSpec
                $tgthost = New-Object VMware.Vim.DistributedVirtualSwitchHostMemberConfigSpec
                $tgthost.Host = $hostMoRef
                $tgthost.Operation = "edit"

                $hostConfig = $vds.ExtensionData.Config.Host | Where-Object { $_.Config.Host.Value -eq $hostMoRef.Value }
                $currentBacking = $hostConfig.Config.Backing

                $tgthost.Backing = New-Object VMware.Vim.DistributedVirtualSwitchHostMemberPnicBacking
                $tgthost.Backing.PnicSpec = @($currentBacking.PnicSpec | Where-Object { $_.PnicDevice -notin $targetNics })

                $spec.Host = $tgthost
                $spec.ConfigVersion = $vds.ExtensionData.Config.ConfigVersion

                try {
                    $taskMoRef = $vds.ExtensionData.ReconfigureDvs_Task($spec)
                    $task = Get-View $taskMoRef
                    
                    while ("running", "queued" -contains $task.Info.State) {
                        Start-Sleep -Seconds 2
                        $task.UpdateViewData("Info")
                    }
                    
                    if ($task.Info.State -eq "success") {
                        Write-Log "      [SUCCESS] Removed [$targetNicsStr]." "Green"
                        $successfullyFreed = $true
                    } else {
                        Write-Log "      [FAILED] $($task.Info.Error.LocalizedMessage)" "Red"
                    }
                }
                catch {
                    Write-Log "      [ERROR] $_" "Red"
                }
            }
        }
        
        # --- ATTACH TO VSS AFTER REMOVAL ---
        if ($successfullyFreed) {
            foreach ($nic in $targetNics) {
                $attachNic = Read-YesNo -PromptMessage "`nDo you want to assign the newly freed '$nic' as an uplink to a Standard Switch now? (y/n)"
                
                if ($attachNic -eq 'y') {
                    $allVss = @()
                    foreach ($h in $hosts) {
                        $allVss += Get-VirtualSwitch -VMHost $h -Standard -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
                    }
                    $uniqueVss = $allVss | Select-Object -Unique

                    if ($uniqueVss.Count -eq 0) {
                        Write-Log "  [!] No Standard Switches found. Create one first." "Red"
                        continue
                    }

                    Write-Log "  Available Standard Switches: $($uniqueVss -join ', ')" "Cyan"
                    $targetVssName = Read-VssName -ValidVssList $uniqueVss

                    Write-Log "`n>>> Assigning $nic to $targetVssName..." "Cyan"
                    foreach ($h in $hosts) {
                        $vssObj = Get-VirtualSwitch -VMHost $h -Name $targetVssName -ErrorAction SilentlyContinue
                        $freePnicObj = Get-VMHostNetworkAdapter -VMHost $h -Physical -Name $nic -ErrorAction SilentlyContinue
                        
                        if ($vssObj -and $freePnicObj) {
                            try {
                                $existingUplinks = Get-VirtualSwitch -VMHost $h -Name $targetVssName | Get-VMHostNetworkAdapter -Physical -ErrorAction SilentlyContinue
                                if ($existingUplinks.Name -contains $nic) {
                                    Write-Log "   -> [HOST: $($h.Name)] $nic is already attached to $targetVssName. Skipping." "DarkGray"
                                } else {
                                    Add-VirtualSwitchPhysicalNetworkAdapter -VirtualSwitch $vssObj -VMHostPhysicalNic $freePnicObj -Confirm:$false | Out-Null
                                    Write-Log "   -> [HOST: $($h.Name)] [SUCCESS] Attached $nic to $targetVssName." "Green"
                                }
                            } catch {
                                Write-Log "   -> [HOST: $($h.Name)] [FAILED] $($_.Exception.Message)" "Red"
                            }
                        }
                    }
                }
            }
        }
    }
}

# --- [ 5. CLEANUP ] ---
Write-Log "`n===========================================================" "White"
Write-Log ">>> Migration Complete!" "Cyan"
Write-Log "LOG SAVED TO: $(Convert-Path $global:LogFilePath)" "Green"

Disconnect-VIServer -Server $vcConn -Confirm:$false
