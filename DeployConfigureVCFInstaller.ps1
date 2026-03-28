# ==============================================================================
# VCF 9.0.1 UNIFIED AUTOMATION (DEPLOY -> CONFIG -> DOWNLOAD -> DASHBOARD)
# ==============================================================================

# Force modern security protocols
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

function Get-SddcAuthToken {
    param ($Fqdn, $User, $Pass)
    $TokenUrl = "https://${Fqdn}/v1/tokens"
    
    # Building literal JSON to prevent PowerShell from modifying special characters in passwords
    $LiteralBody = '{"username":"' + $User + '","password":"' + $Pass + '"}'
    
    try {
        $Resp = Invoke-RestMethod -Uri $TokenUrl `
                                 -Method Post `
                                 -Body $LiteralBody `
                                 -ContentType "application/json; charset=utf-8" `
                                 -SkipCertificateCheck `
                                 -ErrorAction Stop
        
        if ($null -ne $Resp.token) { return $Resp.token }
        if ($null -ne $Resp.accessToken) { return $Resp.accessToken }
        return $null
    } catch {
        if ($_.Exception.Response) {
            $Code = [int]$_.Exception.Response.StatusCode
            Write-Host " (Auth Error: $Code) " -NoNewline -ForegroundColor Red
        }
        return $null
    }
}

Write-Host "`n===============================================" -ForegroundColor Cyan
Write-Host " VCF 9.0.1 UNIFIED DEPLOYMENT UTILITY"
Write-Host "===============================================" -ForegroundColor Cyan

# --- [1] Target Infrastructure Credentials ---
$TargetServer = Read-Host "Enter Target vCenter or ESXi FQDN/IP"
$TargetUser   = Read-Host "Enter Target Username (e.g., root)"
$TargetPassIn = Read-Host "Enter Target Password" -AsSecureString
$TargetPass   = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($TargetPassIn))

# --- [2] Select Input Method ---
$InputMethod = Read-Host "Use Config File (F) or Manual Entry (M)?"

if ($InputMethod -eq "F" -or $InputMethod -eq "f") {
    $ConfigPath = Read-Host "Enter the full path to your JSON config file"
    if (-not (Test-Path $ConfigPath)) { Write-Host "[ERROR] File not found!" -ForegroundColor Red; exit }
    
    $Cfg = Get-Content $ConfigPath | ConvertFrom-Json
    $Infra = $Cfg.Infrastructure
    $Props = $Cfg.ApplianceProperties
    $Depot = $Cfg.DepotSettings
    $BundleCfg = $Cfg.BundleSettings
    $OvfExe = $Infra.OvfToolPath
} 
else {
    Write-Host "`n--- Deployment Details ---" -ForegroundColor Yellow
    $Infra = [PSCustomObject]@{
        VmName = Read-Host "New VM Name"; Datastore = Read-Host "Datastore"; Network = Read-Host "Network"; OvaPath = Read-Host "Full path to OVA"
    }
    $OvfExe = "C:\Program Files\VMware\VMware OVF Tool\ovftool.exe"
    $Props = [PSCustomObject]@{
        vami_hostname = Read-Host "FQDN"; vami_ip0_SDDC_Manager = Read-Host "IP"; vami_netmask0_SDDC_Manager = Read-Host "Netmask"
        vami_gateway_SDDC_Manager = Read-Host "Gateway"; vami_domain_SDDC_Manager = Read-Host "Domain"; vami_searchpath_SDDC_Manager = Read-Host "Search Path"
        vami_DNS_SDDC_Manager = Read-Host "DNS"; guestinfo_ntp = Read-Host "NTP"; ROOT_PASSWORD = Read-Host "ROOT Pass"
        LOCAL_USER_PASSWORD = Read-Host "LOCAL_USER Pass"; VCF_PASSWORD = Read-Host "VCF Pass"
    }
    $Depot = [PSCustomObject]@{ isOfflineDepot = $true; hostname = "depot.vcf-gcp.broadcom.net"; port = 443; depot_user = Read-Host "Depot User"; depot_pass = Read-Host "Depot Pass" }
    $BundleCfg = [PSCustomObject]@{ target_version = Read-Host "Target Version (e.g. 9.0.1.0)" }
}

# --- [3] Phase 1: OVA Deployment ---
Write-Host "`n>>> PHASE 1: Deploying OVA..." -ForegroundColor Cyan
Add-Type -AssemblyName System.Web
$EncodedPass = [System.Net.WebUtility]::UrlEncode($TargetPass)
$TargetURI   = "vi://$($TargetUser):$($EncodedPass)@$($TargetServer)"

$OvfArgs = @(
    "--noSSLVerify", "--acceptAllEulas", "--name=$($Infra.VmName)",
    "--datastore=$($Infra.Datastore)", "--network=$($Infra.Network)",
    "--diskMode=thin", "--powerOn", "--X:injectOvfEnv",
    "--prop:ROOT_PASSWORD=$($Props.ROOT_PASSWORD)",
    "--prop:LOCAL_USER_PASSWORD=$($Props.LOCAL_USER_PASSWORD)",
    "--prop:VCF_PASSWORD=$($Props.VCF_PASSWORD)",
    "--prop:vami.hostname=$($Props.vami_hostname)",
    "--prop:vami.ip0.SDDC-Manager=$($Props.vami_ip0_SDDC_Manager)",
    "--prop:vami.netmask0.SDDC-Manager=$($Props.vami_netmask0_SDDC_Manager)",
    "--prop:vami.gateway.SDDC-Manager=$($Props.vami_gateway_SDDC_Manager)",
    "--prop:vami.domain.SDDC-Manager=$($Props.vami_domain_SDDC_Manager)",
    "--prop:vami.searchpath.SDDC-Manager=$($Props.vami_searchpath_SDDC_Manager)",
    "--prop:vami.DNS.SDDC-Manager=$($Props.vami_DNS_SDDC_Manager)",
    "--prop:guestinfo.ntp=$($Props.guestinfo_ntp)",
    $Infra.OvaPath, $TargetURI
)

& "$OvfExe" @OvfArgs
if ($LASTEXITCODE -ne 0) { Write-Host "[ERROR] Deployment failed." -ForegroundColor Red; exit }

# --- [4] Phase 2: Wait for API Readiness ---
$IP = $Props.vami_ip0_SDDC_Manager
$Authenticated = $false
Write-Host "`n>>> PHASE 2: Waiting for VCF services at $IP..." -ForegroundColor Cyan

while (-not $Authenticated) {
    $Token = Get-SddcAuthToken -Fqdn $IP -User "admin@local" -Pass $Props.LOCAL_USER_PASSWORD
    if ($null -ne $Token) {
        $Authenticated = $true
        Write-Host "`n[ONLINE] Authenticated successfully." -ForegroundColor Green
    } else {
        Write-Host "." -NoNewline -ForegroundColor Yellow; Start-Sleep -Seconds 30
    }
}

# --- [5] Phase 3: Configure Offline Depot ---
Write-Host "`n>>> PHASE 3: Configuring Offline Depot Settings..." -ForegroundColor Cyan
$DepotBody = @{
    offlineAccount = @{ username = $Depot.depot_user; password = $Depot.depot_pass }
    depotConfiguration = @{ isOfflineDepot = $true; hostname = $Depot.hostname; port = $Depot.port }
} | ConvertTo-Json

$Headers = @{ 
    "Authorization" = "Bearer $Token"
    "Accept"        = "application/json"
    "Content-Type"  = "application/json"
}

try {
    Invoke-RestMethod -Uri "https://$IP/v1/system/settings/depot" -Method Put -Body $DepotBody -Headers $Headers -ContentType "application/json" -SkipCertificateCheck
    Write-Host "[SUCCESS] Depot configured." -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Depot config failed." -ForegroundColor Red; exit
}

# --- [6] Phase 4: Bundle Polling ---
$BundlesFound = $false
$BundlesUrl = "https://$IP/v1/bundles"
$OutputFileName = "vcf-bundles-output.json"
$ConfigVersion = $BundleCfg.target_version
$VersionPrefix = $ConfigVersion.Substring(0, 5) # Matches "9.0.1"

Write-Host "`n>>> PHASE 4: Polling for Bundles (Prefix: $VersionPrefix)..." -ForegroundColor Cyan
while (-not $BundlesFound) {
    try {
        $Response = Invoke-RestMethod -Uri $BundlesUrl -Method Get -Headers $Headers -SkipCertificateCheck
        if ($null -ne $Response.elements -and $Response.elements.Count -gt 0) {
            $BundlesFound = $true
            $Response | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputFileName
            Write-Host "[SUCCESS] Metadata saved to $OutputFileName." -ForegroundColor Green
        } else {
            Write-Host "." -NoNewline -ForegroundColor Cyan; Start-Sleep -Seconds 60
        }
    } catch {
        Write-Host "x" -NoNewline -ForegroundColor Red; Start-Sleep -Seconds 60
    }
}

# --- [7] Phase 5: Trigger Bundle Downloads (FIXED LOGIC) ---
Write-Host "`n>>> PHASE 5: Triggering Downloads (Matching Prefix + INSTALL Type)..." -ForegroundColor Cyan

# Logic: Filter for INSTALL bundles and group by type+version to remove invalid metadata duplicates
$BundlesToDownload = $Response.elements | Where-Object {
    $_.version -like "$VersionPrefix*" -and ($_.components | Where-Object { $_.imageType -eq "INSTALL" })
} | Group-Object { $_.components[0].type + $_.version } | ForEach-Object { $_.Group[0] }

if ($null -eq $BundlesToDownload -or ($BundlesToDownload | Measure-Object).Count -eq 0) {
    Write-Host "[INFO] No matching INSTALL bundles found for version prefix $VersionPrefix." -ForegroundColor Yellow
} 
else {
    $BundleIds = @()
    foreach ($Bundle in $BundlesToDownload) {
        $BundleIds += $Bundle.id
        $CompName = $Bundle.components[0].type
        Write-Host "Triggering: $CompName [$($Bundle.version)]..." -NoNewline
        
        $DownloadUrl = "https://$IP/v1/bundles/$($Bundle.id)"
        
        # FIXED BODY: Using bundleDownloadSpec as required by VCF 9
        $DownloadBody = @{
            bundleDownloadSpec = @{
                downloadNow = $true
            }
        } | ConvertTo-Json
        
        try {
            Invoke-RestMethod -Uri $DownloadUrl -Method Patch -Body $DownloadBody -Headers $Headers -ContentType "application/json" -SkipCertificateCheck
            Write-Host " [STARTED]" -ForegroundColor Green
        } catch {
            Write-Host " [FAILED]" -ForegroundColor Red
        }
    }

    # --- [8] Phase 6: Refreshing Monitoring Dashboard ---
    $StatusUrl = "https://$IP/v1/bundles/download-status"
    $AllFinished = $false

    while (-not $AllFinished) {
        try {
            $StatusResponse = Invoke-RestMethod -Uri $StatusUrl -Method Get -Headers $Headers -SkipCertificateCheck
            $MyBundlesStatus = $StatusResponse.elements | Where-Object { $BundleIds -contains $_.bundleId }
            
            Clear-Host
            Write-Host "==========================================================" -ForegroundColor Cyan
            Write-Host " VCF 9.0.x BUNDLE DOWNLOAD DASHBOARD" -ForegroundColor Cyan
            Write-Host " Last Updated: $(Get-Date -Format "HH:mm:ss")" -ForegroundColor Gray
            Write-Host "==========================================================" -ForegroundColor Cyan
            
            $MyBundlesStatus | Select-Object componentType, version, downloadStatus | Format-Table -AutoSize

            $Active = $MyBundlesStatus | Where-Object { $_.downloadStatus -in @("IN_PROGRESS", "PENDING", "SCHEDULED") }
            if ($null -eq $Active -or ($Active | Measure-Object).Count -eq 0) {
                $AllFinished = $true
                Write-Host "`n[COMPLETE] All triggered downloads have finished." -ForegroundColor Green
            } else {
                Write-Host "`nRefreshing in 5 minutes..." -ForegroundColor DarkGray
                Start-Sleep -Seconds 300
            }
        } catch {
            Write-Host "`n[WARNING] API Busy. Retrying in 5 mins..." -ForegroundColor Yellow
            Start-Sleep -Seconds 300
        }
    }
}

Write-Host "`nAutomation sequence finished." -ForegroundColor Green
