# Interactive script to generate VCF management components JSON for Single or HA Deployment

$OutputJsonPath = ".\vcfMgmtComponentsSpec.json"

function Read-Password {
    param([string]$Prompt)
    Add-Type -AssemblyName System.Security
    $secureString = Read-Host $Prompt -AsSecureString
    $plainText = [System.Net.NetworkCredential]::new("", $secureString).Password
    $secureString.Dispose()
    return $plainText
}

function Validate-IpAddress {
    param([string]$ip)
    # Uses .NET IPAddress TryParse for validation
    [System.Net.IPAddress]::TryParse($ip, [ref]$null)
}

function Read-ValidIpAddress {
    param([string]$prompt)
    do {
        $ip = Read-Host $prompt
        if (-not (Validate-IpAddress -ip $ip)) {
            Write-Warning "Invalid IP address format. Please enter a valid IPv4 or IPv6 address."
            $valid = $false
        } else {
            $valid = $true
        }
    } while (-not $valid)
    return $ip
}

function Read-NodeDetails {
    param (
        [string]$role,
        [string]$type,
        [int]$nodeNumber,
        [string]$commonPassword,
        [string]$domainName
    )
    Write-Host "Enter details for VCF Operations node #$nodeNumber (type=$type)" -ForegroundColor Cyan
    $hostnameBase = Read-Host "  Hostname (base name, domain will be appended)"
    $fullHostname = "$hostnameBase.$domainName"
    Write-Host "  Full hostname: $fullHostname" -ForegroundColor Green
    
    return @{
        hostname = $fullHostname
        rootUserPassword = $commonPassword
        type = $type
    }
}

function Read-IPs {
    param (
        [int]$count
    )
    $ips = @()
    for ($i=1; $i -le $count; $i++) {
        $ip = Read-ValidIpAddress -prompt "Enter IP address #$i"
        $ips += $ip
    }
    return $ips
}

function Read-NetworkSpec {
    param([string]$name)
    Write-Host "Enter $name network details" -ForegroundColor Cyan
    $networkName = Read-Host "  Network Name"
    $subnetMask = Read-ValidIpAddress -prompt "  Subnet Mask"
    $gateway = Read-ValidIpAddress -prompt "  Gateway"
    return @{
        networkName = $networkName
        subnetMask = $subnetMask
        gateway = $gateway
    }
}

function Read-ApplianceSize {
    param([string]$componentName)
    
    do {
        Write-Host "`n=== $componentName Appliance Size Selection ===" -ForegroundColor Green
        Write-Host "1. small" -ForegroundColor Yellow
        Write-Host "2. medium" -ForegroundColor Yellow
        Write-Host "3. large" -ForegroundColor Yellow
        Write-Host "4. xlarge" -ForegroundColor Yellow
        Write-Host "========================================" -ForegroundColor Green
        
        $sizeChoice = Read-Host "Enter your choice (1-4)"
        $sizeChoice = $sizeChoice.Trim()
        
        switch ($sizeChoice) {
            "1" { $sizeValid = $true; $applianceSize = "small" }
            "2" { $sizeValid = $true; $applianceSize = "medium" }
            "3" { $sizeValid = $true; $applianceSize = "large" }
            "4" { $sizeValid = $true; $applianceSize = "xlarge" }
            default { $sizeValid = $false; Write-Warning "Invalid choice! Please enter 1, 2, 3, or 4." }
        }
    } while (-not $sizeValid)
    
    Write-Host "$componentName appliance size set to: $applianceSize" -ForegroundColor Green
    return $applianceSize
}

function Read-CollectorApplianceSize {
    do {
        Write-Host "`n=== VCF Operations Collector Appliance Size Selection ===" -ForegroundColor Green
        Write-Host "1. small" -ForegroundColor Yellow
        Write-Host "2. standard" -ForegroundColor Yellow
        Write-Host "=================================" -ForegroundColor Green
        
        $collectorSizeChoice = Read-Host "Enter your choice (1-2)"
        $collectorSizeChoice = $collectorSizeChoice.Trim()
        
        switch ($collectorSizeChoice) {
            "1" { $collectorSizeValid = $true; $collectorApplianceSize = "small" }
            "2" { $collectorSizeValid = $true; $collectorApplianceSize = "standard" }
            default { $collectorSizeValid = $false; Write-Warning "Invalid choice! Please enter 1 for small or 2 for standard." }
        }
    } while (-not $collectorSizeValid)
    
    Write-Host "VCF Operations Collector appliance size set to: $collectorApplianceSize" -ForegroundColor Green
    return $collectorApplianceSize
}

function Read-InternalClusterCidr {
    do {
        Write-Host "`n=== Internal Cluster CIDR Selection ===" -ForegroundColor Green
        Write-Host "1. 198.18.0.0/15" -ForegroundColor Yellow
        Write-Host "2. 240.0.0.0/15" -ForegroundColor Yellow
        Write-Host "3. 250.0.0.0/15" -ForegroundColor Yellow
        Write-Host "================================" -ForegroundColor Green
        
        $cidrChoice = Read-Host "Enter your choice (1-3)"
        $cidrChoice = $cidrChoice.Trim()
        
        switch ($cidrChoice) {
            "1" { $cidrValid = $true; $internalClusterCidr = "198.18.0.0/15" }
            "2" { $cidrValid = $true; $internalClusterCidr = "240.0.0.0/15" }
            "3" { $cidrValid = $true; $internalClusterCidr = "250.0.0.0/15" }
            default { $cidrValid = $false; Write-Warning "Invalid choice! Please enter 1, 2, or 3." }
        }
    } while (-not $cidrValid)
    
    Write-Host "Internal Cluster CIDR set to: $internalClusterCidr" -ForegroundColor Green
    return $internalClusterCidr
}

# Deployment type selection
do {
    Write-Host "`n=== Deployment Type Selection ===" -ForegroundColor Green
    Write-Host "1. Single Node Deployment" -ForegroundColor Yellow
    Write-Host "2. HA Deployment" -ForegroundColor Yellow
    Write-Host "=================================" -ForegroundColor Green
    
    $deploymentChoice = Read-Host "Enter your choice (1 or 2)"
    $deploymentChoice = $deploymentChoice.Trim()
    
    switch ($deploymentChoice) {
        "1" { $isValid = $true; $deploymentType = "single"; Write-Host "Single Node deployment selected." -ForegroundColor Green }
        "2" { $isValid = $true; $deploymentType = "ha"; Write-Host "HA deployment selected." -ForegroundColor Green }
        default { $isValid = $false; Write-Warning "Invalid choice! Please enter 1 for Single Node or 2 for HA Deployment." }
    }
} while (-not $isValid)

# Domain name
$domainName = Read-Host "`nEnter Domain Name"

# Common password choice
do {
    Write-Host "`n=== Password Configuration ===" -ForegroundColor Green
    Write-Host "Do you want to use the same password for all components?" -ForegroundColor Yellow
    Write-Host "1. Yes" -ForegroundColor Yellow
    Write-Host "2. No" -ForegroundColor Yellow
    Write-Host "================================" -ForegroundColor Green
    
    $passwordChoice = Read-Host "Enter your choice (1 or 2)"
    $passwordChoice = $passwordChoice.Trim()
    
    switch ($passwordChoice) {
        "1" { 
            $passwordValid = $true
            $useCommonPassword = $true
            $commonPasswordPlain = Read-Password "Enter the common password for all components"
            Write-Host "Common password set for all root and admin users." -ForegroundColor Green
        }
        "2" { 
            $passwordValid = $true
            $useCommonPassword = $false
            Write-Host "Individual passwords will be prompted for each component." -ForegroundColor Green
        }
        default { $passwordValid = $false; Write-Warning "Invalid choice! Please enter 1 for Yes or 2 for No." }
    }
} while (-not $passwordValid)

# Fleet Management Spec
Write-Host "`n=== VCF Operations Fleet Management Spec ===" -ForegroundColor Cyan
$fleetHostnameBase = Read-Host "  Hostname (base name, domain will be appended)"
$fleetHostname = "$fleetHostnameBase.$domainName"
Write-Host "  Full hostname: $fleetHostname" -ForegroundColor Green

if (-not $useCommonPassword) {
    $fleetRootPasswordPlain = Read-Password "  Root User Password"
    $fleetAdminPasswordPlain = Read-Password "  Admin User Password"
} else {
    $fleetRootPasswordPlain = $commonPasswordPlain
    $fleetAdminPasswordPlain = $commonPasswordPlain
    Write-Host "  Using common password for root and admin users" -ForegroundColor Green
}

# VCF Operations Spec
Write-Host "`n=== VCF Operations Spec ===" -ForegroundColor Cyan
$nodes = @()
if ($deploymentType -eq "single") {
    $nodes += Read-NodeDetails -role "VCF Operations" -type "master" -nodeNumber 1 -commonPassword $commonPasswordPlain -domainName $domainName
} else {
    $nodes += Read-NodeDetails -role "VCF Operations" -type "master" -nodeNumber 1 -commonPassword $commonPasswordPlain -domainName $domainName
    $nodes += Read-NodeDetails -role "VCF Operations" -type "replica" -nodeNumber 2 -commonPassword $commonPasswordPlain -domainName $domainName
    $nodes += Read-NodeDetails -role "VCF Operations" -type "data" -nodeNumber 3 -commonPassword $commonPasswordPlain -domainName $domainName
}

if (-not $useCommonPassword) {
    $adminOpsPasswordPlain = Read-Password "Enter Admin User Password for VCF Operations"
} else {
    $adminOpsPasswordPlain = $commonPasswordPlain
}

$applianceSizeOps = Read-ApplianceSize -componentName "VCF Operations"

# Collector Spec
Write-Host "`n=== VCF Operations Collector Spec ===" -ForegroundColor Cyan
$collectorHostnameBase = Read-Host "  Hostname (base name, domain will be appended)"
$collectorHostname = "$collectorHostnameBase.$domainName"
Write-Host "  Full hostname: $collectorHostname" -ForegroundColor Green

if (-not $useCommonPassword) {
    $collectorRootPasswordPlain = Read-Password "  Root User Password"
} else {
    $collectorRootPasswordPlain = $commonPasswordPlain
    Write-Host "  Using common password for root user" -ForegroundColor Green
}

$collectorApplianceSize = Read-CollectorApplianceSize

# Automation Spec
Write-Host "`n=== VCF Automation Spec ===" -ForegroundColor Cyan
$automationHostnameBase = Read-Host "  Hostname (base name, domain will be appended)"
$automationHostname = "$automationHostnameBase.$domainName"
Write-Host "  Full hostname: $automationHostname" -ForegroundColor Green

$nodePrefix = Read-Host "  Node Prefix (e.g., vcf-automation)"

if (-not $useCommonPassword) {
    $automationAdminPasswordPlain = Read-Password "  Admin User Password"
} else {
    $automationAdminPasswordPlain = $commonPasswordPlain
    Write-Host "  Using common password for admin user" -ForegroundColor Green
}

# IP Pool and CIDR
if ($deploymentType -eq "single") { $ipCount = 2 } else { $ipCount = 4 }
Write-Host "`nEnter $ipCount IP addresses for Automation IP Pool:"
$ipPool = Read-IPs -count $ipCount

$internalClusterCidr = Read-InternalClusterCidr

# Infrastructure specs
Write-Host "`n=== Infrastructure Network Specs ===" -ForegroundColor Cyan
$localRegionNetwork = Read-NetworkSpec -name "Local Region"
$xRegionNetwork = Read-NetworkSpec -name "Cross Region"

# Build final payload with ordered vcfAutomationSpec
$vcfAutomationSpec = [ordered]@{
    hostname = $automationHostname
    nodePrefix = $nodePrefix
    adminUserPassword = $automationAdminPasswordPlain
    internalClusterCidr = $internalClusterCidr
    ipPool = $ipPool
}

$payload = @{
    vcfOperationsFleetManagementSpec = @{
        hostname = $fleetHostname
        rootUserPassword = $fleetRootPasswordPlain
        adminUserPassword = $fleetAdminPasswordPlain
    }
    vcfOperationsSpec = @{
        nodes = $nodes
        adminUserPassword = $adminOpsPasswordPlain
        applianceSize = $applianceSizeOps
    }
    vcfOperationsCollectorSpec = @{
        hostname = $collectorHostname
        rootUserPassword = $collectorRootPasswordPlain
        applianceSize = $collectorApplianceSize
    }
    vcfAutomationSpec = [PSCustomObject]$vcfAutomationSpec
    vcfMangementComponentsInfrastructureSpec = @{
        localRegionNetwork = $localRegionNetwork
        xRegionNetwork = $xRegionNetwork
    }
}

# Generate and save JSON
$payloadJson = $payload | ConvertTo-Json -Depth 10
$payloadJson | Out-File -FilePath $OutputJsonPath -Encoding UTF8

Write-Host "`n" + "="*60 -ForegroundColor Green
Write-Host "VCF management components JSON payload generated successfully!" -ForegroundColor Green
Write-Host "File saved to: $OutputJsonPath" -ForegroundColor Yellow
Write-Host "Domain: $domainName" -ForegroundColor Yellow
Write-Host "VCF Operations Size: $applianceSizeOps" -ForegroundColor Yellow
Write-Host "Collector Size: $collectorApplianceSize" -ForegroundColor Yellow
Write-Host "Automation Node Prefix: $nodePrefix" -ForegroundColor Yellow
Write-Host "Internal Cluster CIDR: $internalClusterCidr" -ForegroundColor Yellow
if ($useCommonPassword) {
    Write-Host "Common password used for ALL root and admin passwords." -ForegroundColor Cyan
}
Write-Host "="*60 -ForegroundColor Green
