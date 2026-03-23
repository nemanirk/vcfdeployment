#----------- VCF 9.0 Management Domain Deployment Script (v4.1) -----------

# --- [Function] Get Authentication Token ---
function Get-SddcAuthToken {
    param ($Fqdn, $User, $Pass)
    $TokenUrl = "https://${Fqdn}/v1/tokens"
    $Body = @{ username = $User; password = $Pass } | ConvertTo-Json
    try {
        $Resp = Invoke-RestMethod -Uri $TokenUrl -Method Post -Body $Body -ContentType "application/json" -SkipCertificateCheck -ErrorAction Stop
        return $Resp.accessToken
    } catch {
        Write-Host "`n[ERROR] VCF Installer Authentication Failed!" -ForegroundColor Red; exit
    }
}

# --- [STEP 1: Authentication] ---
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " VCF 9.0 MANAGEMENT DOMAIN DEPLOYMENT & BRING-UP" -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Cyan

$VcfFqdn = Read-Host "`nEnter VCF Installer (Cloud Builder) FQDN"
$VcfUser = Read-Host "Enter Admin Username"
$SecurePass = Read-Host "Enter Admin Password" -AsSecureString
$VcfPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePass))

$AuthToken = Get-SddcAuthToken -Fqdn $VcfFqdn -User $VcfUser -Pass $VcfPass
$GlobalHeader = @{ "Authorization" = "Bearer ${AuthToken}"; "Content-Type" = "application/json" }
Write-Host "Success! Authentication token received.`n" -ForegroundColor Green

# --- [STEP 2: JSON Payload Prep & Filename Generation] ---
$FileTS = Get-Date -Format "yyyyMMdd_HHmm"
$TemplateJsonPath = Read-Host "Enter the file path for the original JSON template"
$OutputJsonPath = Read-Host "Enter the name/path for the NEW output JSON file"
$LogPath = "bringupSpec_validation_log_$($FileTS).csv"
$ResponseJsonPath = "bringupSpec_validation_$($FileTS).json"

try { 
    $Payload = Get-Content $TemplateJsonPath -Raw | ConvertFrom-Json 
} catch { 
    Write-Host "[ERROR] Failed to parse template JSON file." -ForegroundColor Red; exit 
}

# ... [Host & Thumbprint Logic remains same] ...
$UpdateHosts = Read-Host "`nDo you want to update hosts from a text file? (y/n)"
if ($UpdateHosts -eq "y") {
    $TxtPath = Read-Host "Enter the path for the host FQDNs text file"
    $HostPassSecure = Read-Host "Enter the ESXi root password for all hosts" -AsSecureString
    $HostPassPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($HostPassSecure))
    $NewHosts = Get-Content $TxtPath | Where-Object { $_.Trim() -ne "" }
    $CurrentSpecs = if ($Payload.sddcSpec.hostSpecs) { $Payload.sddcSpec.hostSpecs } else { $Payload.hostSpecs }
    $TemplateHost = $CurrentSpecs[0] | ConvertTo-Json | ConvertFrom-Json 
    $UpdatedHostList = New-Object System.Collections.Generic.List[PSObject]
    for ($i = 0; $i -lt $NewHosts.Count; $i++) {
        $FQDN = $NewHosts[$i].Trim(); $NewEntry = $TemplateHost | ConvertTo-Json | ConvertFrom-Json 
        $NewEntry.hostname = $FQDN; $NewEntry.credentials.password = $HostPassPlain; $UpdatedHostList.Add($NewEntry)
    }
    if ($Payload.sddcSpec.hostSpecs) { $Payload.sddcSpec.hostSpecs = $UpdatedHostList.ToArray() } else { $Payload.hostSpecs = $UpdatedHostList.ToArray() }
    if ((Read-Host "`nRetrieve SSL thumbprints? (y/n)") -eq "y") {
        foreach ($h in $UpdatedHostList) {
            $Cmd = "echo Q | openssl s_client -connect $($h.hostname):443 2>NUL | openssl x509 -noout -fingerprint -sha256"
            if ((cmd /c $Cmd) -match "Fingerprint=(.+)") { $h.sslThumbprint = $matches[1].Trim(); Write-Host " [+] $($h.hostname) Thumbprint OK" -ForegroundColor Green }
        }
    }
}

if ($Payload.ceipEnabled -ne $null) { $Payload.ceipEnabled = [System.Convert]::ToBoolean($Payload.ceipEnabled) }
$FinalJsonString = $Payload | ConvertTo-Json -Depth 100
$FinalJsonString | Set-Content $OutputJsonPath

# --- [STEP 3: Pre-Validation Check] ---
Write-Host "`nChecking for existing validation tasks..." -ForegroundColor Cyan
try {
    $AllVal = Invoke-RestMethod -Uri "https://${VcfFqdn}/v1/sddcs/validations" -Method Get -Headers $GlobalHeader -SkipCertificateCheck
    if ($AllVal | Where-Object { $_.executionStatus -eq "IN_PROGRESS" }) {
        Write-Host "[HOLD] Another task is running. Please wait and retry later." -ForegroundColor Red; exit
    }
} catch { Write-Warning "Pre-check skipped." }

# --- [STEP 4: Validation Submission] ---
if ((Read-Host "`nSubmit the spec for validation? (y/n)") -eq "y") {
    $VUrl = "https://${VcfFqdn}/v1/sddcs/validations"
    try {
        $Resp = Invoke-RestMethod -Uri $VUrl -Method Post -Headers $GlobalHeader -Body $FinalJsonString -SkipCertificateCheck -ErrorAction Stop
    } catch {
        Write-Host "`n[ERROR] Submission Failed!" -ForegroundColor Red
        if ($_.Exception.Response) {
            $Reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            Write-Host "Server Message: $($Reader.ReadToEnd())" -ForegroundColor Yellow
        } else { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
        exit
    }

    $vId = $Resp.id
    Write-Host "`nValidation Task Started! ID: $vId" -ForegroundColor Green

    # --- [STEP 5: Polling & Reporting] ---
    $CheckUrl = "https://${VcfFqdn}/v1/sddcs/validations/$vId"
    $TerminalStates = @("COMPLETED", "FAILED", "CANCELLED")
    $CurrentExecStatus = "IN_PROGRESS"

    Write-Host "`nMonitoring Validation Checks (Interval: 30s)..." -ForegroundColor Cyan
    Write-Host "Current log file: $LogPath" -ForegroundColor Gray

    while ($TerminalStates -notcontains $CurrentExecStatus) {
        try {
            $ValResp = Invoke-RestMethod -Uri $CheckUrl -Method Get -Headers $GlobalHeader -SkipCertificateCheck
            $CurrentExecStatus = $ValResp.executionStatus
            $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

            Write-Host "`n[$TimeStamp] Overall Execution: $CurrentExecStatus | Result: $($ValResp.resultStatus)" -ForegroundColor White
            Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Gray

            $CurrentPollResults = New-Object System.Collections.Generic.List[PSObject]

            foreach ($check in $ValResp.validationChecks) {
                $cColor = switch ($check.resultStatus) {
                    "SUCCEEDED"   { "Green" }
                    "FAILED"      { "Red" }
                    "IN_PROGRESS" { "Yellow" }
                    Default       { "Gray" }
                }
                
                Write-Host " - $($check.description.PadRight(50)) : " -NoNewline
                Write-Host "$($check.resultStatus)" -ForegroundColor $cColor

                $CurrentPollResults.Add([PSCustomObject]@{
                    Time        = $TimeStamp
                    Description = $check.description
                    Status      = $check.resultStatus
                    Severity    = $check.severity
                })
            }
            # Overwrite the specific CSV for THIS run with the latest snapshot
            $CurrentPollResults | Export-Csv -Path $LogPath -NoTypeInformation -Force

        } catch { Write-Warning "API unavailable, retrying..." }

        if ($TerminalStates -notcontains $CurrentExecStatus) { Start-Sleep -Seconds 30 }
    }

    # Save final JSON response with timestamped name
    $ValResp | ConvertTo-Json -Depth 100 | Set-Content $ResponseJsonPath
    Write-Host "`n[COMPLETED] Full JSON saved to: $ResponseJsonPath" -ForegroundColor Cyan
    Write-Host "[COMPLETED] CSV log saved to: $LogPath" -ForegroundColor Cyan

    # --- [STEP 6: Final Result & Bring-Up] ---
    if ($ValResp.resultStatus -eq "SUCCEEDED" -or $ValResp.resultStatus -eq "WARNING") {
        if ($ValResp.resultStatus -eq "WARNING") {
            Write-Host "`n[WARNING] Succeeded with warnings." -ForegroundColor Yellow
        } else {
            Write-Host "`n[SUCCESS] All checks passed." -ForegroundColor Green
        }

        if ((Read-Host "Start Bring-Up? (yes/no)") -eq "yes") {
            $DeployResp = Invoke-RestMethod -Uri "https://${VcfFqdn}/v1/sddcs" -Method Post -Headers $GlobalHeader -Body $FinalJsonString -SkipCertificateCheck
            Write-Host "`n[SUCCESS] Bring-Up Started! ID: $($DeployResp.id). Login to the Installer UI to monitor the progress." -ForegroundColor Green -BackgroundColor Black
        }
    } else {
        Write-Host "`n[FAILED] Validation result: $($ValResp.resultStatus). Review files above for details." -ForegroundColor Red
    }
}
