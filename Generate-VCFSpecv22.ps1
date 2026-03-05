Set-StrictMode -Version Latest # CRITICAL: Force strict error checking to expose hidden bugs

# --- Helper Functions ---


function Get-PlainText {
    param ([System.Security.SecureString]$SecureString)
    # Converts a SecureString back to a standard string.
    if ($null -eq $SecureString) { return $null }
    
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        $PlainText = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
        return $PlainText
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }
}
function Read-String {
    param ([string]$Prompt, [string]$Example)
    $promptText = "$Prompt"
    if (-not [string]::IsNullOrWhiteSpace($Example)) {
        $promptText += " (Example: $Example)"
    }
    
    [string]$inputVal = ""
    while ([string]::IsNullOrWhiteSpace($inputVal)) {
        $inputVal = Read-Host -Prompt $promptText
    }
    return $inputVal
}

function Read-SecureString {
    param ([string]$Prompt)
    [Console]::Write($Prompt + ": ")
    $password = Read-Host -AsSecureString
    return $password
}

function Read-Boolean {
    param ([string]$Prompt)
    [string]$inputVal = ""
    while ($inputVal -notin @('y', 'n', 'yes', 'no', 'true', 'false')) {
        $inputVal = Read-Host -Prompt "$Prompt (y/n)"
    }
    return ($inputVal -match 'y|true')
}

function Read-Choice {
    param ([string]$Prompt, [System.Collections.ArrayList]$Options)
    Write-Host "`n--- $Prompt ---"
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "$($i+1). $($Options[$i])"
    }
    
    $selection = 0
    while ($selection -lt 1 -or $selection -gt $Options.Count) {
        $inputVal = Read-Host -Prompt "Select Option (1-$($Options.Count))"
        if ($inputVal -match "^\d+$") {
            $selection = [int]$inputVal
        }
    }
    return $Options[$selection - 1] 
}

function Test-IPAddress {
    param ([string]$IP)
    $ipObj = $null
    return (-not [string]::IsNullOrEmpty($IP)) -and [System.Net.IPAddress]::TryParse($IP, [ref]$ipObj) -and 
           ($IP -match "^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$")
}

function Test-DomainFormat {
    param ([string]$FQDN)
    return $FQDN -match "^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$"
}

function Test-CIDRFormat {
    param ([string]$CIDR)
    return $CIDR -match "^(?:[0-9]{1,3}\.){3}[0-9]{1,3}\/(?:[0-9]|[12][0-9]|3[0-2])$"
}

function Test-IPInCIDR {
    param (
        [string]$IPAddress,
        [string]$CIDR
    )
    if (-not (Test-CIDRFormat $CIDR)) { return $false }
    if (-not (Test-IPAddress $IPAddress)) { return $false }
    
    try {
        # Simple implementation for basic range check (crude, but avoids external libraries)
        $cidrMask = ($CIDR.Split('/'))[1]
        
        if ([int]$cidrMask -ge 24) {
            $cidrIP = ($CIDR.Split('/'))[0]
            $ipOctets = $IPAddress.Split('.')
            $cidrOctets = $cidrIP.Split('.')
            # Check first three octets match for /24 or tighter subnets
            return ($ipOctets[0] -eq $cidrOctets[0]) -and ($ipOctets[1] -eq $cidrOctets[1]) -and ($ipOctets[2] -eq $cidrOctets[2])
        }
        return $true # Assume correct for broader subnets
    } catch {
        return $false 
    }
}

function Read-UniquePortGroupName {
    param ([string]$Prompt, [string]$DefaultValue, [System.Collections.ArrayList]$UsedNames)
    [string]$inputVal = ""
    $promptText = "$Prompt (Default: $DefaultValue)"
    
    while ([string]::IsNullOrWhiteSpace($inputVal) -or ($inputVal -in $UsedNames)) {
        $inputVal = Read-Host -Prompt $promptText
        
        if ([string]::IsNullOrWhiteSpace($inputVal)) { $inputVal = $DefaultValue }
        
        if ($inputVal -in $UsedNames) {
            Write-Warning "Port Group Name '$inputVal' is already used. Please enter a unique name."
            $inputVal = "" 
        }
    }
    return $inputVal
}

# -----------------------------------------------------------------------------
# Core Function: Interactively maps vmnics to DVS Uplink names
# -----------------------------------------------------------------------------
function Interactively-MapVmnicsToUplinks {
    param(
        [Parameter(Mandatory=$true)]
        [string]$DvsName,

        [Parameter(Mandatory=$true)]
        [string[]]$VmnicsForDVS # e.g., @("vmnic0", "vmnic1") - The total vmnics assigned to this DVS
    )

    # Create a mutable list of vmnics to track availability
    $VmnicsToMap = New-Object System.Collections.ArrayList
    $VmnicsForDVS | ForEach-Object { $null = $VmnicsToMap.Add($_) }
    
    # Final array in the required JSON format: @{ id = "vmnicX"; uplink = "uplinkY" }
    $vmnicsToUplinks = @()
    $uplinkCounter = 1
    
    Write-Host "`n--- Interactive vmnic-to-Uplink Mapping for $DvsName ---" -ForegroundColor Yellow
    
    # Loop exactly once for every vmnic that needs an assignment for this DVS.
    for ($i = 0; $i -lt $VmnicsForDVS.Count; $i++) {
        $UplinkName = "uplink$uplinkCounter"
        $selectedVmnic = ""
        
        # Inner loop for robust input validation. Loops until a valid vmnic is selected.
        while ($true) {
            # 1. Print current mapping uplink
            Write-Host "`nMapping Uplink: $UplinkName" -ForegroundColor Cyan
            
            # 2. Print available vmnics
            $currentAvailableVmnicsString = $VmnicsToMap -join ', '
            Write-Host "Available vmnics: $currentAvailableVmnicsString" -ForegroundColor DarkCyan

            # 3. Prompt the user for selection
            $selectedVmnic = Read-Host "Select vmnic to assign to $UplinkName (Must be one of the available list)"
            
            # Trim whitespace from input and handle potential null/empty input
            $selectedVmnic = $selectedVmnic.Trim() 
            
            # Validation: Is the selected vmnic currently in the available list?
            if ($VmnicsToMap -contains $selectedVmnic) {
                
                # Add the mapping to the final array
                $vmnicsToUplinks += @{ id = $selectedVmnic; uplink = $UplinkName }
                
                # Remove the used vmnic from the available list to enforce 1:1
                $null = $VmnicsToMap.Remove($selectedVmnic)
                
                # 4. Print Success message in the required format
                Write-Host "SUCCESS: $UplinkName mapped to $selectedVmnic." -ForegroundColor Green
                $uplinkCounter++ # Increment uplink counter for the next iteration
                break # Exit the inner while loop and proceed to the next DVS uplink mapping
            } 
            
            # Handle invalid input and loop back
            Write-Warning "Invalid vmnic '$selectedVmnic' selected. It must be in the available list: $currentAvailableVmnicsString"
        }
    }
    
    return $vmnicsToUplinks
}
# -----------------------------------------------------------------------------


# -----------------------------------------------------------------------------
# Function: Prompts the user for Active Uplinks for Network Teaming Policies.
# -----------------------------------------------------------------------------
function Read-UplinkSelection {
    param(
        [string]$NetworkOrPolicyName,
        [string]$DVSName,
        [string[]]$AvailableUplinks # This is the list of 'uplinkX' names for the DVS
    )
    
    Write-Host "`n-- Teaming Configuration for $NetworkOrPolicyName (DVS: $DVSName) --" -ForegroundColor Cyan

    if (@($AvailableUplinks).Count -eq 0) {
        Write-Warning "No uplinks available for DVS '$DVSName'. Cannot configure teaming for '$NetworkOrPolicyName'."
        return @()
    }
    
    $UplinkList = $AvailableUplinks -join ', '
    Write-Host "Available Uplinks: $($UplinkList)"

    [string[]]$selectedUplinks = @()

    while (@($selectedUplinks).Count -eq 0) {
        $inputVal = Read-Host "Enter Active Uplinks (comma separated, e.g., uplink1,uplink2). Must select at least one"
        
        $tempSelection = @($inputVal -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        
        $validSelection = $true
        if (@($tempSelection).Count -eq 0) {
            Write-Warning "You must select at least one uplink."
            $validSelection = $false
        } else {
            # CRITICAL VALIDATION: Check if ALL selected uplinks are in the AvailableUplinks list
            $InvalidUplinks = $tempSelection | Where-Object { $_ -notin $AvailableUplinks }
            
            if (@($InvalidUplinks).Count -gt 0) {
                Write-Warning "Invalid uplink(s) selected: $($InvalidUplinks -join ', '). They must be one of: $($UplinkList)"
                $validSelection = $false
            }
        }
        
        if ($validSelection) {
            $selectedUplinks = $tempSelection | Select-Object -Unique | Sort-Object
        }
    }
    return $selectedUplinks
}
# -----------------------------------------------------------------------------


function Configure-SeparatedDVS {
    param(
        [string]$dvsModel,
        [string]$storageChoice,
        [int]$vmnicCount,
        [string]$dnsSubdomain,
        # FIXED: Ensure TZ names are passed in.
        [string]$overlayTZName,
        [string]$vlanTZName
    )
    
    # ... (function body remains similar for 2 DVS, using passed TZ names) ...
    $allVmnics = @(); for ($i = 0; $i -lt $vmnicCount; $i++) { $allVmnics += "vmnic$i" }
    $minVmnics = [Math]::Floor($vmnicCount / 2); if ($minVmnics -eq 0) { $minVmnics = 1 }
    
    $dvs1Purpose = "Management/Storage"
    $dvs2Purpose = "Workload/NSX-T"
    $dvs2NamePrompt = "Enter Second Distributed Switch Name for Workload/NSX-T (Must be unique from DVS 1: {0})"
    
    if ($dvsModel -eq "Storage separation distributed Switch") {
        $dvs1Purpose = "Management/NSX Workload"
        $dvs2Purpose = "Storage"
        $dvs2NamePrompt = "Enter Second Distributed Switch Name for Storage (Must be unique from DVS 1: {0})"
    }
    
    
    # ----------------------------------------------------------------------------------
    # ## DVS 1: MANAGEMENT/WORKLOAD 
    # ----------------------------------------------------------------------------------
    
    Write-Host "`n======================================================="
    Write-Host "## 🌐 Configuring Distributed Switch 1 (DVS 1: $dvs1Purpose)"
    Write-Host "======================================================="
    
    $dvs1Name = Read-String "Enter First Distributed Switch Name ($dvs1Purpose)" "sdc-m01-vds01"
    [int]$dvs1MTU = 0
    while ($dvs1MTU -lt 1500 -or $dvs1MTU -gt 9000) {
        $inputVal = Read-String "Enter MTU for DVS 1 (numeric, 1500-9000)" "9000"
        if ($inputVal -match "^\d+$") { 
            $dvs1MTU = [int]$inputVal 
            if ($dvs1MTU -lt 1500 -or $dvs1MTU -gt 9000) { Write-Warning "MTU value must be between 1500 and 9000." }
        } else {
            Write-Warning "Invalid MTU format. Please enter a number."
            $dvs1MTU = 0
        }
    }
    
    # Select vmnics for DVS 1 (Must be a subset of all vmnics)
    $selectedVmnics1 = @()
    while (@($selectedVmnics1).Count -lt $minVmnics -or @($selectedVmnics1).Count -ge $vmnicCount) {
        Write-Host "Available vmnics: $($allVmnics -join ', ')"
        $vmnicInput = Read-String "Enter vmnics for DVS 1 (comma separated, e.g., vmnic0,vmnic1). Must be less than $vmnicCount" "vmnic0,vmnic1" 
        $tempVmnics = $vmnicInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $validSelection = $true
        foreach ($vmnic in $tempVmnics) { if ($vmnic -notin $allVmnics) { Write-Warning "Invalid vmnic '$vmnic' entered."; $validSelection = $false; break } }
        if ($validSelection) {
            if (@($tempVmnics).Count -lt $minVmnics) { Write-Warning "Must select at least $minVmnics vmnics." } 
            elseif (@($tempVmnics).Count -ge $vmnicCount) { Write-Warning "Cannot select all $vmnicCount vmnics for DVS 1. Leave some for DVS 2." } 
            else { $selectedVmnics1 = $tempVmnics | Select-Object -Unique | Sort-Object }
        }
    }
    
    # *** INTERACTIVE MAPPING FOR DVS 1 (Using FIXED Function) ***
    $vmnicsToUplinks1 = Interactively-MapVmnicsToUplinks -DvsName $dvs1Name -VmnicsForDVS $selectedVmnics1

    # Extract available uplinks for DVS 1 (guaranteed to be uplink1, uplink2, etc.)
    $dvs1AvailableUplinks = @($vmnicsToUplinks1 | Select-Object -ExpandProperty uplink | Select-Object -Unique | Sort-Object)
    
    # DVS 1 Networks: Core VCF + conditional VSAN/NSX depending on model
    $dvs1Networks = @( "MANAGEMENT", "VM_MANAGEMENT", "VMOTION" )
    $nsxtTeamings1 = @()
    $transportZones = @( @{ name = $overlayTZName; transportType = "OVERLAY" } )
    if (-not [string]::IsNullOrWhiteSpace($vlanTZName)) { $transportZones += @{ name = $vlanTZName; transportType = "VLAN" } }
    
    if ($dvsModel -eq "Workload Separation Distributed Switch Model") {
        if ($storageChoice -eq "VSAN") { 
            Write-Host "VSAN storage selected: Adding VSAN network to DVS 1."
            $dvs1Networks += "VSAN" 
        } else {
            Write-Host "Non-VSAN storage selected: Skipping VSAN network for DVS 1."
        }
    } 
    
    # NSX TEP Teaming for DVS 1 (Only for Storage Separation Model)
    if ($dvsModel -eq "Storage separation distributed Switch") {
        # Get user selection for NSX Teaming on DVS 1
        $nsxActiveUplinks1 = Read-UplinkSelection -NetworkOrPolicyName "NSX-T TEP (DVS 1)" -DVSName $dvs1Name -AvailableUplinks $dvs1AvailableUplinks
        if (@($nsxActiveUplinks1).Count -gt 0) {
            $nsxtTeamings1 += @{ policy = "LOADBALANCE_SRCID"; activeUplinks = $nsxActiveUplinks1 }
        } else {
            Write-Warning "No active uplinks selected for NSX-T on DVS 1. The NSX Teaming policy will be omitted."
        }
    }


    # DVS 1 Object - Safe Filtering of Nulls in Strict Mode
    $tempDvs1 = [ordered]@{
        dvsName = $dvs1Name; 
        mtu = $dvs1MTU.ToString();
        networks = $dvs1Networks; 
        nsxtSwitchConfig = if ($dvsModel -eq "Storage separation distributed Switch") { @{ transportZones = $transportZones } } else { $null };
        vmnicsToUplinks = $vmnicsToUplinks1;
        nsxTeamings = if (@($nsxtTeamings1).Count -gt 0) { $nsxtTeamings1 } else { $null }
    } 
    
    $dvs1 = [ordered]@{}
    foreach ($entry in $tempDvs1.GetEnumerator()) {
        if ($entry.Value -ne $null) {
            $dvs1.Add($entry.Key, $entry.Value)
        }
    }

    # ----------------------------------------------------------------------------------
    # ## DVS 2: WORKLOAD or STORAGE
    # ----------------------------------------------------------------------------------
    
    Write-Host "`n======================================================="
    Write-Host "## 💻 Configuring Distributed Switch 2 (DVS 2: $dvs2Purpose)"
    Write-Host "======================================================="
    
    # Remaining vmnics are automatically the ones not selected for DVS 1
    $remainingVmnics = $allVmnics | Where-Object { $_ -notin $selectedVmnics1 } | Select-Object -Unique | Sort-Object
    $vmnicCountDVS2 = @($remainingVmnics).Count
    $dvs2 = $null 
    $dvs2Networks = @()
    $dvs2AvailableUplinks = @()
    $dvs2Name = "" # Initialize $dvs2Name here
    
    if ($vmnicCountDVS2 -eq 0) { 
        Write-Warning "No remaining vmnics for DVS 2. The Separation Model requires two switches. Returning DVS 1 only." 
        
    } else {
        
        Write-Host "Remaining available vmnics for DVS 2 ($dvs2Purpose): $($remainingVmnics -join ', ')"
        
        while ([string]::IsNullOrWhiteSpace($dvs2Name) -or ($dvs2Name -eq $dvs1Name)) {
            $dvs2Name = Read-String ($dvs2NamePrompt -f $dvs1Name) "sfo-m01-cl01-vds02"
            if ($dvs2Name -eq $dvs1Name) {
                Write-Warning "Distributed Switch Name must be unique from the first DVS: '$dvs1Name'."
                $dvs2Name = ""
            }
        }
        
        [int]$dvs2MTU = 0
        while ($dvs2MTU -lt 1500 -or $dvs2MTU -gt 9000) {
            $inputVal = Read-String "Enter MTU for DVS 2 (numeric, 1500-9000)" "9000"
            if ($inputVal -match "^\d+$") { 
                $dvs2MTU = [int]$inputVal 
                if ($dvs2MTU -lt 1500 -or $dvs2MTU -gt 9000) { Write-Warning "MTU value must be between 1500 and 9000." }
            } else {
                Write-Warning "Invalid MTU format. Please enter a number."
                $dvs2MTU = 0
            }
        }
        
        # *** INTERACTIVE MAPPING FOR DVS 2 (Using FIXED Function) ***
        # The list of vmnics is guaranteed to be the remaining ones
        $vmnicsToUplinks2 = Interactively-MapVmnicsToUplinks -DvsName $dvs2Name -VmnicsForDVS $remainingVmnics

        # Extract available uplinks for DVS 2 (guaranteed to be uplink1, uplink2, etc.)
        $dvs2AvailableUplinks = @($vmnicsToUplinks2 | Select-Object -ExpandProperty uplink | Select-Object -Unique | Sort-Object)

        $nsxtTeamings2 = @()

        if ($dvsModel -eq "Workload Separation Distributed Switch Model") {
            $nsxtSwitchConfig2 = @{ transportZones = $transportZones }
            
            if (@($dvs2AvailableUplinks).Count -gt 0) { 
                $nsxActiveUplinks2 = Read-UplinkSelection -NetworkOrPolicyName "NSX-T TEP (DVS 2)" -DVSName $dvs2Name -AvailableUplinks $dvs2AvailableUplinks
                
                if (@($nsxActiveUplinks2).Count -gt 0) {
                    $nsxtTeamings2 += @{ policy = "LOADBALANCE_SRCID"; activeUplinks = $nsxActiveUplinks2 }
                } else {
                    Write-Warning "No active uplinks selected for NSX-T on DVS 2. The NSX Teaming policy will be omitted."
                }
            }
        }
        
        if ($storageChoice -eq "VSAN") {
            if ($dvsModel -eq "Storage separation distributed Switch") { 
                $dvs2Networks += "VSAN" 
            }
        }
        
        # DVS 2 Object - Safe Filtering of Nulls in Strict Mode
        $tempDvs2 = [ordered]@{
            dvsName = $dvs2Name; 
            mtu = $dvs2MTU.ToString();
            networks = if (@($dvs2Networks).Count -gt 0) { $dvs2Networks } else { $null };
            nsxtSwitchConfig = if ($dvsModel -eq "Workload Separation Distributed Switch Model") { @{ transportZones = $transportZones } } else { $null };
            vmnicsToUplinks = $vmnicsToUplinks2;
            nsxTeamings = if (@($nsxtTeamings2).Count -gt 0) { $nsxtTeamings2 } else { $null }
        } 
        
        $dvs2 = [ordered]@{}
        foreach ($entry in $tempDvs2.GetEnumerator()) {
            if ($entry.Value -ne $null) {
                $dvs2.Add($entry.Key, $entry.Value)
            }
        }
    }

    # Determine all required networks for IP planning
    $allNetworks = @($dvs1Networks) + @($dvs2Networks)
    
    # Create DVS Uplink Map
    $dvsUplinkMap = @{ 
        $dvs1Name = $dvs1AvailableUplinks 
    }
    if ($dvs2Name) { $dvsUplinkMap[$dvs2Name] = $dvs2AvailableUplinks }
    
    # Return the required output array (dvs1, dvs2, allNetworks, dvsUplinkMap)
    return $dvs1, $dvs2, $allNetworks, $dvsUplinkMap 
}

# -----------------------------------------------------------------------------
# NEW FUNCTION: Configures the 3-DVS Separation Model
# -----------------------------------------------------------------------------
function Configure-ThreeDVS {
    param(
        [Parameter(Mandatory=$true)]
        [string]$storageChoice, # Must be VSAN for this function to be called
        [Parameter(Mandatory=$true)]
        [int]$vmnicCount, # Must be >= 6
        [Parameter(Mandatory=$true)]
        [string]$overlayTZName,
        [Parameter(Mandatory=$true)]
        [string]$vlanTZName
    )
    
    $allVmnics = @(); for ($i = 0; $i -lt $vmnicCount; $i++) { $allVmnics += "vmnic$i" }
    
    # Minimum required vmnics for each DVS: 2 (Total minimum: 6)
    $minVmnicsPerDVS = 2
    
    # ----------------------------------------------------------------------------------
    # ## DVS 1: MANAGEMENT (Mgmt, vMotion, VM Mgmt)
    # ----------------------------------------------------------------------------------
    Write-Host "`n======================================================="
    Write-Host "## 🔑 Configuring Distributed Switch 1 (DVS 1: Management)"
    Write-Host "======================================================="
    $dvs1Name = Read-String "Enter First Distributed Switch Name (Management)" "sdc-m01-vds01-mgmt"
    
    [int]$dvs1MTU = 0; while ($dvs1MTU -lt 1500 -or $dvs1MTU -gt 9000) { $inputVal = Read-String "Enter MTU for DVS 1 (Management)" "9000"; if ($inputVal -match "^\d+$") { $dvs1MTU = [int]$inputVal } }

    # Select vmnics for DVS 1 (Management)
    $selectedVmnics1 = @()
    while (@($selectedVmnics1).Count -lt $minVmnicsPerDVS) {
        $remainingVmnicsString = $allVmnics -join ', '
        Write-Host "Available vmnics: $remainingVmnicsString"
        $vmnicInput = Read-String "Enter vmnics for DVS 1 (Management - $minVmnicsPerDVS required)" "vmnic0,vmnic1" 
        $tempVmnics = $vmnicInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        
        $validSelection = $true
        foreach ($vmnic in $tempVmnics) { 
            if ($vmnic -notin $allVmnics) { Write-Warning "Invalid vmnic '$vmnic' entered."; $validSelection = $false; break } 
        }
        if ($validSelection -and @($tempVmnics).Count -ge $minVmnicsPerDVS) {
            $selectedVmnics1 = $tempVmnics | Select-Object -Unique | Sort-Object
        }
        if (@($selectedVmnics1).Count -lt $minVmnicsPerDVS) { Write-Warning "Please select at least $minVmnicsPerDVS vmnics for DVS 1." }
    }
    
    $vmnicsToUplinks1 = Interactively-MapVmnicsToUplinks -DvsName $dvs1Name -VmnicsForDVS $selectedVmnics1
    $dvs1AvailableUplinks = @($vmnicsToUplinks1 | Select-Object -ExpandProperty uplink | Select-Object -Unique | Sort-Object)
    $dvs1Networks = @( "MANAGEMENT", "VMOTION", "VM_MANAGEMENT" )

    $dvs1 = [ordered]@{
        dvsName = $dvs1Name; 
        mtu = $dvs1MTU.ToString();
        networks = $dvs1Networks; 
        vmnicsToUplinks = $vmnicsToUplinks1;
    }
    
    # Update remaining Vmnics
    $remainingVmnics = $allVmnics | Where-Object { $_ -notin $selectedVmnics1 } | Select-Object -Unique | Sort-Object
    
    # ----------------------------------------------------------------------------------
    # ## DVS 2: STORAGE (VSAN)
    # ----------------------------------------------------------------------------------
    Write-Host "`n======================================================="
    Write-Host "## 💾 Configuring Distributed Switch 2 (DVS 2: Storage - VSAN)"
    Write-Host "======================================================="

    $dvs2Name = ""; while ([string]::IsNullOrWhiteSpace($dvs2Name) -or ($dvs2Name -eq $dvs1Name)) {
        $dvs2Name = Read-String "Enter Second Distributed Switch Name (Storage)" "sfo-m01-cl01-vds02-vsan"
        if ($dvs2Name -eq $dvs1Name) { Write-Warning "DVS name must be unique from DVS 1." }
    }
    [int]$dvs2MTU = 0; while ($dvs2MTU -lt 1500 -or $dvs2MTU -gt 9000) { $inputVal = Read-String "Enter MTU for DVS 2 (Storage)" "9000"; if ($inputVal -match "^\d+$") { $dvs2MTU = [int]$inputVal } }

    # Select vmnics for DVS 2 (Storage) from remaining
    $selectedVmnics2 = @()
    while (@($selectedVmnics2).Count -lt $minVmnicsPerDVS) {
        $remainingVmnicsString = $remainingVmnics -join ', '
        Write-Host "Available vmnics: $remainingVmnicsString"
        $vmnicInput = Read-String "Enter vmnics for DVS 2 (Storage - $minVmnicsPerDVS required)" "vmnic2,vmnic3" 
        $tempVmnics = $vmnicInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        
        $validSelection = $true
        foreach ($vmnic in $tempVmnics) { 
            if ($vmnic -notin $remainingVmnics) { Write-Warning "Invalid vmnic '$vmnic' entered. Must be from available list."; $validSelection = $false; break } 
        }
        if ($validSelection -and @($tempVmnics).Count -ge $minVmnicsPerDVS) {
            $selectedVmnics2 = $tempVmnics | Select-Object -Unique | Sort-Object
        }
        if (@($selectedVmnics2).Count -lt $minVmnicsPerDVS) { Write-Warning "Please select at least $minVmnicsPerDVS vmnics for DVS 2." }
    }
    
    $vmnicsToUplinks2 = Interactively-MapVmnicsToUplinks -DvsName $dvs2Name -VmnicsForDVS $selectedVmnics2
    $dvs2AvailableUplinks = @($vmnicsToUplinks2 | Select-Object -ExpandProperty uplink | Select-Object -Unique | Sort-Object)
    $dvs2Networks = @( "VSAN" )

    $dvs2 = [ordered]@{
        dvsName = $dvs2Name; 
        mtu = $dvs2MTU.ToString();
        networks = $dvs2Networks; 
        vmnicsToUplinks = $vmnicsToUplinks2;
    }
    
    # Update remaining Vmnics
    $remainingVmnics = $remainingVmnics | Where-Object { $_ -notin $selectedVmnics2 } | Select-Object -Unique | Sort-Object

    # ----------------------------------------------------------------------------------
    # ## DVS 3: WORKLOAD (NSX-T)
    # ----------------------------------------------------------------------------------
    Write-Host "`n======================================================="
    Write-Host "## 💻 Configuring Distributed Switch 3 (DVS 3: NSX-T Workload)"
    Write-Host "======================================================="
    
    if (@($remainingVmnics).Count -lt $minVmnicsPerDVS) {
        Write-Error "Not enough vmnics remaining for DVS 3. (Needed: $minVmnicsPerDVS, Available: $(@($remainingVmnics).Count))"
        # Return partial result for error handling in main script, but execution will stop later anyway.
        return $dvs1, $dvs2, @($dvs1Networks) + @($dvs2Networks), @{} 
    }

    $dvs3Name = ""; while ([string]::IsNullOrWhiteSpace($dvs3Name) -or ($dvs3Name -eq $dvs1Name) -or ($dvs3Name -eq $dvs2Name)) {
        $dvs3Name = Read-String "Enter Third Distributed Switch Name (NSX-T Workload)" "sfo-m01-cl01-vds03-nsx"
        if ($dvs3Name -eq $dvs1Name -or $dvs3Name -eq $dvs2Name) { Write-Warning "DVS name must be unique from DVS 1 and DVS 2." }
    }
    [int]$dvs3MTU = 0; while ($dvs3MTU -lt 1500 -or $dvs3MTU -gt 9000) { $inputVal = Read-String "Enter MTU for DVS 3 (NSX-T Workload)" "9000"; if ($inputVal -match "^\d+$") { $dvs3MTU = [int]$inputVal } }
    
    # Select vmnics for DVS 3 (NSX-T) - use all remaining
    $selectedVmnics3 = $remainingVmnics
    $vmnicsToUplinks3 = Interactively-MapVmnicsToUplinks -DvsName $dvs3Name -VmnicsForDVS $selectedVmnics3
    $dvs3AvailableUplinks = @($vmnicsToUplinks3 | Select-Object -ExpandProperty uplink | Select-Object -Unique | Sort-Object)

    # NSX TEP Teaming for DVS 3
    $nsxActiveUplinks3 = Read-UplinkSelection -NetworkOrPolicyName "NSX-T TEP (DVS 3)" -DVSName $dvs3Name -AvailableUplinks $dvs3AvailableUplinks
    $nsxtTeamings3 = @()
    if (@($nsxActiveUplinks3).Count -gt 0) {
        $nsxtTeamings3 += @{ policy = "LOADBALANCE_SRCID"; activeUplinks = $nsxActiveUplinks3 }
    }
    
    # Transport Zones configuration (using the global ones)
    $transportZones = @( @{ name = $overlayTZName; transportType = "OVERLAY" } )
    if (-not [string]::IsNullOrWhiteSpace($vlanTZName)) { $transportZones += @{ name = $vlanTZName; transportType = "VLAN" } }
    
    $dvs3 = [ordered]@{
        dvsName = $dvs3Name; 
        mtu = $dvs3MTU.ToString();
        # DVS 3 does not have fixed networks, only NSX TEPs are required
        networks = $null; 
        nsxtSwitchConfig = @{ transportZones = $transportZones };
        vmnicsToUplinks = $vmnicsToUplinks3;
        nsxTeamings = if (@($nsxtTeamings3).Count -gt 0) { $nsxtTeamings3 } else { $null }
    }
    
    $dvs3Filtered = [ordered]@{}
    foreach ($entry in $dvs3.GetEnumerator()) {
        if ($entry.Value -ne $null) { $dvs3Filtered.Add($entry.Key, $entry.Value) }
    }
    
    # Determine all required networks for IP planning
    $allNetworks = @($dvs1Networks) + @($dvs2Networks) 
    
    $dvsUplinkMap = @{ 
        $dvs1Name = $dvs1AvailableUplinks;
        $dvs2Name = $dvs2AvailableUplinks;
        $dvs3Name = $dvs3AvailableUplinks
    }
    
    # Return the required output array (dvs1, dvs2, dvs3, allNetworks, dvsUplinkMap)
    # The main script will handle how to collect these three DVS objects.
    return $dvs1, $dvs2, $dvs3Filtered, $allNetworks, $dvsUplinkMap 
}
# -----------------------------------------------------------------------------


# --- Global Tracking Variables ---
$usedPortGroupNames = [System.Collections.ArrayList]@()
$usedSubnets = [System.Collections.ArrayList]@()
$usedHostnames = [System.Collections.ArrayList]@()
$vcfOperationsNetworkSpec = $null
$vcfOpsDeployModel = $null
$dvsUplinkMap = @{} 
$allRequiredNetworks = @() 

# --- Main Script Execution ---

Write-Host "--- VCF Spec Generator ---"
Write-Host "Note: Output will be saved to newFleetBringup.json"

## 1. Main Level Inputs
$sddcId = Read-String "Enter SDDC ID" "sfo-m01"
# CHANGE 1: Removed VVF option
$workflowOptions = @("VCF", "VCF_EXTEND")
$workflowType = Read-Choice "Select Workflow Type" $workflowOptions
$vcfInstanceName = Read-String "Enter VCF Instance Name" "VCF-Pune"
$version = Read-String "Enter Version" "9.0.0.0"
$ceipEnabled = Read-Boolean "Enable CEIP?" 
$outputFilePath = "newFleetBringup.json"

## 3. DNS Subdomain
$dnsSubdomain = ""
while (-not (Test-DomainFormat $dnsSubdomain)) {
    $dnsSubdomain = Read-String "Enter DNS Subdomain (Validated Format)" "sfo.rainpole.io"
    if (-not (Test-DomainFormat $dnsSubdomain)) { Write-Warning "Invalid domain format. Use standard FQDN rules (e.g., example.com)." }
}

## 4. Infrastructure Details (DNS & NTP)
$dnsServers = @(); $ntpServersList = @()
Write-Host "`n--- Infrastructure Details (DNS & NTP) ---";
$count = 1; while ($true) { $inputVal = Read-Host -Prompt "DNS Server $count (leave blank to finish) (Example: 10.0.0.1)"; if ([string]::IsNullOrWhiteSpace($inputVal)) { break } if (Test-IPAddress $inputVal) { $dnsServers += $inputVal; $count++ } else { Write-Warning "Invalid IP address format." } }
$count = 1; while ($true) { $inputVal = Read-Host -Prompt "NTP Server $count (FQDN or IP, leave blank to finish) (Example: time.google.com or 10.0.0.2)"; if ([string]::IsNullOrWhiteSpace($inputVal)) { break } if (Test-IPAddress $inputVal) { $ntpServersList += $inputVal; $count++ } elseif (Test-DomainFormat $inputVal) { $ntpServersList += $inputVal; $count++ } else { Write-Warning "Invalid format. Please enter a proper IPv4 address or FQDN." } }

# -----------------------------------------------------
# **DEPLOYMENT MODEL**
# -----------------------------------------------------

$deployModelOptions = @("Simple (Single Node)", "High Availability (Three Node)")
Write-Host "`n--- VCF Operations / NSX-T Deployment Model ---"; 
$vcfOpsDeployModel = Read-Choice "Select Deployment Model for VCF Operations/NSX-T" $deployModelOptions
$vcfOpsNodeCount = if ($vcfOpsDeployModel -eq "Simple (Single Node)") { 1 } else { 3 }

# --- Network Configuration Type ---
Write-Host "`n--- Networking Configuration ---"
$networkOptions = @("Shared Management Network", "Advanced Dedicated Network")
$networkTypeChoice = Read-Choice "Select Networking Type" $networkOptions
$isAdvancedDedicated = ($networkTypeChoice -eq "Advanced Dedicated Network")
# -----------------------------------------------

# --- VCF Operations Configuration Block ---

$deployVcfOperations = $false
$deployAutomation = $false 
$finalVcfOperationsSpec = $null; $finalVcfOpsFleetSpec = $null; $finalVcfOpsCollectorSpec = $null; $finalVcfAutomationSpec = $null

if ($isAdvancedDedicated) {
    $deployVcfOperations = $false
    Write-Host "`nSelected Advanced Dedicated Network. Skipping VCF Operations/Automation specs generation."
} else {
    $deployVcfOperations = $true
    Write-Host "`nVCF Operations/Automation deployment is assumed for Shared Management Network (Model: $vcfOpsDeployModel)."
    
    Write-Host "`n--- VCF Operations Node Configuration ---"; 
    
    $vcfOpsAdminPassword = ""; $vcfOpsRootPassword = ""

    $vcfOpsAdminPassword = Get-PlainText (Read-SecureString "Enter VCF Ops Admin User Password")
    $vcfOpsRootPassword = Get-PlainText (Read-SecureString "Enter VCF Ops Root User Password (for nodes)")
    
    # CHANGE 4: VCF Ops Appliance Size selection
    $vcfOpsApplianceOptions = @("xlarge", "large", "medium", "small")
    $vcfOpsApplianceSize = Read-Choice "Select VCF Ops Appliance Size (Default: medium)" $vcfOpsApplianceOptions
    
    # --- "vcfOperationsSpec" ---
    $vcfOpsNodes = @(); $vcfOpsLbFqdn = ""
    if ($vcfOpsNodeCount -eq 1) { 
        $mHostShort = Read-String "Enter Short Hostname for Master Node" "vcfoperations-master"; 
        $vcfOpsNodes += @{ hostname = "$mHostShort.$dnsSubdomain"; rootUserPassword = $vcfOpsRootPassword; type = "master" } 
    } else { 
        $mHost = Read-String "Enter Short Hostname for Master" "vcf-ops-master"; 
        $rHost = Read-String "Enter Short Hostname for Replica" "vcf-ops-replica"; 
        $dHost = Read-String "Enter Short Hostname for Data" "vcf-ops-data"
        $lbHost = Read-String "Enter Short Hostname for Load Balancer" "vcf-ops-lb"; $vcfOpsLbFqdn = "$lbHost.$dnsSubdomain"
        $vcfOpsNodes += @{ hostname = "$mHost.$dnsSubdomain"; rootUserPassword = $vcfOpsRootPassword; type = "master" }; 
        $vcfOpsNodes += @{ hostname = "$rHost.$dnsSubdomain"; rootUserPassword = $vcfOpsRootPassword; type = "replica" }; 
        $vcfOpsNodes += @{ hostname = "$dHost.$dnsSubdomain"; rootUserPassword = $vcfOpsRootPassword; type = "data" } 
    }
    
    $finalVcfOperationsSpec = @{ nodes = $vcfOpsNodes; adminUserPassword = $vcfOpsAdminPassword; applianceSize = $vcfOpsApplianceSize; useExistingDeployment = $false }
    if (-not [string]::IsNullOrWhiteSpace($vcfOpsLbFqdn)) { $finalVcfOperationsSpec["loadBalancerFqdn"] = $vcfOpsLbFqdn }
    
    # --- "vcfOperationsFleetManagementSpec" ---
    $fleetHostShort = Read-String "Enter Fleet Management Short Hostname" "vcf-ops-fleet"
    
    $fleetAdminPass = ""; $fleetRootPass = ""
    $fleetAdminPass = Get-PlainText (Read-SecureString "Enter Fleet Management Admin Password")
    $fleetRootPass = Get-PlainText (Read-SecureString "Enter Fleet Management Root Password")
    $finalVcfOpsFleetSpec = @{ hostname = "$fleetHostShort.$dnsSubdomain"; adminUserPassword = $fleetAdminPass; rootUserPassword = $fleetRootPass; useExistingDeployment = $false }
    
    # --- "vcfOperationsCollectorSpec" ---
    $collHostShort = Read-String "Enter Collector Short Hostname" "vcf-ops-collector"
    
    $collRootPass = ""
    $collRootPass = Get-PlainText (Read-SecureString "Enter Collector Root Password")
    $collSize = Read-String "Enter Collector Appliance Size" "small"; 
    $finalVcfOpsCollectorSpec = @{ hostname = "$collHostShort.$dnsSubdomain"; rootUserPassword = $collRootPass; applianceSize = $collSize; useExistingDeployment = $false }
    
    # --- VCF Automation Spec ---
    Write-Host "`n--- VCF Automation ---"; 
    $deployAutomation = Read-Boolean "Do you want to deploy VCF Automation?"
    if ($deployAutomation) {
        $autoHostShort = Read-String "Enter VCF Automation Hostname" "vcf-auto"; 
        $autoNodePrefix = Read-String "Enter VCF Automation Node Prefix" "auto-node"
        $ipCount = if ($vcfOpsNodeCount -eq 3) { 4 } else { 2 };
        $automationIPs = @()
        for ($i = 1; $i -le $ipCount; $i++) { $inputIP = ""; while (-not (Test-IPAddress $inputIP)) { $inputIP = Read-Host "Enter IP Address $i of $ipCount"; if (-not (Test-IPAddress $inputIP)) { Write-Warning "Invalid IP address format." } } $automationIPs += $inputIP }
        $cidrOptions = @("198.18.0.0/15", "240.0.0.0/15", "250.0.0.0/15"); $selectedCidr = Read-Choice "Select Internal Cluster CIDR" $cidrOptions
        $finalVcfAutomationSpec = @{ useExistingDeployment = $false; ipPool = $automationIPs; internalClusterCidr = $selectedCidr; hostname = "$autoHostShort.$dnsSubdomain"; nodePrefix = $autoNodePrefix }
    } else { 
        $finalVcfAutomationSpec = $null 
    }
}
# --- End VCF Operations Configuration Block ---

## 5. vCenter Inputs 
Write-Host "`n--- vCenter Configuration ---"
$vcHostShort = Read-String "Enter vCenter Short Hostname" "vc01"
$vcHostname = "$vcHostShort.$dnsSubdomain"

$vcPassword = ""
$vcPassword = Get-PlainText (Read-SecureString "Enter vCenter Passwords (root/admin)") 
$vcSize = Read-Choice "Select vCenter VM Size" @("xlarge", "large", "medium", "small", "tiny")
$vcStorage = Read-Choice "Select vCenter Storage Size" @("lstorage", "xlstorage")

# CHANGE 2: Prompt for SSO Domain
$ssoDomain = Read-String "Enter vCenter SSO Domain" "vsphere.local"


## 13. Cluster and Datacenter Spec 
Write-Host "`n--- Cluster and Datacenter Specification ---"
$clusterName = ""; $datacenterName = ""
while ([string]::IsNullOrWhiteSpace($clusterName) -or ($clusterName -eq $datacenterName)) {
    $clusterName = Read-String "Enter Cluster Name" "sfo-m01-cl01"
    $datacenterName = Read-String "Enter Datacenter Name" "sfo-m01-dc01"

    if ($clusterName -eq $datacenterName) {
        Write-Warning "Cluster Name and Datacenter Name cannot be the same. Please re-enter."
        $clusterName = ""
    }
}
$clusterSpec = @{ clusterName = $clusterName; datacenterName = $datacenterName }

## 7. Storage / Datastore Spec 
Write-Host "`n--- Storage Configuration ---"
$storageOptions = @("VSAN", "VMFS on Fiber Channel", "NFS v3")
$storageChoice = Read-Choice "Select Storage Type" $storageOptions
$finalDatastoreSpec = @{}
switch ($storageChoice) {
    "VSAN" {
        $dsName = Read-String "Enter Datastore Name" "vsanDatastore"; $esaEnabled = Read-Boolean "Is vSAN ESA Enabled?"
        $ftt = 0; while ($ftt -lt 1 -or $ftt -gt 3) { $inputVal = Read-Host "Enter Failures To Tolerate (1-3)"; if ($inputVal -match "^\d+$") { $ftt = [int]$inputVal } }
        $finalDatastoreSpec = @{ vsanSpec = @{ datastoreName = $dsName; vsanDedup = $false; esaConfig = @{ enabled = $esaEnabled }; failuresToTolerate = $ftt } }
    }
    "VMFS on Fiber Channel" {
        $dsName = Read-String "Enter Datastore Name" "fcDatastore"; $finalDatastoreSpec = @{ vmfsDatastoreSpec = @{ fcSpec = @(@{ datastoreName = $dsName }) } }
    }
    "NFS v3" {
        $dsName = Read-String "Enter Datastore Name" "nfsDatastore"; $nfsServer = ""; while (-not (Test-IPAddress $nfsServer)) { $nfsServer = Read-Host "Enter NFS Server IP Address"; if (-not (Test-IPAddress $nfsServer)) { Write-Warning "Invalid IP format." } }
        $nfsPath = Read-String "Enter NFS Path" "/nfs_mount/data"; $finalDatastoreSpec = @{ nfsDatastoreSpec = @{ datastoreName = $dsName; nasVolume = @{ serverName = @($nfsServer); path = $nfsPath; readOnly = $false; enableBindToVmknic = $false } } }
}
}


## 6. NSX-T Spec Configuration 
Write-Host "`n--- NSX-T Configuration ---"

# CHANGE 3: Prompt for NSX Manager Appliance Size
$nsxSizeOptions = @("xlarge", "large", "medium", "small")
$nsxtManagerSize = Read-Choice "Select NSX Manager Appliance Size (Default: medium)" $nsxSizeOptions

$modelName = $vcfOpsDeployModel
$nsxNodeCount = if ($modelName -eq "Simple (Single Node)") { 1 } else { 3 }
Write-Host "NSX-T deployment model being used: **$modelName** ($nsxNodeCount node(s))."

$nsxManagers = @(); 
for ($i = 1; $i -le $nsxNodeCount; $i++) { $nsxHostShort = Read-String "Enter NSX Manager Node $i Short Hostname" "nsx0$i"; $nsxManagers += @{ hostname = "$nsxHostShort.$dnsSubdomain" } }
$nsxVipShort = Read-String "Enter NSX VIP Short FQDN" "nsx-vip"

$nsxAdminPass = ""; $nsxAuditPass = ""; $nsxRootPass  = ""
$nsxAdminPass = Get-PlainText (Read-SecureString "Enter NSX Admin Password")
$nsxAuditPass = Get-PlainText (Read-SecureString "Enter NSX Audit Password")
$nsxRootPass  = Get-PlainText (Read-SecureString "Enter NSX Root Password")

# --- NSX-T GLOBAL KEYS ---
Write-Host "`n--- NSX-T Global Settings ---"
$rootLogin = Read-Boolean "Enable Root Login for NSX-T Manager?"
$sshEnabled = Read-Boolean "Enable SSH for NSX-T Manager?"

# --- NSX-T TEP VLAN ID ---
[int]$transportVlanId = 0
while ($transportVlanId -lt 1 -or $transportVlanId -gt 4095) {
    $inputVal = Read-String "Enter VLAN ID for Overlay Transport Network (1-4095)" "1114"
    if ($inputVal -match "^\d+$") { 
        $transportVlanId = [int]$inputVal 
        if ($transportVlanId -lt 1 -or $transportVlanId -gt 4095) { Write-Warning "VLAN ID must be between 1 and 4095." }
    } else {
        Write-Warning "Invalid VLAN ID format. Please enter a number."
        $transportVlanId = 0
    }
}

# --- NSX-T IP ADDRESS POOL SPEC (TEP) ---
Write-Host "`n--- NSX-T TEP IP Pool Configuration ---"
$poolName = Read-String "Enter Pool name for Host TEP IP Assignment" "sfo-m01-r01-ip-pool01-host"
$poolDescription = Read-String "Enter description for TEP IP Pool" "ESX Host Overlay TEP IP Pool"

$tepCidr = ""; while (-not (Test-CIDRFormat $tepCidr)) { $tepCidr = Read-String "Enter TEP Network CIDR" "10.11.14.0/24"; if (-not (Test-CIDRFormat $tepCidr)) { Write-Warning "Invalid CIDR format. (Must be X.X.X.X/Y)" } }
$tepGateway = ""; while (-not (Test-IPInCIDR $tepGateway $tepCidr)) { $tepGateway = Read-String "Enter TEP Network Gateway" "10.11.14.1"; if (-not (Test-IPInCIDR $tepGateway $tepCidr)) { Write-Warning "Gateway IP **$tepGateway** does not belong to the TEP subnet **$tepCidr**." } }
$tepStartIp = ""; while (-not (Test-IPInCIDR $tepStartIp $tepCidr)) { $tepStartIp = Read-Host "Enter TEP Start IP address (must be in $tepCidr range)"; if (-not (Test-IPInCIDR $tepStartIp $tepCidr)) { Write-Warning "Start IP address **$tepStartIp** is outside the subnet range." } }
$tepEndIp = ""; while (-not (Test-IPInCIDR $tepEndIp $tepCidr) -or ($tepEndIp -eq $tepStartIp)) { $tepEndIp = Read-Host "Enter TEP End IP address (must be in $tepCidr range and different from Start IP)"; if ($tepEndIp -eq $tepStartIp) { Write-Warning "End IP address must be different from Start IP address." } elseif (-not (Test-IPInCIDR $tepEndIp $tepCidr)) { Write-Warning "End IP address **$tepEndIp** is outside the subnet range." } }

$ipPoolSpec = @{
    name = $poolName;
    description = $poolDescription;
    subnets = @(
        @{
            cidr = $tepCidr;
            gateway = $tepGateway;
            ipAddressPoolRanges = @( @{ start = $tepStartIp; end = $tepEndIp } )
        }
    )
}

# Combine all NSX-T properties
$nsxtSpec = [ordered]@{ 
    # Value now comes from user prompt
    nsxtManagerSize = $nsxtManagerSize; 
    nsxtManagers = $nsxManagers; 
    vipFqdn = "$nsxVipShort.$dnsSubdomain"; 
    useExistingDeployment = $false; 
    nsxtAdminPassword = $nsxAdminPass; 
    nsxtAuditPassword = $nsxAuditPass; 
    rootNsxtManagerPassword = $nsxRootPass; 
    skipNsxOverlayOverManagementNetwork = $true;

    transportVlanId = $transportVlanId.ToString();
    rootLoginEnabledForNsxtManager = $rootLogin.ToString().ToLower(); 
    sshEnabledForNsxtManager = $sshEnabled.ToString().ToLower();     
    ipAddressPoolSpec = $ipPoolSpec 
}

## 12. SDDC Manager Spec
Write-Host "`n--- SDDC Manager Specification ---"

$sddcHostShort = Read-String "Enter SDDC Manager Short Hostname" "sfo-vcf01"
$sddcHostname = "$sddcHostShort.$dnsSubdomain"

$sddcRootPass = ""; $sddcSshPass = ""; $sddcLocalUserPass = ""
$sddcRootPass = Get-PlainText (Read-SecureString "Enter SDDC Manager Root Password")
$sddcSshPass = Get-PlainText (Read-SecureString "Enter SDDC Manager SSH Password")
$sddcLocalUserPass = Get-PlainText (Read-SecureString "Enter SDDC Manager Local User Password")

$sddcManagerSpec = @{
    hostname = $sddcHostname;
    useExistingDeployment = $false;
    rootPassword = $sddcRootPass;
    sshPassword = $sddcSshPass;
    localUserPassword = $sddcLocalUserPass
}

## 9. Host Specs
Write-Host "`n--- ESXi Host Configuration ---"
$hostSpecsList = @()

$commonHostPassword = ""
$commonHostPassword = Get-PlainText (Read-SecureString "Enter COMMON password for all ESXi hosts")

while ($true) {
    $hostShort = Read-Host -Prompt "Enter Host Short Hostname (leave blank to finish)"
    if ([string]::IsNullOrWhiteSpace($hostShort)) { break }
    
    $fullHostname = "$hostShort.$dnsSubdomain"
    
    if ($fullHostname -in $usedHostnames) {
        Write-Warning "Hostname '$fullHostname' has already been entered. Hostnames must be unique."
        continue 
    }
    
    $thumbprint = Read-String "Enter SSL Thumbprint for $fullHostname" "AA:BB:CC..."
    $hostSpecsList += @{ hostname = $fullHostname; credentials = @{ username = "root"; password = $commonHostPassword }; sslThumbprint = $thumbprint }
    $usedHostnames += $fullHostname
}

# --------------------------------------------------------------------------------------------------
# CRITICAL FIX: Prompt for Transport Zones here so they are available for DVS configuration functions.
# --------------------------------------------------------------------------------------------------
Write-Host "`n--- NSX-T Transport Zone Configuration (Needed for DVS Setup) ---"
$overlayTZName = Read-String "Enter Overlay Transport Zone Name" "Overlay-TZ"
$vlanTZName = Read-String "Enter VLAN Transport Zone Name (optional, leave blank if not needed)" ""
# --------------------------------------------------------------------------------------------------


# --- DVS and Network Configuration Start ---

## 11. Distributed Switch Specifications (DVS Specs)
Write-Host "`n--- Distributed Switch (DVS) Configuration ---"
[int]$vmnicCount = 0
while ($vmnicCount -lt 2) {
    $inputVal = Read-Host -Prompt "Enter the number of Physical Adapters (vmnics) [Must be 2 or greater]"
    if ($inputVal -match "^\d+$") { $vmnicCount = [int]$inputVal; if ($vmnicCount -lt 2) { Write-Warning "Minimum vmnic count is 2." } } else { Write-Warning "Invalid input. Please enter a number." }
}
# Initial DVS Models
$dvsModels = [System.Collections.ArrayList]@("Default distributed switch", "Storage separation distributed Switch", "Workload Separation Distributed Switch Model")

# Conditional addition of the new 3-DVS model
$showThreeDVSModel = ($vmnicCount -ge 6 -and $storageChoice -eq "VSAN")
if ($showThreeDVSModel) {
    # CHANGE: Model is only shown if vmnic >= 6 AND Storage is VSAN
    $null = $dvsModels.Add("Storage and Workload Separation Distributed Switch Model Attributes")
}

$availableModels = $dvsModels; $modelNotes = ""
if ($storageChoice -ne "VSAN") {
    # Remove Storage Separation if not VSAN
    $availableModels = $availableModels | Where-Object { $_ -ne "Storage separation distributed Switch" }; $modelNotes += " (Note: 'Storage separation' model is unavailable because VSAN was NOT selected.)"
}
if ($vmnicCount -lt 6 -and $showThreeDVSModel) {
    # Remove the 3-DVS model if vmnics are too few
     $availableModels = $availableModels | Where-Object { $_ -ne "Storage and Workload Separation Distributed Switch Model Attributes" }; 
}
if ($vmnicCount -eq 2) {
    # If only 2 vmnics, only the default single DVS setup is possible
    $availableModels = @("Default distributed switch"); $modelNotes += " (Note: Only 'Default distributed switch' is available for 2 vmnics.)"
}
Write-Host "`nAvailable Distributed Switch Models:$modelNotes"

$dvsModelChoice = ""
if ($vmnicCount -eq 2) {
    $dvsModelChoice = "Default distributed switch"; Write-Host "Selected DVS Model: **$dvsModelChoice**"
} else {
    $dvsModelChoice = Read-Choice "Select Distributed Switch Model" $availableModels
}

$dvsSpecs = @(); 
$dvs1 = $null; $dvs2 = $null; $dvs3 = $null; 
$dvsUplinkMap = @{}
$allVmnics = @(); for ($i = 0; $i -lt $vmnicCount; $i++) { $allVmnics += "vmnic$i" }

if ($dvsModelChoice -eq "Workload Separation Distributed Switch Model" -or $dvsModelChoice -eq "Storage separation distributed Switch") {
    
    # FIXED: The function now has the TZ names passed as mandatory parameters
    $dvsReturn = Configure-SeparatedDVS `
        -dvsModel $dvsModelChoice `
        -storageChoice $storageChoice `
        -vmnicCount $vmnicCount `
        -dnsSubdomain $dnsSubdomain `
        -overlayTZName $overlayTZName `
        -vlanTZName $vlanTZName

    if ($dvsReturn -eq $null -or @($dvsReturn).Count -lt 4) {
        Write-Error "CRITICAL ARRAY ERROR: DVS configuration function failed to return the expected 4 elements."
        exit 1 
    }
    
    $dvs1 = $dvsReturn[0]
    $dvs2 = $dvsReturn[1]
    $allRequiredNetworks = $dvsReturn[2]
    $dvsUplinkMap = $dvsReturn[3]
    
    $dvsSpecs += $dvs1; 
    if ($dvs2) { $dvsSpecs += $dvs2 }

} elseif ($dvsModelChoice -eq "Storage and Workload Separation Distributed Switch Model Attributes") {
    
    # NEW 3-DVS Logic
    Write-Host "`n--- Configuring 3 Distributed Switches (Management, Storage, NSX Workload) ---" -ForegroundColor Green
    
    $dvsReturn = Configure-ThreeDVS `
        -storageChoice $storageChoice `
        -vmnicCount $vmnicCount `
        -overlayTZName $overlayTZName `
        -vlanTZName $vlanTZName

    if ($dvsReturn -eq $null -or @($dvsReturn).Count -lt 5) {
        Write-Error "CRITICAL ARRAY ERROR: 3-DVS configuration function failed to return the expected 5 elements."
        exit 1 
    }
    
    $dvs1 = $dvsReturn[0] # Management
    $dvs2 = $dvsReturn[1] # Storage
    $dvs3 = $dvsReturn[2] # NSX Workload
    $allRequiredNetworks = $dvsReturn[3]
    $dvsUplinkMap = $dvsReturn[4]
    
    $dvsSpecs += $dvs1; 
    $dvsSpecs += $dvs2;
    $dvsSpecs += $dvs3;

} else {
    # Single DVS configuration (Default distributed switch)
    $dvsName = Read-String "Enter Distributed Switch Name" "sdc-m01-vds"
    [int]$dvsMTU = 0
    while ($dvsMTU -lt 1500 -or $dvsMTU -gt 9000) {
        $inputVal = Read-String "Enter MTU for DVS (numeric, 1500-9000)" "9000"
        if ($inputVal -match "^\d+$") { $dvsMTU = [int]$inputVal; if ($dvsMTU -lt 1500 -or $dvsMTU -gt 9000) { Write-Warning "MTU value must be between 1500 and 9000." } } 
        else { Write-Warning "Invalid MTU format. Please enter a number."; $dvsMTU = 0 }
    }
    
    # FIXED: TZ names are now available
    $transportZones = @( @{ name = $overlayTZName; transportType = "OVERLAY" } )
    if (-not [string]::IsNullOrWhiteSpace($vlanTZName)) { $transportZones += @{ name = $vlanTZName; transportType = "VLAN" } }
    
    # *** INTERACTIVE MAPPING FOR SINGLE DVS (Using FIXED Function) ***
    $vmnicsToUplinks = Interactively-MapVmnicsToUplinks -DvsName $dvsName -VmnicsForDVS $allVmnics
    
    # Extract available uplinks for the single DVS (guaranteed to be uplink1, uplink2, etc.)
    $dvsAvailableUplinks = @($vmnicsToUplinks | Select-Object -ExpandProperty uplink | Select-Object -Unique | Sort-Object)
    # CORRECT: Use the DVS name string as the key
    $dvsUplinkMap = @{ $dvsName = $dvsAvailableUplinks }

    $dvsNetworks = @( "MANAGEMENT", "VM_MANAGEMENT", "VMOTION" ) 
    if ($storageChoice -eq "VSAN") { $dvsNetworks += "VSAN" }
    $allRequiredNetworks = $dvsNetworks
    
    # Get user selection for NSX Teaming on the single DVS
    $nsxActiveUplinks = @()
    if (@($dvsAvailableUplinks).Count -gt 0) {
        # Pass the guaranteed array of uplinks
        $nsxActiveUplinks = Read-UplinkSelection -NetworkOrPolicyName "NSX-T TEP (Single DVS)" -DVSName $dvsName -AvailableUplinks $dvsAvailableUplinks
    }
    $nsxtTeamings = @()
    if (@($nsxActiveUplinks).Count -gt 0) {
        $nsxtTeamings += @{ policy = "LOADBALANCE_SRCID"; activeUplinks = $nsxActiveUplinks }
    } else {
        Write-Warning "No active uplinks selected for NSX-T on the single DVS. The NSX Teaming policy will be omitted."
    }

    $tempDvs1 = [ordered]@{
        dvsName = $dvsName; 
        mtu = $dvsMTU.ToString();
        networks = $dvsNetworks; 
        nsxtSwitchConfig = @{ transportZones = $transportZones };
        vmnicsToUplinks = $vmnicsToUplinks;
        nsxTeamings = if (@($nsxtTeamings).Count -gt 0) { $nsxtTeamings } else { $null }
    }
    
    $dvs1 = [ordered]@{}
    foreach ($entry in $tempDvs1.GetEnumerator()) {
        if ($entry.Value -ne $null) {
            $dvs1.Add($entry.Key, $entry.Value)
        }
    }
    $dvsSpecs += $dvs1
}

# --- Add VCF Operations Dedicated Network if needed ---
if ($isAdvancedDedicated -and $deployVcfOperations) { 
    $allRequiredNetworks += "VCF_OPERATIONS" 
}
# -----------------------------------------------------


## 10. Network Specifications

if ($allRequiredNetworks -eq $null -or @($allRequiredNetworks).Count -eq 0) {
    Write-Error "CRITICAL ERROR: No required networks were defined after DVS configuration. The script cannot continue."
    exit 1 
}

# --- ESXi HOST NETWORK SPECIFICATIONS ---
Write-Host "`n=========================================================================="
Write-Host "## 📋 ESXi HOST NETWORK SPECIFICATIONS (IP, VLAN, and PORT GROUP CONFIGURATION)"
Write-Host "=========================================================================="
# --- END ESXi HOST NETWORK SPECIFICATIONS ---
$finalNetworkSpecs = @()
$vlanCounter = 1111 

foreach ($netType in $allRequiredNetworks) {
    
    if ($netType -eq "VCF_OPERATIONS") {
        $finalNetworkSpecs += $vcfOperationsNetworkSpec
        continue
    }

    $displayMsg = if ($netType -eq "MANAGEMENT") { "Configuring ESX Management Network ($netType)" } else { "Configuring Network: $netType" }
    Write-Host "`n--- $displayMsg ---"
    
    $cidrExample = "10.11.$vlanCounter.0/24"; $gatewayExample = "10.11.$vlanCounter.1"
    if ($netType -eq "MANAGEMENT") { $cidrExample = "10.11.11.0/24"; $gatewayExample = "10.11.11.1"; $vlanCounter = 111 } 
    elseif ($netType -eq "VM_MANAGEMENT") { $cidrExample = "10.11.12.0/24"; $gatewayExample = "10.11.12.1"; $vlanCounter = 112 }
    elseif ($netType -eq "VMOTION") { $cidrExample = "10.11.13.0/24"; $gatewayExample = "10.11.13.1"; $vlanCounter = 113 }
    elseif ($netType -eq "VSAN") { $cidrExample = "10.11.14.0/24"; $gatewayExample = "10.11.14.1"; $vlanCounter = 114 }
    
    $subnet = ""; while (-not (Test-CIDRFormat $subnet) -or ($subnet -in $usedSubnets)) { $subnet = Read-String "Enter $netType Subnet (CIDR)" $cidrExample; if ($subnet -in $usedSubnets) { Write-Warning "CIDR '$subnet' is already used. Subnets must be unique."; $subnet = "" } }
    $usedSubnets += $subnet
    
    $gateway = ""; while (-not (Test-IPInCIDR $gateway $subnet)) { $gateway = Read-String "Enter $netType Gateway" $gatewayExample; if (-not (Test-IPInCIDR $gateway $subnet)) { Write-Warning "Gateway IP **$gateway** does not belong to the subnet **$subnet**." } }
    
    [int]$vlanId = 0
    while ($vlanId -lt 1 -or $vlanId -gt 4095) {
        $inputVal = Read-String "Enter $netType VLAN ID (1-4095)" "$vlanCounter"
        if ($inputVal -match "^\d+$") { $vlanId = [int]$inputVal; if ($vlanId -lt 1 -or $vlanId -gt 4095) { Write-Warning "VLAN ID must be between 1 and 4095." } } else { Write-Warning "Invalid VLAN ID format. Please enter a number."; $vlanId = 0 }
    }
    
    $mtuVal = 1500
    if ($netType -in @("VMOTION", "VSAN")) { $mtuVal = 9000 }
    
    $pgKey = Read-UniquePortGroupName "Enter Port Group Name for $netType Network (Must be unique)" "$netType-PG" $usedPortGroupNames
    $usedPortGroupNames += $pgKey
    
    $ipRangeSpec = $null
    if ($netType -in @("VMOTION", "VSAN")) {
        Write-Host "`n-- IP Address Range for Host Configuration --"
        $startIp = ""; $endIp = ""

        while (-not (Test-IPInCIDR $startIp $subnet)) { $startIp = Read-Host "Enter $netType Start IP address (must be in $subnet range)"; if (-not (Test-IPInCIDR $startIp $subnet)) { Write-Warning "Start IP address **$startIp** is outside the subnet range." } }
        while (-not (Test-IPInCIDR $endIp $subnet) -or ($endIp -eq $startIp)) { $endIp = Read-Host "Enter $netType End IP address (must be in $subnet range and different from Start IP)"; if ($endIp -eq $startIp) { Write-Warning "End IP address must be different from Start IP address." } elseif (-not (Test-IPInCIDR $endIp $subnet)) { Write-Warning "End IP address **$endIp** is outside the subnet range." } }
        
        $ipRangeSpec = @( @{ startIpAddress = $startIp; endIpAddress = $endIp } )
    }
    
    # Determine which DVS this network belongs to
    $dvsNameForNet = ""
    $found = $false
    # Check 3-DVS first
    if ($dvs3 -ne $null) {
        if ($netType -in @("MANAGEMENT", "VMOTION", "VM_MANAGEMENT")) { $dvsNameForNet = $dvs1.dvsName; $found = $true }
        elseif ($netType -eq "VSAN") { $dvsNameForNet = $dvs2.dvsName; $found = $true }
        # NSX TEP uses DVS 3, but this loop only iterates over management/storage networks, so we ignore DVS 3 here.
    }
    # Check 2-DVS
    if (-not $found) {
        if ($dvs2 -ne $null) {
            if ($dvs2.networks -contains $netType) { $dvsNameForNet = $dvs2.dvsName; $found = $true }
        }
        # Default to DVS 1
        if (-not $found) { $dvsNameForNet = $dvs1.dvsName }
    }

    if ([string]::IsNullOrWhiteSpace($dvsNameForNet)) {
        Write-Error "Could not determine the Distributed Switch for network type '$netType'. Skipping teaming configuration."
        $activeUplinks = @()
    } else {
        # CRITICAL ACCESS: Retrieve the correct array of uplink names using the DVS name string
        $currentAvailableUplinks = @($dvsUplinkMap[$dvsNameForNet])
        
        # Get user selection for the network's active uplinks (Pass the guaranteed array)
        $activeUplinks = Read-UplinkSelection -NetworkOrPolicyName "$netType Network" -DVSName $dvsNameForNet -AvailableUplinks $currentAvailableUplinks
    }

    $networkSpec = @{
        networkType = $netType; subnet = $subnet; gateway = $gateway; vlanId = $vlanId.ToString(); mtu = $mtuVal.ToString();
        teamingPolicy = "loadbalance_loadbased"; 
        activeUplinks = $activeUplinks; 
        standbyUplinks = $null;
        portGroupKey = $pgKey 
    }

    if ($ipRangeSpec) {
        $networkSpec["includeIpAddressRanges"] = $ipRangeSpec
    }

    $finalNetworkSpecs += $networkSpec
}

## 🏗️ Build the Complex Object Structure 

$jsonOutput = [ordered]@{
    sddcId = $sddcId; 
    vcfInstanceName = $vcfInstanceName; 
    workflowType = $workflowType; 
    version = $version; 
    ceipEnabled = $ceipEnabled;
    dnsSpec = @{ nameservers = $dnsServers; subdomain = $dnsSubdomain }; 
    ntpServers = $ntpServersList;
    vcenterSpec = @{
        vcenterHostname = $vcHostname; 
        rootVcenterPassword = $vcPassword; 
        vmSize = $vcSize; 
        storageSize = $vcStorage; 
        adminUserSsoPassword = $vcPassword; 
        ssoDomain = $ssoDomain; 
        useExistingDeployment = $false
    };
    clusterSpec = $clusterSpec;
    sddcManagerSpec = $sddcManagerSpec;
    nsxtSpec = $nsxtSpec;
    datastoreSpec = $finalDatastoreSpec;
    hostSpecs = $hostSpecsList;
    networkSpecs = $finalNetworkSpecs;
    dvsSpecs = $dvsSpecs 
}

# --- Conditional Member Insertion (VCF Operations) ---
if ($deployVcfOperations) {
    Write-Host "`nAdding VCF Operations specs to JSON output."
    $jsonOutput.Add("vcfOperationsSpec", $finalVcfOperationsSpec)
    $jsonOutput.Add("vcfOperationsFleetManagementSpec", $finalVcfOpsFleetSpec)
    $jsonOutput.Add("vcfOperationsCollectorSpec", $finalVcfOpsCollectorSpec)

    if ($finalVcfAutomationSpec -ne $null) {
        $jsonOutput.Add("vcfAutomationSpec", $finalVcfAutomationSpec)
    }

    if ($isAdvancedDedicated) {
        $jsonOutput.Add("vcfOperationsNetworkType", "ADVANCED_DEDICATED")
    }
}
# ------------------------------------


# Serialize and Write to File
$jsonOutput | ConvertTo-Json -Depth 100 | Out-File -FilePath $outputFilePath -Encoding UTF8

Write-Host "`nSuccessfully generated JSON configuration file at $outputFilePath"
