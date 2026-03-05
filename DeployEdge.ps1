# ==============================================================================
# VMware Cloud Foundation - NSX Edge Cluster Deployment Tool
# Functionality: Load Spec -> Validate (with Polling) -> Deploy
# ==============================================================================

# ==========================================
# 0. Helper Functions
# ==========================================

function Get-SddcToken {
    param ($BaseUrl, $User, $Pass)
    $TokenUrl = "$BaseUrl/v1/tokens"
    $Body = @{ username = $User; password = $Pass } | ConvertTo-Json
    try {
        $Resp = Invoke-RestMethod -Uri $TokenUrl -Method Post -Body $Body -ContentType "application/json" -SkipCertificateCheck
        return $Resp.accessToken
    } catch {
        Write-Host " [!] Authentication Failed: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# ==========================================
# 1. Initialization & Path Setup
# ==========================================
Clear-Host
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Edge Cluster Deployment & Validation   " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

$JsonPath = Read-Host "`nStep 1: Enter the full path to your Edge Cluster JSON spec"
$JsonPath = $JsonPath -replace '"', '' # Remove quotes if user pasted path with them

if (-not (Test-Path $JsonPath)) {
    Write-Host " [!] Error: File not found at $JsonPath" -ForegroundColor Red
    exit
}

$JsonContent = Get-Content -Path $JsonPath -Raw

# ==========================================
# 2. Validation Phase
# ==========================================
$DoValidation = Read-Host "Step 2: Do you want to validate the spec against SDDC Manager? (y/n)"

if ($DoValidation -eq 'y') {
    Write-Host "`n--- SDDC Manager Authentication ---" -ForegroundColor Cyan
    $SddcFqdn = Read-Host "Enter SDDC Manager FQDN"
    $Username = Read-Host "Enter Username"
    $Password = Read-Host "Enter Password"
    $BaseUrl  = "https://$SddcFqdn"

    $Token = Get-SddcToken -BaseUrl $BaseUrl -User $Username -Pass $Password

    if ($null -ne $Token) {
        $Headers = @{ "Authorization" = "Bearer $Token"; "Content-Type" = "application/json" }
        
        Write-Host "`n[*] Submitting Validation Request..." -ForegroundColor Yellow
        $ValidationUrl = "$BaseUrl/v1/edge-clusters/validations"
        
        try {
            $ValResponse = Invoke-RestMethod -Uri $ValidationUrl -Method Post -Headers $Headers -Body $JsonContent -SkipCertificateCheck
            $ValId = $ValResponse.id
            Write-Host "Validation Task Created. ID: $ValId" -ForegroundColor Cyan

            # --- Polling Logic ---
            $Status = "IN_PROGRESS"
            Write-Host "[*] Polling status every 30 seconds..." -ForegroundColor Gray
            
            do {
                Start-Sleep -Seconds 30
                $StatusResp = Invoke-RestMethod -Uri "$ValidationUrl/$ValId" -Method Get -Headers $Headers -SkipCertificateCheck
                
                # Check for status in different API response formats
                $Status = if ($StatusResp.executionStatus) { $StatusResp.executionStatus } else { $StatusResp.status }
                
                $Timestamp = Get-Date -Format "HH:mm:ss"
                Write-Host "[$Timestamp] Current Status: $Status" -ForegroundColor Yellow

            } while ($Status -match "IN_PROGRESS|PENDING|Processing")

            # --- Save Validation Result ---
            $DateStr = Get-Date -Format "yyyyMMdd_HHmm"
            $LogFile = "edgespec-validation_$DateStr.json"
            $StatusResp | ConvertTo-Json -Depth 10 | Set-Content -Path $LogFile
            Write-Host "`n[+] Validation results saved to: $LogFile" -ForegroundColor Green

            # --- Evaluate Success for Deployment ---
            if ($StatusResp.resultStatus -eq "SUCCEEDED" -or $Status -eq "SUCCEEDED") {
                Write-Host "==========================================" -ForegroundColor Green
                Write-Host " VALIDATION PASSED SUCCESSFULLY           " -ForegroundColor Green
                Write-Host "==========================================" -ForegroundColor Green
                
                $DoDeploy = Read-Host "`nValidation successful. Do you want to post the spec for DEPLOYMENT? (y/n)"
                if ($DoDeploy -eq 'y') {
                    Write-Host "[*] Triggering Deployment..." -ForegroundColor Cyan
                    $DeployUrl = "$BaseUrl/v1/edge-clusters"
                    $DeployResp = Invoke-RestMethod -Uri $DeployUrl -Method Post -Headers $Headers -Body $JsonContent -SkipCertificateCheck
                    Write-Host "`nSUCCESS: Deployment Task Triggered!" -ForegroundColor Green
                    Write-Host "Task ID: $($DeployResp.id)" -ForegroundColor Yellow
                    Write-Host "Monitor progress in SDDC Manager UI." -ForegroundColor Gray
                }
            } else {
                Write-Host " [!] Validation failed or finished with errors. Check $LogFile for details." -ForegroundColor Red
            }
        } catch {
            Write-Host " [!] API Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
} else {
    Write-Host "`nValidation skipped. Exiting script." -ForegroundColor Gray
}
