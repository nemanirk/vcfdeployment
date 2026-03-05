# ==========================================
# VMware Cloud Foundation - Host Spec Generator
# with AUTOMATED Thumbprint Retrieval and SDDC Validation
# ==========================================

# 1. Collect shared values
$username        = "root"
$password        = Read-Host "Enter password for ESXi root"
$networkPoolName = Read-Host "Enter network pool name"
$domainName      = Read-Host "Enter domain name (e.g. lab.local)"

function Get-SddcAuthToken {
    param ($Fqdn, $User, $Pass)
    $TokenUrl = "https://$Fqdn/v1/tokens"
    $Body = @{ username = $User; password = $Pass } | ConvertTo-Json
    try {
        $Resp = Invoke-RestMethod -Uri $TokenUrl -Method Post -Body $Body -ContentType "application/json" -SkipCertificateCheck
        return $Resp.accessToken
    } catch { throw $_ }
}

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
    do {
        $suffixBase = Read-Host "Enter host suffix base (numeric, e.g. 01)"
        $canConvert = [int]::TryParse($suffixBase, [ref]$null)
        if (-not $canConvert) {
            Write-Host "Invalid suffix. Please enter a numeric suffix base like 01 or 1." -ForegroundColor Red
        }
    } while (-not $canConvert)

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
    $hasOpenSSL = (Get-Command openssl.exe -ErrorAction SilentlyContinue)
    $hasPlink = (Get-Command plink.exe -ErrorAction SilentlyContinue)

    if (-not $hasOpenSSL -or -not $hasPlink) {
        Write-Warning "Missing Dependencies:"
        if (-not $hasOpenSSL) { Write-Warning " - OpenSSL.exe not found." }
        if (-not $hasPlink)   { Write-Warning " - plink.exe (PuTTY Link) not found." }
        Write-Error "Cannot proceed. Please install OpenSSL and PuTTY (plink.exe) and add to PATH."
    } 
    else {
        Write-Host "`nStarting Automated Retrieval..." -ForegroundColor Cyan
        foreach ($hostObj in $hosts) {
            $targetHost = $hostObj.fqdn
            Write-Host "`nProcessing: $targetHost" -ForegroundColor Cyan
            try {
                $OpenSslCmd = "echo Q | openssl s_client -connect ${targetHost}:443 2>NUL | openssl x509 -noout -fingerprint -sha256"
                $Output = cmd /c $OpenSslCmd
                if ($Output -match "Fingerprint=(.+)") {
                    $hostObj.sslThumbprint = $matches[1]
                    Write-Host " [SSL] Retrieved: $($hostObj.sslThumbprint)" -ForegroundColor Green
                }
            } catch { Write-Warning " [SSL] Error: $_" }

            try {
                $PlinkCmd = "echo y | plink -ssh -l root -pw $password $targetHost ""cat /etc/ssh/ssh_host_rsa_key.pub"""
                $PublicKeyString = cmd /c $PlinkCmd
                if ($PublicKeyString -match "(ssh-rsa\s+[A-Za-z0-9+/]+={0,2})") {
                    $CleanKey = $matches[1]
                    $Parts = $CleanKey.Trim() -split " "
                    if ($Parts.Count -ge 2) {
                        $Base64Key = $Parts[1]
                        $KeyBytes = [System.Convert]::FromBase64String($Base64Key)
                        $HashBytes = ([System.Security.Cryptography.SHA256]::Create()).ComputeHash($KeyBytes)
                        $ThumbRaw = [System.Convert]::ToBase64String($HashBytes).TrimEnd('=')
                        $hostObj.sshThumbprint = "SHA256:$ThumbRaw"
                        Write-Host " [SSH] Retrieved: $($hostObj.sshThumbprint)" -ForegroundColor Green
                    }
                }
            } catch { Write-Warning " [SSH] Error: $_" }
        }
    }
}

# ==========================================
# 5.5. Network Pool ID Selection
# ==========================================
Write-Host "`n----------------------------------------"
Write-Host "Network Pool ID Selection:"
Write-Host "[1] Retrieve from SDDC Manager automatically"
Write-Host "[2] Manually enter Network Pool ID"
Write-Host "[3] Will edit JSON manually"

do {
    $poolOption = Read-Host "Select an option (1, 2, or 3)"
} while ($poolOption -notmatch "^[123]$")

$globalToken = $null
$sddcFqdn = ""

if ($poolOption -eq "1") {
    $sddcFqdn = Read-Host "Enter SDDC Manager FQDN"
    $sddcUser = "administrator@vsphere.local"
    $sddcPass = Read-Host "Enter password for $sddcUser" -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sddcPass)
    $plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)

    try {
        Write-Host "Authenticating with SDDC Manager..." -ForegroundColor Cyan
        $globalToken = Get-SddcAuthToken -Fqdn $sddcFqdn -User $sddcUser -Pass $plainPass
        $headers = @{ "Authorization" = "Bearer $globalToken"; "Content-Type"  = "application/json" }
        $poolsResponse = Invoke-RestMethod -Method Get -Uri "https://$sddcFqdn/v1/network-pools" -Headers $headers -SkipCertificateCheck
        $poolList = $poolsResponse.elements

        foreach ($hostObj in $hosts) {
            $matchedPool = $poolList | Where-Object { $_.name -eq $hostObj.networkPoolName }
            if ($null -ne $matchedPool) {
                $hostObj | Add-Member -MemberType NoteProperty -Name "networkPoolId" -Value $matchedPool.id -Force
                Write-Host "SUCCESS: Mapped '$($hostObj.networkPoolName)' to ID: $($matchedPool.id) for $($hostObj.fqdn)" -ForegroundColor Green
            } else {
                Write-Warning "FAILED: Network Pool '$($hostObj.networkPoolName)' not found."
                $hostObj | Add-Member -MemberType NoteProperty -Name "networkPoolId" -Value "NOT_FOUND" -Force
            }
        }
    } catch { Write-Error "Failed to integrate with SDDC Manager: $($_.Exception.Message)" }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
} 
elseif ($poolOption -eq "2") {
    $manualPoolId = Read-Host "Enter Network Pool ID (UUID)"
    foreach ($hostObj in $hosts) {
        $hostObj | Add-Member -MemberType NoteProperty -Name "networkPoolId" -Value $manualPoolId -Force
    }
} 
else {
    foreach ($hostObj in $hosts) {
        $hostObj | Add-Member -MemberType NoteProperty -Name "networkPoolId" -Value "EDIT_MANUALLY" -Force
    }
}

# ==========================================
# 6. JSON Export
# ==========================================
$directory = Get-Location
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$path      = Join-Path -Path $directory -ChildPath "hostCommission_$timestamp.json"
$jsonContent = $hosts | ConvertTo-Json -Depth 5
$jsonContent | Set-Content -Path $path -Encoding UTF8

Write-Host "`n----------------------------------------"
Write-Host "JSON saved to: $path" -ForegroundColor Green

if ($poolOption -eq "3") {
    Write-Host "Option 3 selected. Ending script." -ForegroundColor Cyan
    exit
}

# ==========================================
# 7. SDDC Manager Validation & Commissioning
# ==========================================

# Determine if we should proceed with Validation based on the Option
$shouldValidate = $false

if ($poolOption -eq "1" -and $null -ne $globalToken) {
    # For Option 1, explicitly prompt for validation
    if ((Read-Host "`nWould you like to validate this spec against SDDC Manager now? (y/n)") -eq "y") {
        $shouldValidate = $true
    }
}
elseif ($poolOption -eq "2") {
    # For Option 2, prompt for validation; if yes, get credentials
    if ((Read-Host "`nWould you like to validate this spec against SDDC Manager now? (y/n)") -eq "y") {
        $sddcFqdn = Read-Host "Enter SDDC Manager FQDN"
        $sddcUser = "administrator@vsphere.local"
        $sddcPass = Read-Host "Enter password for $sddcUser" -AsSecureString
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sddcPass)
        $plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        try {
            $globalToken = Get-SddcAuthToken -Fqdn $sddcFqdn -User $sddcUser -Pass $plainPass
            if ($null -ne $globalToken) { $shouldValidate = $true }
        } catch { Write-Error "Auth Failed: $($_.Exception.Message)" }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
}

if ($shouldValidate -and $null -ne $globalToken) {
    try {
        $valHeaders = @{ "Authorization" = "Bearer $globalToken"; "Content-Type" = "application/json" }
        Write-Host "Submitting Host Commission Validation..." -ForegroundColor Yellow
        $valResponse = Invoke-RestMethod -Method Post -Uri "https://$sddcFqdn/v1/hosts/validations" -Body $jsonContent -Headers $valHeaders -SkipCertificateCheck
        $valId = $valResponse.id
        Write-Host "Validation Task Submitted. ID: $valId" -ForegroundColor Green

        $isFinished = $false
        while (-not $isFinished) {
            $statusResp = Invoke-RestMethod -Method Get -Uri "https://$sddcFqdn/v1/hosts/validations/$valId" -Headers $valHeaders -SkipCertificateCheck
            $execStatus = $statusResp.executionStatus
            $resStatus  = if ($statusResp.PSObject.Properties['resultStatus']) { $statusResp.resultStatus } else { "PENDING" }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Execution: $execStatus | Result: $resStatus" -ForegroundColor Cyan

            if ($execStatus -match "COMPLETED|FAILED") {
                $isFinished = $true
                $vLogFile = "host-validation-$(Get-Date -Format 'yyyyMMdd_HHmm').json"
                $statusResp | ConvertTo-Json -Depth 10 | Set-Content -Path $vLogFile
                Write-Host "`n[+] Validation results saved to: $vLogFile" -ForegroundColor Green
                
                if ($resStatus -eq "SUCCEEDED") {
                    Write-Host "SUCCESS: Validated!" -ForegroundColor Green
                    if ((Read-Host "`nCommission these hosts now? (y/n)") -eq 'y') {
                        $commResp = Invoke-RestMethod -Method Post -Uri "https://$sddcFqdn/v1/hosts" -Body $jsonContent -Headers $valHeaders -SkipCertificateCheck
                        Write-Host "`nCOMMISSION TASK SUBMITTED. ID: $($commResp.id)" -ForegroundColor Green
                    }
                } else {
                    Write-Host "FAILED: Check $vLogFile for errors." -ForegroundColor Red
                }
            } else { Start-Sleep -Seconds 60 }
        }
    } catch { Write-Error "API Error: $($_.Exception.Message)" }
}
