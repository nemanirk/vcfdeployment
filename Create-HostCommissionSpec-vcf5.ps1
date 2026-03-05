# Collect shared values
$username        = Read-Host "Enter username"
$password        = Read-Host "Enter password"
$networkPoolName = Read-Host "Enter network pool name"
$domainName      = Read-Host "Enter domain name (e.g. lab.local)"

# Ask if host names are sequential
do {
    $isSequential = Read-Host "Are the host names sequential with numeric suffix? (yes/no)"
    $isSequential = $isSequential.Trim().ToLower()
} while ($isSequential -ne "yes" -and $isSequential -ne "no")

# Prompt for storage type choice (shared)
$storageOptions = @("VSAN", "VSAN_ESA", "VSAN_REMOTE", "VSAN_MAX", "NFS", "VMFS_FC", "VVOL", "VMFS")

Write-Host "Select Storage Type:"
for ($i = 0; $i -lt $storageOptions.Count; $i++) {
    Write-Host "[$($i+1)] $($storageOptions[$i])"
}

do {
    $storageChoice = Read-Host "Enter choice number (1-$($storageOptions.Count))"
} while (-not ($storageChoice -as [int]) -or $storageChoice -lt 1 -or $storageChoice -gt $storageOptions.Count)

$storageType = $storageOptions[$storageChoice - 1]

$hosts = @()

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

    # Ask base hostname once
    $baseHostName = Read-Host "Enter base host name (without suffix/domain)"

    # Calculate suffix length for format preservation
    $suffixLength = $suffixBase.Length
    $suffixNumber = [int]$suffixBase

    for ($i = 0; $i -lt $hostCount; $i++) {
        # FIXED: zero-padding suffix formatting
        $currentSuffix = "{0:D$suffixLength}" -f ($suffixNumber + $i)
        $hostFqdn = "$baseHostName$currentSuffix.$domainName"

        $hosts += [pscustomobject]@{
            hostFqdn        = $hostFqdn
            username        = $username
            password        = $password
            storageType     = $storageType
            networkPoolName = $networkPoolName
        }
    }

} else {
    # Read host names from a file. Each line is a hostname (may be short name or FQDN)
    do {
        $filePath = Read-Host "Enter path to text file with hostnames (one per line)"
        if (-not (Test-Path -Path $filePath)) {
            Write-Host "File not found. Please enter a valid file path." -ForegroundColor Red
        }
    } while (-not (Test-Path -Path $filePath))

    $hostNamesFromFile = Get-Content -Path $filePath | Where-Object { $_.Trim() -ne "" }

    foreach ($rawName in $hostNamesFromFile) {
        $hostName = $rawName.Trim()

        # Check if hostname already contains the user-specified domain name
        if ($hostName -like "*.$domainName" -or $hostName.EndsWith($domainName, [StringComparison]::OrdinalIgnoreCase)) {
            $hostFqdn = $hostName  # Already has domain, use as-is
        } else {
            $hostFqdn = "$hostName.$domainName"  # Append domain
        }

        $hosts += [pscustomobject]@{
            hostFqdn        = $hostFqdn
            username        = $username
            password        = $password
            storageType     = $storageType
            networkPoolName = $networkPoolName
        }
    }
}

# Wrap in top-level object with hostSpec list
$spec = [pscustomobject]@{
    hostSpec = $hosts
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

# Convert to JSON and save
$spec | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
Write-Host "JSON saved to: $path"
