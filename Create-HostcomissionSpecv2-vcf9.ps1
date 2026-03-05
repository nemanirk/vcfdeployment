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

# ==========================================
# 6. JSON Export
# ==========================================

# Wrap in top-level object
$spec = [pscustomobject]@{
    hosts = $hosts
}

# Determine output filename
$baseName  = "hostComission.json"
$directory = Get-Location
$path      = Join-Path -Path $directory -ChildPath $baseName

if (Test-Path -Path $path) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $baseName  = "hostComission_$timestamp.json"
    $path      = Join-Path -Path $directory -ChildPath $baseName
}

$spec | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
Write-Host "`n----------------------------------------"
Write-Host "JSON saved to: $path" -ForegroundColor Green
