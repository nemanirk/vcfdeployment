# ==============================================================================
# SCRIPT: VCSA ESA Bootstrap Deployment Only (vSphere 9.0)
# ==============================================================================

# --- [ 1. CONFIGURATION VARIABLES ] ---

$IsoPath          = "F:\downloads\VMware-VCSA-all-9.0.2.0100.25629525.iso" 
$JsonConfigPath   = "C:\temp\vcsa-vsan-esa-deploy.json"
$VsanHclPath      = "F:\downloads\all.json" 

# vCenter Appliance Configuration
$VcsaName         = "sfo-w01-vc01"
$VcsaRootPassword = "VMw@re1!VMw@re1!"
$SsoDomain        = "vsphere.local"
$SsoPassword      = "VMw@re1!VMw@re1!"
$VcsaIp           = "10.11.10.160"
$VcsaFqdn         = "sfo-w02-vc01.sfo.rainpole.io"
$VcsaPrefix       = "24" 
$VcsaGateway      = "10.11.10.1"
$VcsaDnsServers   = "10.11.10.4,10.11.10.5"
$VcsaNtpServers   = "ntp0.sfo.rainpole.io,ntp1.sfo.rainpole.io"
$DeploymentSize   = "small" 

# Inventory Targets
$DatacenterName   = "sfo-w02-dc01"
$ClusterName      = "sfo-w02-cl01"

# Bootstrap Host Details
$BootstrapFqdn    = "sfo01-m01-r01-esx08.sfo.rainpole.io"
$BootstrapPass    = "VMw@re1!"

# Manual ESA Disk Entry for Bootstrap Node
$BootstrapEsaDisks = @(
    "eui.d6e46c8cbfa4bfb7000c2960fb4966f9",
    "eui.c83c8105c9786d0d000c296d3909a7cf", 
    "eui.03591e3868059d4d000c296e7743ca23"
)

# ==============================================================================
# --- [ 2. JSON GENERATION & VCSA DEPLOYMENT ] ---
# ==============================================================================

Write-Host "`n>>> Generating JSON and Launching VCSA Installer..." -ForegroundColor Cyan

# Format Arrays and Paths for JSON payload
$EsaDisksJson = ($BootstrapEsaDisks | ForEach-Object { "`"$_`"" }) -join ", "
$DnsJson = ($VcsaDnsServers -split ',' | ForEach-Object { "`"$($_.Trim())`"" }) -join ", "
$EscapedHclPath = $VsanHclPath.Replace('\', '\\') 

$JsonContent = @"
{
    "__version": "2.13.0",
    "new_vcsa": {
        "esxi": {
            "hostname": "$BootstrapFqdn",
            "username": "root",
            "password": "$BootstrapPass",
            "deployment_network": "VM Network",
            "VCSA_cluster": {
                "datacenter": "$DatacenterName",
                "cluster": "$ClusterName",
                "compression_only": false,
                "deduplication_and_compression": false,
                "enable_vsan_esa": true,
                "storage_pool": {
                    "single_tier": [
                        $EsaDisksJson
                    ]
                },
                "vsan_hcl_database_path": "$EscapedHclPath"
            }
        },
        "appliance": {
            "thin_disk_mode": true,
            "deployment_option": "$DeploymentSize",
            "name": "$VcsaName"
        },
        "network": {
            "ip_family": "ipv4",
            "mode": "static",
            "ip": "$VcsaIp",
            "dns_servers": [ $DnsJson ],
            "prefix": "$VcsaPrefix",
            "gateway": "$VcsaGateway",
            "system_name": "$VcsaFqdn"
        },
        "os": { 
            "password": "$VcsaRootPassword", 
            "ssh_enable": true,
            "ntp_servers": "$VcsaNtpServers" 
        },
        "sso": { "password": "$SsoPassword", "domain_name": "$SsoDomain" }
    },
    "ceip": { "settings": { "ceip_enabled": false } }
}
"@

New-Item -ItemType Directory -Path (Split-Path $JsonConfigPath) -Force | Out-Null
$JsonContent | Set-Content -Path $JsonConfigPath -Encoding UTF8

# Mount ISO and run installer
Write-Host "Mounting ISO and starting installer..." -ForegroundColor Gray
$MountResult = Mount-DiskImage -ImagePath $IsoPath -PassThru
$DriveLetter = ($MountResult | Get-Volume).DriveLetter
$IsoDrive = "$($DriveLetter):\"
$InstallerPath = Join-Path $IsoDrive "vcsa-cli-installer\win32\vcsa-deploy.exe"

if (-not (Test-Path $InstallerPath)) {
    Write-Error "[FATAL] Installer not found at $InstallerPath. Did the ISO mount correctly?"
    Dismount-DiskImage -ImagePath $IsoPath | Out-Null
    exit
}

# Use VCSA dashed arguments and string execution
$DeployArgs = "install --accept-eula --acknowledge-ceip --no-ssl-certificate-verification `"$JsonConfigPath`""
Write-Host "Executing Installer: vcsa-deploy.exe $DeployArgs" -ForegroundColor DarkGray
$Process = Start-Process -FilePath $InstallerPath -ArgumentList $DeployArgs -Wait -NoNewWindow -PassThru

# Cleanup Bootstrap artifacts
Dismount-DiskImage -ImagePath $IsoPath | Out-Null
Remove-Item -Path $JsonConfigPath -Force -ErrorAction SilentlyContinue

if ($Process.ExitCode -ne 0) { 
    Write-Error "VCSA deployment failed. Check logs."
} else {
    Write-Host "Bootstrap completed successfully!" -ForegroundColor Green
}
