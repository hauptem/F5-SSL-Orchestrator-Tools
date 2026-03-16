#===============================================================================
# TLS Recon Tester v1.0 
# Production tool for F5 SSLO validation
#
# Tests TCP connectivity and TLS handshakes against multiple ports.
# Supports IPv4, IPv6, and hostnames with interactive or batch port input.
#
# Requirements: PowerShell 5.1+ or PowerShell Core 7+
# Usage: .\tls-recon-tester-legacy.ps1
#
# Repository: https://github.com/hauptem/F5-SSL-Orchestrator-Tools
#===============================================================================

#Requires -Version 5.1

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------

$Script:DefaultTimeout = 2000  # milliseconds
$Script:Timeout = if ($env:TIMEOUT) { [int]$env:TIMEOUT * 1000 } else { $Script:DefaultTimeout }

# Persistent state for repeat tests
$Script:LastTarget = ""
$Script:LastSNI = ""
$Script:LastPorts = @()

#-------------------------------------------------------------------------------
# Output Helpers
#-------------------------------------------------------------------------------

function Write-Banner {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "         TLS Recon Tester v1.0" -ForegroundColor Cyan
    Write-Host "         F5 SSLO Validation Tool" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Footer {
    Write-Host ""
    Write-Host "TLS Recon is part of the SSLO Tools repository" -ForegroundColor White
    Write-Host "https://github.com/hauptem/F5-SSL-Orchestrator-Tools" -ForegroundColor White
    Write-Host ""
}

function Write-Error-Msg {
    param([string]$Message)
    Write-Host "[ERROR] " -ForegroundColor Red -NoNewline
    Write-Host $Message
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] " -ForegroundColor White -NoNewline
    Write-Host $Message
}

function Write-Warning-Msg {
    param([string]$Message)
    Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-Separator {
    param([string]$Title)
    Write-Host ""
    Write-Host "------------------------------------------" -ForegroundColor Cyan
    Write-Host "              $Title" -ForegroundColor Cyan
    Write-Host "------------------------------------------" -ForegroundColor Cyan
    Write-Host ""
}

#-------------------------------------------------------------------------------
# Input Validation
#-------------------------------------------------------------------------------

function Test-ValidTarget {
    param([string]$Target)
    
    if ([string]::IsNullOrWhiteSpace($Target)) {
        Write-Error-Msg "Target cannot be empty"
        return $false
    }
    
    # IPv4 validation
    if ($Target -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        $octets = $Target -split '\.'
        foreach ($octet in $octets) {
            $val = [int]$octet
            if ($val -lt 0 -or $val -gt 255) {
                Write-Error-Msg "Invalid IPv4 address: octet $octet out of range"
                return $false
            }
        }
        return $true
    }
    
    # IPv6 basic validation
    if ($Target -match '^[0-9a-fA-F:]+$') {
        return $true
    }
    
    # Hostname validation (RFC 1123)
    if ($Target -match '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$') {
        return $true
    }
    
    Write-Error-Msg "Invalid target: must be a valid IP address or hostname"
    return $false
}

function Test-ValidSNI {
    param([string]$SNI)
    
    if ([string]::IsNullOrWhiteSpace($SNI)) {
        Write-Error-Msg "SNI cannot be empty"
        return $false
    }
    
    if ($SNI -match '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$') {
        return $true
    }
    
    Write-Error-Msg "Invalid SNI: must be a valid hostname"
    return $false
}

function Test-ValidPort {
    param([string]$Port)
    
    if ($Port -notmatch '^\d+$') {
        Write-Error-Msg "Invalid port: '$Port' is not a number"
        return $false
    }
    
    $portNum = [int]$Port
    if ($portNum -lt 1 -or $portNum -gt 65535) {
        Write-Error-Msg "Invalid port: $Port is out of range (1-65535)"
        return $false
    }
    
    return $true
}

function Get-ValidatedPortList {
    param([string]$PortsInput)
    
    if ([string]::IsNullOrWhiteSpace($PortsInput)) {
        Write-Error-Msg "Ports cannot be empty"
        return $null
    }
    
    # Normalize: replace commas with spaces, split
    $normalized = $PortsInput -replace ',', ' '
    $ports = $normalized -split '\s+' | Where-Object { $_ -ne '' }
    
    foreach ($port in $ports) {
        if (-not (Test-ValidPort $port)) {
            return $null
        }
    }
    
    # Remove duplicates while preserving order
    $uniquePorts = @()
    foreach ($port in $ports) {
        if ($uniquePorts -notcontains $port) {
            $uniquePorts += $port
        }
    }
    
    return $uniquePorts
}

#-------------------------------------------------------------------------------
# User Prompts
#-------------------------------------------------------------------------------

function Read-Target {
    while ($true) {
        if ($Script:LastTarget) {
            $prompt = "Enter target IP or hostname [$($Script:LastTarget)]: "
        } else {
            $prompt = "Enter target IP or hostname: "
        }
        
        $target = Read-Host -Prompt $prompt.TrimEnd(': ')
        
        if ([string]::IsNullOrWhiteSpace($target) -and $Script:LastTarget) {
            return $Script:LastTarget
        }
        
        if (Test-ValidTarget $target) {
            return $target
        }
    }
}

function Read-SNI {
    while ($true) {
        if ($Script:LastSNI) {
            $prompt = "Enter SNI hostname [$($Script:LastSNI)]: "
        } else {
            $prompt = "Enter SNI hostname: "
        }
        
        $sni = Read-Host -Prompt $prompt.TrimEnd(': ')
        
        if ([string]::IsNullOrWhiteSpace($sni) -and $Script:LastSNI) {
            return $Script:LastSNI
        }
        
        if (Test-ValidSNI $sni) {
            return $sni
        }
    }
}

function Read-TestType {
    Write-Separator "TEST TYPE"
    
    Write-Host "  [1] TCP  - TCP handshake only" -ForegroundColor White
    Write-Host "  [2] TLS  - TLS handshake only" -ForegroundColor White
    Write-Host "  [3] Both - TCP and TLS handshakes" -ForegroundColor White
    Write-Host ""
    
    while ($true) {
        $choice = Read-Host -Prompt "Select test type [1/2/3]"
        
        switch ($choice) {
            "1" { return "tcp" }
            "2" { return "tls" }
            "3" { return "both" }
            default { Write-Error-Msg "Invalid selection. Enter 1, 2, or 3." }
        }
    }
}

function Read-Ports {
    Write-Separator "PORT INPUT METHOD"
    
    Write-Host "  [1] Interactive - enter ports one at a time" -ForegroundColor White
    Write-Host "  [2] Batch       - enter comma or space separated list" -ForegroundColor White
    
    if ($Script:LastPorts.Count -gt 0) {
        Write-Host "  [3] Reuse       - use previous port list ($($Script:LastPorts.Count) ports)" -ForegroundColor White
    }
    
    Write-Host ""
    
    while ($true) {
        if ($Script:LastPorts.Count -gt 0) {
            $choice = Read-Host -Prompt "Select method [1/2/3]"
        } else {
            $choice = Read-Host -Prompt "Select method [1/2]"
        }
        
        switch ($choice) {
            "1" { return Read-PortsInteractive }
            "2" { return Read-PortsBatch }
            "3" {
                if ($Script:LastPorts.Count -gt 0) {
                    Write-Success "Using previous port list: $($Script:LastPorts -join ', ')"
                    return $Script:LastPorts
                }
                Write-Error-Msg "Invalid selection"
            }
            default { Write-Error-Msg "Invalid selection" }
        }
    }
}

function Read-PortsInteractive {
    $ports = @()
    Write-Host ""
    Write-Host "Enter ports one at a time. Type 'done' when finished." -ForegroundColor White
    Write-Host ""
    
    while ($true) {
        $portInput = Read-Host -Prompt "Port (or 'done')"
        
        if ($portInput -match '^done$') {
            if ($ports.Count -eq 0) {
                Write-Error-Msg "At least one port is required"
                continue
            }
            break
        }
        
        if (Test-ValidPort $portInput) {
            if ($ports -notcontains $portInput) {
                $ports += $portInput
                Write-Success "Added port $portInput (total: $($ports.Count))"
            } else {
                Write-Warning-Msg "Port $portInput already in list"
            }
        }
    }
    
    return $ports
}

function Read-PortsBatch {
    Write-Host ""
    
    while ($true) {
        Write-Host "Enter ports (comma or space separated):" -ForegroundColor White
        $portsInput = Read-Host -Prompt ">"
        
        $ports = Get-ValidatedPortList $portsInput
        if ($ports) {
            Write-Success "Validated $($ports.Count) ports"
            return $ports
        }
    }
}

#-------------------------------------------------------------------------------
# Test Functions
#-------------------------------------------------------------------------------

# FIXED: Use runspaces instead of jobs for PS 5.1 compatibility
function Test-TCPPorts {
    param(
        [string]$Target,
        [array]$Ports
    )
    
    Write-Separator "TCP HANDSHAKE TEST"
    
    $runspacePool = [RunspaceFactory]::CreateRunspacePool(1, [Math]::Min($Ports.Count, 10))
    $runspacePool.Open()
    
    $runspaces = @()
    $timeout = $Script:Timeout
    
    $scriptBlock = {
        param($Target, $Port, $Timeout)
        
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $connect = $tcpClient.BeginConnect($Target, [int]$Port, $null, $null)
            $wait = $connect.AsyncWaitHandle.WaitOne($Timeout, $false)
            
            if ($wait) {
                try {
                    $tcpClient.EndConnect($connect)
                    $status = "OPEN"
                } catch {
                    $status = "REFUSED"
                }
            } else {
                $status = "TIMEOUT"
            }
            
            $tcpClient.Close()
            $tcpClient.Dispose()
        } catch {
            $status = "FAILED"
        }
        
        return @{
            Port = $Port
            Status = $status
        }
    }
    
    foreach ($port in $Ports) {
        $powershell = [PowerShell]::Create()
        $powershell.RunspacePool = $runspacePool
        [void]$powershell.AddScript($scriptBlock)
        [void]$powershell.AddArgument($Target)
        [void]$powershell.AddArgument($port)
        [void]$powershell.AddArgument($timeout)
        
        $runspaces += @{
            PowerShell = $powershell
            Handle = $powershell.BeginInvoke()
            Port = $port
        }
    }
    
    # Wait with timeout
    $maxWait = [Math]::Min(30000, ($timeout + 2000))
    $results = @()
    
    foreach ($rs in $runspaces) {
        try {
            if ($rs.Handle.AsyncWaitHandle.WaitOne($maxWait, $false)) {
                $result = $rs.PowerShell.EndInvoke($rs.Handle)
                if ($result) {
                    $results += $result
                } else {
                    $results += @{ Port = $rs.Port; Status = "FAILED" }
                }
            } else {
                $results += @{ Port = $rs.Port; Status = "TIMEOUT" }
            }
        } catch {
            $results += @{ Port = $rs.Port; Status = "FAILED" }
        } finally {
            $rs.PowerShell.Dispose()
        }
    }
    
    $runspacePool.Close()
    $runspacePool.Dispose()
    
    # Sort by port and display
    $results | Sort-Object { [int]$_.Port } | ForEach-Object {
        switch ($_.Status) {
            "OPEN" { 
                Write-Host "[OPEN] " -ForegroundColor Green -NoNewline
                Write-Host "TCP port $($_.Port)"
            }
            "REFUSED" {
                Write-Host "[REFUSED] " -ForegroundColor Red -NoNewline
                Write-Host "TCP port $($_.Port)"
            }
            "TIMEOUT" {
                Write-Host "[TIMEOUT] " -ForegroundColor Yellow -NoNewline
                Write-Host "TCP port $($_.Port)"
            }
            default {
                Write-Host "[FAILED] " -ForegroundColor Red -NoNewline
                Write-Host "TCP port $($_.Port)"
            }
        }
    }
}

# ORIGINAL: Fire-and-forget TLS handshakes (unchanged)
function Test-TLSPorts {
    param(
        [string]$Target,
        [string]$SNI,
        [array]$Ports
    )
    
    Write-Separator "TLS HANDSHAKE TEST"
    
    foreach ($port in $Ports | Sort-Object { [int]$_ }) {
        Write-Host "[INIT] " -ForegroundColor Green -NoNewline
        Write-Host "TLS handshake initiated on port $port"
        
        # Fire and forget TLS connection in background
        Start-Job -ScriptBlock {
            param($Target, $Port, $SNI, $Timeout)
            
            try {
                $tcpClient = New-Object System.Net.Sockets.TcpClient
                $tcpClient.Connect($Target, [int]$Port)
                
                $sslStream = New-Object System.Net.Security.SslStream(
                    $tcpClient.GetStream(),
                    $false,
                    { $true }  # Accept any certificate
                )
                
                $sslStream.AuthenticateAsClient($SNI)
                $sslStream.Close()
                $tcpClient.Close()
            } catch {
                # Silently ignore - we just want to initiate the handshake
            }
        } -ArgumentList $Target, $port, $SNI, $Script:Timeout | Out-Null
    }
    
    # Wait a moment for handshakes to initiate
    Start-Sleep -Milliseconds 500
    
    # Clean up background jobs
    Get-Job | Where-Object { $_.State -eq 'Completed' -or $_.State -eq 'Failed' } | Remove-Job -Force
}

function Write-Summary {
    param(
        [string]$Target,
        [string]$SNI,
        [array]$Ports,
        [string]$TestType
    )
    
    $testLabel = switch ($TestType) {
        "tcp" { "TCP only" }
        "tls" { "TLS only" }
        "both" { "TCP + TLS" }
    }
    
    Write-Separator "SUMMARY"
    
    Write-Host "Target:      " -ForegroundColor White -NoNewline
    Write-Host $Target -ForegroundColor Green
    
    Write-Host "SNI:         " -ForegroundColor White -NoNewline
    Write-Host $SNI -ForegroundColor Green
    
    Write-Host "Ports:       " -ForegroundColor White -NoNewline
    Write-Host "$($Ports.Count)" -ForegroundColor Green -NoNewline
    Write-Host " ports tested"
    
    Write-Host "Test Type:   " -ForegroundColor White -NoNewline
    Write-Host $testLabel -ForegroundColor Green
    
    Write-Host "Timeout:     " -ForegroundColor White -NoNewline
    Write-Host "$($Script:Timeout / 1000)s" -ForegroundColor Green
    
    Write-Host "Timestamp:   " -ForegroundColor White -NoNewline
    Write-Host (Get-Date -Format "yyyy-MM-dd HH:mm:ss K") -ForegroundColor Green
    
    Write-Host ""
    Write-Host "------------------------------------------" -ForegroundColor Cyan
}

function Read-RunAgain {
    Write-Host ""
    $again = Read-Host -Prompt "Run another test? (y/n)"
    return $again -match '^[Yy](es)?$'
}

#-------------------------------------------------------------------------------
# Main Entry Point
#-------------------------------------------------------------------------------

function Main {
    Clear-Host
    Write-Banner
    
    while ($true) {
        # Collect inputs
        $target = Read-Target
        $Script:LastTarget = $target
        
        $sni = Read-SNI
        $Script:LastSNI = $sni
        
        $testType = Read-TestType
        
        $ports = Read-Ports
        $Script:LastPorts = $ports
        
        # Confirm configuration
        Write-Host ""
        Write-Info "Configuration:"
        Write-Host "  Target:    $target" -ForegroundColor White
        Write-Host "  SNI:       $sni" -ForegroundColor White
        Write-Host "  Test Type: $testType" -ForegroundColor White
        Write-Host "  Ports:     $($ports -join ' ')" -ForegroundColor White
        Write-Host ""
        
        $confirm = Read-Host -Prompt "Proceed with tests? (y/n)"
        if ($confirm -notmatch '^[Yy](es)?$') {
            Write-Warning-Msg "Aborted by user"
            continue
        }
        
        # Execute tests
        switch ($testType) {
            "tcp" {
                Test-TCPPorts -Target $target -Ports $ports
            }
            "tls" {
                Test-TLSPorts -Target $target -SNI $sni -Ports $ports
            }
            "both" {
                Test-TCPPorts -Target $target -Ports $ports
                Test-TLSPorts -Target $target -SNI $sni -Ports $ports
            }
        }
        
        Write-Summary -Target $target -SNI $sni -Ports $ports -TestType $testType
        
        if (-not (Read-RunAgain)) {
            Write-Info "Goodbye!"
            Write-Footer
            break
        }
        
        Clear-Host
        Write-Banner
    }
}

# Handle Ctrl+C
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Write-Host ""
    Write-Warning-Msg "Interrupted"
    Write-Footer
}

# Run
try {
    Main
} finally {
    # Cleanup any remaining jobs
    Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
}
