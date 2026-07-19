Function Get-ApplianceSha256Thumbprint {
    param(
        [string]$HostName, 
        [int]$Port = 443, 
        [int]$TimeoutMs = 10000
    )

    $tcpClient = $null
    $sslStream = $null

    try {
        $tcpClient = [System.Net.Sockets.TcpClient]::new()
        $connectTask = $tcpClient.ConnectAsync($HostName, $Port)
        
        if (-not $connectTask.Wait($TimeoutMs)) { throw "Timed out connecting to ${HostName}:${Port}" }

        $sslStream = [System.Net.Security.SslStream]::new(
            $tcpClient.GetStream(), 
            $false, 
            { param($sender, $certificate, $chain, $sslPolicyErrors) return $true }
        )
        $sslStream.AuthenticateAsClient($HostName)

        if (-not $sslStream.RemoteCertificate) { throw "No remote certificate presented." }

        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($sslStream.RemoteCertificate)
        $hashHex = $cert.GetCertHashString("SHA256")
        
        # Format the hex string with colons
        return ($hashHex -split '(..)' | Where-Object { $_ }) -join ':'
    } catch {
        Write-Host "`n[ERROR] Failed to retrieve thumbprint: $_" -ForegroundColor Red
    } finally {
        if ($sslStream) { $sslStream.Dispose() }
        if ($tcpClient) { $tcpClient.Dispose() }
    }
}

# 1. Prompt for the endpoint
$applianceFqdn = Read-Host "Enter the Appliance FQDN or IP (e.g., sddc-manager.local)"

# 2. Retrieve and display the SHA-256 Thumbprint
Write-Host "`nRetrieving TLS Certificate Thumbprint for $applianceFqdn..." -ForegroundColor Cyan

$thumbprint = Get-ApplianceSha256Thumbprint -HostName $applianceFqdn

if ($thumbprint) {
    Write-Host "SHA256 Fingerprint: $thumbprint" -ForegroundColor Green
} else {
    Write-Host "Could not retrieve the thumbprint. Please verify the endpoint is online and reachable on port 443." -ForegroundColor Yellow
}
