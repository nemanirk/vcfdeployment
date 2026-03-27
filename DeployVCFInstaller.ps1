# ==============================================================================
# VCF 9.0.1 UNIFIED AUTOMATION (CORRECTED API AUTHENTICATION)
# ==============================================================================

function Get-SddcAuthToken {
    param ($Fqdn, $User, $Pass)
    $TokenUrl = "https://${Fqdn}/v1/tokens"
    # User is now admin@local per VCF 9.x requirements
    $Body = @{ username = $User; password = $Pass } | ConvertTo-Json
    try {
        $Resp = Invoke-RestMethod -Uri $TokenUrl -Method Post -Body $Body -ContentType "application/json" -SkipCertificateCheck -ErrorAction Stop
        
        if ($null -ne $Resp.token) { return $Resp.token }
        if ($null -ne $Resp.accessToken) { return $Resp.accessToken }
        
        return $null
    } catch {
        if ($_.Exception.Response) {
            $Code = $_.Exception.Response.StatusCode.value__
            if ($Code -eq 401) { Write-Host "(401-Unauthorized)" -NoNewline -ForegroundColor Red }
            else { Write-Host "($Code)" -NoNewline -ForegroundColor Gray }
        }
        return $null
    }
}

Write-Host "`n===============================================" -ForegroundColor Cyan
Write-Host " VCF 9.0.1 UNIFIED DEPLOYMENT UTILITY"
Write-Host "===============================================" -ForegroundColor Cyan

# --- [1] Target Infrastructure (Manual Input) ---
$TargetServer = Read-Host "Enter Target vCenter or ESXi FQDN/IP"
$TargetUser   = Read-Host "Enter Target Username (e.g., root)"
$TargetPassIn = Read-Host "Enter Target Password" -AsSecureString
$TargetPass   = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($TargetPassIn))

# --- [2] Input Method Selection ---
$InputMethod = Read-Host "Use Config File (F) or Manual Entry (M)?"

if ($InputMethod -eq "F" -or $InputMethod -eq "f") {
    $ConfigPath = Read-Host "Enter the full path to your JSON config file"
    if (-not (Test-Path $ConfigPath)) { Write-Host "[ERROR] File not found!" -ForegroundColor Red; exit }
    
    $Cfg = Get-Content $ConfigPath | ConvertFrom-Json
    $Infra = $Cfg.Infrastructure
    $Props = $Cfg.ApplianceProperties
    $Depot = $Cfg.DepotSettings
    $OvfExe = $Infra.OvfToolPath
} 
else {
    # Manual Entry Logic
    $Infra = [PSCustomObject]@{
        VmName      = Read-Host "New VM Name"
        Datastore   = Read-Host "Datastore Name"
        Network     = Read-Host "Network Name"
        OvaPath     = Read-Host "Full path to OVA"
    }
    $OvfExe = "C:\Program Files\VMware\VMware OVF Tool\ovftool.exe"
    
    $Props = [PSCustomObject]@{
        vami_hostname = Read-Host "Appliance FQDN"
        vami_ip0_SDDC_Manager = Read-Host "Appliance IP"
        vami_netmask0_SDDC_Manager = Read-Host "Netmask"
        vami_gateway_SDDC_Manager = Read-Host "Gateway"
        vami_domain_SDDC_Manager = Read-Host "Domain"
        vami_searchpath_SDDC_Manager = Read-Host "Search Path"
        vami_DNS_SDDC_Manager = Read-Host "DNS"
        guestinfo_ntp = Read-Host "NTP"
        ROOT_PASSWORD = Read-Host "ROOT Password"
        LOCAL_USER_PASSWORD = Read-Host "LOCAL_USER Password"
        VCF_PASSWORD = Read-Host "VCF (Bring-up) Password"
    }
    
    $Depot = [PSCustomObject]@{
        isOfflineDepot = $true
        hostname = "depot.vcf-gcp.broadcom.net"
        port = 443
        depot_user = Read-Host "Depot User"
        depot_pass = Read-Host "Depot Pass"
    }
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
$StartTime = Get-Date
$Authenticated = $false

Write-Host "`n>>> PHASE 2: Waiting for VCF services at $IP..." -ForegroundColor Cyan
Write-Host "Authenticating as admin@local using LOCAL_USER_PASSWORD..." -ForegroundColor Gray

while (-not $Authenticated) {
    # Using 'admin@local' and the 'LOCAL_USER_PASSWORD' as per your update
    $Token = Get-SddcAuthToken -Fqdn $IP -User "admin@local" -Pass $Props.LOCAL_USER_PASSWORD
    
    if ($null -ne $Token) {
        $Authenticated = $true
        $Duration = New-TimeSpan -Start $StartTime -End (Get-Date)
        Write-Host "`n[ONLINE] Authenticated successfully in $($Duration.Minutes)m $($Duration.Seconds)s." -ForegroundColor Green
    } else {
        if ((Get-Date) -gt $StartTime.AddMinutes(20)) {
            Write-Host "`n[FATAL] Timeout reached." -ForegroundColor Red; exit
        }
        Write-Host "." -NoNewline -ForegroundColor Yellow
        Start-Sleep -Seconds 30
    }
}

# --- [5] Phase 3: Configure Offline Depot ---
Write-Host "`n>>> PHASE 3: Configuring Offline Depot Settings..." -ForegroundColor Cyan
$DepotBody = @{
    offlineAccount = @{ username = $Depot.depot_user; password = $Depot.depot_pass }
    depotConfiguration = @{ isOfflineDepot = $true; hostname = $Depot.hostname; port = $Depot.port }
} | ConvertTo-Json

$Headers = @{ "Authorization" = "Bearer $Token"; "Accept" = "application/json" }

try {
    Invoke-RestMethod -Uri "https://$IP/v1/system/settings/depot" -Method Put -Body $DepotBody -Headers $Headers -ContentType "application/json" -SkipCertificateCheck
    Write-Host "[SUCCESS] End-to-end deployment and configuration complete!" -ForegroundColor Green
    Write-Host "Access URL: https://$IP" -ForegroundColor Cyan
} catch {
    Write-Host "[ERROR] Depot configuration failed." -ForegroundColor Red
}
