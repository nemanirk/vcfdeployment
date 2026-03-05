# ==========================================
# VMware Cloud Foundation - Host Spec Generator
# with AUTOMATED Thumbprint Retrieval and SDDC Validation
# ==========================================

# ... [Previous logic for collecting values and generating $hosts array remains unchanged] ...

# ==========================================
# VMware Cloud Foundation - Host Spec Generator
# with AUTOMATED Thumbprint Retrieval (requires plink.exe)
# ==========================================

# ==========================================
# This is an update version of the Host comission Script. This script connects to each host and retrieves the SSL fingerprint and SSH thumbprint.
# The SSH service must be running on the hosts for the sript to connect and succesfully retrieve the ssh thumbprint.
# with AUTOMATED Thumbprint Retrieval (requires plink.exe)
# ==========================================


# 1. Collect shared values
$username        = "root"
$password        = Read-Host "Enter password for ESXi root"
$networkPoolName = Read-Host "Enter network pool name"
$domainName      = Read-Host "Enter domain name (e.g. lab.local)"

# 2. Ask if host names are sequential
do {
    $isSequential = Read-Host "Are the host names sequential with numeric suffix? (yes/no)"
    $isSequential = $isSequential.Trim().ToLower()
} while ($isSequential -ne "yes" -and $isSequential -ne "no")

# 3. Prompt for storage type choice (shared)
$storageOptions = @("VSAN", "VSAN_ESA", "VSAN_REMOTE", "VSAN_MAX", "NFS", "VMFS_FC", "VVOL", "VMFS")

Write-Host "`nSelect Storage Type:"
for ($i = 0; $i -lt $storageOptions.Count; $i++) {
    Write-Host "[$($i+1)] $($storageOptions[$i])"
}

do {
    $storageChoice = Read-Host "Enter choice number (1-$($storageOptions.Count))"
} while (-not ($storageChoice -as [int]) -or $storageChoice -lt 1 -or $storageChoice -gt $storageOptions.Count)

$storageType = $storageOptions[$storageChoice - 1]

$hosts = @()

# 4. Host List Generation Logic
if ($isSequential -eq "yes") {
    # Validate suffix base is numeric string and prompt until valid
    do {
        $suffixBase = Read-Host "Enter host suffix base (numeric, e.g. 01)"
        $canConvert = [int]::TryParse($suffixBase, [ref]$null)
        if (-not $canConvert) {
            Write-Host "Invalid suffix. Please enter a numeric suffix base like 01 or 1." -ForegroundColor Red
        }
    } while (-not $canConvert)

    # Validate number of hosts input between 1 and 50
    function Get-NumberOfHosts {
        [CmdletBinding()]
        Param()
        $isValid = $false
        $numberOfHosts = 0
        do {
            try {
                $input = Read-Host -Prompt "Enter the number of hosts (1-50)"
                $numberOfHosts = [int]$input
                if ($numberOfHosts -ge 1 -and $numberOfHosts -le 50) {
                    $isValid = $true
                } else {
                    Write-Warning "The number of hosts must be between 1 and 50."
                }
            }
            catch [System.Management.Automation.RuntimeException] {
                Write-Warning "Invalid input. Please enter a valid integer."
            }
        } while (-not $isValid)
        return $numberOfHosts
    }

    $hostCount = Get-NumberOfHosts
    $baseHostName = Read-Host "Enter base host name (without suffix/domain)"
    $suffixLength = $suffixBase.Length
    $suffixNumber = [int]$suffixBase

    for ($i = 0; $i -lt $hostCount; $i++) {
        $currentSuffix = "{0:D$suffixLength}" -f ($suffixNumber + $i)
        $hostFqdn = "$baseHostName$currentSuffix.$domainName"

        $hosts += [pscustomobject]@{
            fqdn            = $hostFqdn
            username        = $username
            password        = $password
            storageType     = $storageType
            networkPoolName = $networkPoolName
            sslThumbprint   = ""
            sshThumbprint   = ""
        }
    }
} else {
    do {
        $filePath = Read-Host "Enter path to text file with hostnames (one per line)"
        $filePath = $filePath.Trim('"') 
        if (-not (Test-Path -Path $filePath)) {
            Write-Host "File not found. Please enter a valid file path." -ForegroundColor Red
        }
    } while (-not (Test-Path -Path $filePath))

    $hostNamesFromFile = Get-Content -Path $filePath | Where-Object { $_.Trim() -ne "" }

    foreach ($rawName in $hostNamesFromFile) {
        $hostName = $rawName.Trim()
        if ($hostName -like "*.$domainName" -or $hostName.EndsWith($domainName, [StringComparison]::OrdinalIgnoreCase)) {
            $hostFqdn = $hostName 
        } else {
            $hostFqdn = "$hostName.$domainName"
        }
        $hosts += [pscustomobject]@{
            fqdn            = $hostFqdn
            username        = $username
            password        = $password
            storageType     = $storageType
            networkPoolName = $networkPoolName
            sslThumbprint   = ""
            sshThumbprint   = ""
        }
    }
}

# ==========================================
# 5. Automated Thumbprint Retrieval
# ==========================================
Write-Host "`n----------------------------------------"
$retrieveThumbprints = Read-Host "Do you want to automatically retrieve SSL/SSH thumbprints? (yes/no)"

if ($retrieveThumbprints.ToLower().Trim() -eq "yes") {
    
    # Check dependencies
    $hasOpenSSL = (Get-Command openssl.exe -ErrorAction SilentlyContinue)
    
    # CHECK FOR PLINK (Required for password automation)
    $hasPlink = (Get-Command plink.exe -ErrorAction SilentlyContinue)

    if (-not $hasOpenSSL -or -not $hasPlink) {
        Write-Warning "Missing Dependencies:"
        if (-not $hasOpenSSL) { Write-Warning " - OpenSSL.exe not found." }
        if (-not $hasPlink)   { Write-Warning " - plink.exe (PuTTY Link) not found. Required for password automation." }
        Write-Error "Cannot proceed. Please install OpenSSL and PuTTY (plink.exe) and add to PATH."
        # Don't exit script, just skip retrieval so user gets partial JSON
    } 
    else {
        Write-Host "`nStarting Automated Retrieval..." -ForegroundColor Cyan

        foreach ($hostObj in $hosts) {
            $targetHost = $hostObj.fqdn
            Write-Host "`nProcessing: $targetHost" -ForegroundColor Cyan

            # --- A. Get SSL Thumbprint ---
            try {
                $OpenSslCmd = "echo Q | openssl s_client -connect ${targetHost}:443 2>NUL | openssl x509 -noout -fingerprint -sha256"
                $Output = cmd /c $OpenSslCmd
                
                if ($Output -match "Fingerprint=(.+)") {
                    $hostObj.sslThumbprint = $matches[1]
                    Write-Host " [SSL] Retrieved: $($hostObj.sslThumbprint)" -ForegroundColor Green
                } else {
                    Write-Warning " [SSL] Failed to retrieve or parse output."
                }
            } catch {
                Write-Warning " [SSL] Error: $_"
            }

            # --- B. Get SSH Thumbprint (using PLINK for auth) ---
            try {
                # Plink arguments:
                # -batch : Disable interactive prompts
                # -ssh   : Use SSH protocol
                # -pw    : Pass the password variable
                # -o StrictHostKeyChecking=no : Auto-accept host keys (Command syntax differs slightly for Plink vs SSH)
                
                # Note: Plink handles "StrictHostKeyChecking" by answering 'y' to prompts if piped "echo y", 
                # but modern plink has -batch which aborts on prompts.
                # To bypass host key prompt in Plink effectively without manual intervention:
                $PlinkCmd = "echo y | plink -ssh -l root -pw $password $targetHost ""cat /etc/ssh/ssh_host_rsa_key.pub"""
                
                # Invoke via cmd /c to handle the pipe "echo y | plink"
                $PublicKeyString = cmd /c $PlinkCmd

                # Parse output (Plink might output the key along with "Access granted" or banner info)
                # We specifically look for the "ssh-rsa ..." line
                if ($PublicKeyString -match "(ssh-rsa\s+[A-Za-z0-9+/]+={0,2})") {
                    $CleanKey = $matches[1]
                    
                    # Calculate SHA256 locally
                    $Parts = $CleanKey.Trim() -split " "
                    if ($Parts.Count -ge 2) {
                        $Base64Key = $Parts[1]
                        $KeyBytes = [System.Convert]::FromBase64String($Base64Key)
                        $Sha256 = [System.Security.Cryptography.SHA256]::Create()
                        $HashBytes = $Sha256.ComputeHash($KeyBytes)
                        $ThumbRaw = [System.Convert]::ToBase64String($HashBytes).TrimEnd('=')
                        
                        $hostObj.sshThumbprint = "SHA256:$ThumbRaw"
                        Write-Host " [SSH] Retrieved: $($hostObj.sshThumbprint)" -ForegroundColor Green
                    }
                } else {
                    Write-Warning " [SSH] Failed. Output did not contain a valid public key."
                    # Debug output if needed: Write-Host $PublicKeyString
                }
            } catch {
                Write-Warning " [SSH] Error: $_"
            }
        }
    }
} else {
    Write-Host "Skipping interactive thumbprint retrieval." -ForegroundColor Gray
}

# # ==========================================
# VMware Cloud Foundation - Host Spec Generator
# Single-Auth for Pool Lookup & Validation
# ==========================================

# ... [Previous logic for collecting $username, $password, $hosts array remains unchanged] ...

# # ==========================================
# 5.5. SDDC Manager Integration (Pool Lookup & Auth)
# ==========================================
Write-Host "`n----------------------------------------"
$connectSddc = Read-Host "Connect to SDDC Manager for Network Pool IDs and Validation? (y/n)"
$globalToken = $null
$sddcFqdn = ""

if ($connectSddc.ToLower().Trim() -eq "y") {
    $sddcFqdn = Read-Host "Enter SDDC Manager FQDN"
    $sddcUser = "administrator@vsphere.local"
    $sddcPass = Read-Host "Enter password for $sddcUser" -AsSecureString
    
    # Secure string handling
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sddcPass)
    $plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)

    try {
        Write-Host "Authenticating with SDDC Manager..." -ForegroundColor Cyan
        $globalToken = Get-SddcAuthToken -Fqdn $sddcFqdn -User $sddcUser -Pass $plainPass
        $headers = @{
            "Authorization" = "Bearer $globalToken"
            "Content-Type"  = "application/json"
        }

        # Fetch Network Pools
        Write-Host "Retrieving Network Pools..." -ForegroundColor Gray
        $poolUrl = "https://$sddcFqdn/v1/network-pools"
        $poolsResponse = Invoke-RestMethod -Method Get -Uri $poolUrl -Headers $headers -SkipCertificateCheck

        # FIX: The API returns pools inside an 'elements' array
        $poolList = $poolsResponse.elements

        # Perform Lookup
        foreach ($hostObj in $hosts) {
            # Search inside the 'elements' array for a matching name
            $matchedPool = $poolList | Where-Object { $_.name -eq $hostObj.networkPoolName }
            
            if ($null -ne $matchedPool) {
                # Add the ID to the host object
                $hostObj | Add-Member -MemberType NoteProperty -Name "networkPoolId" -Value $matchedPool.id -Force
                Write-Host "SUCCESS: Mapped '$($hostObj.networkPoolName)' to ID: $($matchedPool.id) for $($hostObj.fqdn)" -ForegroundColor Green
            } else {
                Write-Warning "FAILED: Network Pool '$($hostObj.networkPoolName)' not found in SDDC Manager."
                $hostObj | Add-Member -MemberType NoteProperty -Name "networkPoolId" -Value "NOT_FOUND" -Force
            }
        }
    }
    catch {
        Write-Error "Failed to integrate with SDDC Manager: $($_.Exception.Message)"
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

# ==========================================
# 6. JSON Export (Removed hostSpecs Wrapper)
# ==========================================

# Determine output filename
$directory = Get-Location
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$path      = Join-Path -Path $directory -ChildPath "hostCommission_$timestamp.json"

# Export the raw array directly
$jsonContent = $hosts | ConvertTo-Json -Depth 5
$jsonContent | Set-Content -Path $path -Encoding UTF8

Write-Host "`n----------------------------------------"
Write-Host "JSON saved (Raw Array) to: $path" -ForegroundColor Green

# # ==========================================
# 7. SDDC Manager Validation & Commissioning
# ==========================================
if ($null -ne $globalToken) {
    $doValidate = Read-Host "`nWould you like to validate this spec against SDDC Manager now? (y/n)"
    
    if ($doValidate.ToLower().Trim() -eq "y") {
        try {
            $valHeaders = @{
                "Authorization" = "Bearer $globalToken"
                "Content-Type"  = "application/json"
            }

            Write-Host "Submitting Host Commission Validation..." -ForegroundColor Yellow
            $valUrl = "https://$sddcFqdn/v1/hosts/validations"
            $valResponse = Invoke-RestMethod -Method Post -Uri $valUrl -Body $jsonContent -Headers $valHeaders -SkipCertificateCheck
            
            $valId = $valResponse.id
            Write-Host "Validation Task Submitted. ID: $valId" -ForegroundColor Green

            # --- Polling Logic ---
            $statusUrl = "https://$sddcFqdn/v1/hosts/validations/$valId"
            $isFinished = $false
            
            while (-not $isFinished) {
                $statusResp = Invoke-RestMethod -Method Get -Uri $statusUrl -Headers $valHeaders -SkipCertificateCheck
                
                # Retrieve executionStatus (IN_PROGRESS, COMPLETED, FAILED)
                $execStatus = $statusResp.executionStatus
                # Retrieve resultStatus (SUCCEEDED, FAILED) - may be null until COMPLETED
                $resStatus  = if ($statusResp.PSObject.Properties['resultStatus']) { $statusResp.resultStatus } else { "PENDING" }

                $time = Get-Date -Format "HH:mm:ss"
                Write-Host "[$time] Execution: $execStatus | Result: $resStatus" -ForegroundColor Cyan

                if ($execStatus -eq "COMPLETED" -or $execStatus -eq "FAILED") {
                    $isFinished = $true
                    Write-Host "`nValidation Process Finished." -ForegroundColor Gray
                    
                    if ($resStatus -eq "SUCCEEDED") {
                        Write-Host "SUCCESS: Host specification is valid for commissioning!" -ForegroundColor Green
                        
                        # --- COMMISSION TRIGGER ---
                        do {
                            $commChoice = Read-Host "`nDo you want to commission these hosts now? (y/n)"
                        } while ($commChoice -notmatch "^[yn]$")

                        if ($commChoice -eq 'y') {
                            Write-Host "Submitting Host Commissioning Request..." -ForegroundColor Yellow
                            $commUrl = "https://$sddcFqdn/v1/hosts"
                            $commResp = Invoke-RestMethod -Method Post -Uri $commUrl -Body $jsonContent -Headers $valHeaders -SkipCertificateCheck
                            
                            Write-Host "`n===========================================================" -ForegroundColor Green
                            Write-Host "COMMISSION TASK SUBMITTED SUCCESSFULLY"
                            Write-Host "Task ID: $($commResp.id)" -ForegroundColor White
                            Write-Host "Please monitor progress in the SDDC Manager UI under 'Tasks'."
                            Write-Host "===========================================================" -ForegroundColor Green
                        } else {
                            Write-Host "Commissioning skipped by user." -ForegroundColor Gray
                        }
                    } 
                    else {
                        Write-Host "FAILED: Validation encountered errors." -ForegroundColor Red
                        # Print errors if available
                        if ($statusResp.PSObject.Properties['validationResults']) {
                            $statusResp.validationResults | Where-Object { $_.status -eq "FAILED" } | ForEach-Object {
                                Write-Host " - [$($_.name)]: $($_.errorMessages)" -ForegroundColor Red
                            }
                        }
                    }
                } 
                else {
                    # Status is likely IN_PROGRESS, wait 60 seconds
                    Start-Sleep -Seconds 60
                }
            }
        }
        catch {
            Write-Error "API Workflow Error: $($_.Exception.Message)"
        }
    }
}
