# --- Configuration & File Setup ---
$outputFilePath = "vcf9-add-cluster.json"

# --- SSL & Protocol Setup ---
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[System.Net.SecurityProtocolType]::Tls12

# --- Helper Functions ---
function Read-String { 
    param($Prompt, $Default) 
    $val = Read-Host -Prompt "$Prompt (Default: $Default)"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default } else { return $val } 
}

function Read-SecureString { param($Prompt) [Console]::Write($Prompt + ": "); return Read-Host -AsSecureString }

function Get-PlainText { 
    param($SecureString) 
    if ($null -eq $SecureString) { return "" }
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } 
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) } 
}

function Get-SddcAuthToken {
    param ($Fqdn, $User, $Pass)
    $Body = @{ username = $User; password = $Pass } | ConvertTo-Json
    try {
        $Resp = Invoke-RestMethod -Uri "https://$Fqdn/v1/tokens" -Method Post -Body $Body -ContentType "application/json" -SkipCertificateCheck
        return $Resp.accessToken
    } catch { throw "SDDC Auth Failed: $($_.Exception.Message)" }
}

try {
    Write-Host "--- VCF 9.0 Cluster Metadata Setup ---" -ForegroundColor Cyan
    $domainName     = Read-String "Enter Domain Name" "sfo-m01"
    $datacenterName = Read-String "Enter Datacenter Name" "sfo-w01-dc01"
    $clusterName    = Read-String "Enter New Cluster Name" "sfo-w01-cl02"
    $hostsFilePath  = Read-Host -Prompt "Enter full path to hosts.txt"
    if (-not (Test-Path $hostsFilePath)) { throw "File not found: $hostsFilePath" }

    # 1. SDDC Manager Authentication
    $sddcManager = Read-String "Enter SDDC Manager FQDN" "sfo-vcf01.sfo.rainpole.io"
    $user        = Read-String "Enter SDDC Admin Username" "admin@local"
    $token       = Get-SddcAuthToken -Fqdn $sddcManager -User $user -Pass (Get-PlainText (Read-SecureString "Enter Password"))
    $headers     = @{ 'Authorization' = "Bearer $token"; 'Content-Type' = 'application/json' }

    # 2. Host Discovery
    $apiResponse = Invoke-RestMethod -Uri "https://$sddcManager/v1/hosts?status=UNASSIGNED_USEABLE" -Headers $headers -Method Get -SkipCertificateCheck
    $targetHostnames = Get-Content $hostsFilePath | ForEach-Object { $_.Trim() }
    
    $foundHosts = @()
    foreach ($fqdn in $targetHostnames) {
        $match = $apiResponse.elements | Where-Object { $_.fqdn -eq $fqdn }
        if ($match) { $foundHosts += $match }
    }
    if ($foundHosts.Count -eq 0) { throw "No matching unassigned hosts found." }
    
    $vmnicList = $foundHosts[0].physicalNics.deviceName 
    $allUsedPgNames = New-Object System.Collections.Generic.List[string]

    # 3. DVS Model Selection
    $models = @("Single DVS Model", "Two DVS Separation Model")
    Write-Host "`nHardware Discovery: Found $($foundHosts[0].physicalNics.Count) NICs." -ForegroundColor Yellow
    for ($i=0; $i -lt $models.Count; $i++) { Write-Host "$($i+1). $($models[$i])" }
    $modelSelection = $models[[int](Read-Host "Select DVS Model") - 1]

    # 4. Interactive VDS & Uplink Mapping
    $vdsSpecs = @()
    $hostNicMappings = @()
    $vdsCount = if ($modelSelection -eq "Two DVS Separation Model") { 2 } else { 1 }
    
    $availableVmnics = New-Object System.Collections.Generic.List[string]
    $vmnicList | ForEach-Object { $availableVmnics.Add($_) }

    for ($v=1; $v -le $vdsCount; $v++) {
        $vdsName = Read-String "Enter Name for DVS $v" "$clusterName-vds0$v"
        
        # MTU VALIDATION
        [int]$mtu = 0
        while ($mtu -lt 1500 -or $mtu -gt 9000) {
            $mtuInput = Read-String "Enter MTU for ${vdsName} (1500-9000)" "9000"
            if ($mtuInput -match "^\d+$") { $mtu = [int]$mtuInput }
        }

        $currentVdsUplinks = @()
        for ($u=1; $u -le 2; $u++) {
            Write-Host "`nAvailable vmnics for ${vdsName}, uplink${u}:" -ForegroundColor Cyan
            Write-Host ($availableVmnics -join ', ') -ForegroundColor Gray
            $selectedVmnic = ""
            while (-not $availableVmnics.Contains($selectedVmnic)) { $selectedVmnic = Read-Host "Select vmnic for uplink$u" }
            $currentVdsUplinks += "uplink$u"
            $hostNicMappings += @{ id = $selectedVmnic; vdsName = $vdsName; uplink = "uplink$u" }
            $availableVmnics.Remove($selectedVmnic) | Out-Null
        }

        # 5. Portgroup & NSX Switch Config
        $pgSpecs = @()
        $tzs = @() # To store Transport Zones for this VDS
        
        $transportTypes = if ($modelSelection -eq "Two DVS Separation Model") {
            if ($v -eq 1) { @("MANAGEMENT", "VMOTION", "VSAN") } else { @("OVERLAY", "VLAN") }
        } else { @("MANAGEMENT", "VMOTION", "VSAN", "OVERLAY", "VLAN") }

        foreach ($tt in $transportTypes) {
            # Only configure TZs for NSX types
            if ($tt -eq "OVERLAY" -or $tt -eq "VLAN") {
                $tzName = Read-String "Enter Name for $tt Transport Zone" "sfo-m01-tz-$($tt.ToLower())01"
                $tzs += @{ name = $tzName; transportType = $tt }
                
                # For VLAN/OVERLAY in VCF, portgroups are often managed by NSX, 
                # but if you need a standard PG for them, it's defined here:
                $addPg = Read-Host "Do you want to add a manual Portgroup for $tt? (y/n)"
                if ($addPg -eq 'y') {
                    $validPgName = $false
                    while (-not $validPgName) {
                        $pgName = Read-String "Enter $tt PG Name" "${clusterName}-vds-0${v}-pg-$($tt.ToLower())"
                        if ($allUsedPgNames.Contains($pgName)) { Write-Host "Error: Name exists." -ForegroundColor Red }
                        else { $allUsedPgNames.Add($pgName); $validPgName = $true }
                    }
                    $pgSpecs += @{ name = $pgName; transportType = $tt; activeUplinks = $currentVdsUplinks; teamingPolicy = "loadbalance_loadbased" }
                }
            } else {
                # Standard MGMT, VSAN, VMOTION
                $pgName = Read-String "Enter PG Name for $tt" "${clusterName}-vds-0${v}-pg-$($tt.ToLower())"
                $allUsedPgNames.Add($pgName)
                $pgSpecs += @{ name = $pgName; transportType = $tt; activeUplinks = $currentVdsUplinks; teamingPolicy = "loadbalance_loadbased" }
            }
        }

        $vdsObj = [ordered]@{ name = $vdsName; mtu = $mtu }
        if ($pgSpecs.Count -gt 0) { $vdsObj.Add("portGroupSpecs", $pgSpecs) }
        if ($tzs.Count -gt 0) { $vdsObj.Add("nsxtSwitchConfig", @{ transportZones = $tzs }) }
        
        $vdsSpecs += $vdsObj
    }

    # 6. Final JSON Assembly
    $hostSpecs = foreach ($h in $foundHosts) {
        @{ id = $h.id; licenseKey = "XX0XX-XXXXX"; username = "root"; hostNetworkSpec = @{ vmNics = $hostNicMappings } }
    }

    $finalJson = [ordered]@{
        domainId = (Invoke-RestMethod -Uri "https://$sddcManager/v1/domains" -Headers $headers -Method Get -SkipCertificateCheck).elements | Where-Object { $_.name -eq $domainName } | Select-Object -ExpandProperty id
        computeSpec = @{
            clusterSpecs = @(
                [ordered]@{
                    datacenterName = $datacenterName
                    name = $clusterName
                    hostSpecs = $hostSpecs
                    datastoreSpec = @{ vsanDatastoreSpec = @{ failuresToTolerate = 1; licenseKey = "XXXX-XXXX"; datastoreName = "$clusterName-ds-vsan01" } }
                    networkSpec = @{ vdsSpecs = $vdsSpecs }
                }
            )
        }
    }

    $finalJson | ConvertTo-Json -Depth 20 | Out-File $outputFilePath -Encoding UTF8
    Write-Host "`n✔ SUCCESS: NSX Switch Config included. JSON saved to $outputFilePath" -ForegroundColor Green

} catch {
    Write-Host "`n✘ ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
