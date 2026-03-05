# ==========================================
# VMware Cloud Foundation - Edge Cluster Automation Tool
# Functionality: Create JSON Spec -> Validate -> Deploy
# ==========================================

# ==========================================
# 0. Global Helper Functions
# ==========================================

# 1. Password Validation
function Get-ValidPassword {
    param ([string]$PromptText)
    $IsValid = $false
    do {
        Write-Host "$PromptText (Min 15 chars, 1 Upper, 1 Lower, 1 Digit, 1 Special): " -NoNewline
        $PlainPass = Read-Host
        
        if ($PlainPass.Length -lt 15) { Write-Warning "Too short. Min 15 chars."; continue }
        if ($PlainPass -notmatch '[A-Z]') { Write-Warning "Missing Uppercase."; continue }
        if ($PlainPass -notmatch '[a-z]') { Write-Warning "Missing Lowercase."; continue }
        if ($PlainPass -notmatch '\d') { Write-Warning "Missing Digit."; continue }
        if ($PlainPass -notmatch '[@!#\$%\?\^]') { Write-Warning "Missing Special char (@!#$%?^)."; continue }
        
        $IsValid = $true
    } while (-not $IsValid)
    return $PlainPass
}

# 2. Integer Validation
function Get-ValidInt {
    param ([string]$PromptText)
    $IsValid = $false
    $IntVal = 0
    do {
        $InputStr = Read-Host $PromptText
        if ($InputStr -match '^\d+$') {
            $IntVal = [int]$InputStr
            $IsValid = $true
        } else { Write-Warning "Invalid input. Must be a number." }
    } while (-not $IsValid)
    return $IntVal
}

# 3. VLAN Validation
function Get-ValidVlan {
    param ([string]$PromptText)
    $IsValid = $false
    $VlanId = 0
    do {
        $InputStr = Read-Host $PromptText
        if ($InputStr -match '^\d+$') {
            $VlanId = [int]$InputStr
            if ($VlanId -ge 1 -and $VlanId -le 4095) { $IsValid = $true } else { Write-Warning "VLAN must be 1-4095." }
        } else { Write-Warning "Invalid input." }
    } while (-not $IsValid)
    return $VlanId
}

# 4. CIDR Validation
function Get-ValidCidr {
    param ([string]$PromptText)
    $IsValid = $false
    do {
        $CidrInput = Read-Host $PromptText
        if ($CidrInput -match '^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\/(?:3[0-2]|[12]?[0-9])$') {
            $IsValid = $true
        } else { Write-Warning "Invalid CIDR format. (Example: 192.168.1.1/24)" }
    } while (-not $IsValid)
    return $CidrInput
}

# 5. MTU Validation
function Get-ValidMtu {
    param ([string]$PromptText)
    $IsValid = $false
    $MtuVal = 0
    do {
        $InputStr = Read-Host $PromptText
        if ($InputStr -match '^\d+$') {
            $MtuVal = [int]$InputStr
            if ($MtuVal -ge 1400 -and $MtuVal -le 9000) { $IsValid = $true } else { Write-Warning "MTU must be 1400-9000." }
        } else { Write-Warning "Invalid input." }
    } while (-not $IsValid)
    return $MtuVal
}

# 6. IP Format Validation
function Get-ValidIp {
    param ([string]$PromptText)
    $IsValid = $false
    do {
        $IpInput = Read-Host $PromptText
        if ($IpInput -match '^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$') {
            $IsValid = $true
        } else { Write-Warning "Invalid IP format." }
    } while (-not $IsValid)
    return $IpInput
}

# 7. IP in Subnet Check
function Test-IpInCidr {
    param([string]$SubnetCidr, [string]$TargetIpOrCidr)
    try {
        if ($TargetIpOrCidr -match '/') { $TargetIp = $TargetIpOrCidr.Split('/')[0] } else { $TargetIp = $TargetIpOrCidr }
        $NetworkIpStr, $PrefixLenStr = $SubnetCidr.Split('/')
        $PrefixLen = [int]$PrefixLenStr
        $NetBytes = [System.Net.IPAddress]::Parse($NetworkIpStr).GetAddressBytes()
        $TgtBytes = [System.Net.IPAddress]::Parse($TargetIp).GetAddressBytes()
        $MaskBytes = New-Object byte[] 4
        $FullBytes = [math]::Floor($PrefixLen / 8)
        for ($i = 0; $i -lt $FullBytes; $i++) { $MaskBytes[$i] = 255 }
        $Remainder = $PrefixLen % 8
        if ($Remainder -gt 0) { $Shift = 8 - $Remainder; $MaskBytes[$FullBytes] = [byte]((255 -shl $Shift) -band 255) }
        for ($i = 0; $i -lt 4; $i++) { if (($NetBytes[$i] -band $MaskBytes[$i]) -ne ($TgtBytes[$i] -band $MaskBytes[$i])) { return $false } }
        return $true
    } catch { return $false }
}

# 8. Helper: Check if two CIDRs are in same subnet
function Test-CidrMatch {
    param([string]$Cidr1, [string]$Cidr2)
    try {
        $Ip1, $Mask1 = $Cidr1.Split('/')
        $Ip2, $Mask2 = $Cidr2.Split('/')
        if ($Mask1 -ne $Mask2) { return $false }
        return (Test-IpInCidr -SubnetCidr $Cidr1 -TargetIpOrCidr $Ip2)
    } catch { return $false }
}

# 9. Function: Run Validation Process
function Invoke-EdgeClusterValidation {
    param (
        [string]$JsonSpecPath
    )

    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host " STARTING SDDC MANAGER VALIDATION PROCESS " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    # --- Configuration & Credentials ---
    $SddcFqdn = "sfo-vcf01.sfo.rainpole.io"
    $Username = "administrator@vsphere.local"
    $Password = "VMw@re1!VMw@re1!" 
    $BaseUrl = "https://$SddcFqdn"

    # --- Retrieve Access Token ---
    Write-Host "--- Authenticating with SDDC Manager ---" -ForegroundColor Cyan
    $TokenUrl = "$BaseUrl/v1/tokens"
    $TokenBody = @{ username = $Username; password = $Password } | ConvertTo-Json

    try {
        $TokenResponse = Invoke-RestMethod -Uri $TokenUrl -Method Post -Body $TokenBody -ContentType "application/json" -SkipCertificateCheck
        $AccessToken = $TokenResponse.accessToken
        Write-Host "Authentication Successful. Token Retrieved." -ForegroundColor Green
    }
    catch {
        Write-Error "Authentication Failed. Stopping script."
        Write-Error $_
        return
    }

    # --- Read JSON Content ---
    try {
        if (-not $JsonSpecPath) {
            do {
                $JsonSpecPath = Read-Host "Enter the full path to your Edge Cluster JSON file"
                $JsonSpecPath = $JsonSpecPath -replace '"', ''
                if (-not (Test-Path $JsonSpecPath)) { Write-Warning "File not found." }
            } while (-not (Test-Path $JsonSpecPath))
        }
        $JsonContent = Get-Content -Path $JsonSpecPath -Raw -ErrorAction Stop
        Write-Host "Successfully read JSON file: $JsonSpecPath" -ForegroundColor Gray
    }
    catch {
        Write-Error "Failed to read file: $_"
        return
    }

    # --- Run Validation API ---
    Write-Host "`n--- Executing Validation API ---" -ForegroundColor Cyan
    $ValidationUrl = "$BaseUrl/v1/edge-clusters/validations"
    $Headers = @{ "Authorization" = "Bearer $AccessToken"; "Content-Type"  = "application/json" }
    $ValidationId = $null

    try {
        Write-Host "Sending validation request..." -ForegroundColor Yellow
        $ValidationResponse = Invoke-RestMethod -Uri $ValidationUrl -Method Post -Headers $Headers -Body $JsonContent -SkipCertificateCheck
        
        Write-Host "Validation Request Submitted Successfully!" -ForegroundColor Green
        if ($ValidationResponse.id) {
            $ValidationId = $ValidationResponse.id
            Write-Host "Validation ID: $ValidationId" -ForegroundColor Cyan
        } else {
            Write-Warning "No Validation ID returned."
            return
        }
    }
    catch {
        Write-Host "Validation API Call Failed." -ForegroundColor Red
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            Write-Host "API Error Details: $($_.ErrorDetails.Message)" -ForegroundColor Yellow
        } else {
            try {
                $ErrorBody = $null
                if ($_.Exception.Response.Content) { $ErrorBody = $_.Exception.Response.Content.ReadAsStringAsync().Result }
                elseif ($_.Exception.Response.GetResponseStream) { 
                    $Reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $ErrorBody = $Reader.ReadToEnd() 
                }
                if ($ErrorBody) { Write-Host "API Error Body: $ErrorBody" -ForegroundColor Yellow }
                else { Write-Host "Exception: $($_.Exception.Message)" -ForegroundColor Red }
            } catch { Write-Host "Basic Error: $($_.Exception.Message)" -ForegroundColor Red }
        }
        return
    }

    # --- Poll Validation Status ---
    if ($ValidationId) {
        Write-Host "`n--- Polling Validation Status [$ValidationId] ---" -ForegroundColor Cyan
        $StatusUrl = "$BaseUrl/v1/edge-clusters/validations/$ValidationId"
        $ValidationStatus = "IN_PROGRESS"
        
        do {
            try {
                $StatusResponse = Invoke-RestMethod -Uri $StatusUrl -Method Get -Headers $Headers -SkipCertificateCheck
                
                if ($StatusResponse.executionStatus) { $ValidationStatus = $StatusResponse.executionStatus } 
                elseif ($StatusResponse.status) { $ValidationStatus = $StatusResponse.status }
                
                $TimeStamp = Get-Date -Format "HH:mm:ss"
                Write-Host "[$TimeStamp] Current Status: $ValidationStatus" -ForegroundColor ($ValidationStatus -eq "IN_PROGRESS" ? "Yellow" : "Green")
                
                if ($ValidationStatus -match "SUCCEEDED|FAILED|COMPLETED") {
                    
                    Write-Host ""
                    Write-Host "Validation Finished with status: $ValidationStatus" -ForegroundColor ($ValidationStatus -eq "SUCCEEDED" ? "Green" : "Red")
                    
                    if ($StatusResponse.resultStatus) {
                        Write-Host "Result Status: $($StatusResponse.resultStatus)" -ForegroundColor Yellow
                    }

                    if ($ValidationStatus -eq "FAILED") {
                        if ($StatusResponse.errors) { $StatusResponse.errors | Format-Table -AutoSize }
                        elseif ($StatusResponse.validationErrors) { $StatusResponse.validationErrors | Format-List }
                    }
                    break
                }
            }
            catch { Write-Warning "Status poll failed. Retrying..." }
            Start-Sleep -Seconds 60
        } while ($ValidationStatus -match "IN_PROGRESS|PENDING|Processing")
    }
}


# ==========================================
# WIZARD START (MENU REMOVED)
# ==========================================
Clear-Host
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Edge Cluster Automation Tool v2.2      " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "`n--- Starting Edge Cluster Spec Creation Wizard ---" -ForegroundColor Cyan

# --- 1. Global Inputs ---
$EdgeClusterName = Read-Host "Enter Edge Cluster Name"

$ValidFormFactors = @("XLARGE", "LARGE", "MEDIUM", "SMALL")
do {
    $EdgeFormFactor = Read-Host "Enter Edge Form Factor (XLARGE, LARGE, MEDIUM, SMALL)"
    if ([string]::IsNullOrWhiteSpace($EdgeFormFactor)) { $EdgeFormFactor = "MEDIUM" } 
    if ($ValidFormFactors -notcontains $EdgeFormFactor.ToUpper()) { Write-Warning "Invalid Form Factor."; $FormValid = $false } 
    else { $EdgeFormFactor = $EdgeFormFactor.ToUpper(); $FormValid = $true }
} while (-not $FormValid)

$EdgeAdminPassword = Get-ValidPassword "Enter Admin Password"
$EdgeRootPassword  = Get-ValidPassword "Enter Root Password"
$EdgeAuditPassword = Get-ValidPassword "Enter Audit Password" 

# --- Edge Cluster Profile Selection ---
$ValidProfileTypes = @("DEFAULT", "CUSTOM")
do {
    $ProfileTypeInput = Read-Host "Enter Edge Cluster Profile Type (DEFAULT, CUSTOM) [Default: DEFAULT]"
    if ([string]::IsNullOrWhiteSpace($ProfileTypeInput)) { $ProfileTypeInput = "DEFAULT" }
    if ($ValidProfileTypes -notcontains $ProfileTypeInput.ToUpper()) { Write-Warning "Invalid Type."; $ProfileValid = $false } 
    else { $EdgeClusterProfileType = $ProfileTypeInput.ToUpper(); $ProfileValid = $true }
} while (-not $ProfileValid)

if ($EdgeClusterProfileType -eq "CUSTOM") {
    Write-Host "--- Custom Profile Configuration ---" -ForegroundColor Yellow
    $MyEdgeClusterProfileName = Read-Host "Enter Profile Name"
    $BfdAllowedHop = Get-ValidInt "Enter BFD Allowed Hop"
    $BfdDeclareDeadMultiple = Get-ValidInt "Enter BFD Declare Dead Multiple"
    $BfdProbeInterval = Get-ValidInt "Enter BFD Probe Interval"
    $StandbyRelocationThreshold = Get-ValidInt "Enter Standby Relocation Threshold"
}

# --- 2. Edge Node 1 Config & ID Logic ---
Write-Host "`n--- Configure Edge Node 1 ---" -ForegroundColor Cyan
$Node1Fqdn = Read-Host "Enter First Edge Node FQDN"

# === CLUSTER ID LOGIC START ===
$AutoRetrieveId = Read-Host "Do you want to retrieve the vSphere Cluster ID automatically from SDDC Manager? (y/n)"
$VsphereClusterId = $null
$VsphereClusterName = $null

if ($AutoRetrieveId -eq 'n') {
    $VsphereClusterId = Read-Host "Enter vSphere Cluster ID"
} else {
    $VsphereClusterName = Read-Host "Enter vSphere Cluster Name (exactly as in SDDC Manager)"
}
# === CLUSTER ID LOGIC END ===

$MgmtPortGroup = Read-Host "Enter Portgroup name"
$MgmtVlan = Get-ValidVlan "Enter Management VLAN"

do {
    $Node1MgmtIpCidr = Get-ValidCidr "Enter Management IP (CIDR)"
    $Node1MgmtGateway = Read-Host "Enter Gateway"
    if (Test-IpInCidr -SubnetCidr $Node1MgmtIpCidr -TargetIpOrCidr $Node1MgmtGateway) { $MgmtValid = $true } 
    else { Write-Warning "Gateway not in subnet."; $MgmtValid = $false }
} while (-not $MgmtValid)

# --- TEP Config ---
Write-Host "`n--- Edge TEP Configuration ---" -ForegroundColor Cyan
Write-Host "[1] Use Existing Edge TEP Pool"
Write-Host "[2] Static TEP IP"
do { $TepMode = Read-Host "Enter choice (1 or 2)" } while ($TepMode -notin '1','2')

$TepVlan = Get-ValidVlan "Enter TEP VLAN"

if ($TepMode -eq '1') {
    $UseTepPool = $true
    Write-Host "--- Existing TEP Pool Selected ---" -ForegroundColor Yellow
    $IpPoolName = Read-Host "Enter Existing Edge TEP Pool Name"
    $EdgeTepGateway = $null; $Node1Tep1Ip = $null; $Node1Tep2Ip = $null
} else {
    $UseTepPool = $false
    Write-Host "--- Static TEP IP Selected ---" -ForegroundColor Yellow
    $IpPoolName = $null
    $EdgeTepGateway = Get-ValidIp "Enter Edge TEP Gateway IP"
    $Node1Tep1Ip = Get-ValidCidr "Enter Node 1 - First Edge TEP IP (CIDR)"
    $Node1Tep2Ip = Get-ValidCidr "Enter Node 1 - Second Edge TEP IP (CIDR)"
}

Write-Host "`n--- Workload Domain Connectivity ---" -ForegroundColor Cyan
$Tier0Name = Read-Host "Enter Tier0 Gateway name"

# --- HA / Routing / ASN ---
$ValidHaModes = @("ACTIVE_ACTIVE", "ACTIVE_STANDBY")
do {
    $HaModeInput = Read-Host "Select HA Mode (ACTIVE_ACTIVE, ACTIVE_STANDBY) [Default: ACTIVE_STANDBY]"
    if ([string]::IsNullOrWhiteSpace($HaModeInput)) { $HaModeInput = "ACTIVE_STANDBY" }
    if ($ValidHaModes -notcontains $HaModeInput.ToUpper()) { Write-Warning "Invalid Mode."; $HaValid = $false } 
    else { $Tier0HaMode = $HaModeInput.ToUpper(); $HaValid = $true }
} while (-not $HaValid)

$ValidRouting = @("EBGP", "STATIC")
do {
    $RoutingInput = Read-Host "Enter Routing Type (EBGP, STATIC) [Default: EBGP]"
    if ([string]::IsNullOrWhiteSpace($RoutingInput)) { $RoutingInput = "EBGP" }
    if ($ValidRouting -notcontains $RoutingInput.ToUpper()) { Write-Warning "Invalid Type."; $RouteValid = $false } 
    else { $Tier0RoutingType = $RoutingInput.ToUpper(); $RouteValid = $true }
} while (-not $RouteValid)

do {
    $LocalAsnInput = Read-Host "Enter Local ASN"
    if ($LocalAsnInput -match '^\d+$' -and [long]$LocalAsnInput -gt 0) { $LocalAsn = [long]$LocalAsnInput; $AsnValid = $true } 
    else { Write-Warning "Invalid ASN."; $AsnValid = $false }
} while (-not $AsnValid)


# --- Uplinks Node 1 ---
Write-Host "`n--- Configure Gateway Uplinks for Edge Node 1 ---" -ForegroundColor Cyan
# Uplink 1
Write-Host "--- Uplink 1 ---" -ForegroundColor Yellow
$Node1Up1Vlan = Get-ValidVlan "Enter Interface VLAN"
$Node1Up1Cidr = Get-ValidCidr "Enter Interface CIDR"
do {
    $Node1Up1PeerCidr = Get-ValidCidr "Enter BGP Peer IP (CIDR)"
    if (Test-IpInCidr -SubnetCidr $Node1Up1Cidr -TargetIpOrCidr $Node1Up1PeerCidr) { $Up1PeerValid = $true }
    else { Write-Warning "Peer IP not in Interface range."; $Up1PeerValid = $false }
} while (-not $Up1PeerValid)

$Node1Up1Mtu = Get-ValidMtu "Enter MTU"
$Node1Up1PeerAsn = Read-Host "Enter BGP Peer ASN"
$Node1Up1PeerPass = Read-Host "Enter BGP Peer Password"

# Uplink 2
Write-Host "--- Uplink 2 ---" -ForegroundColor Yellow
do {
    $Node1Up2Vlan = Get-ValidVlan "Enter Interface VLAN"
    if ($Node1Up2Vlan -eq $Node1Up1Vlan) { Write-Warning "Uplink 2 VLAN must differ from Uplink 1."; $VlanUnique = $false } else { $VlanUnique = $true }
} while (-not $VlanUnique)

do {
    $Node1Up2Cidr = Get-ValidCidr "Enter Interface CIDR"
    if (Test-CidrMatch -Cidr1 $Node1Up1Cidr -Cidr2 $Node1Up2Cidr) { Write-Warning "Subnet overlap with Uplink 1."; $Up2Valid = $false; continue }
    $Node1Up2PeerCidr = Get-ValidCidr "Enter BGP Peer IP (CIDR)"
    if (-not (Test-IpInCidr -SubnetCidr $Node1Up2Cidr -TargetIpOrCidr $Node1Up2PeerCidr)) { Write-Warning "Peer IP not in range."; $Up2Valid = $false; continue }
    $Up2Valid = $true
} while (-not $Up2Valid)

$Node1Up2Mtu = $Node1Up1Mtu
$Node1Up2PeerAsn = $Node1Up1PeerAsn
$Node1Up2PeerPass = $Node1Up1PeerPass
Write-Host "Using MTU, ASN, and Password from Uplink 1." -ForegroundColor Gray


# --- Edge Node 2 ---
$AddSecondNode = Read-Host "`nEnter details of another edge Node? (y/n)"
if ($AddSecondNode -eq 'y') {
    Write-Host "`n--- Configure Edge Node 2 ---" -ForegroundColor Cyan
    $Node2Fqdn = Read-Host "Enter Edge Node 2 FQDN"
    do {
        $Node2MgmtIpCidr = Get-ValidCidr "Enter Management IP (CIDR)"
        $Node2MgmtGateway = Read-Host "Enter Gateway"
        if (-not (Test-IpInCidr -SubnetCidr $Node2MgmtIpCidr -TargetIpOrCidr $Node2MgmtGateway)) { Write-Warning "Gateway not in subnet."; $Node2MgmtValid = $false; continue }
        if ($Node1MgmtIpCidr.Split('/')[0] -eq $Node2MgmtIpCidr.Split('/')[0]) { Write-Warning "Cannot match Node 1 IP."; $Node2MgmtValid = $false } else { $Node2MgmtValid = $true }
    } while (-not $Node2MgmtValid)
    
    if ($UseTepPool) {
        Write-Host "Using Existing TEP Pool ($IpPoolName). Skipping TEP IPs." -ForegroundColor Gray
        $Node2Tep1Ip = $null; $Node2Tep2Ip = $null
    } else {
        $Node2Tep1Ip = Get-ValidCidr "Enter Node 2 - First Edge TEP IP (CIDR)"
        $Node2Tep2Ip = Get-ValidCidr "Enter Node 2 - Second Edge TEP IP (CIDR)"
    }
    
    # Node 2 Uplinks (Auto-reuse VLANs)
    Write-Host "`n--- Node 2 Uplinks ---" -ForegroundColor Yellow
    $Node2Up1Vlan = $Node1Up1Vlan; $Node2Up2Vlan = $Node1Up2Vlan
    Write-Host "Reusing VLANs: $Node2Up1Vlan, $Node2Up2Vlan" -ForegroundColor Gray
    
    do {
        $Node2Up1Cidr = Get-ValidCidr "Enter N2 Uplink 1 CIDR"
        if (-not (Test-CidrMatch -Cidr1 $Node1Up1Cidr -Cidr2 $Node2Up1Cidr)) { Write-Warning "Must be in same subnet as N1 Uplink 1."; $N2Up1Valid = $false; continue }
        if ($Node1Up1Cidr.Split('/')[0] -eq $Node2Up1Cidr.Split('/')[0]) { Write-Warning "IP Duplicate."; $N2Up1Valid = $false; continue }
        $N2Up1Valid = $true
    } while (-not $N2Up1Valid)
    
    do {
        $Node2Up2Cidr = Get-ValidCidr "Enter N2 Uplink 2 CIDR"
        if (-not (Test-CidrMatch -Cidr1 $Node1Up2Cidr -Cidr2 $Node2Up2Cidr)) { Write-Warning "Must be in same subnet as N1 Uplink 2."; $N2Up2Valid = $false; continue }
        if ($Node1Up2Cidr.Split('/')[0] -eq $Node2Up2Cidr.Split('/')[0]) { Write-Warning "IP Duplicate."; $N2Up2Valid = $false; continue }
        $N2Up2Valid = $true
    } while (-not $N2Up2Valid)
    
    $Node2Up2PeerCidr = $Node1Up2PeerCidr
    Write-Host "Using Peer IP from Node 1 Uplink 2: $Node1Up2PeerCidr" -ForegroundColor Gray
}

# === POST-WIZARD SDDC AUTH & LOOKUP START ===
if ($AutoRetrieveId -eq 'y') {
    Write-Host "`n--- SDDC Manager Connection (Retrieving Cluster ID) ---" -ForegroundColor Cyan
    $LookupFqdn = Read-Host "Enter SDDC Manager FQDN"
    $LookupUser = Read-Host "Enter Username"
    $LookupPass = Read-Host "Enter Password"
    
    Write-Host "Attempting to retrieve ID for cluster: $VsphereClusterName..." -ForegroundColor Yellow
    try {
        $TokenUrl = "https://$LookupFqdn/v1/tokens"
        $TokenBody = @{ username = $LookupUser; password = $LookupPass } | ConvertTo-Json
        $TokenResponse = Invoke-RestMethod -Uri $TokenUrl -Method Post -Body $TokenBody -ContentType "application/json" -SkipCertificateCheck
        
        $ClustersUrl = "https://$LookupFqdn/v1/clusters"
        $Headers = @{ "Authorization" = "Bearer $($TokenResponse.accessToken)"; "Content-Type"  = "application/json" }
        $ClustersResponse = Invoke-RestMethod -Uri $ClustersUrl -Method Get -Headers $Headers -SkipCertificateCheck
        
        $TargetCluster = $ClustersResponse.elements | Where-Object { $_.name -eq $VsphereClusterName }
        if ($TargetCluster) {
            $VsphereClusterId = $TargetCluster.id
            Write-Host "SUCCESS: Found ID $VsphereClusterId" -ForegroundColor Green
        } else {
            Write-Warning "Cluster not found in SDDC Manager. Reverting to manual entry."
            $VsphereClusterId = Read-Host "Enter vSphere Cluster ID manually"
        }
    } catch {
        Write-Warning "Failed to connect to SDDC Manager. Reverting to manual entry."
        $VsphereClusterId = Read-Host "Enter vSphere Cluster ID manually"
    }
}
# === POST-WIZARD SDDC AUTH & LOOKUP END ===

# --- Construct Spec ---
Write-Host "`n--- Constructing Specifications ---" -ForegroundColor Cyan

function New-UplinkObj ($Vlan, $InterfaceIp, $PeerIp, $PeerAsn, $PeerPass) {
    return [Ordered]@{
        uplinkVlan = $Vlan; uplinkInterfaceIP = $InterfaceIp
        bgpPeers = @( [Ordered]@{ ip = $PeerIp; asn = $PeerAsn; password = $PeerPass } )
    }
}
$N1U1 = New-UplinkObj $Node1Up1Vlan $Node1Up1Cidr $Node1Up1PeerCidr $Node1Up1PeerAsn $Node1Up1PeerPass
$N1U2 = New-UplinkObj $Node1Up2Vlan $Node1Up2Cidr $Node1Up2PeerCidr $Node1Up2PeerAsn $Node1Up2PeerPass
$Node1Uplinks = @($N1U1, $N1U2)
if ($AddSecondNode -eq 'y') {
    $N2U1 = New-UplinkObj $Node2Up1Vlan $Node2Up1Cidr $Node1Up1PeerCidr $Node1Up1PeerAsn $Node1Up1PeerPass
    $N2U2 = New-UplinkObj $Node2Up2Vlan $Node2Up2Cidr $Node1Up2PeerCidr $Node1Up2PeerAsn $Node1Up2PeerPass
    $Node2Uplinks = @($N2U1, $N2U2)
}

function New-EdgeNodeSpec {
    param($Name, $MgmtIp, $MgmtGw, $Uplinks, $UsePool, $PoolName, $StaticTep1, $StaticTep2, $StaticGw, $TepVlan)
    $Spec = [Ordered]@{ edgeNodeName = $Name; managementIP = $MgmtIp; managementGateway = $MgmtGw }
    if ($UsePool) { $Spec["edgeTepIpAddressPool"] = [Ordered]@{ name = $PoolName } }
    else { $Spec["edgeTepGateway"] = $StaticGw; $Spec["edgeTep1IP"] = $StaticTep1; $Spec["edgeTep2IP"] = $StaticTep2 }
    $Spec["edgeTepVlan"] = $TepVlan
    $Spec["clusterId"] = $VsphereClusterId
    $Spec["interRackCluster"] = "false"
    $Spec["uplinkNetwork"] = $Uplinks
    $Spec["vmManagementPortgroupName"] = $MgmtPortGroup
    $Spec["vmManagementPortgroupVlan"] = $MgmtVlan
    return $Spec
}

$EdgeNodeSpecs = @()
$EdgeNodeSpecs += New-EdgeNodeSpec -Name $Node1Fqdn -MgmtIp $Node1MgmtIpCidr -MgmtGw $Node1MgmtGateway -Uplinks $Node1Uplinks -UsePool $UseTepPool -PoolName $IpPoolName -StaticTep1 $Node1Tep1Ip -StaticTep2 $Node1Tep2Ip -StaticGw $EdgeTepGateway -TepVlan $TepVlan
if ($AddSecondNode -eq 'y') {
    $EdgeNodeSpecs += New-EdgeNodeSpec -Name $Node2Fqdn -MgmtIp $Node2MgmtIpCidr -MgmtGw $Node2MgmtGateway -Uplinks $Node2Uplinks -UsePool $UseTepPool -PoolName $IpPoolName -StaticTep1 $Node2Tep1Ip -StaticTep2 $Node2Tep2Ip -StaticGw $EdgeTepGateway -TepVlan $TepVlan
}

$EdgeClusterCreationSpec = [Ordered]@{
    asn = $LocalAsn
    edgeAdminPassword = $EdgeAdminPassword
    edgeAuditPassword = $EdgeAuditPassword
    edgeClusterName = $EdgeClusterName
    edgeClusterProfileType = $EdgeClusterProfileType
    edgeClusterType = "NSX-T"
    edgeFormFactor = $EdgeFormFactor
    edgeNodeSpecs = $EdgeNodeSpecs
    edgeRootPassword = $EdgeRootPassword
    mtu = $Node1Up1Mtu
    skipTepRoutabilityCheck = $false
    tier0Name = $Tier0Name
    tier0RoutingType = $Tier0RoutingType
    tier0ServicesHighAvailability = $Tier0HaMode
    tier1Name = ""
    tier1Unhosted = $false
}
if ($EdgeClusterProfileType -eq "CUSTOM") {
    $EdgeClusterCreationSpec["edgeClusterProfileSpec"] = [Ordered]@{
        edgeClusterProfileName = $MyEdgeClusterProfileName
        bfdAllowedHop = $BfdAllowedHop
        bfdDeclareDeadMultiple = $BfdDeclareDeadMultiple
        bfdProbeInterval = $BfdProbeInterval
        standbyRelocationThreshold = $StandbyRelocationThreshold
    }
}

$Filename = "EdgeClusterSpec_$(Get-Date -Format 'yyyyMMdd-HHmm').json"
$OutputPath = Join-Path -Path $PWD -ChildPath $Filename

try {
    $EdgeClusterCreationSpec | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Force
    Write-Host "`nSUCCESS: Spec saved to: $OutputPath" -ForegroundColor Green
} catch { Write-Error "Failed to save file: $_"; exit }


# ==========================================
# PROMPT FOR IMMEDIATE VALIDATION
# ==========================================
Write-Host "`n--- Validation ---" -ForegroundColor Cyan
do {
    $ValidateChoice = Read-Host "Do you want to validate this spec against SDDC Manager now? (y/n)"
} while ($ValidateChoice -notin 'y','n')

if ($ValidateChoice -eq 'y') {
    Invoke-EdgeClusterValidation -JsonSpecPath $OutputPath
} else {
    Write-Host "Exiting. You can validate the file later." -ForegroundColor Gray
}
