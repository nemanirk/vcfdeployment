# 1. Prompt the user for VCF connection details
$vcfFqdn = Read-Host "Enter the VCF FQDN (e.g., sddc-manager.local)"
$vcfUser = Read-Host "Enter the Username (e.g., administrator@vsphere.local)"
$securePass = Read-Host "Enter the Password" -AsSecureString

# Convert SecureString back to Plain Text for the REST API JSON body
$vcfPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass))

function Get-SddcAuthToken {
    param ($Fqdn, $User, $Pass)
    $TokenUrl = "https://${Fqdn}/v1/tokens"
    $Body = @{ username = $User; password = $Pass } | ConvertTo-Json
    
    try {
        $Resp = Invoke-RestMethod -Uri $TokenUrl -Method Post -Body $Body -ContentType "application/json" -SkipCertificateCheck -ErrorAction Stop
        return $Resp.accessToken
    } catch {
        Write-Host "`n[ERROR] VCF Authentication Failed! $_" -ForegroundColor Red
        exit
    }
}

Write-Host "`nAuthenticating to $vcfFqdn..." -ForegroundColor Cyan
$global:AuthToken = Get-SddcAuthToken -Fqdn $vcfFqdn -User $vcfUser -Pass $vcfPass

if ($global:AuthToken) {
    Write-Host "[SUCCESS] Token retrieved successfully." -ForegroundColor Green
}

# 2. Prompt for the JSON file path
Write-Host ""
$jsonFilePath = Read-Host "Enter the full path to the VCF Management Components JSON file (e.g., C:\temp\vcf-spec.json)"

if (-not (Test-Path $jsonFilePath)) {
    Write-Host "[ERROR] The file at '$jsonFilePath' was not found! Exiting." -ForegroundColor Red
    exit
}

# 3. Prompt for validation execution
$proceed = Read-Host "Do you want to post this JSON for validation? (Y/N)"

if ($proceed -notmatch "^[Yy](es)?$") {
    Write-Host "User cancelled the validation step. Exiting script." -ForegroundColor Yellow
    exit
}

# 4. Execute the Validation API
$ValidationUrl = "https://${vcfFqdn}/v1/vcf-management-components/validations"
$JsonBody = Get-Content -Path $jsonFilePath -Raw

$Headers = @{
    "Authorization" = "Bearer $($global:AuthToken)"
    "Accept"        = "application/json"
    "Content-Type"  = "application/json"
}

Write-Host "`nPosting JSON to $ValidationUrl for validation..." -ForegroundColor Cyan

try {
    $ValidationResp = Invoke-RestMethod -Uri $ValidationUrl -Method Post -Headers $Headers -Body $JsonBody -SkipCertificateCheck -ErrorAction Stop
    $ValidationId = $ValidationResp.id
    
    if (-not $ValidationId) {
        Write-Host "[ERROR] Failed to extract Validation ID from the response. Exiting." -ForegroundColor Red
        exit
    }
    
    Write-Host "[SUCCESS] Validation task initiated! Task ID: $ValidationId" -ForegroundColor Green
    
} catch {
    Write-Host "`n[ERROR] VCF Management Components Validation Request Failed!" -ForegroundColor Red
    if ($_.ErrorDetails) { Write-Host "API Message: $($_.ErrorDetails.Message)" -ForegroundColor Yellow }
    exit
}

# 5. Track the Validation Progress
$ValidationStatusUrl = "https://${vcfFqdn}/v1/vcf-management-components/validations/$ValidationId"
$execStatus = "IN_PROGRESS"
$resultStatus = ""

Write-Host "`nTracking validation progress (this may take a few minutes)..." -ForegroundColor Cyan

do {
    Start-Sleep -Seconds 10
    try {
        $StatusResp = Invoke-RestMethod -Uri $ValidationStatusUrl -Method Get -Headers $Headers -SkipCertificateCheck -ErrorAction Stop
        
        # Track executionStatus to determine when loop finishes
        if ($StatusResp.executionStatus) { $execStatus = $StatusResp.executionStatus }
        elseif ($StatusResp.status) { $execStatus = $StatusResp.status }
        
        # Track resultStatus for actual validation outcome (PASSED/SUCCEEDED/FAILED)
        if ($StatusResp.resultStatus) { $resultStatus = $StatusResp.resultStatus }
        
        if ($resultStatus) {
            Write-Host "Execution Status: $execStatus | Result Status: $resultStatus"
        } else {
            Write-Host "Execution Status: $execStatus"
        }
        
    } catch {
        Write-Host "[WARNING] Failed to query validation status. Retrying in the next loop... $_" -ForegroundColor Yellow
    }
    
} while ($execStatus -match "IN_PROGRESS|PENDING|RUNNING")

# 6. Log the validation output
$LogFileName = "validation_output_$ValidationId.json"
$LogFilePath = Join-Path (Split-Path $jsonFilePath) $LogFileName
$StatusResp | ConvertTo-Json -Depth 10 | Out-File -FilePath $LogFilePath
Write-Host "`n[INFO] Detailed validation results saved to: $LogFilePath" -ForegroundColor Cyan

# 7. Evaluate resultStatus before prompting for deployment
if ($resultStatus -match "SUCCEEDED|SUCCESS|PASSED") {
    Write-Host "`n[SUCCESS] Validation completed successfully! (Result Status: $resultStatus)" -ForegroundColor Green
    
    $deployProceed = Read-Host "Do you want to deploy the VCF management components now? (Y/N)"
    if ($deployProceed -match "^[Yy](es)?$") {
        
        $DeployUrl = "https://${vcfFqdn}/v1/vcf-management-components"
        Write-Host "`nInitiating Deployment at $DeployUrl..." -ForegroundColor Cyan
        
        try {
            $DeployResp = Invoke-RestMethod -Uri $DeployUrl -Method Post -Headers $Headers -Body $JsonBody -SkipCertificateCheck -ErrorAction Stop
            $DeployTaskId = $DeployResp.id
            
            Write-Host "`n============================================================" -ForegroundColor Green
            Write-Host " [SUCCESS] VCF Management Components Deployment Initiated! " -ForegroundColor Green
            Write-Host "============================================================" -ForegroundColor Green
            Write-Host " DEPLOYMENT TASK ID : $DeployTaskId" -ForegroundColor Cyan
            Write-Host "============================================================" -ForegroundColor Green
            Write-Host "`nPlease monitor the deployment task progress directly from the VCF Operations / SDDC Manager UI." -ForegroundColor Yellow
            
            exit
            
        } catch {
            Write-Host "`n[ERROR] Deployment Request Failed!" -ForegroundColor Red
            if ($_.ErrorDetails) { Write-Host "API Message: $($_.ErrorDetails.Message)" -ForegroundColor Yellow }
            exit
        }
    } else {
        Write-Host "`nUser selected not to deploy the VCF management components. Exiting script." -ForegroundColor Yellow
        exit
    }
} else {
    Write-Host "`n[ERROR] Validation finished with failure resultStatus: '$resultStatus' (Execution Status: '$execStatus')." -ForegroundColor Red
    Write-Host "Please review the validation output log at '$LogFilePath' to resolve errors before attempting deployment." -ForegroundColor Yellow
    exit
}
