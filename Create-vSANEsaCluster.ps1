# --- PRE-FLIGHT: JSON LOAD & SANITIZATION ---
$jsonPath = Read-Host "Enter the full path to your JSON file (e.g., F:\scripts\config.json)"
if (-not (Test-Path $jsonPath)) { Write-Error "File not found."; return }

$config = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json

$vcServer = $config.vCenterSettings.FQDN.Trim()
$vcUser = $config.vCenterSettings.User.Trim()
$dcName = $config.Inventory.DatacenterName.Trim()
$clusterName = $config.Inventory.ClusterName.Trim()

# --- STEP 0: SESSION CHECK / AUTHENTICATION ---
if ($global:DefaultVIServer.Name -eq $vcServer) {
    Write-Host "Existing session detected for $vcServer." -ForegroundColor Green
} else {
    Write-Host "Connecting to $vcServer as $vcUser..." -ForegroundColor Cyan
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
    $vcPass = Read-Host "Enter password for $vcUser" -AsSecureString
    try {
        Connect-VIServer -Server $vcServer -User $vcUser -Password $vcPass -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "Auth failed. Please check credentials."
        return
    }
}

$dc = Get-Datacenter -Name $dcName

# --- STEP 1: ADD HOSTS TO VCENTER (STANDALONE) ---
foreach ($h in $config.Inventory.Hosts) {
    Write-Host "Step 1: Adding Host $($h.FQDN) as Standalone..." -ForegroundColor Yellow
    Add-VMHost -Name $h.FQDN -Location $dc -User $config.HostSettings.User -Password $config.HostSettings.Password -Force -Confirm:$false | Out-Null
}

# --- STEP 2: CREATE VSAN ESA ENABLED CLUSTER ---
Write-Host "Step 2: Creating vSAN ESA Cluster: $clusterName" -ForegroundColor Cyan
New-Cluster -Name $clusterName -Location $dc -VsanEnabled -VsanEsaEnabled:$true | Out-Null
$targetCluster = Get-Cluster -Name $clusterName

# --- STEP 3: CREATE VDS & NETWORKING SETUP ---
Write-Host "Step 3: Creating VDS and Networking..." -ForegroundColor Cyan
$vds = New-VDSwitch -Name $config.Networking.VdsName -Location $dc -NumUplinkPorts 2 -Mtu $config.Networking.MTU | Out-Null
$vds = Get-VDSwitch -Name $config.Networking.VdsName

# Create Portgroups
New-VDPortgroup -VDSwitch $vds -Name $config.Networking.Management.Name -VlanId $config.Networking.Management.Vlan | Out-Null
New-VDPortgroup -VDSwitch $vds -Name $config.Networking.vMotion.Name -VlanId $config.Networking.vMotion.Vlan | Out-Null
New-VDPortgroup -VDSwitch $vds -Name $config.Networking.vSAN.Name -VlanId $config.Networking.vSAN.Vlan | Out-Null

foreach ($h in $config.Inventory.Hosts) {
    $VMhost = Get-VMHost -Name $h.FQDN
    Write-Host "  -> Configuring Networking for $($h.FQDN)..." -ForegroundColor Yellow
    
    # Add Host to VDS
    $vds | Add-VDSwitchVMHost -VMHost $VMhost | Out-Null

    # Migrate Management (vmk0) via vmnic1
    $physicalNic = Get-VMHost $VMhost | Get-VMHostNetworkAdapter -Physical -Name "vmnic1"
    $virtualNic = Get-VMHostNetworkAdapter -VMHost $VMhost -Name "vmk0"
    
    # Using your validated manual syntax
    $vds | Add-VDSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $physicalNic -VMHostVirtualNic $virtualNic -VirtualNicPortgroup (Get-VDPortgroup -VDSwitch $vds -Name $config.Networking.Management.Name) -Confirm:$false | Out-Null
        
    # Provision vMotion & vSAN VMKernels
    New-VMHostNetworkAdapter -VMHost $VMhost -Portgroup $config.Networking.vMotion.Name -VirtualSwitch $vds -IP $h.VmotionIP -SubnetMask $config.Networking.vMotion.Netmask -vMotionEnabled $true -Confirm:$false | Out-Null
    New-VMHostNetworkAdapter -VMHost $VMhost -Portgroup $config.Networking.vSAN.Name -VirtualSwitch $vds -IP $h.VsanIP -SubnetMask $config.Networking.vSAN.Netmask -VsanTrafficEnabled $true -Confirm:$false | Out-Null
}

# --- STEP 4: MOVE HOSTS TO CLUSTER, MAINTENANCE MODE, & RECLAIM VMNIC0 ---
foreach ($h in $config.Inventory.Hosts) {
    $VMhost = Get-VMHost -Name $h.FQDN
    Write-Host "Step 4: Joining Cluster and Reclaiming vmnic0 for $($h.FQDN)..." -ForegroundColor Red

    # Reclaim vmnic0 from vSwitch0
    $vmnic0 = Get-VMHost $VMhost | Get-VMHostNetworkAdapter -Physical -Name "vmnic0"
    $vmnic0 | Remove-VirtualSwitchPhysicalNetworkAdapter -Confirm:$false | Out-Null

    # Add vmnic0 to VDS
    $vds | Add-VDSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $vmnic0 -Confirm:$false | Out-Null

    # Delete standard vSwitch0
    Get-VirtualSwitch -VMHost $VMhost -Name "vSwitch0" | Remove-VirtualSwitch -Confirm:$false | Out-Null
    
    # Move to Cluster and Enter Maintenance Mode
    Move-VMHost -VMHost $VMhost -Destination $targetCluster -Confirm:$false | Out-Null
    Set-VMHost -VMHost $VMhost -State Maintenance -Confirm:$false | Out-Null
}

# --- STEP 5: CLAIM VSAN ESA DISKS PER HOST ---
Write-Host "Step 5: Claiming disks for vSAN ESA Storage Pool..." -ForegroundColor Cyan
foreach ($h in $config.Inventory.Hosts) {
    $VMhost = Get-VMHost -Name $h.FQDN
    Write-Host "  -> Claiming ESA disks on $($VMhost.Name)..." -ForegroundColor Green
    
    # Discovery using the -VMHost parameter
    $hostEligibleDisks = Get-VsanEsaEligibleDisk -VMHost $VMhost
    $hostDiskNames = $hostEligibleDisks | Select-Object -ExpandProperty CanonicalName
    
    if ($hostDiskNames) {
        # Using exact syntax: VMHost object, singleTier type, and CanonicalName array
        Add-VsanStoragePoolDisk -VMHost $VMhost -VsanStoragePoolDiskType "singleTier" -DiskCanonicalName $hostDiskNames | Out-Null
    } else {
        Write-Warning "No ESA eligible disks found on $($VMhost.Name)."
    }
}

# --- FINALIZATION: EXIT MAINTENANCE MODE ---
Write-Host "Finalizing: Taking hosts out of Maintenance Mode..." -ForegroundColor Cyan
foreach ($h in $config.Inventory.Hosts) {
    Set-VMHost -VMHost (Get-VMHost -Name $h.FQDN) -State Connected -Confirm:$false | Out-Null
}

Write-Host "`nDeployment Workflow Complete." -ForegroundColor Green
