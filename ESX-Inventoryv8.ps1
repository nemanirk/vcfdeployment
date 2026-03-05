# ==========================================
# ESXi Advanced Inventory & DNS Validator
# ==========================================

# --- [1] Configuration & Log Setup ---
$HostListFile = Read-Host "Enter the full path to your ESXi hosts txt file"
if (-not (Test-Path $HostListFile)) { 
    Write-Host "ERROR: File not found at $HostListFile" -ForegroundColor Red; exit 
}

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogPath = Join-Path $PSScriptRoot "ESXi_Full_Validation_$Timestamp.log"

function Write-OutputAll {
    param([string]$Message, [ConsoleColor]$Color = "White", [ConsoleColor]$BG = "Black")
    $Stamp = Get-Date -Format "HH:mm:ss"
    $FormattedMsg = "[$Stamp] $Message"
    Write-Host $FormattedMsg -ForegroundColor $Color -BackgroundColor $BG
    $FormattedMsg | Out-File -FilePath $LogPath -Append
}

# --- [2] Credentials ---
$User = "root"
$Password = Read-Host "Enter ESXi root password" -AsSecureString
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
$PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

$InputHosts = Get-Content $HostListFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

Write-OutputAll "Starting Full ESXi Validation..." -Color Cyan

# --- [3] Process Hosts ---
foreach ($InputName in $InputHosts) {
    Write-OutputAll "`n================ HOST: $InputName ================" -Color White -BG DarkBlue
    
    $ResolvedIP = "N/A"
    try {
        $ResolvedIP = [System.Net.Dns]::GetHostAddresses($InputName).IPAddressToString | Select-Object -First 1
        Write-OutputAll "Forward Lookup: Found IP $ResolvedIP"
        $fPing = Test-Connection -ComputerName $InputName -Count 1 -Quiet
        $iPing = Test-Connection -ComputerName $ResolvedIP -Count 1 -Quiet
        Write-OutputAll "Ping FQDN: $fPing"
        Write-OutputAll "Ping IP:   $iPing"
    } catch { 
        Write-OutputAll "DNS/Ping: FAILED" -Color Red 
    }

    try {
        # B. Connect to Host
        $Conn = Connect-VIServer -Server $InputName -User $User -Password $PlainPassword -ErrorAction Stop
        
        # RETRIEVE HOSTNAME VIA ESXCLI
        $esxcli = Get-EsxCli -VMHost $InputName -V2
        $hostnameInfo = $esxcli.system.hostname.get.Invoke()
        $ActualName = $hostnameInfo.FullyQualifiedDomainName
        
        $vmhost = Get-VMHost -Name $InputName
        Write-OutputAll "ESX Hostname (ESXCLI FQDN): $ActualName" -Color Cyan
        Write-OutputAll "ESX Version: $($vmhost.Version) (Build: $($vmhost.Build))"

        # C. DNS PTR MATCH (REVISED FOR CASE PRESERVATION)
        $PtrFqdn = "PTR_NOT_FOUND"
        try {
            # Resolve-DnsName is more likely to return the raw string from the DNS record
            $DnsResult = Resolve-DnsName -Name $ResolvedIP -Type PTR -ErrorAction Stop
            # We select the NameHost property which contains the target FQDN
            $PtrFqdn = $DnsResult.NameHost.TrimEnd('.') 
            
            Write-OutputAll "Reverse Lookup (PTR): $PtrFqdn"
            
            if ($ActualName -ceq $PtrFqdn) {
                Write-OutputAll "DNS Match Result: MATCH (Exact Case)" -Color Green
            }
            elseif ($ActualName -ieq $PtrFqdn) {
                Write-OutputAll "DNS Match Result: MISMATCH (Case Differs: $ActualName vs $PtrFqdn)" -Color Yellow
            }
            else {
                Write-OutputAll "DNS Match Result: MISMATCH (Full Name Mismatch)" -Color Red
            }
        } catch { 
            Write-OutputAll "DNS Match Result: FAILED (No PTR record found via Resolve-DnsName)" -Color Red 
        }

        # D. Certificate Check (Case-Sensitive)
        try {
            $TcpClient = New-Object System.Net.Sockets.TcpClient($InputName, 443)
            $SslStream = New-Object System.Net.Security.SslStream($TcpClient.GetStream(), $false, { $true })
            $SslStream.AuthenticateAsClient($InputName)
            $CertObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($SslStream.RemoteCertificate)
            
            $CertCN = (($CertObj.Subject -split "CN=")[1] -split ",")[0]
            $CertSANList = @()
            $Ext = $CertObj.Extensions | Where-Object { $_.Oid.FriendlyName -eq "Subject Alternative Name" }
            if ($null -ne $Ext) { 
                $CertSANList = $Ext.Format($false) -split ", " | ForEach-Object { $_ -replace "DNS Name=", "" }
            }

            Write-OutputAll "Certificate CN:  $CertCN"
            Write-OutputAll "Certificate SAN: $($CertSANList -join ', ')"
            
            $CertStatus = "MISMATCH"
            $CertColor = "Red"
            $MatchedSAN = $false
            foreach ($san in $CertSANList) {
                if ($san -ceq $ActualName) { $MatchedSAN = $true }
            }

            if ($CertCN -ceq $ActualName -or $MatchedSAN -eq $true) {
                $CertStatus = "MATCH (Exact Case)"
                $CertColor = "Green"
            }
            elseif ($CertCN -ieq $ActualName -or ($CertSANList -contains $ActualName)) {
                $CertStatus = "MISMATCH (Case Differs: $ActualName vs Cert)"
                $CertColor = "Yellow"
            }

            Write-OutputAll "Certificate Result: $CertStatus" -Color $CertColor
            $TcpClient.Close()
        } catch { Write-OutputAll "Certificate Check: FAILED" -Color Red }

        # E. SSH Service Check
        $sshSvc = Get-VMHostService -VMHost $vmhost | Where-Object {$_.Key -eq "TSM-SSH"}
        $sshRun = "Stopped"; $sshColor = "Yellow"
        if ($sshSvc.Running) { $sshRun = "Running"; $sshColor = "Green" }
        Write-OutputAll "SSH Service: $sshRun" -Color $sshColor
        Write-OutputAll "SSH Policy: $($sshSvc.Policy)"

        # F. NTP Configuration
        $ntpSrv = Get-VMHostNtpServer -VMHost $vmhost
        $ntpSvc = Get-VMHostService -VMHost $vmhost | Where-Object {$_.Key -eq "ntpd"}
        $ntpRun = "Stopped"
        if ($ntpSvc.Running) { $ntpRun = "Running" }
        Write-OutputAll "NTP Servers: $($ntpSrv -join ', ')"
        Write-OutputAll "NTP Service: $ntpRun (Policy: $($ntpSvc.Policy))"

        # G. Virtual Networking
        Write-OutputAll "VIRTUAL NETWORKING:" -Color Yellow
        $vSwitches = Get-VirtualSwitch -VMHost $vmhost
        foreach ($vs in $vSwitches) {
            Write-OutputAll "  - Switch: $($vs.Name)"
            $pgs = Get-VirtualPortGroup -VirtualSwitch $vs
            foreach ($pg in $pgs) {
                Write-OutputAll "    * PortGroup: $($pg.Name) | VLAN: $($pg.VLanId)"
            }
        }

        # H. Physical NICs
        Write-OutputAll "PHYSICAL NICS:" -Color Yellow
        $pnics = Get-VMHostNetworkAdapter -VMHost $vmhost -Physical
        foreach ($p in $pnics) {
            $pName = $p.Name
            $pLink = "Down"
            if ($null -ne $p.ExtensionData.LinkSpeed) { $pLink = "Up" }
            $pSpeed = "0"
            if ($null -ne $p.ExtensionData.LinkSpeed) { $pSpeed = [string]$p.ExtensionData.LinkSpeed.SpeedMb }
            
            $pUsage = "Unused"
            foreach ($vsCheck in $vSwitches) {
                if ($vsCheck.Nic -contains $pName) { $pUsage = "Active/Standby" }
            }
            Write-OutputAll "  - $pName | Status: $pUsage | Link: $pLink | Speed: $pSpeed Mbps"
        }

        # I. Datastores
        $dsList = Get-Datastore -VMHost $vmhost | Select-Object -ExpandProperty Name
        Write-OutputAll "DATASTORES: $($dsList -join ', ')"

        Disconnect-VIServer -Server $Conn -Confirm:$false
    } catch {
        Write-OutputAll "CRITICAL ERROR: $($_.Exception.Message)" -Color Red
    }
}

# --- Cleanup ---
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
Write-OutputAll "`nValidation Finished. Log: $LogPath" -Color Cyan
