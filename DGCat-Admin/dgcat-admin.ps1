# =============================================================================
# DGCat-Admin - F5 BIG-IP Datagroup and URL Category Administration Tool
# =============================================================================
# Version: 5.1
# Author: Eric Haupt
# Released under the MIT License. See LICENSE file for details.
# https://github.com/hauptem/F5-SSL-Orchestrator-Tools
#
# Requirements: PowerShell 5.1+, BIG-IP TMOS 17.x or higher
#
# PURPOSE:
#   Menu-driven tool for managing LTM datagroups and URL categories used in
#   SSL Orchestrator policies. Supports bulk import/export via CSV files,
#   backup before modifications, type validation, and bidirectional conversion
#   between datagroups and URL categories.
#
# USAGE:
#   .\dgcat-admin.ps1
#
# =============================================================================

#Requires -Version 5.1

# =============================================================================
# CONFIGURATION
# =============================================================================

# Backup settings
$script:BACKUP_DIR = Join-Path $PSScriptRoot "dgcat-admin-backups"
$script:MAX_BACKUPS = 10
$script:BACKUPS_ENABLED = 0

# Session logging (set to 1 to enable log file creation)
$script:LOGGING_ENABLED = 0

# API timeout (seconds)
# Max time for any single API request including connection
$script:API_TIMEOUT = 60

# Partitions to manage (array)
# Add additional partitions as needed
# WARNING: Only include partitions you intend to manage with this tool
$script:PARTITIONS = @("Common")

# Protected system datagroups - DO NOT MODIFY
$script:PROTECTED_DATAGROUPS = @("private_net", "images", "aol", "sys_APM_MS_Office_OFBA_DG")

# CSV preview lines
$script:PREVIEW_LINES = 5

# Editor page size
$script:EDIT_PAGE_SIZE = 20

# =============================================================================
# CONNECTION SETTINGS
# =============================================================================

# Connection settings
$script:RemoteHost = ""
$script:RemoteUser = ""
$script:RemotePass = ""
$script:RemoteHostname = ""
$script:AuthHeader = ""

# =============================================================================
# FLEET CONFIGURATION
# =============================================================================

$script:FLEET_CONFIG_FILE = ""
$script:FleetSites = @()
$script:FleetHosts = @()
$script:FleetUniqueSites = @()

# =============================================================================
# SESSION CACHE
# =============================================================================

$script:PartitionCache = @{}
$script:UrlCategoryDbCached = ""

# =============================================================================
# SESSION VARIABLES
# =============================================================================

$script:Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:LogFile = ""

# =============================================================================
# SSL CERTIFICATE BYPASS (required for self-signed BIG-IP management certs)
# =============================================================================

function Initialize-SslBypass {
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

function Write-Log {
    param([string]$Message)
    Write-Host $Message
    if ($script:LogFile -and (Test-Path (Split-Path $script:LogFile -Parent) -ErrorAction SilentlyContinue)) {
        $Message | Out-File -FilePath $script:LogFile -Append -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

function Write-LogSection {
    param([string]$Title)
    Write-Log ""
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "    $Title" -ForegroundColor White
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
}

function Write-LogInfo {
    param([string]$Message)
    Write-Host "  [INFO]  " -NoNewline -ForegroundColor White
    Write-Host "$Message" -ForegroundColor White
    if ($script:LogFile) { "  [INFO]  $Message" | Out-File -FilePath $script:LogFile -Append -Encoding UTF8 -ErrorAction SilentlyContinue }
}

function Write-LogOk {
    param([string]$Message)
    Write-Host "  [ OK ]" -NoNewline -ForegroundColor Green
    Write-Host "  $Message" -ForegroundColor White
    if ($script:LogFile) { "  [ OK ]  $Message" | Out-File -FilePath $script:LogFile -Append -Encoding UTF8 -ErrorAction SilentlyContinue }
}

function Write-LogWarn {
    param([string]$Message)
    Write-Host "  [WARN]" -NoNewline -ForegroundColor Yellow
    Write-Host "  $Message" -ForegroundColor White
    if ($script:LogFile) { "  [WARN]  $Message" | Out-File -FilePath $script:LogFile -Append -Encoding UTF8 -ErrorAction SilentlyContinue }
}

function Write-LogError {
    param([string]$Message)
    Write-Host "  [FAIL]" -NoNewline -ForegroundColor Red
    Write-Host "  $Message" -ForegroundColor White
    if ($script:LogFile) { "  [FAIL]  $Message" | Out-File -FilePath $script:LogFile -Append -Encoding UTF8 -ErrorAction SilentlyContinue }
}

function Write-LogStep {
    param([string]$Message)
    Write-Host "  [....]  $Message" -ForegroundColor White
    if ($script:LogFile) { "  [....]  $Message" | Out-File -FilePath $script:LogFile -Append -Encoding UTF8 -ErrorAction SilentlyContinue }
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

function Press-EnterToContinue {
    Write-Host ""
    Read-Host "  Press Enter to continue"
}

function Test-IntegerFormat {
    param([string]$Entry)
    return $Entry -match '^-?[0-9]+$'
}

function Test-AddressFormat {
    param([string]$Entry)
    if ($Entry -match '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$') { return $true }
    if ($Entry -match '^[0-9a-fA-F:]+(/[0-9]{1,3})?$' -and $Entry.Contains(':')) { return $true }
    return $false
}

function Test-CidrAlignment {
    param([string[]]$Keys)
    
    $errors = @()
    
    foreach ($entry in $Keys) {
        if ($entry -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$') { continue }
        
        $a = [int]$Matches[1]; $b = [int]$Matches[2]; $c = [int]$Matches[3]; $d = [int]$Matches[4]
        $prefix = [int]$Matches[5]
        
        if ($prefix -lt 1 -or $prefix -gt 32) { continue }
        
        $ipInt = ($a -shl 24) + ($b -shl 16) + ($c -shl 8) + $d
        $mask = ([uint32]::MaxValue -shl (32 - $prefix)) -band [uint32]::MaxValue
        $netInt = $ipInt -band $mask
        
        $netA = ($netInt -shr 24) -band 0xFF
        $netB = ($netInt -shr 16) -band 0xFF
        $netC = ($netInt -shr 8) -band 0xFF
        $netD = $netInt -band 0xFF
        
        $correct = "${netA}.${netB}.${netC}.${netD}/${prefix}"
        
        if ($entry -ne $correct) {
            $errors += @{ Original = $entry; Correct = $correct }
        }
    }
    
    return $errors
}

function Test-ProtectedDatagroup {
    param([string]$Name)
    return $script:PROTECTED_DATAGROUPS -contains $Name
}

function Remove-PartitionPrefix {
    param([string]$Name)
    return $Name -replace '^/[^/]*/', ''
}

function ConvertTo-UnixLineEndings {
    param([string]$FilePath)
    $FilePath = (Resolve-Path $FilePath).Path
    $content = [System.IO.File]::ReadAllText($FilePath)
    if ($content.Contains("`r`n")) {
        Write-LogInfo "Converting Windows line endings (CRLF) to Unix (LF)..."
        $content = $content.Replace("`r`n", "`n")
        [System.IO.File]::WriteAllText($FilePath, $content)
    }
}

function Test-WindowsLineEndings {
    param([string]$FilePath)
    $FilePath = (Resolve-Path $FilePath).Path
    $content = [System.IO.File]::ReadAllText($FilePath)
    return $content.Contains("`r`n")
}

function Confirm-BackupDir {
    if (-not (Test-Path $script:BACKUP_DIR)) {
        try {
            New-Item -Path $script:BACKUP_DIR -ItemType Directory -Force | Out-Null
        } catch {
            return $false
        }
    }
    try {
        $testFile = Join-Path $script:BACKUP_DIR ".write_test"
        [System.IO.File]::WriteAllText($testFile, "test")
        Remove-Item $testFile -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Remove-OldBackups {
    param([string]$Pattern)
    $files = @(Get-ChildItem -Path $script:BACKUP_DIR -Filter "${Pattern}_*.csv" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($files -and $files.Count -gt $script:MAX_BACKUPS) {
        $files | Select-Object -Skip $script:MAX_BACKUPS | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Format-DomainForUrlCategory {
    param([string]$Domain)
    $Domain = $Domain -replace '^https?://', ''
    $Domain = $Domain -replace '/.*$', ''
    if ($Domain.StartsWith('.')) {
        $Domain = "*$Domain"
    }
    return "https://$Domain/"
}


# =============================================================================
# API FUNCTIONS
# =============================================================================

# -----------------------------------------------------------------------------
# API Helper Functions
# -----------------------------------------------------------------------------

function Invoke-F5Api {
    param(
        [string]$Method,
        [string]$Endpoint,
        [object]$Body = $null
    )
    
    $uri = "https://$($script:RemoteHost)$Endpoint"
    $headers = @{
        "Authorization" = "Basic $($script:AuthHeader)"
        "Content-Type" = "application/json"
    }
    
    $params = @{
        Uri = $uri
        Headers = $headers
        Method = $Method
        TimeoutSec = $script:API_TIMEOUT
        ErrorAction = "Stop"
    }
    
    if ($Body) {
        if ($Body -is [string]) {
            $params.Body = $Body
        } else {
            $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
        }
    }
    
    try {
        $response = Invoke-RestMethod @params
        return @{ Success = $true; Response = $response; StatusCode = 200 }
    } catch {
        $statusCode = 0
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        return @{ Success = $false; Response = $null; StatusCode = $statusCode; Error = $_.Exception.Message }
    }
}

function Invoke-F5Get {
    param([string]$Endpoint)
    return Invoke-F5Api -Method "GET" -Endpoint $Endpoint
}

function Invoke-F5Post {
    param([string]$Endpoint, [object]$Body)
    return Invoke-F5Api -Method "POST" -Endpoint $Endpoint -Body $Body
}

function Invoke-F5Patch {
    param([string]$Endpoint, [object]$Body)
    return Invoke-F5Api -Method "PATCH" -Endpoint $Endpoint -Body $Body
}

function Invoke-F5Delete {
    param([string]$Endpoint)
    return Invoke-F5Api -Method "DELETE" -Endpoint $Endpoint
}

# -----------------------------------------------------------------------------
# Connection Functions
# -----------------------------------------------------------------------------

function Initialize-RemoteConnection {
    Write-LogSection "DGCat Connection Setup"
    
    # Show fleet hosts for quick selection if fleet is loaded
    if ($script:FleetHosts.Count -gt 0) {
        Write-Host ""
        Write-Host "  Fleet hosts:" -ForegroundColor White
        Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
        for ($i = 0; $i -lt $script:FleetHosts.Count; $i++) {
            $num = $i + 1
            Write-Host "    " -NoNewline; Write-Host $num.ToString().PadLeft(2) -NoNewline -ForegroundColor Yellow; Write-Host ") " -NoNewline -ForegroundColor White
            Write-Host "$($script:FleetHosts[$i]) ($($script:FleetSites[$i]))" -ForegroundColor White
        }
        Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
        Write-Host '     ' -NoNewline; Write-Host '0' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
        Write-Host "Exit" -ForegroundColor White
    }
    
    Write-Host ""
    if ($script:FleetHosts.Count -gt 0) {
        $hostInput = Read-Host "  Select [0-$($script:FleetHosts.Count)] or enter hostname/IP"
    } else {
        $hostInput = Read-Host "  BIG-IP hostname or IP (0 to exit)"
    }
    
    if ($hostInput -eq "0") {
        Write-Host ""
        Write-Host "  Exiting." -ForegroundColor White
        Write-Host "  Latest version: https://github.com/hauptem/F5-SSL-Orchestrator-Tools" -ForegroundColor Cyan
        Write-Host ""
        exit 0
    }
    
    # Check if numeric and within fleet range
    $num = 0
    if ([int]::TryParse($hostInput, [ref]$num) -and $num -ge 1 -and $num -le $script:FleetHosts.Count) {
        $script:RemoteHost = $script:FleetHosts[$num - 1]
    } else {
        $script:RemoteHost = $hostInput
    }
    
    if ([string]::IsNullOrWhiteSpace($script:RemoteHost)) {
        Write-LogError "No hostname provided."
        return $false
    }
    
    $script:RemoteUser = Read-Host "  Username"
    if ([string]::IsNullOrWhiteSpace($script:RemoteUser)) {
        Write-LogError "No username provided."
        return $false
    }
    
    $securePass = Read-Host "  Password" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
    $script:RemotePass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    
    if ([string]::IsNullOrWhiteSpace($script:RemotePass)) {
        Write-LogError "No password provided."
        return $false
    }
    
    # Build auth header
    $pair = "$($script:RemoteUser):$($script:RemotePass)"
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
    $script:AuthHeader = [System.Convert]::ToBase64String($bytes)
    
    # Test connection
    Write-LogStep "Connecting to $($script:RemoteHost)..."
    $result = Invoke-F5Get -Endpoint "/mgmt/tm/sys/version"
    
    if ($result.Success) {
        $version = ""
        try {
            $entries = $result.Response.entries.PSObject.Properties
            foreach ($entry in $entries) {
                $version = $entry.Value.nestedStats.entries.Version.description
                break
            }
        } catch {}
        
        # Retrieve system hostname for operator validation
        $hostnameResult = Invoke-F5Get -Endpoint "/mgmt/tm/sys/global-settings"
        if ($hostnameResult.Success) {
            try { $script:RemoteHostname = $hostnameResult.Response.hostname } catch {}
        }
        if ([string]::IsNullOrWhiteSpace($script:RemoteHostname)) {
            $script:RemoteHostname = $script:RemoteHost
        }
        
        Write-LogOk "Connected to BIG-IP: $($script:RemoteHostname)"
        if ($version) {
            Write-LogOk "TMOS version $version"
        }
        return $true
    } else {
        if ($result.StatusCode -eq 401) {
            Write-LogError "Authentication failed. Check username/password."
        } elseif ($result.StatusCode -eq 0) {
            Write-LogError "Connection failed. Check hostname and network connectivity."
        } else {
            Write-LogError "Connection failed. HTTP $($result.StatusCode)"
        }
        return $false
    }
}

# -----------------------------------------------------------------------------
# System Functions
# -----------------------------------------------------------------------------

function Save-F5Config {
    $result = Invoke-F5Post -Endpoint "/mgmt/tm/sys/config" -Body @{ command = "save" }
    if ($result.Success) { return $true }
    # BIG-IP closes TCP after a successful save config POST.
    # Invoke-RestMethod treats this as a failure even though the save completed.
    if ($result.Error -match "underlying connection was closed") { return $true }
    return $false
}

function Test-PartitionRemote {
    param([string]$Partition)
    $result = Invoke-F5Get -Endpoint "/mgmt/tm/auth/partition/$Partition"
    return $result.Success
}

# -----------------------------------------------------------------------------
# Datagroup Functions
# -----------------------------------------------------------------------------

function Get-DatagroupListRemote {
    param([string]$Partition)
    
    $result = Invoke-F5Get -Endpoint "/mgmt/tm/ltm/data-group/internal?`$filter=partition%20eq%20$Partition"
    if (-not $result.Success) { return @() }
    
    $items = @()
    if ($result.Response.items) {
        foreach ($item in $result.Response.items) {
            if ($item.partition -eq $Partition -and $item.fullPath -notmatch '\.app/') {
                $items += @{ Partition = $Partition; Name = $item.name; Class = "internal" }
            }
        }
    }
    return $items
}

function Test-DatagroupExistsRemote {
    param([string]$Partition, [string]$Name)
    $result = Invoke-F5Get -Endpoint "/mgmt/tm/ltm/data-group/internal/~${Partition}~${Name}"
    return $result.Success
}

function Get-DatagroupTypeRemote {
    param([string]$Partition, [string]$Name)
    $result = Invoke-F5Get -Endpoint "/mgmt/tm/ltm/data-group/internal/~${Partition}~${Name}"
    if ($result.Success) { return $result.Response.type }
    return ""
}

function Get-DatagroupRecordsRemote {
    param([string]$Partition, [string]$Name)
    $result = Invoke-F5Get -Endpoint "/mgmt/tm/ltm/data-group/internal/~${Partition}~${Name}"
    if (-not $result.Success) { return @() }
    
    $records = @()
    if ($result.Response.records) {
        foreach ($rec in $result.Response.records) {
            $records += @{ Key = $rec.name; Value = $(if ($rec.data) { $rec.data } else { "" }) }
        }
    }
    return $records
}

function New-DatagroupRemote {
    param([string]$Partition, [string]$Name, [string]$Type)
    $body = @{ name = $Name; partition = $Partition; type = $Type }
    $result = Invoke-F5Post -Endpoint "/mgmt/tm/ltm/data-group/internal" -Body $body
    return $result.Success
}

function Set-DatagroupRecordsRemote {
    param([string]$Partition, [string]$Name, [array]$Records)
    $body = @{ records = $Records }
    $result = Invoke-F5Patch -Endpoint "/mgmt/tm/ltm/data-group/internal/~${Partition}~${Name}" -Body $body
    return $result
}

function Remove-DatagroupRemote {
    param([string]$Partition, [string]$Name)
    $result = Invoke-F5Delete -Endpoint "/mgmt/tm/ltm/data-group/internal/~${Partition}~${Name}"
    return $result.Success
}

function ConvertTo-RecordsJson {
    param([array]$Keys, [array]$Values)
    $records = @()
    for ($i = 0; $i -lt $Keys.Count; $i++) {
        if ($Values[$i]) {
            $records += @{ name = $Keys[$i]; data = $Values[$i] }
        } else {
            $records += @{ name = $Keys[$i] }
        }
    }
    return $records
}

# Build tmsh-style record string for incremental add
# Returns: "key1 { data value1 } key2"
function ConvertTo-TmshRecordsAdd {
    param([array]$Keys, [array]$Values)
    $result = ""
    for ($i = 0; $i -lt $Keys.Count; $i++) {
        if ([string]::IsNullOrWhiteSpace($Keys[$i])) { continue }
        if ($Values[$i]) {
            $result += " $($Keys[$i]) { data $($Values[$i]) }"
        } else {
            $result += " $($Keys[$i])"
        }
    }
    return $result
}

# Build tmsh-style key string for incremental delete
# Returns: "key1 key2 key3"
function ConvertTo-TmshRecordsDelete {
    param([string[]]$Keys)
    $result = ""
    foreach ($key in $Keys) {
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $result += " $key"
    }
    return $result
}

# Add records to datagroup incrementally using ?options=records add
function Add-DatagroupRecordsIncremental {
    param([string]$Partition, [string]$Name, [string]$TmshRecords)
    
    $options = [System.Uri]::EscapeDataString("records add {$TmshRecords }")
    $body = @{ name = $Name; partition = $Partition }
    
    $result = Invoke-F5Patch -Endpoint "/mgmt/tm/ltm/data-group/internal/~${Partition}~${Name}?options=$options" -Body $body
    return $result.Success
}

# Delete records from datagroup incrementally using ?options=records delete
function Remove-DatagroupRecordsIncremental {
    param([string]$Partition, [string]$Name, [string]$TmshKeys)
    
    $options = [System.Uri]::EscapeDataString("records delete {$TmshKeys }")
    $body = @{ name = $Name; partition = $Partition }
    
    $result = Invoke-F5Patch -Endpoint "/mgmt/tm/ltm/data-group/internal/~${Partition}~${Name}?options=$options" -Body $body
    return $result.Success
}

# -----------------------------------------------------------------------------
# URL Category Functions
# -----------------------------------------------------------------------------

function Test-UrlCategoryExistsRemote {
    param([string]$Name)
    $result = Invoke-F5Get -Endpoint "/mgmt/tm/sys/url-db/url-category/~Common~$Name"
    return $result.Success
}

function Get-UrlCategoryListRemote {
    $result = Invoke-F5Get -Endpoint "/mgmt/tm/sys/url-db/url-category"
    if (-not $result.Success) { return @() }
    $names = @()
    if ($result.Response.items) {
        foreach ($item in $result.Response.items) { $names += $item.name }
    }
    return @($names | Sort-Object)
}

function Get-UrlCategoryEntriesRemote {
    param([string]$Name)
    $result = Invoke-F5Get -Endpoint "/mgmt/tm/sys/url-db/url-category/~Common~$Name"
    if (-not $result.Success) { return @() }
    $urls = @()
    if ($result.Response.urls) {
        foreach ($url in $result.Response.urls) { $urls += $url.name }
    }
    return $urls
}

function Get-UrlCategoryCountRemote {
    param([string]$Name)
    $result = Invoke-F5Get -Endpoint "/mgmt/tm/sys/url-db/url-category/~Common~$Name"
    if (-not $result.Success) { return 0 }
    if ($result.Response.urls) { return $result.Response.urls.Count }
    return 0
}

function New-UrlCategoryRemote {
    param([string]$Name, [string]$DefaultAction, [array]$Urls)
    $body = @{ name = $Name; displayName = $Name; defaultAction = $DefaultAction; urls = $Urls }
    $result = Invoke-F5Post -Endpoint "/mgmt/tm/sys/url-db/url-category" -Body $body
    return $result.Success
}

function Add-UrlCategoryEntriesRemote {
    param([string]$Name, [array]$NewUrls)
    
    $result = Invoke-F5Get -Endpoint "/mgmt/tm/sys/url-db/url-category/~Common~$Name"
    if (-not $result.Success) { return $false }
    
    $existing = @()
    if ($result.Response.urls) { $existing = @($result.Response.urls) }
    
    # Merge and deduplicate by name
    $merged = @{}
    foreach ($url in $existing) { $merged[$url.name] = $url }
    foreach ($url in $NewUrls) { $merged[$url.name] = $url }
    
    $body = @{ urls = @($merged.Values) }
    $patchResult = Invoke-F5Patch -Endpoint "/mgmt/tm/sys/url-db/url-category/~Common~$Name" -Body $body
    return $patchResult.Success
}

function Remove-UrlCategoryEntriesRemote {
    param([string]$Name, [string[]]$UrlsToDelete)
    
    $result = Invoke-F5Get -Endpoint "/mgmt/tm/sys/url-db/url-category/~Common~$Name"
    if (-not $result.Success) { return $false }
    
    $existing = @()
    if ($result.Response.urls) { $existing = @($result.Response.urls) }
    
    $remaining = @($existing | Where-Object { $UrlsToDelete -notcontains $_.name })
    
    $body = @{ urls = @($remaining) }
    $patchResult = Invoke-F5Patch -Endpoint "/mgmt/tm/sys/url-db/url-category/~Common~$Name" -Body $body
    return $patchResult.Success
}

function Set-UrlCategoryEntriesRemote {
    param([string]$Name, [array]$Urls)
    $body = @{ urls = $Urls }
    $result = Invoke-F5Patch -Endpoint "/mgmt/tm/sys/url-db/url-category/~Common~$Name" -Body $body
    return $result.Success
}

function Remove-UrlCategoryRemote {
    param([string]$Name)
    $result = Invoke-F5Delete -Endpoint "/mgmt/tm/sys/url-db/url-category/~Common~$Name"
    return $result.Success
}

function ConvertTo-UrlObjects {
    param([string[]]$Urls)
    $objects = @()
    foreach ($url in $Urls) {
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        $type = $(if ($url.Contains('*')) { "glob-match" } else { "exact-match" })
        $objects += @{ name = $url; type = $type }
    }
    return $objects
}


# =============================================================================
# PARTITION FUNCTIONS
# =============================================================================

function Test-PartitionExists {
    param([string]$Partition)
    
    # Check cache first
    if ($script:PartitionCache.ContainsKey($Partition)) {
        return $script:PartitionCache[$Partition] -eq "valid"
    }
    
    $exists = Test-PartitionRemote -Partition $Partition
    $script:PartitionCache[$Partition] = $(if ($exists) { "valid" } else { "invalid" })
    return $exists
}

function Test-UrlCategoryDbAvailable {
    if ($script:UrlCategoryDbCached -eq "yes") { return $true }
    if ($script:UrlCategoryDbCached -eq "no") { return $false }
    
    $result = Invoke-F5Get -Endpoint "/mgmt/tm/sys/url-db/url-category"
    if ($result.Success) {
        $script:UrlCategoryDbCached = "yes"
        return $true
    }
    $script:UrlCategoryDbCached = "no"
    return $false
}

function Select-Partition {
    param([string]$Prompt = "Select partition")
    
    if ($script:PARTITIONS.Count -eq 1) {
        return $script:PARTITIONS[0]
    }
    
    Write-Host ""
    Write-Host "  ${Prompt}:" -ForegroundColor White
    for ($i = 0; $i -lt $script:PARTITIONS.Count; $i++) {
        $num = $i + 1
        Write-Host "    " -NoNewline; Write-Host "$num" -NoNewline -ForegroundColor Yellow; Write-Host ") " -NoNewline -ForegroundColor White
        Write-Host $script:PARTITIONS[$i] -ForegroundColor White
    }
    Write-Host '    ' -NoNewline; Write-Host '0' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Cancel" -ForegroundColor White
    Write-Host ""
    
    $choice = Read-Host "  Select [0-$($script:PARTITIONS.Count)]"
    
    if ($choice -eq "0" -or [string]::IsNullOrWhiteSpace($choice)) { return "" }
    
    $num = 0
    if ([int]::TryParse($choice, [ref]$num) -and $num -ge 1 -and $num -le $script:PARTITIONS.Count) {
        return $script:PARTITIONS[$num - 1]
    }
    return ""
}

function Get-AllDatagroupList {
    $all = @()
    foreach ($partition in $script:PARTITIONS) {
        if (Test-PartitionExists -Partition $partition) {
            $all += Get-DatagroupListRemote -Partition $partition
        }
    }
    return @($all | Sort-Object { $_.Partition }, { $_.Name })
}

function Select-Datagroup {
    param([string]$Partition, [string]$Prompt = "Enter datagroup name", [string]$Mode = "existing")
    # Modes: existing (must exist), any (accept new or existing), new (must not exist)
    
    # Pull datagroup list
    Write-Host "  [....] Retrieving datagroups..." -ForegroundColor White
    $datagroups = @(Get-AllDatagroupList | Where-Object { $_.Partition -eq $Partition })
    
    if ($datagroups.Count -eq 0 -and $Mode -eq "existing") {
        Write-LogInfo "No datagroups found in partition '$Partition'."
        return $null
    }
    
    # Filter out system datagroups
    $filteredDatagroups = @($datagroups | Where-Object { -not (Test-ProtectedDatagroup -Name $_.Name) })
    
    if ($filteredDatagroups.Count -eq 0 -and $Mode -eq "existing") {
        Write-LogInfo "No datagroups found in partition '$Partition'."
        return $null
    }
    
    # Display list
    if ($filteredDatagroups.Count -gt 0) {
        Write-Host ""
        Write-LogInfo "Available datagroups in partition '$Partition':"
        Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
        
        for ($i = 0; $i -lt $filteredDatagroups.Count; $i++) {
            $dg = $filteredDatagroups[$i]
            $line = "{0,-35} ({1})" -f $dg.Name, $dg.Class
            if ($Mode -eq "new") {
                Write-Host "    $line" -ForegroundColor White
            } else {
                Write-Host -NoNewline "    "; Write-Host -NoNewline ($i + 1).ToString().PadLeft(3) -ForegroundColor Yellow; Write-Host -NoNewline ") " -ForegroundColor White
                Write-Host $line -ForegroundColor White
            }
        }
        
        Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
    }
    
    while ($true) {
        Write-Host ""
        $dgInput = Read-Host "  $Prompt (or 'q' to cancel)"
        
        if ([string]::IsNullOrWhiteSpace($dgInput) -or $dgInput -eq 'q' -or $dgInput -eq 'Q') {
            Write-LogInfo "Cancelled."
            return $null
        }
        
        # Check if input is a number
        $num = 0
        if ([int]::TryParse($dgInput, [ref]$num) -and $num -ge 1 -and $num -le $filteredDatagroups.Count) {
            if ($Mode -eq "new") {
                Write-LogError "Datagroup '$($filteredDatagroups[$num - 1].Name)' already exists. Enter a new name."
                continue
            }
            $sel = $filteredDatagroups[$num - 1]
            return @{ Name = $sel.Name; Class = $sel.Class }
        }
        
        if ([int]::TryParse($dgInput, [ref]$num)) {
            Write-LogError "Invalid selection. Try again."
            continue
        }
        
        # Direct name entry - check against in-memory list
        $dgName = Remove-PartitionPrefix -Name $dgInput
        $found = $datagroups | Where-Object { $_.Name -eq $dgName } | Select-Object -First 1
        
        if ($found) {
            if ($Mode -eq "new") {
                Write-LogError "Datagroup '$dgName' already exists. Enter a new name."
                continue
            }
            return @{ Name = $found.Name; Class = $found.Class }
        } else {
            if ($Mode -eq "existing") {
                Write-LogError "Datagroup '$dgName' does not exist in partition '$Partition'. Try again."
                continue
            }
            return @{ Name = $dgName; Class = "" }
        }
    }
}

function Invoke-PromptSaveConfig {
    Write-Host ""
    $saveChoice = Read-Host "  Save configuration? (yes/no) [yes]"
    if ([string]::IsNullOrWhiteSpace($saveChoice)) { $saveChoice = "yes" }
    if ($saveChoice -eq "yes") {
        Write-LogStep "Saving configuration..."
        if (Save-F5Config) {
            Write-LogOk "Configuration saved."
        } else {
            Write-LogWarn "Could not save configuration. Save manually via BIG-IP GUI or tmsh."
        }
    }
}

# =============================================================================
# FLEET MANAGEMENT FUNCTIONS
# =============================================================================

function Import-FleetConfig {
    $script:FleetSites = @()
    $script:FleetHosts = @()
    $script:FleetUniqueSites = @()
    
    if (-not (Test-Path $script:FLEET_CONFIG_FILE)) { return $false }
    
    $seenSites = @{}
    $seenHosts = @{}
    $duplicateHosts = @()
    
    foreach ($line in (Get-Content $script:FLEET_CONFIG_FILE)) {
        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        
        $parts = $line.Split('|')
        if ($parts.Count -lt 2) { continue }
        
        $site = $parts[0].Trim()
        $host_ = $parts[1].Trim()
        
        if ([string]::IsNullOrWhiteSpace($site) -or [string]::IsNullOrWhiteSpace($host_)) { continue }
        if ($site -notmatch '^[a-zA-Z0-9_-]+$') { continue }
        
        # Check for duplicate hosts
        if ($seenHosts.ContainsKey($host_)) {
            $duplicateHosts += "$($seenHosts[$host_])|$host_"
            $duplicateHosts += "$site|$host_"
            continue
        }
        $seenHosts[$host_] = $site
        
        $script:FleetSites += $site
        $script:FleetHosts += $host_
        
        if (-not $seenSites.ContainsKey($site)) {
            $seenSites[$site] = $true
            $script:FleetUniqueSites += $site
        }
    }
    
    # Halt on duplicate hosts
    if ($duplicateHosts.Count -gt 0) {
        Write-Host ""
        Write-LogError "Duplicate hosts detected in fleet.conf:"
        Write-Host ""
        foreach ($dup in $duplicateHosts) {
            Write-Host "          $dup" -ForegroundColor White
        }
        Write-Host ""
        Write-Host "          Correct fleet.conf and restart." -ForegroundColor White
        Write-Host ""
        exit 1
    }
    
    return $script:FleetHosts.Count -gt 0
}

function Test-FleetAvailable {
    return $script:FleetHosts.Count -gt 0
}

function Get-SiteHosts {
    param([string]$SiteId)
    $hosts = @()
    for ($i = 0; $i -lt $script:FleetHosts.Count; $i++) {
        if ($script:FleetSites[$i] -eq $SiteId) { $hosts += $script:FleetHosts[$i] }
    }
    return $hosts
}

function Get-HostSite {
    param([string]$Hostname)
    for ($i = 0; $i -lt $script:FleetHosts.Count; $i++) {
        if ($script:FleetHosts[$i] -eq $Hostname) { return $script:FleetSites[$i] }
    }
    return ""
}

function Get-SiteHostCount {
    param([string]$SiteId)
    return @($script:FleetSites | Where-Object { $_ -eq $SiteId }).Count
}

function Confirm-SiteLogDir {
    param([string]$SiteId)
    $dir = Join-Path $script:BACKUP_DIR $SiteId
    if (-not (Test-Path $dir)) {
        try { New-Item -Path $dir -ItemType Directory -Force | Out-Null; return $true }
        catch { return $false }
    }
    return $true
}

# Get the correct backup directory for the connected host
# Fleet hosts use site subfolder, non-fleet hosts use root backup directory
function Get-ConnectedBackupDir {
    $hostSite = Get-HostSite -Hostname $script:RemoteHost
    if ($hostSite) {
        Confirm-SiteLogDir -SiteId $hostSite | Out-Null
        return Join-Path $script:BACKUP_DIR $hostSite
    }
    return $script:BACKUP_DIR
}

# =============================================================================
# DEPLOY VALIDATION FUNCTIONS
# =============================================================================

function Test-HostConnection {
    param([string]$HostName)
    $origHost = $script:RemoteHost
    $script:RemoteHost = $HostName
    $result = Invoke-F5Get -Endpoint "/mgmt/tm/sys/version"
    $script:RemoteHost = $origHost
    return $result.Success
}

function Test-RemoteDatagroup {
    param([string]$HostName, [string]$Partition, [string]$Name)
    $origHost = $script:RemoteHost
    $script:RemoteHost = $HostName
    $exists = Test-DatagroupExistsRemote -Partition $Partition -Name $Name
    $script:RemoteHost = $origHost
    return $exists
}

function Test-RemoteUrlCategory {
    param([string]$HostName, [string]$Name)
    $origHost = $script:RemoteHost
    $script:RemoteHost = $HostName
    $exists = Test-UrlCategoryExistsRemote -Name $Name
    $script:RemoteHost = $origHost
    return $exists
}

function Backup-RemoteDatagroup {
    param([string]$HostName, [string]$Partition, [string]$Name, [string]$SiteId)
    $origHost = $script:RemoteHost
    $script:RemoteHost = $HostName
    
    Confirm-SiteLogDir -SiteId $SiteId | Out-Null
    $safeHost = $HostName -replace '[^a-zA-Z0-9_-]', '_'
    $backupFile = Join-Path $script:BACKUP_DIR "$SiteId\${safeHost}_${Partition}_${Name}_$($script:Timestamp).csv"
    
    $dgType = Get-DatagroupTypeRemote -Partition $Partition -Name $Name
    $records = Get-DatagroupRecordsRemote -Partition $Partition -Name $Name
    
    $lines = @(
        "# Datagroup Backup: /${Partition}/${Name}",
        "# Host: $HostName",
        "# Site: $SiteId",
        "# Type: $dgType",
        "# Created: $(Get-Date)",
        "# Reason: Pre-deploy backup",
        "#"
    )
    foreach ($rec in $records) { $lines += "$($rec.Key),$($rec.Value)" }
    
    $script:RemoteHost = $origHost
    
    try {
        $lines | Out-File -FilePath $backupFile -Encoding UTF8
        return $backupFile
    } catch {
        return ""
    }
}

function Backup-RemoteUrlCategory {
    param([string]$HostName, [string]$CatName, [string]$SiteId)
    $origHost = $script:RemoteHost
    $script:RemoteHost = $HostName
    
    Confirm-SiteLogDir -SiteId $SiteId | Out-Null
    $safeHost = $HostName -replace '[^a-zA-Z0-9_-]', '_'
    $safeCat = $CatName -replace '[^a-zA-Z0-9_-]', '_'
    $backupFile = Join-Path $script:BACKUP_DIR "$SiteId\${safeHost}_urlcat_${safeCat}_$($script:Timestamp).csv"
    
    $entries = Get-UrlCategoryEntriesRemote -Name $CatName
    
    $lines = @(
        "# URL Category Backup: $CatName",
        "# Host: $HostName",
        "# Site: $SiteId",
        "# Created: $(Get-Date)",
        "# Reason: Pre-deploy backup",
        "#"
    )
    $lines += $entries
    
    $script:RemoteHost = $origHost
    
    try {
        $lines | Out-File -FilePath $backupFile -Encoding UTF8
        return $backupFile
    } catch {
        return ""
    }
}

# =============================================================================
# DEPLOY EXECUTION FUNCTIONS
# =============================================================================

$script:DeployErrorMsg = ""

function Select-DeployScope {
    param([string]$ObjectType, [string]$ObjectName, [bool]$IncludeSelf = $false)
    
    Write-Host ""
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "    DEPLOY SCOPE SELECTION" -ForegroundColor White
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Object: $ObjectName" -ForegroundColor White
    Write-Host "  Type:   $ObjectType" -ForegroundColor White
    Write-Host ""
    Write-Host "  Select deployment scope:" -ForegroundColor White
    Write-Host ""
    Write-Host -NoNewline "    "; Write-Host -NoNewline "1" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " All fleet hosts" -ForegroundColor White
    Write-Host -NoNewline "    "; Write-Host -NoNewline "2" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Select by site" -ForegroundColor White
    Write-Host -NoNewline "    "; Write-Host -NoNewline "3" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Select by host" -ForegroundColor White
    Write-Host -NoNewline "    "; Write-Host -NoNewline "0" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Cancel" -ForegroundColor White
    Write-Host ""
    $scopeType = Read-Host "  Select [0-3]"
    
    $targets = @()
    
    switch ($scopeType) {
        "1" {
            if ($IncludeSelf) {
                $targets = @($script:FleetHosts)
            } else {
                $targets = @($script:FleetHosts | Where-Object { $_ -ne $script:RemoteHost })
            }
        }
        "2" {
            Write-Host ""
            for ($s = 0; $s -lt $script:FleetUniqueSites.Count; $s++) {
                $site = $script:FleetUniqueSites[$s]
                $siteCount = @(Get-SiteHosts -SiteId $site).Count
                $siteHostWord = $(if ($siteCount -eq 1) { "host" } else { "hosts" })
                Write-Host -NoNewline "    "; Write-Host -NoNewline "$($s + 1)" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White
                Write-Host " $site ($siteCount $siteHostWord)" -ForegroundColor White
            }
            Write-Host ""
            $siteInput = Read-Host "  Enter site numbers (comma-separate for multiple)"
            if ([string]::IsNullOrWhiteSpace($siteInput)) { return @() }
            foreach ($sel in ($siteInput -split ',')) {
                $sel = $sel.Trim()
                $num = 0
                if ([int]::TryParse($sel, [ref]$num) -and $num -ge 1 -and $num -le $script:FleetUniqueSites.Count) {
                    $selectedSite = $script:FleetUniqueSites[$num - 1]
                    for ($i = 0; $i -lt $script:FleetHosts.Count; $i++) {
                        if ($script:FleetSites[$i] -eq $selectedSite) {
                            if ($IncludeSelf -or $script:FleetHosts[$i] -ne $script:RemoteHost) {
                                $targets += $script:FleetHosts[$i]
                            }
                        }
                    }
                }
            }
        }
        "3" {
            Write-Host ""
            for ($h = 0; $h -lt $script:FleetHosts.Count; $h++) {
                Write-Host -NoNewline "    "; Write-Host -NoNewline "$($h + 1)" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White
                Write-Host " $($script:FleetHosts[$h]) ($($script:FleetSites[$h]))" -ForegroundColor White
            }
            Write-Host ""
            $hostInput = Read-Host "  Enter host numbers (comma-separate for multiple)"
            if ([string]::IsNullOrWhiteSpace($hostInput)) { return @() }
            foreach ($sel in ($hostInput -split ',')) {
                $sel = $sel.Trim()
                $num = 0
                if ([int]::TryParse($sel, [ref]$num) -and $num -ge 1 -and $num -le $script:FleetHosts.Count) {
                    $idx = $num - 1
                    if ($IncludeSelf -or $script:FleetHosts[$idx] -ne $script:RemoteHost) {
                        $targets += $script:FleetHosts[$idx]
                    }
                }
            }
        }
        default { return @() }
    }
    
    return $targets
}

function Deploy-DatagroupToHost {
    param(
        [string]$HostName, [string]$Partition, [string]$DgName, [string]$DgType,
        [array]$RecordsJson, [string]$SiteId,
        [string]$DeployMode = "replace", [array]$AdditionsJson = @(), [string[]]$DeletionsList = @()
    )
    
    $script:DeployErrorMsg = ""
    $origHost = $script:RemoteHost
    $script:RemoteHost = $HostName
    
    if ($DeployMode -eq "merge") {
        # tmsh modify mode: add then delete
        $mergeErrors = 0
        
        # Additions first
        if ($AdditionsJson.Count -gt 0) {
            $addKeys = @(); $addValues = @()
            foreach ($rec in $AdditionsJson) {
                $addKeys += $rec.name
                $addValues += $(if ($rec.data) { $rec.data } else { "" })
            }
            $addTmsh = ConvertTo-TmshRecordsAdd -Keys $addKeys -Values $addValues
            if ($addTmsh) {
                if (-not (Add-DatagroupRecordsIncremental -Partition $Partition -Name $DgName -TmshRecords $addTmsh)) {
                    Write-Host "  [FAIL]" -NoNewline -ForegroundColor Red; Write-Host "  Adding records" -ForegroundColor White
                    $mergeErrors++
                }
            }
        }
        
        # Deletions second
        if ($DeletionsList.Count -gt 0) {
            $delTmsh = ConvertTo-TmshRecordsDelete -Keys $DeletionsList
            if ($delTmsh) {
                if (-not (Remove-DatagroupRecordsIncremental -Partition $Partition -Name $DgName -TmshKeys $delTmsh)) {
                    Write-Host "  [FAIL]" -NoNewline -ForegroundColor Red; Write-Host "  Deleting records" -ForegroundColor White
                    $mergeErrors++
                }
            }
        }
        
        if ($mergeErrors -gt 0) {
            Write-Host "  [FAIL]" -NoNewline -ForegroundColor Red; Write-Host "  Applying changes" -ForegroundColor White
            $script:DeployErrorMsg = "tmsh modify completed with $mergeErrors error(s)"
            $script:RemoteHost = $origHost
            return $false
        }
        Write-Host "  [ OK ]" -NoNewline -ForegroundColor Green; Write-Host "  Applying changes" -ForegroundColor White
    } else {
        # Full replace
        $result = Set-DatagroupRecordsRemote -Partition $Partition -Name $DgName -Records $RecordsJson
        if (-not $result.Success) {
            Write-Host "  [FAIL]" -NoNewline -ForegroundColor Red; Write-Host "  Applying changes" -ForegroundColor White
            $script:DeployErrorMsg = "Failed to apply records (HTTP $($result.StatusCode))"
            $script:RemoteHost = $origHost
            return $false
        }
        Write-Host "  [ OK ]" -NoNewline -ForegroundColor Green; Write-Host "  Applying changes" -ForegroundColor White
    }
    
    # Save config
    if (-not (Save-F5Config)) {
        Write-Host "  [FAIL]" -NoNewline -ForegroundColor Red; Write-Host "  Saving configuration" -ForegroundColor White
        $script:DeployErrorMsg = "Applied but failed to save config"
        $script:RemoteHost = $origHost
        return $false
    }
    Write-Host "  [ OK ]" -NoNewline -ForegroundColor Green; Write-Host "  Saving configuration" -ForegroundColor White
    
    $script:RemoteHost = $origHost
    return $true
}

function Deploy-UrlCategoryToHost {
    param(
        [string]$HostName, [string]$CatName, [array]$UrlsJson, [string]$SiteId,
        [string]$DeployMode = "replace", [array]$AdditionsJson = @(), [string[]]$DeletionsList = @()
    )
    
    $script:DeployErrorMsg = ""
    $origHost = $script:RemoteHost
    $script:RemoteHost = $HostName
    
    if ($DeployMode -eq "merge") {
        $mergeErrors = 0
        
        if ($DeletionsList.Count -gt 0) {
            if (-not (Remove-UrlCategoryEntriesRemote -Name $CatName -UrlsToDelete $DeletionsList)) {
                $mergeErrors++
            }
        }
        
        if ($AdditionsJson.Count -gt 0) {
            if (-not (Add-UrlCategoryEntriesRemote -Name $CatName -NewUrls $AdditionsJson)) {
                $mergeErrors++
            }
        }
        
        if ($mergeErrors -gt 0) {
            Write-Host "  [FAIL]" -NoNewline -ForegroundColor Red; Write-Host "  Applying changes" -ForegroundColor White
            $script:DeployErrorMsg = "Merge completed with $mergeErrors error(s)"
            $script:RemoteHost = $origHost
            return $false
        }
        Write-Host "  [ OK ]" -NoNewline -ForegroundColor Green; Write-Host "  Applying changes" -ForegroundColor White
    } else {
        if (-not (Set-UrlCategoryEntriesRemote -Name $CatName -Urls $UrlsJson)) {
            Write-Host "  [FAIL]" -NoNewline -ForegroundColor Red; Write-Host "  Applying changes" -ForegroundColor White
            $script:DeployErrorMsg = "Failed to apply URLs"
            $script:RemoteHost = $origHost
            return $false
        }
        Write-Host "  [ OK ]" -NoNewline -ForegroundColor Green; Write-Host "  Applying changes" -ForegroundColor White
    }
    
    if (-not (Save-F5Config)) {
        Write-Host "  [FAIL]" -NoNewline -ForegroundColor Red; Write-Host "  Saving configuration" -ForegroundColor White
        $script:DeployErrorMsg = "Applied but failed to save config"
        $script:RemoteHost = $origHost
        return $false
    }
    Write-Host "  [ OK ]" -NoNewline -ForegroundColor Green; Write-Host "  Saving configuration" -ForegroundColor White
    
    $script:RemoteHost = $origHost
    return $true
}

function Invoke-PreDeployValidation {
    param([string]$ObjectType, [string]$ObjectName, [string]$Partition, [string[]]$Targets)
    
    Write-Host ""
    
    $results = @()
    
    foreach ($hostName in $Targets) {
        if ([string]::IsNullOrWhiteSpace($hostName)) { continue }
        $siteId = Get-HostSite -Hostname $hostName
        
        Write-Host "`r  [....] $hostName ($siteId)" -NoNewline -ForegroundColor White
        
        # Test connectivity
        if (-not (Test-HostConnection -HostName $hostName)) {
            Write-Host "`r$(' ' * 80)" -NoNewline
            Write-Host "`r  [FAIL]" -NoNewline -ForegroundColor Red
            Write-Host " $hostName ($siteId) - Connection failed" -ForegroundColor White
            $results += @{ Host = $hostName; Site = $siteId; Status = "FAIL"; Message = "Connection failed" }
            continue
        }
        
        # Verify object exists
        $exists = $false
        if ($ObjectType -eq "datagroup") {
            $exists = Test-RemoteDatagroup -HostName $hostName -Partition $Partition -Name $ObjectName
        } else {
            $exists = Test-RemoteUrlCategory -HostName $hostName -Name $ObjectName
        }
        
        if (-not $exists) {
            Write-Host "`r$(' ' * 80)" -NoNewline
            Write-Host "`r  [FAIL]" -NoNewline -ForegroundColor Red
            Write-Host " $hostName ($siteId) - Object not found" -ForegroundColor White
            $results += @{ Host = $hostName; Site = $siteId; Status = "FAIL"; Message = "Object not found" }
            continue
        }
        
        Write-Host "`r$(' ' * 80)" -NoNewline
        Write-Host "`r  [ OK ]" -NoNewline -ForegroundColor Green
        Write-Host " $hostName ($siteId) - Ready" -ForegroundColor White
        $results += @{ Host = $hostName; Site = $siteId; Status = "OK"; Message = "Ready" }
    }
    
    Write-Host ""
    Write-Host "  ──────────────────────────────────────────────────────────────" -ForegroundColor Cyan
    
    $okCount = @($results | Where-Object { $_.Status -eq "OK" }).Count
    $failCount = @($results | Where-Object { $_.Status -ne "OK" }).Count
    
    Write-Host -NoNewline "  Validation complete: "
    Write-Host -NoNewline "$okCount ready" -ForegroundColor Green
    Write-Host ", $failCount failed" -ForegroundColor Red
    
    return $results
}

function Invoke-FleetDeploy {
    param(
        [string]$ObjectType, [string]$ObjectName, [string]$Partition,
        [array]$ValidationResults, [scriptblock]$DeployAction,
        [string]$CurrentHost = "", [string]$CurrentStatus = "", [string]$CurrentMessage = ""
    )
    
    $successCount = 0
    $failCount = 0
    $skipCount = 0
    $lastError = ""
    $consecutiveSameError = 0
    $deployResults = @()
    
    if ($CurrentHost) {
        $deployResults += @{ Host = $CurrentHost; Site = "(current)"; Status = $CurrentStatus; Message = $CurrentMessage }
        if ($CurrentStatus -eq "OK") { $successCount++ } else { $failCount++ }
    }
    
    
    foreach ($vr in $ValidationResults) {
        if ($vr.Status -ne "OK") {
            # Pre-check failures are skips in deploy - FAIL is reserved for actual deploy failures
            $deployResults += @{ Host = $vr.Host; Site = $vr.Site; Status = "SKIP"; Message = "" }
            $skipCount++
            continue
        }
        
        Write-Host ""
        Write-Host "  Deploying to $($vr.Host) ($($vr.Site))..." -ForegroundColor White
        
        # Backup
        if ($script:BACKUPS_ENABLED -eq 1) {
            $backupFile = ""
            if ($ObjectType -eq "datagroup") {
                $backupFile = Backup-RemoteDatagroup -HostName $vr.Host -Partition $Partition -Name $ObjectName -SiteId $vr.Site
            } else {
                $backupFile = Backup-RemoteUrlCategory -HostName $vr.Host -CatName $ObjectName -SiteId $vr.Site
            }
            
            if ([string]::IsNullOrWhiteSpace($backupFile)) {
                Write-Host "  [FAIL]" -NoNewline -ForegroundColor Red; Write-Host "  Creating backup" -ForegroundColor White
                $deployResults += @{ Host = $vr.Host; Site = $vr.Site; Status = "FAIL"; Message = "Backup failed" }
                $failCount++
                $consecutiveSameError++
                $lastError = "Backup failed"
                if ($consecutiveSameError -ge 3) {
                    Write-Host ""
                    Write-LogWarn "Systemic failure detected: Same error on 3 consecutive hosts"
                    Write-Host "  Continue deploying to remaining hosts? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $cont = Read-Host
                    if ($cont -ne "yes") {
                        Write-LogInfo "Deployment stopped by user."
                        break
                    }
                    $consecutiveSameError = 0
                }
                continue
            }
            Write-Host "  [ OK ]" -NoNewline -ForegroundColor Green; Write-Host "  Creating backup" -ForegroundColor White
        }
        
        # Deploy (apply + save with verbose output from deploy functions)
        $success = & $DeployAction $vr.Host $vr.Site
        
        if ($success) {
            $deployResults += @{ Host = $vr.Host; Site = $vr.Site; Status = "OK"; Message = "Deployed and saved" }
            $successCount++
            $lastError = ""
            $consecutiveSameError = 0
        } else {
            $deployResults += @{ Host = $vr.Host; Site = $vr.Site; Status = "FAIL"; Message = $script:DeployErrorMsg }
            $failCount++
            
            if ($script:DeployErrorMsg -eq $lastError) {
                $consecutiveSameError++
                if ($consecutiveSameError -ge 3) {
                    Write-Host ""
                    Write-LogWarn "Systemic failure detected: Same error on 3 consecutive hosts"
                    Write-Host "  Continue deploying to remaining hosts? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $cont = Read-Host
                    if ($cont -ne "yes") {
                        Write-LogInfo "Deployment stopped by user."
                        break
                    }
                    $consecutiveSameError = 0
                }
            } else {
                $lastError = $script:DeployErrorMsg
                $consecutiveSameError = 1
            }
        }
    }
    
    # Display summary
    Write-Host ""
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "    DEPLOY SUMMARY" -ForegroundColor White
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("  {0,-35} {1,-10} {2,-8} {3}" -f "HOST", "SITE", "STATUS", "MESSAGE") -ForegroundColor White
    Write-Host "  ──────────────────────────────────────────────────────────────" -ForegroundColor Cyan
    
    foreach ($dr in $deployResults) {
        $statusColor = switch ($dr.Status) {
            "OK" { "Green" }
            "FAIL" { "Red" }
            "SKIP" { "Yellow" }
            default { "White" }
        }
        $hostDisplay = $(if ($dr.Host.Length -gt 35) { $dr.Host.Substring(0,35) } else { $dr.Host })
        $msgDisplay = $(if ($dr.Message.Length -gt 30) { $dr.Message.Substring(0,30) } else { $dr.Message })
        
        Write-Host ("  {0,-35} " -f $hostDisplay) -NoNewline -ForegroundColor White
        Write-Host ("{0,-10} " -f $dr.Site) -NoNewline -ForegroundColor White
        Write-Host ("{0,-8} " -f $dr.Status) -NoNewline -ForegroundColor $statusColor
        Write-Host $msgDisplay -ForegroundColor White
    }
    
    Write-Host "  ──────────────────────────────────────────────────────────────" -ForegroundColor Cyan
    Write-Host -NoNewline "  Total: "
    Write-Host -NoNewline "$successCount succeeded" -ForegroundColor Green
    Write-Host -NoNewline ", $failCount failed" -ForegroundColor Red
    Write-Host ", $skipCount skipped" -ForegroundColor Yellow
    Write-Host ""
}

# =============================================================================
# BACKUP FUNCTIONS
# =============================================================================

function Backup-Datagroup {
    param([string]$Partition, [string]$Name)
    
    $safePartition = $Partition -replace '/', '_'
    $safeHostname = $script:RemoteHost -replace '[^a-zA-Z0-9_-]', '_'
    $backupPath = Get-ConnectedBackupDir
    $backupFile = Join-Path $backupPath "${safeHostname}_${safePartition}_${Name}_internal_$($script:Timestamp).csv"
    
    $dgType = Get-DatagroupTypeRemote -Partition $Partition -Name $Name
    $records = Get-DatagroupRecordsRemote -Partition $Partition -Name $Name
    
    $lines = @(
        "# Datagroup Backup: /${Partition}/${Name}",
        "# Partition: $Partition",
        "# Class: internal",
        "# Type: $dgType",
        "# Created: $(Get-Date)",
        "# Format: key,value",
        "#"
    )
    foreach ($rec in $records) { $lines += "$($rec.Key),$($rec.Value)" }
    
    try {
        $lines | Out-File -FilePath $backupFile -Encoding UTF8
        Remove-OldBackups -Pattern "${safePartition}_${Name}_internal"
        return $backupFile
    } catch {
        return ""
    }
}

function Backup-UrlCategory {
    param([string]$CatName)
    
    $safeName = $CatName -replace '[^a-zA-Z0-9_-]', '_'
    $safeHostname = $script:RemoteHost -replace '[^a-zA-Z0-9_-]', '_'
    $backupPath = Get-ConnectedBackupDir
    $backupFile = Join-Path $backupPath "${safeHostname}_urlcat_${safeName}_$($script:Timestamp).csv"
    
    $entries = Get-UrlCategoryEntriesRemote -Name $CatName
    
    $lines = @(
        "# URL Category Backup: $CatName",
        "# Created: $(Get-Date)",
        "# Reason: Pre-change backup",
        "#"
    )
    $lines += $entries
    
    try {
        $lines | Out-File -FilePath $backupFile -Encoding UTF8
        return $backupFile
    } catch {
        return ""
    }
}

# =============================================================================
# CSV PARSING AND VALIDATION
# =============================================================================

function Import-CsvDatagroup {
    param([string]$FilePath, [string]$Format)
    
    $keys = @()
    $values = @()
    $lineNum = 0
    
    foreach ($rawLine in (Get-Content $FilePath)) {
        $lineNum++
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('#')) { continue }
        
        if ($Format -eq "keys_only") {
            $key = ($line -split ',')[0].Trim()
            if ([string]::IsNullOrWhiteSpace($key)) {
                Write-LogWarn "Line ${lineNum}: Empty key, skipping"
                continue
            }
            $keys += $key
            $values += ""
        } else {
            $parts = $line -split ',', 2
            $key = $parts[0].Trim()
            $value = $(if ($parts.Count -gt 1) { $parts[1].Trim() } else { "" })
            
            if ([string]::IsNullOrWhiteSpace($key)) {
                Write-LogWarn "Line ${lineNum}: Empty key, skipping"
                continue
            }
            $keys += $key
            $values += $value
        }
    }
    
    if ($keys.Count -eq 0) {
        Write-LogError "No valid entries found in CSV file"
        return $null
    }
    
    return @{ Keys = $keys; Values = $values }
}

function Test-EntryTypes {
    param([string]$ExpectedType, [string[]]$Keys)
    
    $intCount = 0; $addrCount = 0; $otherCount = 0
    foreach ($key in $Keys) {
        if (Test-IntegerFormat -Entry $key) { $intCount++ }
        elseif (Test-AddressFormat -Entry $key) { $addrCount++ }
        else { $otherCount++ }
    }
    
    $total = $Keys.Count
    $mismatchCount = 0
    $mismatchType = ""
    
    if ($ExpectedType -eq "string") {
        if ($addrCount -gt 0) { $mismatchCount = $addrCount; $mismatchType = "address" }
        elseif ($intCount -gt 0) { $mismatchCount = $intCount; $mismatchType = "integer" }
    } elseif ($ExpectedType -eq "address") {
        $nonAddr = $intCount + $otherCount
        if ($nonAddr -gt 0) { $mismatchCount = $nonAddr; $mismatchType = "non-address" }
    } elseif ($ExpectedType -eq "integer") {
        $nonInt = $addrCount + $otherCount
        if ($nonInt -gt 0) { $mismatchCount = $nonInt; $mismatchType = "non-integer" }
    }
    
    $pct = $(if ($total -gt 0) { [math]::Round($mismatchCount * 100 / $total) } else { 0 })
    return @{ Count = $mismatchCount; Type = $mismatchType; Percent = $pct }
}

function Show-CsvPreview {
    param([string]$FilePath)
    
    $allLines = Get-Content $FilePath
    $dataLines = @($allLines | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') })
    
    Write-Host ""
    Write-Host "  Analyzing file: $(Split-Path $FilePath -Leaf)" -ForegroundColor White
    Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
    
    $count = 0
    foreach ($line in $dataLines) {
        $count++
        if ($count -le $script:PREVIEW_LINES) {
            Write-Host "    Row ${count}: $line" -ForegroundColor White
        }
    }
    
    Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor Cyan
    Write-Host "  Showing first $($script:PREVIEW_LINES) of $($dataLines.Count) data entries." -ForegroundColor White
    Write-Host ""
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

function Invoke-PreFlightChecks {
    Write-LogSection "Pre-Flight Checks"
    
    # Parse partitions (already an array)
    if ($script:PARTITIONS.Count -eq 0) {
        Write-LogError "No partitions configured."
        exit 1
    }
    Write-LogOk "Configured partitions: $($script:PARTITIONS -join ', ')"
    
    # Set fleet config file path
    $script:FLEET_CONFIG_FILE = Join-Path $script:BACKUP_DIR "fleet.conf"
    
    # Load fleet configuration if available
    if (Import-FleetConfig) {
        $hostWord = $(if ($script:FleetHosts.Count -eq 1) { "host" } else { "hosts" })
        $siteWord = $(if ($script:FleetUniqueSites.Count -eq 1) { "site" } else { "sites" })
        Write-LogOk "Fleet loaded: $($script:FleetHosts.Count) $hostWord across $($script:FleetUniqueSites.Count) $siteWord"
    } else {
        # Create boilerplate fleet.conf for the user
        if (-not (Test-Path $script:FLEET_CONFIG_FILE) -and (Test-Path $script:BACKUP_DIR)) {
            $template = @(
                "# DGCat-Admin Fleet Configuration File",
                "# This file defines BIG-IPs within an enterprise that will be managed by DGCat-Admin",
                "# https://github.com/hauptem/F5-SSL-Orchestrator-Tools",
                "#",
                "# Format: SITE|HOSTNAME_OR_IP",
                "#",
                "# Examples:",
                "# DC1|bigip01-mgmt.dc1.example.com",
                "# DC1|bigip02-mgmt.dc1.example.com",
                "# DC2|bigip01-mgmt.dc2.example.com",
                "# DC2|bigip02-mgmt.dc2.example.com",
                "#",
                "# Site names: letters, numbers, dashes, underscores only"
            )
            try {
                $template | Out-File -FilePath $script:FLEET_CONFIG_FILE -Encoding UTF8
                Write-LogInfo "Fleet config template created: $($script:FLEET_CONFIG_FILE)"
            } catch {
                Write-LogInfo "No fleet configured (optional: create $($script:FLEET_CONFIG_FILE))"
            }
        } else {
            Write-LogInfo "No fleet configured (optional: create $($script:FLEET_CONFIG_FILE))"
        }
    }
    
    # Establish connection (with retry loop)
    while ($true) {
        if (Initialize-RemoteConnection) { break }
        Write-Host ""
        $retry = Read-Host "  Retry connection? (yes/no) [yes]"
        if ([string]::IsNullOrWhiteSpace($retry)) { $retry = "yes" }
        if ($retry -ne "yes") {
            Write-LogInfo "Exiting."
            Write-Host "  Latest version: https://github.com/hauptem/F5-SSL-Orchestrator-Tools" -ForegroundColor Cyan
            exit 0
        }
    }
    
    # Validate partitions
    Write-LogStep "Validating partitions on target system..."
    $invalidCount = 0
    foreach ($partition in $script:PARTITIONS) {
        if (-not (Test-PartitionExists -Partition $partition)) {
            Write-LogWarn "Partition '$partition' not found on $($script:RemoteHost)"
            $invalidCount++
        }
    }
    if ($invalidCount -gt 0) {
        Write-LogWarn "$invalidCount configured partition(s) not found. They will be skipped."
    } else {
        Write-LogOk "All partitions validated"
    }
    
    # Setup backup directory
    if (-not (Confirm-BackupDir)) {
        Write-LogWarn "Cannot create or access backup directory: $($script:BACKUP_DIR)"
        Write-LogWarn "Backups will be disabled. Proceed with caution."
    } else {
        Write-LogOk "Backup directory: $($script:BACKUP_DIR)"
    }
    
    # Cache URL category DB availability
    if (Test-UrlCategoryDbAvailable) {
        Write-LogOk "URL category database available"
    } else {
        Write-LogInfo "URL category database not available (URL filtering module may not be provisioned)"
    }
    
    Write-Log ""
    Write-LogInfo "Connected to: $($script:RemoteHostname)"
    if ($script:LOGGING_ENABLED -eq 1) {
        Write-LogInfo "Log file: $($script:LogFile)"
    }
}

# =============================================================================
# MENU FUNCTIONS
# =============================================================================

function Show-MainMenu {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║" -NoNewline -ForegroundColor Cyan
    Write-Host "                    DGCAT-Admin v5.1                        " -NoNewline -ForegroundColor White
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ║" -NoNewline -ForegroundColor Cyan
    Write-Host "               F5 BIG-IP Administration Tool                " -NoNewline -ForegroundColor White
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ╠════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "    Connected: " -NoNewline -ForegroundColor White
    Write-Host $script:RemoteHostname -ForegroundColor Yellow
    Write-Host "  ╠════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "  ║                                                            ║" -ForegroundColor Cyan
    Write-Host "  ║" -NoNewline -ForegroundColor Cyan
    Write-Host "   " -NoNewline -ForegroundColor White
    Write-Host "1" -NoNewline -ForegroundColor Yellow; Write-Host ")" -NoNewline -ForegroundColor White
    Write-Host "  Create Datagroup or URL Category                     " -NoNewline -ForegroundColor White
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ║" -NoNewline -ForegroundColor Cyan
    Write-Host "   " -NoNewline -ForegroundColor White
    Write-Host "2" -NoNewline -ForegroundColor Yellow; Write-Host ")" -NoNewline -ForegroundColor White
    Write-Host "  Create/Update Datagroup or URL Category from CSV     " -NoNewline -ForegroundColor White
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ║" -NoNewline -ForegroundColor Cyan
    Write-Host "   " -NoNewline -ForegroundColor White
    Write-Host "3" -NoNewline -ForegroundColor Yellow; Write-Host ")" -NoNewline -ForegroundColor White
    Write-Host "  Delete Datagroup or URL Category                     " -NoNewline -ForegroundColor White
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ║" -NoNewline -ForegroundColor Cyan
    Write-Host "   " -NoNewline -ForegroundColor White
    Write-Host "4" -NoNewline -ForegroundColor Yellow; Write-Host ")" -NoNewline -ForegroundColor White
    Write-Host "  Export Datagroup or URL Category to CSV              " -NoNewline -ForegroundColor White
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ║" -NoNewline -ForegroundColor Cyan
    Write-Host "   " -NoNewline -ForegroundColor White
    Write-Host "5" -NoNewline -ForegroundColor Yellow; Write-Host ")" -NoNewline -ForegroundColor White
    Write-Host "  View/Edit a Datagroup or URL Category                " -NoNewline -ForegroundColor White
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ║" -NoNewline -ForegroundColor Cyan
    Write-Host "   " -NoNewline -ForegroundColor White
    Write-Host "6" -NoNewline -ForegroundColor Yellow; Write-Host ")" -NoNewline -ForegroundColor White
    Write-Host "  Search                                               " -NoNewline -ForegroundColor White
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ║" -NoNewline -ForegroundColor Cyan
    Write-Host "   " -NoNewline -ForegroundColor White
    Write-Host "7" -NoNewline -ForegroundColor Yellow; Write-Host ")" -NoNewline -ForegroundColor White
    Write-Host "  Backup                                               " -NoNewline -ForegroundColor White
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ║" -NoNewline -ForegroundColor Cyan
    Write-Host "   " -NoNewline -ForegroundColor White
    Write-Host "8" -NoNewline -ForegroundColor Yellow; Write-Host ")" -NoNewline -ForegroundColor White
    Write-Host "  Bootstrap                                            " -NoNewline -ForegroundColor White
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ║                                                            ║" -ForegroundColor Cyan
    Write-Host "  ╠════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "  ║" -NoNewline -ForegroundColor Cyan
    Write-Host "   " -NoNewline -ForegroundColor White
    Write-Host "0" -NoNewline -ForegroundColor Yellow; Write-Host ")" -NoNewline -ForegroundColor White
    Write-Host "  Exit                                                 " -NoNewline -ForegroundColor White
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

# Option 1: Create Datagroup or URL Category
function Invoke-CreateEmpty {
    Write-LogSection "Create Datagroup or URL Category"
    
    Write-Host ""
    Write-Host "  What would you like to create?" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '1' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Datagroup" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '2' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "URL Category" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '0' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Cancel" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "  Select [0-2]"
    
    switch ($choice) {
        "1" { Invoke-CreateEmptyDatagroup }
        "2" { Invoke-CreateEmptyUrlCategory }
        default {
            Write-LogInfo "Cancelled."
            Press-EnterToContinue
        }
    }
}

function Invoke-CreateEmptyDatagroup {
    Write-LogSection "Create Empty Datagroup"
    
    $partition = Select-Partition -Prompt "Select partition"
    if ([string]::IsNullOrWhiteSpace($partition)) {
        Write-LogInfo "Cancelled."
        Press-EnterToContinue
        return
    }
    
    $selection = Select-Datagroup -Partition $partition -Prompt "Enter new datagroup name" -Mode "new"
    if ($null -eq $selection) { Press-EnterToContinue; return }
    
    $dgName = $selection.Name
    
    if (Test-ProtectedDatagroup -Name $dgName) {
        Write-LogError "The name '$dgName' is reserved for a BIG-IP system datagroup."
        Press-EnterToContinue
        return
    }
    
    # Select type
    Write-Host ""
    Write-Host "  Select datagroup type:" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '1' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "string  - For domains, hostnames, URLs" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '2' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "address - For IP addresses, subnets (CIDR)" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '3' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "integer - For port numbers, numeric values" -ForegroundColor White
    Write-Host ""
    $typeChoice = Read-Host "  Select [1-3]"
    
    $dgType = switch ($typeChoice) { "1" { "string" }; "2" { "ip" }; "3" { "integer" }; default { "" } }
    if ([string]::IsNullOrWhiteSpace($dgType)) {
        Write-LogWarn "Invalid selection."
        Press-EnterToContinue
        return
    }
    
    $displayType = $(if ($dgType -eq "ip") { "address" } else { $dgType })
    
    # Confirm
    Write-Host ""
    Write-LogInfo "Ready to create:"
    Write-LogInfo "  Path: /${partition}/${dgName}"
    Write-LogInfo "  Type: $displayType"
    Write-Host ""
    Write-Host "  Create this datagroup? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $confirm = Read-Host
    if ($confirm -ne "yes") {
        Write-LogInfo "Cancelled."
        Press-EnterToContinue
        return
    }
    
    Write-LogStep "Creating datagroup '/${partition}/${dgName}'..."
    if (New-DatagroupRemote -Partition $partition -Name $dgName -Type $dgType) {
        Write-LogOk "Datagroup '/${partition}/${dgName}' created successfully (empty)."
        Invoke-PromptSaveConfig
    } else {
        Write-LogError "Failed to create datagroup."
    }
    
    Press-EnterToContinue
}

function Invoke-CreateEmptyUrlCategory {
    Write-LogSection "Create Empty URL Category"
    
    if (-not (Test-UrlCategoryDbAvailable)) {
        Write-LogError "URL database not available or accessible."
        Write-LogInfo "This feature requires the URL filtering module."
        Press-EnterToContinue
        return
    }
    
    Write-Host ""
    $catName = Read-Host "  Enter URL category name (or 'q' to cancel)"
    if ([string]::IsNullOrWhiteSpace($catName) -or $catName -eq 'q') {
        Write-LogInfo "Cancelled."
        Press-EnterToContinue
        return
    }
    
    # Sanitize name
    $originalName = $catName
    $catName = $catName -replace '[^a-zA-Z0-9_-]', '_'
    if ($catName -ne $originalName) { Write-LogInfo "Category name sanitized to: $catName" }
    
    # Check if already exists
    if (Test-UrlCategoryExistsRemote -Name $catName) {
        Write-LogError "URL category '$catName' already exists."
        Write-LogInfo "Use the editor (option 5) to modify existing URL categories."
        Press-EnterToContinue
        return
    }
    
    # Check if SSLO version exists
    $ssloName = "sslo-urlCat$catName"
    if (Test-UrlCategoryExistsRemote -Name $ssloName) {
        Write-LogError "URL category '$catName' exists as SSLO category '$ssloName'."
        Write-LogInfo "Use the editor (option 5) to modify existing URL categories."
        Press-EnterToContinue
        return
    }
    
    # Select default action
    Write-Host ""
    Write-Host "  Select default action for this category:" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '1' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "allow   - Allow traffic (use for bypass lists)" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '2' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "block   - Block traffic" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '3' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "confirm - Prompt user for confirmation" -ForegroundColor White
    Write-Host ""
    $actionChoice = Read-Host "  Select [1-3] [1]"
    if ([string]::IsNullOrWhiteSpace($actionChoice)) { $actionChoice = "1" }
    $defaultAction = switch ($actionChoice) { "1" { "allow" }; "2" { "block" }; "3" { "confirm" }; default { "allow" } }
    
    # Confirm
    Write-Host ""
    Write-LogInfo "Ready to create:"
    Write-LogInfo "  Category: $catName"
    Write-LogInfo "  Action:   $defaultAction"
    Write-Host ""
    Write-Host "  Create this URL category? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $confirm = Read-Host
    if ($confirm -ne "yes") {
        Write-LogInfo "Cancelled."
        Press-EnterToContinue
        return
    }
    
    Write-LogStep "Creating URL category '$catName'..."
    if (New-UrlCategoryRemote -Name $catName -DefaultAction $defaultAction -Urls @()) {
        Write-LogOk "URL category '$catName' created successfully (empty)."
        Invoke-PromptSaveConfig
    } else {
        Write-LogError "Failed to create URL category."
    }
    
    Press-EnterToContinue
}

# Option 3: Create/Update from CSV
function Invoke-CreateFromCsv {
    Write-LogSection "Create/Restore from CSV"
    
    Write-Host ""
    Write-Host "  What would you like to create?" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '1' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Datagroup" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '2' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "URL Category" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '0' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Cancel" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "  Select [0-2]"
    
    switch ($choice) {
        "1" { Invoke-CreateDatagroup }
        "2" { Invoke-CreateUrlCategory }
        default {
            Write-LogInfo "Cancelled."
            Press-EnterToContinue
        }
    }
}

function Invoke-CreateDatagroup {
    Write-LogSection "Create/Restore Datagroup from CSV"
    
    $partition = Select-Partition -Prompt "Select partition"
    if ([string]::IsNullOrWhiteSpace($partition)) {
        Write-LogInfo "Cancelled."
        Press-EnterToContinue
        return
    }
    
    $selection = Select-Datagroup -Partition $partition -Prompt "Enter datagroup name" -Mode "any"
    if ($null -eq $selection) { Press-EnterToContinue; return }
    
    $dgName = $selection.Name
    
    if (Test-ProtectedDatagroup -Name $dgName) {
        Write-LogError "The name '$dgName' is reserved for a BIG-IP system datagroup."
        Press-EnterToContinue
        return
    }
    
    # Determine if datagroup exists (class is populated from selection)
    $exists = (-not [string]::IsNullOrWhiteSpace($selection.Class))
    $dgType = ""
    $restoreMode = ""
    
    if ($exists) {
        $dgType = Get-DatagroupTypeRemote -Partition $partition -Name $dgName
        $records = Get-DatagroupRecordsRemote -Partition $partition -Name $dgName
        
        Write-LogInfo "Datagroup '$dgName' exists in partition '$partition'."
        Write-LogInfo "  Type: $dgType"
        Write-LogInfo "  Current records: $($records.Count)"
        Write-Host ""
        Write-Host "  How do you want to proceed?" -ForegroundColor White
        Write-Host '    ' -NoNewline; Write-Host '1' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
        Write-Host "Overwrite - Replace all existing entries with CSV contents" -ForegroundColor White
        Write-Host '    ' -NoNewline; Write-Host '2' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
        Write-Host "Merge     - Add CSV entries to existing (deduplicated)" -ForegroundColor White
        Write-Host '    ' -NoNewline; Write-Host '3' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
        Write-Host "Cancel" -ForegroundColor White
        Write-Host ""
        $existChoice = Read-Host "  Select [1-3]"
        
        switch ($existChoice) {
            "1" { $restoreMode = "overwrite" }
            "2" { $restoreMode = "merge" }
            default {
                Write-LogInfo "Cancelled."
                Press-EnterToContinue
                return
            }
        }
        
        # Backup before modification
        if ($script:BACKUPS_ENABLED -eq 1) {
            Write-LogStep "Creating backup of existing datagroup..."
            $backupFile = Backup-Datagroup -Partition $partition -Name $dgName
            if ($backupFile) {
                Write-LogOk "Backup saved: $backupFile"
            } else {
                Write-LogWarn "Could not create backup."
                Write-Host "  Continue without backup? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $cont = Read-Host
                if ($cont -ne "yes") {
                    Write-LogInfo "Aborted."
                    Press-EnterToContinue
                    return
                }
            }
        }
    } else {
        # New datagroup - ask for type
        Write-Host ""
        Write-Host "  Select datagroup type:" -ForegroundColor White
        Write-Host '    ' -NoNewline; Write-Host '1' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
        Write-Host "string  - For domains, hostnames, URLs" -ForegroundColor White
        Write-Host '    ' -NoNewline; Write-Host '2' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
        Write-Host "address - For IP addresses, subnets (CIDR)" -ForegroundColor White
        Write-Host '    ' -NoNewline; Write-Host '3' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
        Write-Host "integer - For port numbers, numeric values" -ForegroundColor White
        Write-Host ""
        $typeChoice = Read-Host "  Select [1-3]"
        
        switch ($typeChoice) {
            "1" { $dgType = "string" }
            "2" { $dgType = "address" }
            "3" { $dgType = "integer" }
            default {
                Write-LogWarn "Invalid selection."
                Press-EnterToContinue
                return
            }
        }
    }
    
    # Get CSV file path
    while ($true) {
        Write-Host ""
        $csvPath = Read-Host "  Enter path to CSV file (or 'q' to cancel)"
        if ([string]::IsNullOrWhiteSpace($csvPath)) {
            Write-LogWarn "No file path provided."
            continue
        }
        if ($csvPath -eq 'q') {
            Write-LogInfo "Cancelled."
            Press-EnterToContinue
            return
        }
        if (-not (Test-Path $csvPath)) {
            Write-LogError "File not found: $csvPath"
            continue
        }
        break
    }
    
    # Handle CRLF
    $tempCsv = ""
    if (Test-WindowsLineEndings -FilePath $csvPath) {
        Write-LogWarn "File has Windows line endings (CRLF). Converting..."
        $tempCsv = Join-Path $env:TEMP "import_$($script:Timestamp).csv"
        Copy-Item $csvPath $tempCsv
        ConvertTo-UnixLineEndings -FilePath $tempCsv
        $csvPath = $tempCsv
    }
    
    # Preview
    Show-CsvPreview -FilePath $csvPath
    
    # Ask about format
    Write-Host "  What does this file contain?" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '1' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Keys only (e.g., domains, subnets)" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '2' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Keys and Values (e.g., domain,action)" -ForegroundColor White
    Write-Host ""
    $formatChoice = Read-Host "  Select [1-2]"
    $csvFormat = switch ($formatChoice) { "1" { "keys_only" }; "2" { "keys_values" }; default { "" } }
    
    if ([string]::IsNullOrWhiteSpace($csvFormat)) {
        Write-LogWarn "Invalid selection."
        if ($tempCsv) { Remove-Item $tempCsv -ErrorAction SilentlyContinue }
        Press-EnterToContinue
        return
    }
    
    # Parse CSV
    Write-LogStep "Parsing CSV file..."
    $parsed = Import-CsvDatagroup -FilePath $csvPath -Format $csvFormat
    if ($null -eq $parsed) {
        if ($tempCsv) { Remove-Item $tempCsv -ErrorAction SilentlyContinue }
        Press-EnterToContinue
        return
    }
    Write-LogOk "Parsed $($parsed.Keys.Count) entries"
    
    # Type mismatch check
    $mismatch = Test-EntryTypes -ExpectedType $dgType -Keys $parsed.Keys
    if ($mismatch.Count -gt 0) {
        Write-Host ""
        Write-LogWarn "Type mismatch detected!"
        Write-LogWarn "Datagroup type is '$dgType' but $($mismatch.Count) entries ($($mismatch.Percent)%) appear to be '$($mismatch.Type)' format."
        Write-Host ""
        Write-Host "  Continue anyway? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $cont = Read-Host
        if ($cont -ne "yes") {
            Write-LogInfo "Aborted by user."
            if ($tempCsv) { Remove-Item $tempCsv -ErrorAction SilentlyContinue }
            Press-EnterToContinue
            return
        }
    }
    
    # Check for CIDR alignment errors (address type only)
    if ($dgType -eq "address") {
        $cidrErrors = Test-CidrAlignment -Keys $parsed.Keys
        if ($cidrErrors.Count -gt 0) {
            Write-Host ""
            Write-LogWarn "CIDR alignment errors detected"
            Write-LogWarn "$($cidrErrors.Count) entries have non-zero host bits that BIG-IP will reject"
            Write-Host ""
            $showCount = [Math]::Min($cidrErrors.Count, 5)
            for ($i = 0; $i -lt $showCount; $i++) {
                Write-Host "          $($cidrErrors[$i].Original) -> $($cidrErrors[$i].Correct)" -ForegroundColor White
            }
            if ($cidrErrors.Count -gt 5) {
                Write-Host "          ... and $($cidrErrors.Count - 5) more" -ForegroundColor White
            }
            Write-Host ""
            Write-LogError "Correct these entries in your CSV and reimport."
            if ($tempCsv) { Remove-Item $tempCsv -ErrorAction SilentlyContinue }
            Press-EnterToContinue
            return
        }
    }
    
    # Prepare final arrays
    if ($restoreMode -eq "merge") {
        Write-LogStep "Reading existing entries for merge..."
        $existing = Get-DatagroupRecordsRemote -Partition $partition -Name $dgName
        $merged = @{}
        foreach ($rec in $existing) { $merged[$rec.Key] = $rec.Value }
        for ($i = 0; $i -lt $parsed.Keys.Count; $i++) { $merged[$parsed.Keys[$i]] = $parsed.Values[$i] }
        
        $newEntries = $merged.Count - $existing.Count
        Write-LogInfo "Existing: $($existing.Count), New unique: $newEntries, Final: $($merged.Count)"
        
        $finalKeys = @($merged.Keys)
        $finalValues = @($merged.Values)
    } else {
        # Overwrite or new: Deduplicate CSV entries
        $dedup = @{}
        for ($i = 0; $i -lt $parsed.Keys.Count; $i++) {
            $dedup[$parsed.Keys[$i]] = $parsed.Values[$i]
        }
        $dedupRemoved = $parsed.Keys.Count - $dedup.Count
        if ($dedupRemoved -gt 0) {
            Write-LogInfo "$dedupRemoved duplicate entries removed, $($dedup.Count) unique entries"
        }
        $finalKeys = @($dedup.Keys)
        $finalValues = @($dedup.Values)
    }
    
    # Build records and apply
    Write-LogStep "Building datagroup records..."
    $apiType = $(if ($dgType -eq "address") { "ip" } else { $dgType })
    $records = ConvertTo-RecordsJson -Keys $finalKeys -Values $finalValues
    
    if (-not $exists) {
        Write-LogStep "Creating datagroup '/${partition}/${dgName}'..."
        if (-not (New-DatagroupRemote -Partition $partition -Name $dgName -Type $apiType)) {
            Write-LogError "Failed to create datagroup."
            if ($tempCsv) { Remove-Item $tempCsv -ErrorAction SilentlyContinue }
            Press-EnterToContinue
            return
        }
    }
    
    Write-LogStep "Applying $($finalKeys.Count) entries to datagroup..."
    $result = Set-DatagroupRecordsRemote -Partition $partition -Name $dgName -Records $records
    if (-not $result.Success) {
        Write-LogError "Failed to apply records. HTTP $($result.StatusCode)"
        if ($tempCsv) { Remove-Item $tempCsv -ErrorAction SilentlyContinue }
        Press-EnterToContinue
        return
    }
    
    Write-LogOk "Datagroup '/${partition}/${dgName}' saved with $($finalKeys.Count) entries."
    Invoke-PromptSaveConfig
    
    if ($tempCsv) { Remove-Item $tempCsv -ErrorAction SilentlyContinue }
    Press-EnterToContinue
}

function Invoke-CreateUrlCategory {
    Write-LogSection "Create URL Category from CSV"
    
    if (-not (Test-UrlCategoryDbAvailable)) {
        Write-LogError "URL database not available or accessible."
        Write-LogInfo "This feature requires the URL filtering module."
        Press-EnterToContinue
        return
    }
    
    Write-Host ""
    $catName = Read-Host "  Enter URL category name (or 'q' to cancel)"
    if ([string]::IsNullOrWhiteSpace($catName) -or $catName -eq 'q') {
        Write-LogInfo "Cancelled."
        Press-EnterToContinue
        return
    }
    
    $originalName = $catName
    $catName = $catName -replace '[^a-zA-Z0-9_-]', '_'
    if ($catName -ne $originalName) { Write-LogInfo "Category name sanitized to: $catName" }
    
    # Check if exists
    $restoreMode = ""
    if (Test-UrlCategoryExistsRemote -Name $catName) {
        $currentCount = Get-UrlCategoryCountRemote -Name $catName
        Write-LogInfo "URL category '$catName' already exists with $currentCount URLs."
        Write-Host ""
        Write-Host "  How do you want to proceed?" -ForegroundColor White
        Write-Host '    ' -NoNewline; Write-Host '1' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
        Write-Host "Overwrite - Replace all existing URLs" -ForegroundColor White
        Write-Host '    ' -NoNewline; Write-Host '2' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
        Write-Host "Merge     - Add new URLs to existing (deduplicated)" -ForegroundColor White
        Write-Host '    ' -NoNewline; Write-Host '3' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
        Write-Host "Cancel" -ForegroundColor White
        Write-Host ""
        $existChoice = Read-Host "  Select [1-3]"
        switch ($existChoice) {
            "1" { $restoreMode = "overwrite" }
            "2" { $restoreMode = "merge" }
            default {
                Write-LogInfo "Cancelled."
                Press-EnterToContinue
                return
            }
        }
    } else {
        # Check if SSLO version exists
        $ssloName = "sslo-urlCat$catName"
        if (Test-UrlCategoryExistsRemote -Name $ssloName) {
            Write-LogInfo "Found as SSLO category: $ssloName"
            $catName = $ssloName
            $currentCount = Get-UrlCategoryCountRemote -Name $catName
            Write-LogInfo "URL category '$catName' has $currentCount URLs."
            Write-Host ""
            Write-Host "  How do you want to proceed?" -ForegroundColor White
            Write-Host '    ' -NoNewline; Write-Host '1' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
            Write-Host "Overwrite - Replace all existing URLs" -ForegroundColor White
            Write-Host '    ' -NoNewline; Write-Host '2' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
            Write-Host "Merge     - Add new URLs to existing (deduplicated)" -ForegroundColor White
            Write-Host '    ' -NoNewline; Write-Host '3' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
            Write-Host "Cancel" -ForegroundColor White
            Write-Host ""
            $existChoice = Read-Host "  Select [1-3]"
            switch ($existChoice) {
                "1" { $restoreMode = "overwrite" }
                "2" { $restoreMode = "merge" }
                default {
                    Write-LogInfo "Cancelled."
                    Press-EnterToContinue
                    return
                }
            }
        }
    }
    
    # Get CSV file
    while ($true) {
        Write-Host ""
        $csvPath = Read-Host "  Enter path to CSV file (or 'q' to cancel)"
        if ([string]::IsNullOrWhiteSpace($csvPath)) { Write-LogWarn "No file path provided."; continue }
        if ($csvPath -eq 'q') { Write-LogInfo "Cancelled."; Press-EnterToContinue; return }
        if (-not (Test-Path $csvPath)) { Write-LogError "File not found: $csvPath"; continue }
        break
    }
    
    # Handle CRLF
    $tempCsv = ""
    if (Test-WindowsLineEndings -FilePath $csvPath) {
        Write-LogWarn "File has Windows line endings (CRLF). Converting..."
        $tempCsv = Join-Path $env:TEMP "import_cat_$($script:Timestamp).csv"
        Copy-Item $csvPath $tempCsv
        ConvertTo-UnixLineEndings -FilePath $tempCsv
        $csvPath = $tempCsv
    }
    
    Show-CsvPreview -FilePath $csvPath
    
    # Parse CSV - keys only (domains)
    Write-LogStep "Parsing CSV file..."
    $parsed = Import-CsvDatagroup -FilePath $csvPath -Format "keys_only"
    if ($null -eq $parsed) {
        if ($tempCsv) { Remove-Item $tempCsv -ErrorAction SilentlyContinue }
        Press-EnterToContinue
        return
    }
    Write-LogOk "Parsed $($parsed.Keys.Count) entries"
    
    # Convert domains to URL format
    $convertedUrls = @()
    foreach ($domain in $parsed.Keys) {
        $convertedUrls += Format-DomainForUrlCategory -Domain $domain
    }
    
    # Deduplicate converted URLs
    $uniqueUrls = @($convertedUrls | Select-Object -Unique)
    $urlDedupRemoved = $convertedUrls.Count - $uniqueUrls.Count
    if ($urlDedupRemoved -gt 0) {
        Write-LogInfo "$urlDedupRemoved duplicate URLs removed, $($uniqueUrls.Count) unique URLs"
    }
    $convertedUrls = $uniqueUrls
    
    # Build URL objects
    $urlObjects = ConvertTo-UrlObjects -Urls $convertedUrls
    
    # Handle merge
    if ($restoreMode -eq "merge") {
        Write-LogStep "Reading existing URLs for merge..."
        $existing = Get-UrlCategoryEntriesRemote -Name $catName
        $existingSet = @{}
        foreach ($url in $existing) { $existingSet[$url] = $true }
        
        $newUrls = @($convertedUrls | Where-Object { -not $existingSet.ContainsKey($_) })
        
        if ($newUrls.Count -eq 0) {
            Write-LogInfo "No new URLs to add - all entries already exist."
            if ($tempCsv) { Remove-Item $tempCsv -ErrorAction SilentlyContinue }
            Press-EnterToContinue
            return
        }
        
        Write-LogInfo "Existing: $($existing.Count), New unique: $($newUrls.Count)"
        $urlObjects = ConvertTo-UrlObjects -Urls $newUrls
    }
    
    # Default action for new categories
    $defaultAction = ""
    if ($restoreMode -ne "merge") {
        Write-Host ""
        Write-Host "  Select default action for this category:" -ForegroundColor White
        Write-Host '    ' -NoNewline; Write-Host '1' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
        Write-Host "allow   - Allow traffic (use for bypass lists)" -ForegroundColor White
        Write-Host '    ' -NoNewline; Write-Host '2' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
        Write-Host "block   - Block traffic" -ForegroundColor White
        Write-Host '    ' -NoNewline; Write-Host '3' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
        Write-Host "confirm - Prompt user for confirmation" -ForegroundColor White
        Write-Host ""
        $actionChoice = Read-Host "  Select [1-3] [1]"
        if ([string]::IsNullOrWhiteSpace($actionChoice)) { $actionChoice = "1" }
        $defaultAction = switch ($actionChoice) { "1" { "allow" }; "2" { "block" }; "3" { "confirm" }; default { "allow" } }
    }
    
    # Confirm
    Write-Host ""
    Write-LogInfo "Ready to create URL category:"
    Write-LogInfo "  Name: $catName"
    Write-LogInfo "  URLs: $($urlObjects.Count)"
    if ($defaultAction) { Write-LogInfo "  Action: $defaultAction" }
    if ($restoreMode) { Write-LogInfo "  Mode: $restoreMode" }
    Write-Host ""
    Write-Host "  Proceed? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $confirm = Read-Host
    if ($confirm -ne "yes") {
        Write-LogInfo "Aborted."
        if ($tempCsv) { Remove-Item $tempCsv -ErrorAction SilentlyContinue }
        Press-EnterToContinue
        return
    }
    
    # Apply
    if ($restoreMode -eq "overwrite") {
        Write-LogStep "Replacing URLs in category '$catName'..."
        if (-not (Set-UrlCategoryEntriesRemote -Name $catName -Urls $urlObjects)) {
            Write-LogError "Failed to update URL category."
            if ($tempCsv) { Remove-Item $tempCsv -ErrorAction SilentlyContinue }
            Press-EnterToContinue
            return
        }
    } elseif ([string]::IsNullOrWhiteSpace($restoreMode)) {
        # Create new category (empty first, then populate)
        Write-LogStep "Creating URL category '$catName'..."
        if (-not (New-UrlCategoryRemote -Name $catName -DefaultAction $defaultAction -Urls @())) {
            Write-LogError "Failed to create URL category."
            if ($tempCsv) { Remove-Item $tempCsv -ErrorAction SilentlyContinue }
            Press-EnterToContinue
            return
        }
        Write-LogOk "URL category created"
        Write-LogStep "Populating $($urlObjects.Count) URLs..."
        if (-not (Set-UrlCategoryEntriesRemote -Name $catName -Urls $urlObjects)) {
            Write-LogError "Failed to populate URL category."
            Write-LogWarn "Category '$catName' exists but is empty. Retry with overwrite."
            if ($tempCsv) { Remove-Item $tempCsv -ErrorAction SilentlyContinue }
            Press-EnterToContinue
            return
        }
    } else {
        Write-LogStep "Adding URLs to existing category '$catName'..."
        if (-not (Add-UrlCategoryEntriesRemote -Name $catName -NewUrls $urlObjects)) {
            Write-LogError "Failed to update URL category."
            if ($tempCsv) { Remove-Item $tempCsv -ErrorAction SilentlyContinue }
            Press-EnterToContinue
            return
        }
    }
    
    Write-LogOk "URL category '$catName' created successfully with $($urlObjects.Count) URLs."
    Invoke-PromptSaveConfig
    if ($tempCsv) { Remove-Item $tempCsv -ErrorAction SilentlyContinue }
    Press-EnterToContinue
}

# Option 3: Delete Datagroup or URL Category
function Invoke-DeleteMenu {
    Write-LogSection "Delete Datagroup or URL Category"
    
    Write-Host ""
    Write-Host "  What would you like to delete?" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '1' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Datagroup" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '2' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "URL Category" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '0' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Cancel" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "  Select [0-2]"
    
    switch ($choice) {
        "1" { Invoke-DeleteDatagroup }
        "2" { Invoke-DeleteUrlCategory }
        default { Write-LogInfo "Cancelled."; Press-EnterToContinue }
    }
}

function Invoke-DeleteDatagroup {
    Write-LogSection "Delete Datagroup"
    
    $partition = Select-Partition -Prompt "Select partition containing datagroup to delete"
    if ([string]::IsNullOrWhiteSpace($partition)) { Write-LogInfo "Cancelled."; Press-EnterToContinue; return }
    
    $selection = Select-Datagroup -Partition $partition -Prompt "Enter datagroup name to delete"
    if ($null -eq $selection) { Press-EnterToContinue; return }
    
    $dgName = $selection.Name
    
    if (Test-ProtectedDatagroup -Name $dgName) {
        Write-LogError "Datagroup '$dgName' is a protected BIG-IP system datagroup."
        Write-LogError "This operation is blocked for safety."
        Press-EnterToContinue
        return
    }
    
    $dgType = Get-DatagroupTypeRemote -Partition $partition -Name $dgName
    $records = Get-DatagroupRecordsRemote -Partition $partition -Name $dgName
    
    Write-Host ""
    Write-LogWarn "You are about to delete the following datagroup:"
    Write-LogInfo "  Path:    /${partition}/${dgName}"
    Write-LogInfo "  Type:    $dgType"
    Write-LogInfo "  Records: $($records.Count)"
    Write-Host ""
    
    if ($script:BACKUPS_ENABLED -eq 1) {
        Write-LogStep "Creating backup before deletion..."
        $backupFile = Backup-Datagroup -Partition $partition -Name $dgName
        if ($backupFile) {
            Write-LogOk "Backup saved: $backupFile"
        } else {
            Write-LogWarn "Could not create backup."
            Write-Host "  Continue without backup? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $cont = Read-Host
            if ($cont -ne "yes") { Write-LogInfo "Aborted."; Press-EnterToContinue; return }
        }
    }
    
    Write-Host ""
    Write-Host "  Type DELETE to confirm: " -NoNewline -ForegroundColor Red
    $confirm = Read-Host
    if ($confirm -cne "DELETE") { Write-LogInfo "Aborted."; Press-EnterToContinue; return }
    
    Write-LogStep "Deleting datagroup '/${partition}/${dgName}'..."
    if (Remove-DatagroupRemote -Partition $partition -Name $dgName) {
        Write-LogOk "Datagroup '/${partition}/${dgName}' deleted successfully."
    } else {
        Write-LogError "Failed to delete datagroup."
        Press-EnterToContinue
        return
    }
    
    Invoke-PromptSaveConfig
    Press-EnterToContinue
}

function Invoke-DeleteUrlCategory {
    Write-LogSection "Delete URL Category"
    
    if (-not (Test-UrlCategoryDbAvailable)) {
        Write-LogError "URL database not available or accessible."
        Press-EnterToContinue
        return
    }
    
    Write-Host ""
    Write-Host -NoNewline "    "; Write-Host -NoNewline "1" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " List all categories" -ForegroundColor White
    Write-Host -NoNewline "    "; Write-Host -NoNewline "0" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Cancel" -ForegroundColor White
    Write-Host ""
    $catInput = Read-Host "  Enter URL category name or select [0-1]"
    
    $selectedCategory = ""
    
    switch ($catInput) {
        "0" { Write-LogInfo "Cancelled."; Press-EnterToContinue; return }
        "" { Write-LogInfo "Cancelled."; Press-EnterToContinue; return }
        "1" {
            Write-LogStep "Retrieving URL categories..."
            $categories = Get-UrlCategoryListRemote
            if ($categories.Count -eq 0) { Write-LogError "No URL categories found."; Press-EnterToContinue; return }
            
            Write-Host ""
            Write-Host "  Available URL Categories:" -ForegroundColor White
            Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor Cyan
            for ($i = 0; $i -lt $categories.Count; $i++) {
                Write-Host "    " -NoNewline; Write-Host ($i + 1).ToString().PadLeft(3) -NoNewline -ForegroundColor Yellow; Write-Host ") " -NoNewline -ForegroundColor White
                Write-Host $categories[$i] -ForegroundColor White
            }
            Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor Cyan
            Write-Host '      ' -NoNewline; Write-Host '0' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
            Write-Host "Cancel" -ForegroundColor White
            Write-Host ""
            
            $catChoice = Read-Host "  Select URL category [0-$($categories.Count)]"
            if ($catChoice -eq "0" -or [string]::IsNullOrWhiteSpace($catChoice)) { Write-LogInfo "Cancelled."; Press-EnterToContinue; return }
            $num = 0
            if ([int]::TryParse($catChoice, [ref]$num) -and $num -ge 1 -and $num -le $categories.Count) {
                $selectedCategory = $categories[$num - 1]
            } else { Write-LogWarn "Invalid selection."; Press-EnterToContinue; return }
        }
        default {
            $selectedCategory = $catInput
            if (-not (Test-UrlCategoryExistsRemote -Name $selectedCategory)) {
                $ssloName = "sslo-urlCat$selectedCategory"
                if (Test-UrlCategoryExistsRemote -Name $ssloName) {
                    Write-LogInfo "Found as SSLO category: $ssloName"
                    $selectedCategory = $ssloName
                } else {
                    Write-LogError "Category '$selectedCategory' not found."
                    Press-EnterToContinue
                    return
                }
            }
        }
    }
    
    $urlCount = Get-UrlCategoryCountRemote -Name $selectedCategory
    
    Write-Host ""
    Write-LogWarn "You are about to delete the following URL category:"
    Write-LogInfo "  Category: $selectedCategory"
    Write-LogInfo "  URLs:     $urlCount"
    Write-Host ""
    
    if ($script:BACKUPS_ENABLED -eq 1) {
        Write-LogStep "Creating backup before deletion..."
        $backupFile = Backup-UrlCategory -CatName $selectedCategory
        if ($backupFile) { Write-LogOk "Backup saved: $backupFile" }
        else {
            Write-LogWarn "Could not create backup."
            Write-Host "  Continue without backup? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $cont = Read-Host
            if ($cont -ne "yes") { Write-LogInfo "Aborted."; Press-EnterToContinue; return }
        }
    }
    
    Write-Host ""
    Write-Host "  Type DELETE to confirm: " -NoNewline -ForegroundColor Red
    $confirm = Read-Host
    if ($confirm -cne "DELETE") { Write-LogInfo "Aborted."; Press-EnterToContinue; return }
    
    Write-LogStep "Deleting URL category '$selectedCategory'..."
    if (Remove-UrlCategoryRemote -Name $selectedCategory) {
        Write-LogOk "URL category '$selectedCategory' deleted successfully."
    } else {
        Write-LogError "Failed to delete URL category."
        Press-EnterToContinue
        return
    }
    
    Invoke-PromptSaveConfig
    Press-EnterToContinue
}

# Option 4: Export to CSV
function Invoke-ExportToCsv {
    Write-LogSection "Export to CSV"
    
    Write-Host ""
    Write-Host "  What would you like to export?" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '1' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Datagroup" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '2' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "URL Category" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '0' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Cancel" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "  Select [0-2]"
    
    switch ($choice) {
        "1" { Invoke-ExportDatagroup }
        "2" { Invoke-ExportUrlCategory }
        default { Write-LogInfo "Cancelled."; Press-EnterToContinue }
    }
}

function Invoke-ExportDatagroup {
    Write-LogSection "Export Datagroup to CSV"
    
    $partition = Select-Partition -Prompt "Select partition containing datagroup to export"
    if ([string]::IsNullOrWhiteSpace($partition)) { Write-LogInfo "Cancelled."; Press-EnterToContinue; return }
    
    $selection = Select-Datagroup -Partition $partition -Prompt "Enter datagroup name to export"
    if ($null -eq $selection) { Press-EnterToContinue; return }
    
    $dgName = $selection.Name
    $safePartition = $partition -replace '/', '_'
    $defaultPath = Join-Path $script:BACKUP_DIR "${safePartition}_${dgName}_internal_$($script:Timestamp).csv"
    Write-Host ""
    $exportPath = Read-Host "  Export path [$defaultPath]"
    if ([string]::IsNullOrWhiteSpace($exportPath)) { $exportPath = $defaultPath }
    
    # Ensure directory exists
    $exportDir = Split-Path $exportPath -Parent
    if ($exportDir -and -not (Test-Path $exportDir)) {
        try { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }
        catch { Write-LogError "Could not create directory: $exportDir"; Press-EnterToContinue; return }
    }
    
    Write-LogStep "Exporting datagroup..."
    $dgType = Get-DatagroupTypeRemote -Partition $partition -Name $dgName
    $records = Get-DatagroupRecordsRemote -Partition $partition -Name $dgName
    
    $lines = @(
        "# Datagroup Export: /${partition}/${dgName}",
        "# Partition: $partition",
        "# Type: $dgType",
        "# Exported: $(Get-Date)",
        "# Format: key,value",
        "#"
    )
    foreach ($rec in $records) { $lines += "$($rec.Key),$($rec.Value)" }
    
    try {
        $lines | Out-File -FilePath $exportPath -Encoding UTF8
        $dataCount = @($lines | Where-Object { $_ -and -not $_.StartsWith('#') }).Count
        Write-LogOk "Exported $dataCount records to: $exportPath"
    } catch {
        Write-LogError "Export failed."
    }
    
    Press-EnterToContinue
}

function Invoke-ExportUrlCategory {
    Write-LogSection "Export URL Category to CSV"
    
    if (-not (Test-UrlCategoryDbAvailable)) {
        Write-LogError "URL database not available or accessible."
        Press-EnterToContinue
        return
    }
    
    # Select category
    Write-Host ""
    Write-Host -NoNewline "    "; Write-Host -NoNewline "1" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " List all categories" -ForegroundColor White
    Write-Host -NoNewline "    "; Write-Host -NoNewline "0" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Cancel" -ForegroundColor White
    Write-Host ""
    $catInput = Read-Host "  Enter URL category name or select [0-1]"
    
    $selectedCategory = ""
    switch ($catInput) {
        "0" { Write-LogInfo "Cancelled."; Press-EnterToContinue; return }
        "" { Write-LogInfo "Cancelled."; Press-EnterToContinue; return }
        "1" {
            Write-LogStep "Retrieving URL categories..."
            $categories = Get-UrlCategoryListRemote
            if ($categories.Count -eq 0) { Write-LogError "No URL categories found."; Press-EnterToContinue; return }
            
            Write-Host ""
            Write-Host "  Available URL Categories:" -ForegroundColor White
            Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor Cyan
            for ($i = 0; $i -lt $categories.Count; $i++) {
                Write-Host "    " -NoNewline; Write-Host ($i + 1).ToString().PadLeft(3) -NoNewline -ForegroundColor Yellow; Write-Host ") " -NoNewline -ForegroundColor White
                Write-Host $categories[$i] -ForegroundColor White
            }
            Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor Cyan
            Write-Host '      ' -NoNewline; Write-Host '0' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
            Write-Host "Cancel" -ForegroundColor White
            Write-Host ""
            $catChoice = Read-Host "  Select [0-$($categories.Count)]"
            if ($catChoice -eq "0" -or [string]::IsNullOrWhiteSpace($catChoice)) { Write-LogInfo "Cancelled."; Press-EnterToContinue; return }
            $num = 0
            if ([int]::TryParse($catChoice, [ref]$num) -and $num -ge 1 -and $num -le $categories.Count) {
                $selectedCategory = $categories[$num - 1]
            } else { Write-LogWarn "Invalid selection."; Press-EnterToContinue; return }
        }
        default {
            $selectedCategory = $catInput
            if (-not (Test-UrlCategoryExistsRemote -Name $selectedCategory)) {
                $ssloName = "sslo-urlCat$selectedCategory"
                if (Test-UrlCategoryExistsRemote -Name $ssloName) {
                    Write-LogInfo "Found as SSLO category: $ssloName"
                    $selectedCategory = $ssloName
                } else {
                    Write-LogError "Category '$selectedCategory' not found."
                    Press-EnterToContinue
                    return
                }
            }
        }
    }
    
    Write-LogInfo "Selected category: $selectedCategory"
    $urlCount = Get-UrlCategoryCountRemote -Name $selectedCategory
    if ($urlCount -eq 0) { Write-LogWarn "Category '$selectedCategory' has no URLs."; Press-EnterToContinue; return }
    Write-LogInfo "URLs in category: $urlCount"
    
    $safeName = $selectedCategory -replace '[^a-zA-Z0-9_-]', '_'
    $defaultPath = Join-Path $script:BACKUP_DIR "urlcat_${safeName}_$($script:Timestamp).csv"
    Write-Host ""
    $exportPath = Read-Host "  Export path [$defaultPath]"
    if ([string]::IsNullOrWhiteSpace($exportPath)) { $exportPath = $defaultPath }
    
    Write-Host ""
    Write-Host "  Export format:" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '1' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Domain only (e.g., example.com)" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '2' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Full URL format (e.g., https://example.com/)" -ForegroundColor White
    Write-Host ""
    $formatChoice = Read-Host "  Select [1-2] [1]"
    if ([string]::IsNullOrWhiteSpace($formatChoice)) { $formatChoice = "1" }
    $stripProtocol = ($formatChoice -eq "1")
    
    $exportDir = Split-Path $exportPath -Parent
    if ($exportDir -and -not (Test-Path $exportDir)) {
        try { New-Item -Path $exportDir -ItemType Directory -Force | Out-Null }
        catch { Write-LogError "Could not create directory: $exportDir"; Press-EnterToContinue; return }
    }
    
    Write-LogStep "Exporting URL category..."
    $entries = Get-UrlCategoryEntriesRemote -Name $selectedCategory
    
    $lines = @(
        "# URL Category Export: $selectedCategory",
        "# Exported: $(Get-Date)",
        "# Format: one URL per line",
        "#"
    )
    foreach ($url in $entries) {
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        if ($stripProtocol) {
            $domain = $url -replace '^https?://', '' -replace '/.*$', '' -replace '^\\\*\.', '.' -replace '^\*\.', '.'
            $lines += $domain
        } else {
            $lines += $url
        }
    }
    
    try {
        $lines | Out-File -FilePath $exportPath -Encoding UTF8
        $dataCount = @($lines | Where-Object { $_ -and -not $_.StartsWith('#') }).Count
        Write-LogOk "Exported $dataCount URLs to: $exportPath"
    } catch {
        Write-LogError "Export failed."
    }
    
    Press-EnterToContinue
}

# =============================================================================
# OPTION 6: FLEET LOOKING GLASS
# =============================================================================

function Invoke-FleetLookingGlass {
    Write-LogSection "DGCat-Admin Search"
    
    if ($script:FleetHosts.Count -eq 0) {
        Write-LogError "No fleet configuration loaded. Configure fleet.conf to use this feature."
        Press-EnterToContinue
        return
    }
    
    Write-Host ""
    Write-Host "  What would you like to inspect?" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '1' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Datagroup" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '2' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "URL Category" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '0' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Cancel" -ForegroundColor White
    Write-Host ""
    $typeChoice = Read-Host "  Select [0-2]"
    
    $objectType = ""
    $objectName = ""
    $partition = ""
    
    switch ($typeChoice) {
        "1" {
            $objectType = "datagroup"
            if ($script:PARTITIONS.Count -gt 1) {
                $partition = Select-Partition
                if (-not $partition) { return }
            } else {
                $partition = $script:PARTITIONS[0]
            }
            $dgSelection = Select-Datagroup -Partition $partition -Prompt "Enter datagroup name"
            if ($null -eq $dgSelection) { return }
            $objectName = $dgSelection.Name
        }
        "2" {
            $objectType = "urlcat"
            Write-Host ""
            $objectName = Read-Host "  Enter URL category name (or 'q' to cancel)"
            if ([string]::IsNullOrWhiteSpace($objectName) -or $objectName -eq "q") { return }
            # Resolve SSLO category name if needed
            if (-not (Test-UrlCategoryExistsRemote -Name $objectName)) {
                $ssloName = "sslo-urlCat$objectName"
                if (Test-UrlCategoryExistsRemote -Name $ssloName) {
                    Write-LogInfo "Found as SSLO category: $ssloName"
                    $objectName = $ssloName
                }
            }
        }
        default { return }
    }
    
    # Select search scope
    Write-Host ""
    Write-Host "  Select search scope:" -ForegroundColor White
    Write-Host ""
    Write-Host -NoNewline "    "; Write-Host -NoNewline "1" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " All fleet hosts" -ForegroundColor White
    Write-Host -NoNewline "    "; Write-Host -NoNewline "2" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Select by site" -ForegroundColor White
    Write-Host -NoNewline "    "; Write-Host -NoNewline "3" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Select by host" -ForegroundColor White
    Write-Host -NoNewline "    "; Write-Host -NoNewline "0" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Cancel" -ForegroundColor White
    Write-Host ""
    $scopeType = Read-Host "  Select [0-3]"
    
    $targetHosts = @()
    $targetSites = @()
    
    switch ($scopeType) {
        "1" {
            $targetHosts = @($script:FleetHosts)
            $targetSites = @($script:FleetSites)
        }
        "2" {
            Write-Host ""
            for ($s = 0; $s -lt $script:FleetUniqueSites.Count; $s++) {
                $site = $script:FleetUniqueSites[$s]
                $siteCount = Get-SiteHostCount -SiteId $site
                $siteHostWord = $(if ($siteCount -eq 1) { "host" } else { "hosts" })
                Write-Host -NoNewline "    "; Write-Host -NoNewline "$($s + 1)" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White
                Write-Host " $site ($siteCount $siteHostWord)" -ForegroundColor White
            }
            Write-Host ""
            $siteInput = Read-Host "  Enter site numbers (comma-separate for multiple)"
            if ([string]::IsNullOrWhiteSpace($siteInput)) { return }
            
            $siteSelections = $siteInput -split ',' | ForEach-Object { $_.Trim() }
            foreach ($sel in $siteSelections) {
                if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $script:FleetUniqueSites.Count) {
                    $selectedSite = $script:FleetUniqueSites[[int]$sel - 1]
                    for ($i = 0; $i -lt $script:FleetHosts.Count; $i++) {
                        if ($script:FleetSites[$i] -eq $selectedSite) {
                            $targetHosts += $script:FleetHosts[$i]
                            $targetSites += $script:FleetSites[$i]
                        }
                    }
                }
            }
        }
        "3" {
            Write-Host ""
            for ($h = 0; $h -lt $script:FleetHosts.Count; $h++) {
                Write-Host -NoNewline "    "; Write-Host -NoNewline "$($h + 1)" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White
                Write-Host " $($script:FleetHosts[$h]) ($($script:FleetSites[$h]))" -ForegroundColor White
            }
            Write-Host ""
            $hostInput = Read-Host "  Enter host numbers (comma-separate for multiple)"
            if ([string]::IsNullOrWhiteSpace($hostInput)) { return }
            
            $hostSelections = $hostInput -split ',' | ForEach-Object { $_.Trim() }
            foreach ($sel in $hostSelections) {
                if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $script:FleetHosts.Count) {
                    $idx = [int]$sel - 1
                    $targetHosts += $script:FleetHosts[$idx]
                    $targetSites += $script:FleetSites[$idx]
                }
            }
        }
        default { return }
    }
    
    if ($targetHosts.Count -eq 0) {
        Write-LogWarn "No valid scope selected."
        Press-EnterToContinue
        return
    }
    
    # Pull from fleet
    Clear-Host
    Write-Host ""
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "    FLEET QUERY: $objectName" -ForegroundColor White
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    $origHost = $script:RemoteHost
    
    $entryHosts = @{}       # entry -> list of hosts
    $pulledHosts = @()
    $hostCounts = @{}
    $hostSites = @{}
    
    for ($h = 0; $h -lt $targetHosts.Count; $h++) {
        $hostName = $targetHosts[$h]
        $siteId = $targetSites[$h]
        $hostSites[$hostName] = $siteId
        
        Write-Host "`r  [....] $hostName ($siteId)" -NoNewline -ForegroundColor White
        
        $script:RemoteHost = $hostName
        
        # Test connectivity
        $connResult = Invoke-F5Get -Endpoint "/mgmt/tm/sys/version"
        if (-not $connResult.Success) {
            Write-Host "`r$(' ' * 80)" -NoNewline
            Write-Host "`r  [FAIL]" -NoNewline -ForegroundColor Red
            Write-Host " $hostName ($siteId) - Connection failed" -ForegroundColor White
            continue
        }
        
        # Pull entries
        $entries = @()
        if ($objectType -eq "datagroup") {
            $records = Get-DatagroupRecordsRemote -Partition $partition -Name $objectName
            if ($records.Count -eq 0) {
                # Check if object exists vs empty
                $existResult = Invoke-F5Get -Endpoint "/mgmt/tm/ltm/data-group/internal/~${partition}~${objectName}"
                if (-not $existResult.Success) {
                    Write-Host "`r$(' ' * 80)" -NoNewline
                    Write-Host "`r  [FAIL]" -NoNewline -ForegroundColor Red
                    Write-Host " $hostName ($siteId) - Object not found" -ForegroundColor White
                    continue
                }
            }
            foreach ($rec in $records) {
                $entry = $rec.Key
                if (-not $entryHosts.ContainsKey($entry)) {
                    $entryHosts[$entry] = @()
                }
                $entryHosts[$entry] += $hostName
            }
            $entries = $records
        } else {
            $urls = Get-UrlCategoryEntriesRemote -Name $objectName
            if ($urls.Count -eq 0) {
                $existResult = Invoke-F5Get -Endpoint "/mgmt/tm/sys/url-db/url-category/~Common~${objectName}"
                if (-not $existResult.Success) {
                    Write-Host "`r$(' ' * 80)" -NoNewline
                    Write-Host "`r  [FAIL]" -NoNewline -ForegroundColor Red
                    Write-Host " $hostName ($siteId) - Object not found" -ForegroundColor White
                    continue
                }
            }
            foreach ($url in $urls) {
                if (-not $entryHosts.ContainsKey($url)) {
                    $entryHosts[$url] = @()
                }
                $entryHosts[$url] += $hostName
            }
            $entries = $urls
        }
        
        $pulledHosts += $hostName
        $hostCounts[$hostName] = $entries.Count
        Write-Host "`r$(' ' * 80)" -NoNewline
        Write-Host "`r  [ OK ]" -NoNewline -ForegroundColor Green
        Write-Host " $hostName ($siteId) - $($entries.Count) entries" -ForegroundColor White
    }
    
    $script:RemoteHost = $origHost
    
    Write-Host "  ──────────────────────────────────────────────────────────────" -ForegroundColor Cyan
    
    $totalPulled = $pulledHosts.Count
    
    if ($totalPulled -eq 0) {
        Write-LogError "No hosts returned data."
        Press-EnterToContinue
        return
    }
    
    # Build display info
    if ($objectType -eq "datagroup") {
        $objectDisplay = "/${partition}/${objectName} (Datagroup)"
    } else {
        $objectDisplay = "${objectName} (URL Category)"
    }
    
    # Viewer loop
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "                           DGCat-Admin Search                            " -ForegroundColor White
        Write-Host "  ╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host -NoNewline "  Object: " -ForegroundColor White
        Write-Host $objectDisplay -ForegroundColor Yellow
        Write-Host -NoNewline "  Hosts:  " -ForegroundColor White
        Write-Host -NoNewline "$totalPulled" -ForegroundColor Green
        Write-Host " of $($targetHosts.Count) pulled | $($entryHosts.Count) unique entries across fleet" -ForegroundColor White
        Write-Host ""
        # Host counts
        foreach ($fleetHost in $pulledHosts) {
            $site = $hostSites[$fleetHost]
            Write-Host -NoNewline "    " -ForegroundColor White
            Write-Host -NoNewline "*" -ForegroundColor Green
            Write-Host " $fleetHost ($site): $($hostCounts[$fleetHost]) entries" -ForegroundColor White
        }
        Write-Host ""
        Write-Host "  ──────────────────────────────────────────────────────────────────────────" -ForegroundColor Cyan
        Write-Host ""
        Write-Host -NoNewline "  "; Write-Host -NoNewline "s" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host -NoNewline " Search      " -ForegroundColor White
        Write-Host -NoNewline "d" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host -NoNewline " Diff      " -ForegroundColor White
        Write-Host -NoNewline "q" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Quit" -ForegroundColor White
        Write-Host ""
        $input = Read-Host "  Select option"
        
        if ([string]::IsNullOrWhiteSpace($input)) { continue }
        
        if ($input -eq "q" -or $input -eq "Q") { break }
        
        if ($input -eq "d" -or $input -eq "D") {
            Clear-Host
            Write-Host ""
            Write-Host "  ╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
            Write-Host "                           DGCat-Admin Search                            " -ForegroundColor White
            Write-Host "  ╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
            Write-Host -NoNewline "  Object: " -ForegroundColor White
            Write-Host $objectDisplay -ForegroundColor Yellow
            Write-Host -NoNewline "  Hosts:  " -ForegroundColor White
            Write-Host -NoNewline "$totalPulled" -ForegroundColor Green
            Write-Host " of $($targetHosts.Count) pulled | $($entryHosts.Count) unique entries across fleet" -ForegroundColor White
            Write-Host ""
            Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
            if ($objectType -eq "datagroup") {
                $diffLabel = "Datagroup: /${partition}/${objectName}"
            } else {
                $diffLabel = "URL Category: ${objectName}"
            }
            Write-Host "    $diffLabel" -ForegroundColor White
            Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
            Write-Host ""
            
            $driftCount = 0
            $consistentCount = 0
            
            foreach ($entry in $entryHosts.Keys) {
                $hostsWithEntry = $entryHosts[$entry]
                
                if ($hostsWithEntry.Count -lt $totalPulled) {
                    $driftCount++
                    Write-Host "  $entry" -ForegroundColor Yellow
                    Write-Host "  ──────────────────────────────────────────────────────────────" -ForegroundColor Cyan
                    foreach ($fleetHost in $pulledHosts) {
                        $site = $hostSites[$fleetHost]
                        if ($hostsWithEntry -contains $fleetHost) {
                            Write-Host "    $fleetHost ($site)" -ForegroundColor White
                        } else {
                            Write-Host -NoNewline "    $fleetHost ($site) - " -ForegroundColor White; Write-Host "missing" -ForegroundColor Red
                        }
                    }
                    Write-Host ""
                } else {
                    $consistentCount++
                }
            }
            
            if ($driftCount -eq 0) {
                Write-Host "  All $($entryHosts.Count) entries consistent across all $totalPulled hosts." -ForegroundColor Green
            } else {
                Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
                Write-Host "  $driftCount inconsistent | $consistentCount consistent across all hosts" -ForegroundColor White
            }
            Write-Host ""
            Press-EnterToContinue
            continue
        }
        
        if ($input -eq "s" -or $input -eq "S") {
            Write-Host ""
            $searchTerm = Read-Host "  Enter search pattern"
            if ([string]::IsNullOrWhiteSpace($searchTerm)) { continue }
            
            Clear-Host
            Write-Host ""
            Write-Host "  ╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
            Write-Host "                           DGCat-Admin Search                            " -ForegroundColor White
            Write-Host "  ╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
            Write-Host -NoNewline "  Object: " -ForegroundColor White
            Write-Host $objectDisplay -ForegroundColor Yellow
            Write-Host -NoNewline "  Hosts:  " -ForegroundColor White
            Write-Host -NoNewline "$totalPulled" -ForegroundColor Green
            Write-Host " of $($targetHosts.Count) pulled | $($entryHosts.Count) unique entries across fleet" -ForegroundColor White
            Write-Host ""
            Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
            Write-Host "    SEARCH: $searchTerm" -ForegroundColor White
            Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
            Write-Host ""
            
            $searchLower = $searchTerm.ToLower()
            $matchCount = 0
            
            # Collect matching entries and classify by consistency
            $consistentMatches = @()
            $inconsistentMatches = @()
            
            foreach ($entry in $entryHosts.Keys) {
                if ($entry.ToLower().Contains($searchLower)) {
                    $matchCount++
                    if ($entryHosts[$entry].Count -ge $totalPulled) {
                        $consistentMatches += $entry
                    } else {
                        $inconsistentMatches += $entry
                    }
                }
            }
            
            if ($matchCount -eq 0) {
                Write-Host "  No matches for '$searchTerm'" -ForegroundColor White
            } else {
                # Display consistent matches (on all hosts) - listed once
                if ($consistentMatches.Count -gt 0) {
                    Write-Host "  Matches on all $totalPulled hosts ($($consistentMatches.Count)):" -ForegroundColor Green
                    Write-Host "  ──────────────────────────────────────────────────────────────" -ForegroundColor Cyan
                    foreach ($m in $consistentMatches) {
                        Write-Host "          $m" -ForegroundColor Yellow
                    }
                    Write-Host ""
                }
                
                # Display inconsistent matches (some hosts) - per-host detail
                if ($inconsistentMatches.Count -gt 0) {
                    Write-Host "  Partial matches ($($inconsistentMatches.Count)):" -ForegroundColor Yellow
                    Write-Host "  ──────────────────────────────────────────────────────────────" -ForegroundColor Cyan
                    foreach ($entry in $inconsistentMatches) {
                        Write-Host "  $entry" -ForegroundColor Yellow
                        foreach ($fleetHost in $pulledHosts) {
                            $site = $hostSites[$fleetHost]
                            if ($entryHosts[$entry] -contains $fleetHost) {
                                Write-Host "    $fleetHost ($site)" -ForegroundColor White
                            } else {
                                Write-Host -NoNewline "    $fleetHost ($site) - " -ForegroundColor White; Write-Host "missing" -ForegroundColor Red
                            }
                        }
                        Write-Host ""
                    }
                }
                
                Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
                Write-Host -NoNewline "  $matchCount unique matches | " -ForegroundColor White
                Write-Host -NoNewline "$($consistentMatches.Count) on all hosts" -ForegroundColor Green
                Write-Host -NoNewline ", " -ForegroundColor White
                Write-Host "$($inconsistentMatches.Count) inconsistent" -ForegroundColor Yellow
            }
            Write-Host ""
            Press-EnterToContinue
            continue
        }
        
        Write-LogWarn "Invalid selection."
        Press-EnterToContinue
    }
}

# =============================================================================
# FLEET BACKUP
# =============================================================================

function Invoke-FleetBackup {
    Write-LogSection "Backup"
    
    if ($script:FleetHosts.Count -eq 0) {
        Write-LogError "No fleet configuration loaded. Configure fleet.conf to use this feature."
        Press-EnterToContinue
        return
    }
    
    Write-Host ""
    Write-Host "  What would you like to backup?" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '1' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Datagroup" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '2' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "URL Category" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '0' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Cancel" -ForegroundColor White
    Write-Host ""
    $typeChoice = Read-Host "  Select [0-2]"
    
    $objectType = ""
    $objectName = ""
    $partition = ""
    
    switch ($typeChoice) {
        "1" {
            $objectType = "datagroup"
            if ($script:PARTITIONS.Count -gt 1) {
                $partition = Select-Partition
                if ([string]::IsNullOrWhiteSpace($partition)) { return }
            } else {
                $partition = $script:PARTITIONS[0]
            }
            $dgSelection = Select-Datagroup -Partition $partition -Prompt "Enter datagroup name"
            if ($null -eq $dgSelection) { return }
            $objectName = $dgSelection.Name
        }
        "2" {
            $objectType = "urlcat"
            Write-Host ""
            $objectName = Read-Host "  Enter URL category name (or 'q' to cancel)"
            if ([string]::IsNullOrWhiteSpace($objectName) -or $objectName -eq "q") { return }
            # Resolve SSLO category name if needed
            if (-not (Test-UrlCategoryExistsRemote -Name $objectName)) {
                $ssloName = "sslo-urlCat$objectName"
                if (Test-UrlCategoryExistsRemote -Name $ssloName) {
                    Write-LogInfo "Found as SSLO category: $ssloName"
                    $objectName = $ssloName
                }
            }
        }
        default { return }
    }
    
    # Select backup scope
    Write-Host ""
    Write-Host "  Select backup scope:" -ForegroundColor White
    Write-Host ""
    Write-Host -NoNewline "    "; Write-Host -NoNewline "1" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " All fleet hosts" -ForegroundColor White
    Write-Host -NoNewline "    "; Write-Host -NoNewline "2" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Select by site" -ForegroundColor White
    Write-Host -NoNewline "    "; Write-Host -NoNewline "3" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Select by host" -ForegroundColor White
    Write-Host -NoNewline "    "; Write-Host -NoNewline "0" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Cancel" -ForegroundColor White
    Write-Host ""
    $scopeType = Read-Host "  Select [0-3]"
    
    $targetHosts = @()
    $targetSites = @()
    
    switch ($scopeType) {
        "1" {
            $targetHosts = @($script:FleetHosts)
            $targetSites = @($script:FleetSites)
        }
        "2" {
            Write-Host ""
            for ($s = 0; $s -lt $script:FleetUniqueSites.Count; $s++) {
                $site = $script:FleetUniqueSites[$s]
                $siteCount = @(Get-SiteHosts -SiteId $site).Count
                $siteHostWord = $(if ($siteCount -eq 1) { "host" } else { "hosts" })
                Write-Host "    $($s + 1)) $site ($siteCount $siteHostWord)" -ForegroundColor White
            }
            Write-Host ""
            $siteInput = Read-Host "  Enter site numbers (comma-separate for multiple)"
            if ([string]::IsNullOrWhiteSpace($siteInput)) { return }
            foreach ($sel in ($siteInput -split ',')) {
                $sel = $sel.Trim()
                $num = 0
                if ([int]::TryParse($sel, [ref]$num) -and $num -ge 1 -and $num -le $script:FleetUniqueSites.Count) {
                    $selectedSite = $script:FleetUniqueSites[$num - 1]
                    for ($i = 0; $i -lt $script:FleetHosts.Count; $i++) {
                        if ($script:FleetSites[$i] -eq $selectedSite) {
                            $targetHosts += $script:FleetHosts[$i]
                            $targetSites += $script:FleetSites[$i]
                        }
                    }
                }
            }
        }
        "3" {
            Write-Host ""
            for ($h = 0; $h -lt $script:FleetHosts.Count; $h++) {
                Write-Host "    $($h + 1)) $($script:FleetHosts[$h]) ($($script:FleetSites[$h]))" -ForegroundColor White
            }
            Write-Host ""
            $hostInput = Read-Host "  Enter host numbers (comma-separate for multiple)"
            if ([string]::IsNullOrWhiteSpace($hostInput)) { return }
            foreach ($sel in ($hostInput -split ',')) {
                $sel = $sel.Trim()
                $num = 0
                if ([int]::TryParse($sel, [ref]$num) -and $num -ge 1 -and $num -le $script:FleetHosts.Count) {
                    $idx = $num - 1
                    $targetHosts += $script:FleetHosts[$idx]
                    $targetSites += $script:FleetSites[$idx]
                }
            }
        }
        default { return }
    }
    
    if ($targetHosts.Count -eq 0) {
        Write-LogWarn "No valid scope selected."
        Press-EnterToContinue
        return
    }
    
    # Execute backup
    Clear-Host
    Write-Host ""
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "    FLEET BACKUP: $objectName" -ForegroundColor White
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    $origHost = $script:RemoteHost
    $successCount = 0
    $failCount = 0
    
    for ($h = 0; $h -lt $targetHosts.Count; $h++) {
        $hostName = $targetHosts[$h]
        $siteId = $targetSites[$h]
        
        Write-Host "`r  [....] $hostName ($siteId)" -NoNewline -ForegroundColor White
        
        $script:RemoteHost = $hostName
        
        # Test connectivity
        $connResult = Invoke-F5Get -Endpoint "/mgmt/tm/sys/version"
        if (-not $connResult.Success) {
            Write-Host "`r$(' ' * 80)" -NoNewline
            Write-Host "`r  [FAIL]" -NoNewline -ForegroundColor Red
            Write-Host " $hostName ($siteId) - Connection failed" -ForegroundColor White
            $failCount++
            continue
        }
        
        # Create backup
        $backupFile = ""
        if ($objectType -eq "datagroup") {
            $backupFile = Backup-RemoteDatagroup -HostName $hostName -Partition $partition -Name $objectName -SiteId $siteId
        } else {
            $backupFile = Backup-RemoteUrlCategory -HostName $hostName -CatName $objectName -SiteId $siteId
        }
        
        if ($backupFile) {
            Write-Host "`r$(' ' * 80)" -NoNewline
            Write-Host "`r  [ OK ]" -NoNewline -ForegroundColor Green
            Write-Host " $hostName ($siteId)" -ForegroundColor White
            $successCount++
        } else {
            Write-Host "`r$(' ' * 80)" -NoNewline
            Write-Host "`r  [FAIL]" -NoNewline -ForegroundColor Red
            Write-Host " $hostName ($siteId) - Backup failed" -ForegroundColor White
            $failCount++
        }
    }
    
    $script:RemoteHost = $origHost
    
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host -NoNewline "  Backup complete: " -ForegroundColor White
    Write-Host -NoNewline "$successCount saved" -ForegroundColor Green
    Write-Host -NoNewline ", " -ForegroundColor White
    Write-Host -NoNewline "$failCount failed" -ForegroundColor Red
    Write-Host " of $($targetHosts.Count) hosts" -ForegroundColor White
    Write-Host ""
    if ($successCount -gt 0) {
        Write-LogInfo "Backups saved to: $($script:BACKUP_DIR)\"
    }
    
    Press-EnterToContinue
}

# =============================================================================
# INTERACTIVE EDITOR
# =============================================================================

function Invoke-EditMenu {
    Write-LogSection "Edit a Datagroup or URL Category"
    
    Write-Host ""
    Write-Host "  What would you like to edit?" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '1' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Datagroup" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '2' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "URL Category" -ForegroundColor White
    Write-Host '    ' -NoNewline; Write-Host '0' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
    Write-Host "Cancel" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "  Select [0-2]"
    
    switch ($choice) {
        "1" {
            $partition = Select-Partition -Prompt "Select partition"
            if ([string]::IsNullOrWhiteSpace($partition)) { Write-LogInfo "Cancelled."; Press-EnterToContinue; return }
            
            $selection = Select-Datagroup -Partition $partition -Prompt "Enter datagroup name to edit"
            if ($null -eq $selection) { Press-EnterToContinue; return }
            
            if (Test-ProtectedDatagroup -Name $selection.Name) {
                Write-LogError "The datagroup '$($selection.Name)' is a protected BIG-IP system datagroup."
                Press-EnterToContinue
                return
            }
            
            Invoke-EditorSubmenu -EditType "datagroup" -Partition $partition -DgName $selection.Name -DgClass $selection.Class
        }
        "2" {
            if (-not (Test-UrlCategoryDbAvailable)) {
                Write-LogError "URL database not available or accessible."
                Press-EnterToContinue
                return
            }
            
            # Category selection
            Write-Host ""
            Write-Host -NoNewline "    "; Write-Host -NoNewline "1" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " List all categories" -ForegroundColor White
            Write-Host -NoNewline "    "; Write-Host -NoNewline "0" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Cancel" -ForegroundColor White
            Write-Host ""
            $catInput = Read-Host "  Enter URL category name or select [0-1]"
            
            $selectedCategory = ""
            switch ($catInput) {
                "0" { Write-LogInfo "Cancelled."; Press-EnterToContinue; return }
                "" { Write-LogInfo "Cancelled."; Press-EnterToContinue; return }
                "1" {
                    Write-LogStep "Retrieving URL categories..."
                    $categories = Get-UrlCategoryListRemote
                    if ($categories.Count -eq 0) { Write-LogError "No URL categories found."; Press-EnterToContinue; return }
                    Write-Host ""
                    Write-Host "  Available URL Categories:" -ForegroundColor White
                    Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor Cyan
                    for ($i = 0; $i -lt $categories.Count; $i++) {
                        Write-Host "    " -NoNewline; Write-Host ($i + 1).ToString().PadLeft(3) -NoNewline -ForegroundColor Yellow; Write-Host ") " -NoNewline -ForegroundColor White
                        Write-Host $categories[$i] -ForegroundColor White
                    }
                    Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor Cyan
                    Write-Host "      " -NoNewline; Write-Host "0" -NoNewline -ForegroundColor Yellow; Write-Host ") Cancel" -ForegroundColor White
                    Write-Host ""
                    $catChoice = Read-Host "  Select [0-$($categories.Count)]"
                    if ($catChoice -eq "0" -or [string]::IsNullOrWhiteSpace($catChoice)) { Write-LogInfo "Cancelled."; Press-EnterToContinue; return }
                    $num = 0
                    if ([int]::TryParse($catChoice, [ref]$num) -and $num -ge 1 -and $num -le $categories.Count) {
                        $selectedCategory = $categories[$num - 1]
                    } else { Write-LogWarn "Invalid selection."; Press-EnterToContinue; return }
                }
                default {
                    $selectedCategory = $catInput
                    if (-not (Test-UrlCategoryExistsRemote -Name $selectedCategory)) {
                        $ssloName = "sslo-urlCat$selectedCategory"
                        if (Test-UrlCategoryExistsRemote -Name $ssloName) {
                            Write-LogInfo "Found as SSLO category: $ssloName"
                            $selectedCategory = $ssloName
                        } else {
                            Write-LogError "Category '$selectedCategory' not found."
                            Press-EnterToContinue
                            return
                        }
                    }
                }
            }
            
            Invoke-EditorSubmenu -EditType "urlcat" -CatName $selectedCategory
        }
        default { Write-LogInfo "Cancelled."; Press-EnterToContinue }
    }
}

function Invoke-EditorSubmenu {
    param(
        [string]$EditType,
        [string]$Partition = "", [string]$DgName = "", [string]$DgClass = "",
        [string]$CatName = ""
    )
    
    # Setup display info
    $dgType = ""
    $displayTitle = "DGCat-Admin Editor"
    $displayInfo1 = ""
    $displayInfo2 = ""
    $entryLabel = "Entries"
    
    if ($EditType -eq "datagroup") {
        $dgType = Get-DatagroupTypeRemote -Partition $Partition -Name $DgName
        $displayInfo1 = "Path:  /${Partition}/${DgName}"
        $displayInfo2 = "Class: $DgClass  |  Type: $dgType"
    } else {
        $displayInfo1 = "URL Category: $CatName"
        $entryLabel = "URLs"
    }
    
    # Load current state
    Write-LogStep "Loading current entries..."
    $workingKeys = [System.Collections.ArrayList]::new()
    $workingValues = [System.Collections.ArrayList]::new()
    $originalKeys = [System.Collections.ArrayList]::new()
    $originalValues = [System.Collections.ArrayList]::new()
    
    if ($EditType -eq "datagroup") {
        $records = Get-DatagroupRecordsRemote -Partition $Partition -Name $DgName
        foreach ($rec in $records) {
            $workingKeys.Add($rec.Key) | Out-Null
            $workingValues.Add($rec.Value) | Out-Null
            $originalKeys.Add($rec.Key) | Out-Null
            $originalValues.Add($rec.Value) | Out-Null
        }
    } else {
        $entries = Get-UrlCategoryEntriesRemote -Name $CatName
        foreach ($url in $entries) {
            $workingKeys.Add($url) | Out-Null
            $workingValues.Add("") | Out-Null
            $originalKeys.Add($url) | Out-Null
            $originalValues.Add("") | Out-Null
        }
    }
    Write-LogOk "Loaded $($workingKeys.Count) entries"
    Start-Sleep -Seconds 1
    
    # Session state
    $currentPage = 1
    $currentFilter = ""
    $currentSort = "original"
    
    # Helper: check for pending changes
    function Test-PendingChanges {
        if ($workingKeys.Count -ne $originalKeys.Count) { return $true }
        for ($i = 0; $i -lt $workingKeys.Count; $i++) {
            if ($workingKeys[$i] -ne $originalKeys[$i] -or $workingValues[$i] -ne $originalValues[$i]) { return $true }
        }
        return $false
    }
    
    # Helper: compute additions and deletions
    function Get-ChangeAnalysis {
        $additions = @()
        $deletions = @()
        $origSet = @{}; foreach ($k in $originalKeys) { $origSet[$k] = $true }
        $workSet = @{}; foreach ($k in $workingKeys) { $workSet[$k] = $true }
        foreach ($k in $originalKeys) { if (-not $workSet.ContainsKey($k)) { $deletions += $k } }
        foreach ($k in $workingKeys) { if (-not $origSet.ContainsKey($k)) { $additions += $k } }
        return @{ Additions = $additions; Deletions = $deletions }
    }
    
    # Main editor loop
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "                             $displayTitle" -ForegroundColor White
        Write-Host "  ╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host "  $displayInfo1" -ForegroundColor White
        if ($displayInfo2) { Write-Host "  $displayInfo2" -ForegroundColor White }
        Write-Host "  ${entryLabel}: $($workingKeys.Count)" -ForegroundColor White
        if (Test-PendingChanges) { Write-Host "  (Pending changes - not yet applied)" -ForegroundColor Yellow }
        
        # Build display entries
        $displayEntries = @()
        for ($i = 0; $i -lt $workingKeys.Count; $i++) {
            if ($EditType -eq "datagroup" -and $workingValues[$i]) {
                $displayEntries += "$($workingKeys[$i])|$($workingValues[$i])"
            } else {
                $displayEntries += $workingKeys[$i]
            }
        }
        
        # Apply filter
        $filteredEntries = @($displayEntries)
        if ($currentFilter) {
            $filteredEntries = @($displayEntries | Where-Object { $_ -match [regex]::Escape($currentFilter) })
        }
        
        # Apply sort
        if ($currentSort -eq "asc") {
            $sortedEntries = @($filteredEntries | Sort-Object)
        } elseif ($currentSort -eq "desc") {
            $sortedEntries = @($filteredEntries | Sort-Object -Descending)
        } else {
            $sortedEntries = @($filteredEntries)
        }
        $totalCount = $sortedEntries.Count
        
        # Pagination
        $pageSize = $script:EDIT_PAGE_SIZE
        $totalPages = [math]::Max(1, [math]::Ceiling($totalCount / $pageSize))
        if ($currentPage -gt $totalPages) { $currentPage = $totalPages }
        if ($currentPage -lt 1) { $currentPage = 1 }
        $startIdx = ($currentPage - 1) * $pageSize
        $endIdx = [math]::Min($startIdx + $pageSize - 1, $totalCount - 1)
        
        # Display entries
        Write-Host ""
        Write-Host "  ──────────────────────────────────────────────────────────────────────────" -ForegroundColor Cyan
        Write-Host ("  {0,-6}  {1,-66}" -f "NUM", "ENTRY") -ForegroundColor White
        Write-Host "  ──────────────────────────────────────────────────────────────────────────" -ForegroundColor Cyan
        
        if ($totalCount -eq 0) {
            Write-Host "  (No matching entries)" -ForegroundColor White
        } else {
            for ($i = $startIdx; $i -le $endIdx; $i++) {
                $entry = $sortedEntries[$i]
                $displayEntry = $(if ($entry.Length -gt 66) { $entry.Substring(0, 63) + "..." } else { $entry })
                Write-Host ("  {0,-6}  {1,-66}" -f ($i + 1), $displayEntry) -ForegroundColor White
            }
        }
        
        Write-Host "  ──────────────────────────────────────────────────────────────────────────" -ForegroundColor Cyan
        
        $showEnd = [math]::Min($endIdx + 1, $totalCount)
        Write-Host "  Showing $($startIdx + 1)-$showEnd of $totalCount entries (Page $currentPage/$totalPages)" -ForegroundColor White
        if ($currentFilter) { Write-Host "  Filter: '$currentFilter'" -ForegroundColor Yellow }
        
        $sortIndicator = switch ($currentSort) { "asc" { "A-Z" }; "desc" { "Z-A" }; default { "Original" } }
        Write-Host "  Sort: $sortIndicator" -ForegroundColor White
        
        # Menu options
        Write-Host ""
        Write-Host "  ──────────────────────────────────────────────────────────────────────────" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  " -NoNewline; Write-Host "n" -NoNewline -ForegroundColor Yellow; Write-Host ") " -NoNewline -ForegroundColor White; Write-Host "Next page    " -NoNewline -ForegroundColor Green
        Write-Host "p" -NoNewline -ForegroundColor Yellow; Write-Host ") " -NoNewline -ForegroundColor White; Write-Host "Previous page    " -NoNewline -ForegroundColor Green
        Write-Host "g" -NoNewline -ForegroundColor Yellow; Write-Host ") " -NoNewline -ForegroundColor White; Write-Host "Go to page" -ForegroundColor Green
        Write-Host "  " -NoNewline; Write-Host "f" -NoNewline -ForegroundColor Yellow; Write-Host ") " -NoNewline -ForegroundColor White; Write-Host "Filter       " -NoNewline -ForegroundColor Green
        Write-Host "c" -NoNewline -ForegroundColor Yellow; Write-Host ") " -NoNewline -ForegroundColor White; Write-Host "Clear filter     " -NoNewline -ForegroundColor Green
        Write-Host "s" -NoNewline -ForegroundColor Yellow; Write-Host ") " -NoNewline -ForegroundColor White; Write-Host "Change sort" -ForegroundColor Green
        Write-Host ""
        Write-Host "  " -NoNewline; Write-Host "a" -NoNewline -ForegroundColor Yellow; Write-Host ") " -NoNewline -ForegroundColor White; Write-Host "Add entry    " -NoNewline -ForegroundColor Green
        Write-Host "d" -NoNewline -ForegroundColor Yellow; Write-Host ") " -NoNewline -ForegroundColor White; Write-Host "Delete entry     " -NoNewline -ForegroundColor Green
        Write-Host "x" -NoNewline -ForegroundColor Yellow; Write-Host ") " -NoNewline -ForegroundColor White; Write-Host "Delete by pattern" -ForegroundColor Green
        Write-Host ""
        Write-Host "  " -NoNewline; Write-Host "w" -NoNewline -ForegroundColor Yellow; Write-Host ") " -NoNewline -ForegroundColor White; Write-Host "Apply changes (write to current device)" -ForegroundColor Green
        if (Test-FleetAvailable) {
            Write-Host "  " -NoNewline; Write-Host "D" -NoNewline -ForegroundColor Yellow; Write-Host ") " -NoNewline -ForegroundColor White; Write-Host "Deploy to fleet" -ForegroundColor Green
        }
        Write-Host ""
        Write-Host "  " -NoNewline; Write-Host "q" -NoNewline -ForegroundColor Yellow; Write-Host ") " -NoNewline -ForegroundColor White; Write-Host "Done (return to main menu)" -ForegroundColor Green
        Write-Host ""
        $editChoice = Read-Host "  Select option"
        
        switch -CaseSensitive ($editChoice) {
            "n" { if ($currentPage -lt $totalPages) { $currentPage++ } }
            "p" { if ($currentPage -gt 1) { $currentPage-- } }
            "g" {
                Write-Host ""
                $gotoPage = Read-Host "  Enter page number (1-$totalPages)"
                $num = 0
                if ([int]::TryParse($gotoPage, [ref]$num) -and $num -ge 1 -and $num -le $totalPages) { $currentPage = $num }
                else { Write-LogWarn "Invalid page number."; Press-EnterToContinue }
            }
            "f" {
                Write-Host ""
                $currentFilter = Read-Host "  Enter search pattern (case-insensitive)"
                $currentPage = 1
            }
            "c" { $currentFilter = ""; $currentPage = 1 }
            "s" {
                Write-Host ""
                Write-Host "  Sort order:" -ForegroundColor White
                Write-Host "    " -NoNewline; Write-Host "1" -NoNewline -ForegroundColor Yellow; Write-Host ") Original (as stored)" -ForegroundColor White
                Write-Host "    " -NoNewline; Write-Host "2" -NoNewline -ForegroundColor Yellow; Write-Host ") A-Z (ascending)" -ForegroundColor White
                Write-Host "    " -NoNewline; Write-Host "3" -NoNewline -ForegroundColor Yellow; Write-Host ") Z-A (descending)" -ForegroundColor White
                Write-Host ""
                $sortChoice = Read-Host "  Select [1-3]"
                switch ($sortChoice) { "1" { $currentSort = "original" }; "2" { $currentSort = "asc" }; "3" { $currentSort = "desc" } }
            }
            "a" {
                # Add entry
                if ($EditType -eq "datagroup") {
                    Write-Host ""
                    $newKey = Read-Host "  Enter new entry"
                    if ([string]::IsNullOrWhiteSpace($newKey)) { Write-LogWarn "No entry provided."; Press-EnterToContinue; continue }
                    if ($workingKeys -contains $newKey) { Write-LogWarn "Entry '$newKey' already exists."; Press-EnterToContinue; continue }
                    $newValue = Read-Host "  Enter value (optional, press Enter to skip)"
                    $workingKeys.Add($newKey) | Out-Null
                    $workingValues.Add($newValue) | Out-Null
                    Write-LogOk "Entry staged for addition: $newKey"
                } else {
                    Write-Host ""
                    $newUrl = Read-Host "  Enter domain or URL to add"
                    if ([string]::IsNullOrWhiteSpace($newUrl)) { Write-LogWarn "No URL provided."; Press-EnterToContinue; continue }
                    $formattedUrl = Format-DomainForUrlCategory -Domain $newUrl
                    if ($workingKeys -contains $formattedUrl) { Write-LogWarn "URL '$formattedUrl' already exists."; Press-EnterToContinue; continue }
                    Write-LogInfo "Will add: $formattedUrl"
                    $confirmAdd = Read-Host "  Confirm? (yes/no) [yes]"
                    if ([string]::IsNullOrWhiteSpace($confirmAdd)) { $confirmAdd = "yes" }
                    if ($confirmAdd -ne "yes") { Write-LogInfo "Cancelled."; Press-EnterToContinue; continue }
                    $workingKeys.Add($formattedUrl) | Out-Null
                    $workingValues.Add("") | Out-Null
                    Write-LogOk "URL staged for addition: $formattedUrl"
                }
                Press-EnterToContinue
            }
            "d" {
                # Delete single entry
                Write-Host ""
                $delInput = Read-Host "  Enter entry number or key to delete (or 'q' to cancel)"
                if ([string]::IsNullOrWhiteSpace($delInput) -or $delInput -eq 'q') { Write-LogInfo "Cancelled."; Press-EnterToContinue; continue }
                
                $delKey = ""
                $num = 0
                if ([int]::TryParse($delInput, [ref]$num)) {
                    # Lookup from filtered/sorted view
                    if ($num -ge 1 -and $num -le $totalCount) {
                        $entry = $sortedEntries[$num - 1]
                        $delKey = $(if ($EditType -eq "datagroup" -and $entry.Contains('|')) { ($entry -split '\|')[0] } else { $entry })
                    }
                } else {
                    $delKey = $delInput
                }
                
                if ([string]::IsNullOrWhiteSpace($delKey)) { Write-LogError "Entry not found."; Press-EnterToContinue; continue }
                
                $foundIdx = $workingKeys.IndexOf($delKey)
                if ($foundIdx -eq -1) { Write-LogError "Entry not found: $delKey"; Press-EnterToContinue; continue }
                
                Write-Host ""
                Write-LogWarn "Delete entry: $delKey"
                Write-Host "  Confirm? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $confirmDel = Read-Host
                if ($confirmDel -ne "yes") { Write-LogInfo "Cancelled."; Press-EnterToContinue; continue }
                
                $workingKeys.RemoveAt($foundIdx)
                $workingValues.RemoveAt($foundIdx)
                Write-LogOk "Entry staged for deletion: $delKey"
                Press-EnterToContinue
            }
            "x" {
                # Delete by pattern
                Write-Host ""
                $delPattern = Read-Host "  Enter pattern to match entries for deletion"
                if ([string]::IsNullOrWhiteSpace($delPattern)) { Write-LogWarn "No pattern provided."; Press-EnterToContinue; continue }
                
                $matchIndices = @()
                for ($i = 0; $i -lt $workingKeys.Count; $i++) {
                    if ($workingKeys[$i] -match [regex]::Escape($delPattern)) { $matchIndices += $i }
                }
                
                if ($matchIndices.Count -eq 0) { Write-LogInfo "No entries match pattern '$delPattern'."; Press-EnterToContinue; continue }
                
                Write-Host ""
                Write-LogWarn "Found $($matchIndices.Count) entries matching '$delPattern':"
                Write-Host "  ──────────────────────────────────────────────────────────────────────────" -ForegroundColor Cyan
                $showCount = 0
                foreach ($idx in $matchIndices) {
                    if ($showCount -lt 20) { Write-Host "    $($workingKeys[$idx])" -ForegroundColor White }
                    $showCount++
                }
                if ($matchIndices.Count -gt 20) { Write-Host "    ... and $($matchIndices.Count - 20) more" -ForegroundColor Yellow }
                Write-Host "  ──────────────────────────────────────────────────────────────────────────" -ForegroundColor Cyan
                
                Write-Host ""
                Write-Host "  Delete all $($matchIndices.Count) matching entries? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $confirmDel = Read-Host
                if ($confirmDel -ne "yes") { Write-LogInfo "Cancelled."; Press-EnterToContinue; continue }
                
                # Remove in reverse order to preserve indices
                $matchIndices | Sort-Object -Descending | ForEach-Object {
                    $workingKeys.RemoveAt($_)
                    $workingValues.RemoveAt($_)
                }
                Write-LogOk "$($matchIndices.Count) entries staged for deletion."
                Press-EnterToContinue
            }
            "w" {
                # Apply changes to current device
                if (-not (Test-PendingChanges)) { Write-LogInfo "No changes to apply."; Press-EnterToContinue; continue }
                
                $changes = Get-ChangeAnalysis
                
                # Display pending changes
                Write-Host ""
                Write-LogInfo "Pending changes:"
                Write-Host "  ──────────────────────────────────────────────────────────────────────────" -ForegroundColor Cyan
                if ($changes.Additions.Count -gt 0) {
                    Write-Host "  Additions ($($changes.Additions.Count)):" -ForegroundColor Green
                    foreach ($entry in $changes.Additions) { Write-Host "    + $entry" -ForegroundColor Green }
                }
                if ($changes.Deletions.Count -gt 0) {
                    if ($changes.Additions.Count -gt 0) { Write-Host "" }
                    Write-Host "  Deletions ($($changes.Deletions.Count)):" -ForegroundColor Red
                    foreach ($entry in $changes.Deletions) { Write-Host "    - $entry" -ForegroundColor Red }
                }
                Write-Host "  ──────────────────────────────────────────────────────────────────────────" -ForegroundColor Cyan
                Write-Host "  Final count: $($workingKeys.Count) entries" -ForegroundColor White
                Write-Host ""
                Write-Host "  Apply these changes? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $confirmApply = Read-Host
                if ($confirmApply -ne "yes") { Write-LogInfo "Cancelled."; Press-EnterToContinue; continue }
                
                # Create backup
                if ($script:BACKUPS_ENABLED -eq 1) {
                    Write-LogStep "Creating backup before applying changes..."
                    $backupFile = ""
                    if ($EditType -eq "datagroup") {
                        $backupFile = Backup-Datagroup -Partition $Partition -Name $DgName
                    } else {
                        $backupFile = Backup-UrlCategory -CatName $CatName
                    }
                    if ($backupFile) { Write-LogOk "Backup saved: $backupFile" }
                    else {
                        Write-LogWarn "Could not create backup."
                        Write-Host "  Continue without backup? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $cont = Read-Host
                        if ($cont -ne "yes") { continue }
                    }
                }
                
                # Apply
                if ($EditType -eq "datagroup") {
                    # Select apply mode
                    Write-Host ""
                    Write-Host "  Select apply mode:" -ForegroundColor White
                    Write-Host -NoNewline "    "; Write-Host -NoNewline "1" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " tmsh Modify   - Add/delete only changed records (tmsh passthrough)" -ForegroundColor White
                    Write-Host -NoNewline "    "; Write-Host -NoNewline "2" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Full Replace  - PATCH entire record set via REST" -ForegroundColor White
                    Write-Host -NoNewline "    "; Write-Host -NoNewline "0" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Cancel" -ForegroundColor White
                    Write-Host ""
                    $applyModeChoice = Read-Host "  Select [0-2]"
                    
                    switch ($applyModeChoice) {
                        "1" {
                            Write-LogStep "Applying changes to datagroup (tmsh modify)..."
                            $incErrors = 0
                            
                            # Additions first
                            if ($changes.Additions.Count -gt 0) {
                                $addKeys = @()
                                $addValues = @()
                                foreach ($addKey in $changes.Additions) {
                                    $idx = $workingKeys.IndexOf($addKey)
                                    $addKeys += $addKey
                                    $addValues += $(if ($idx -ge 0) { $workingValues[$idx] } else { "" })
                                }
                                $addTmsh = ConvertTo-TmshRecordsAdd -Keys $addKeys -Values $addValues
                                if (Add-DatagroupRecordsIncremental -Partition $Partition -Name $DgName -TmshRecords $addTmsh) {
                                    Write-LogOk "$($changes.Additions.Count) record(s) added."
                                } else {
                                    Write-LogError "Failed to add records."
                                    $incErrors++
                                }
                            }
                            
                            # Deletions second
                            if ($changes.Deletions.Count -gt 0) {
                                $delTmsh = ConvertTo-TmshRecordsDelete -Keys $changes.Deletions
                                if (Remove-DatagroupRecordsIncremental -Partition $Partition -Name $DgName -TmshKeys $delTmsh) {
                                    Write-LogOk "$($changes.Deletions.Count) record(s) deleted."
                                } else {
                                    Write-LogError "Failed to delete records."
                                    $incErrors++
                                }
                            }
                            
                            if ($incErrors -gt 0) {
                                Write-LogError "tmsh modify completed with errors."
                                Press-EnterToContinue
                                continue
                            }
                            Write-LogOk "Changes applied successfully."
                        }
                        "2" {
                            Write-LogStep "Applying changes to datagroup (full replace)..."
                            $records = ConvertTo-RecordsJson -Keys @($workingKeys) -Values @($workingValues)
                            $result = Set-DatagroupRecordsRemote -Partition $Partition -Name $DgName -Records $records
                            if ($result.Success) {
                                Write-LogOk "Changes applied successfully."
                            } else {
                                Write-LogError "Failed to apply changes. HTTP $($result.StatusCode)"
                                Press-EnterToContinue
                                continue
                            }
                        }
                        default {
                            Write-LogInfo "Cancelled."
                            Press-EnterToContinue
                            continue
                        }
                    }
                } else {
                    Write-LogStep "Applying changes to URL category..."
                    $applyErrors = 0
                    
                    if ($changes.Deletions.Count -gt 0) {
                        if (-not (Remove-UrlCategoryEntriesRemote -Name $CatName -UrlsToDelete $changes.Deletions)) { $applyErrors++ }
                    }
                    if ($changes.Additions.Count -gt 0) {
                        $addObjects = ConvertTo-UrlObjects -Urls $changes.Additions
                        if (-not (Add-UrlCategoryEntriesRemote -Name $CatName -NewUrls $addObjects)) { $applyErrors++ }
                    }
                    
                    if ($applyErrors -eq 0) { Write-LogOk "Changes applied successfully." }
                    else { Write-LogWarn "Changes applied with $applyErrors error(s)." }
                }
                
                # Update original arrays
                $originalKeys.Clear()
                $originalValues.Clear()
                foreach ($k in $workingKeys) { $originalKeys.Add($k) | Out-Null }
                foreach ($v in $workingValues) { $originalValues.Add($v) | Out-Null }
                
                Invoke-PromptSaveConfig
                Press-EnterToContinue
            }
            "D" {
                # Deploy to fleet
                if (-not (Test-FleetAvailable)) { Write-LogWarn "No fleet configured."; Press-EnterToContinue; continue }
                
                $hasPending = Test-PendingChanges
                $changes = @{ Additions = @(); Deletions = @() }
                
                if (-not $hasPending) {
                    Write-Host ""
                    Write-LogInfo "No pending changes detected."
                    Write-Host "  Deploy current state to fleet anyway? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $deployAnyway = Read-Host
                    if ($deployAnyway -ne "yes") { Write-LogInfo "Deploy cancelled."; Press-EnterToContinue; continue }
                }
                
                if ($hasPending) {
                    $changes = Get-ChangeAnalysis
                    
                    # Show changes
                    Write-Host ""
                    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
                    Write-Host "    PENDING CHANGES TO DEPLOY" -ForegroundColor White
                    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
                    Write-Host ""
                    if ($changes.Additions.Count -gt 0) {
                        Write-Host "  Additions ($($changes.Additions.Count)):" -ForegroundColor Green
                        $show = 0; foreach ($e in $changes.Additions) { if ($show -lt 10) { Write-Host "    + $e" -ForegroundColor Green }; $show++ }
                        if ($changes.Additions.Count -gt 10) { Write-Host "    ... and $($changes.Additions.Count - 10) more" -ForegroundColor Green }
                    }
                    if ($changes.Deletions.Count -gt 0) {
                        if ($changes.Additions.Count -gt 0) { Write-Host "" }
                        Write-Host "  Deletions ($($changes.Deletions.Count)):" -ForegroundColor Red
                        $show = 0; foreach ($e in $changes.Deletions) { if ($show -lt 10) { Write-Host "    - $e" -ForegroundColor Red }; $show++ }
                        if ($changes.Deletions.Count -gt 10) { Write-Host "    ... and $($changes.Deletions.Count - 10) more" -ForegroundColor Red }
                    }
                    Write-Host ""
                    Write-Host "  ──────────────────────────────────────────────────────────────" -ForegroundColor Cyan
                    Write-Host "  Final entry count: $($workingKeys.Count)" -ForegroundColor White
                    Write-Host ""
                    
                    Write-Host "  Continue to deployment options? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $contDeploy = Read-Host
                    if ($contDeploy -ne "yes") { Write-LogInfo "Deploy cancelled."; Press-EnterToContinue; continue }
                    
                    # Select deploy mode
                    Write-Host ""
                    Write-Host "  Select deployment mode:" -ForegroundColor White
                    Write-Host '    ' -NoNewline; Write-Host '1' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
                    Write-Host "Full Replace - Overwrite target with exact state from current device" -ForegroundColor White
                    Write-Host '    ' -NoNewline; Write-Host '2' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
                    Write-Host "Merge        - Apply only additions/deletions, preserve target-specific entries" -ForegroundColor White
                    Write-Host '    ' -NoNewline; Write-Host '0' -NoNewline -ForegroundColor Yellow; Write-Host ') ' -NoNewline -ForegroundColor White
                    Write-Host "Cancel" -ForegroundColor White
                    Write-Host ""
                    $deployModeChoice = Read-Host "  Select [0-2]"
                    $deployMode = switch ($deployModeChoice) { "1" { "replace" }; "2" { "merge" }; default { "" } }
                    if ([string]::IsNullOrWhiteSpace($deployMode)) { Write-LogInfo "Deploy cancelled."; Press-EnterToContinue; continue }
                } else {
                    $deployMode = "replace"
                    Write-LogInfo "Deploying current state ($($workingKeys.Count) entries) as full replace."
                }
                
                # Select scope
                $deployTargets = @()
                if ($EditType -eq "datagroup") {
                    $deployTargets = Select-DeployScope -ObjectType "datagroup" -ObjectName "/${Partition}/${DgName}"
                } else {
                    $deployTargets = Select-DeployScope -ObjectType "urlcat" -ObjectName $CatName
                }
                if ($deployTargets.Count -eq 0) { Write-LogInfo "Deploy cancelled."; Press-EnterToContinue; continue }
                
                $targetCount = $deployTargets.Count
                
                # Show preview
                Write-Host ""
                Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
                Write-Host "    DEPLOY PREVIEW" -ForegroundColor White
                Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
                Write-Host ""
                if ($EditType -eq "datagroup") {
                    Write-Host "  Object:  /${Partition}/${DgName} ($dgType)" -ForegroundColor White
                } else {
                    Write-Host "  Object:  $CatName" -ForegroundColor White
                }
                Write-Host -NoNewline "  Changes: " -ForegroundColor White
                Write-Host -NoNewline "+$($changes.Additions.Count)" -ForegroundColor Green
                Write-Host -NoNewline " / " -ForegroundColor White
                Write-Host "-$($changes.Deletions.Count)" -ForegroundColor Red
                if ($deployMode -eq "merge") {
                    Write-Host "  Mode:    Merge (additions/deletions only, preserves target-specific entries)" -ForegroundColor White
                } else {
                    Write-Host "  Mode:    Full Replace (exact parity with current device)" -ForegroundColor White
                }
                Write-Host ""
                Write-Host "  Deployment order:" -ForegroundColor White
                $tNum = 1
                if ($hasPending) {
                    Write-Host "    $tNum. $($script:RemoteHost) (current device)" -ForegroundColor White
                    $tNum++
                }
                foreach ($t in $deployTargets) {
                    $tSite = Get-HostSite -Hostname $t
                    Write-Host "    $tNum. $t ($tSite)" -ForegroundColor White
                    $tNum++
                }
                Write-Host ""
                $totalDevices = $(if ($hasPending) { $targetCount + 1 } else { $targetCount })
                Write-Host "  Total: $totalDevices device(s)" -ForegroundColor White
                Write-Host ""
                $warningText = $(if ($hasPending) { "  WARNING: This will push pending changes to all listed Big-IPs." } else { "  WARNING: This will push current state to all listed Big-IPs." })
                Write-Host $warningText -ForegroundColor Red
                Write-Host ""
                $confirmDeploy = Read-Host "  Type DEPLOY to confirm"
                if ($confirmDeploy -cne "DEPLOY") { Write-LogInfo "Deploy cancelled."; Press-EnterToContinue; continue }
                
                Clear-Host
                
                # ── Step 1: Pre-deploy validation ──
                Write-Host ""
                Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
                Write-Host "    STEP 1: PRE-DEPLOY VALIDATION" -ForegroundColor White
                Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
                
                if ($EditType -eq "datagroup") {
                    $validationResults = Invoke-PreDeployValidation -ObjectType "datagroup" -ObjectName $DgName -Partition $Partition -Targets $deployTargets
                } else {
                    $validationResults = Invoke-PreDeployValidation -ObjectType "urlcat" -ObjectName $CatName -Partition "" -Targets $deployTargets
                }
                
                $readyCount = @($validationResults | Where-Object { $_.Status -eq "OK" }).Count
                if ($readyCount -eq 0) {
                    Write-LogWarn "No fleet hosts passed validation. No changes have been made."
                    Press-EnterToContinue
                    continue
                }
                
                # Only prompt if some hosts failed - user already typed DEPLOY
                if ($readyCount -lt $targetCount) {
                    Write-Host ""
                    if ($hasPending) {
                        Write-Host "  Proceed with deployment to $readyCount fleet host(s) + current device? (yes/no) " -NoNewline
                    } else {
                        Write-Host "  Proceed with deployment to $readyCount fleet host(s)? (yes/no) " -NoNewline
                    }
                    Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline
                    $proceedDeploy = Read-Host
                    if ($proceedDeploy -ne "yes") {
                        Write-LogInfo "Deploy cancelled. No changes have been made."
                        Press-EnterToContinue
                        continue
                    }
                }
                
                # ── Step 2: Apply to current device (only if pending changes) ──
                $currentStatus = "OK"
                $currentMessage = "No changes needed"
                
                if ($hasPending) {
                    Write-Host ""
                    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
                    Write-Host "    STEP 2: APPLYING TO CURRENT DEVICE" -ForegroundColor White
                    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
                    Write-Host ""
                    Write-Host "  Deploying to $($script:RemoteHost)..." -ForegroundColor White
                    
                    # Backup
                    if ($script:BACKUPS_ENABLED -eq 1) {
                        $currentBackup = ""
                        if ($EditType -eq "datagroup") {
                            $currentBackup = Backup-Datagroup -Partition $Partition -Name $DgName
                        } else {
                            $currentBackup = Backup-UrlCategory -CatName $CatName
                        }
                        if ($currentBackup) {
                            Write-Host "  [ OK ]" -NoNewline -ForegroundColor Green; Write-Host "  Creating backup" -ForegroundColor White
                        } else {
                            Write-Host "  [FAIL]" -NoNewline -ForegroundColor Red; Write-Host "  Creating backup" -ForegroundColor White
                            Write-Host "  Continue without backup? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $cont = Read-Host
                            if ($cont -ne "yes") { Write-LogInfo "Deploy cancelled."; Press-EnterToContinue; continue }
                        }
                    }
                    
                    # Apply
                    $currentSuccess = $false
                    if ($EditType -eq "datagroup") {
                        $records = ConvertTo-RecordsJson -Keys @($workingKeys) -Values @($workingValues)
                        $result = Set-DatagroupRecordsRemote -Partition $Partition -Name $DgName -Records $records
                        if ($result.Success) {
                            Write-Host "  [ OK ]" -NoNewline -ForegroundColor Green; Write-Host "  Applying changes" -ForegroundColor White
                            if (Save-F5Config) {
                                Write-Host "  [ OK ]" -NoNewline -ForegroundColor Green; Write-Host "  Saving configuration" -ForegroundColor White
                                $currentSuccess = $true
                            } else {
                                Write-Host "  [FAIL]" -NoNewline -ForegroundColor Red; Write-Host "  Saving configuration" -ForegroundColor White
                            }
                        } else {
                            Write-Host "  [FAIL]" -NoNewline -ForegroundColor Red; Write-Host "  Applying changes" -ForegroundColor White
                        }
                    } else {
                        $urlObjects = ConvertTo-UrlObjects -Urls @($workingKeys)
                        if (Set-UrlCategoryEntriesRemote -Name $CatName -Urls $urlObjects) {
                            Write-Host "  [ OK ]" -NoNewline -ForegroundColor Green; Write-Host "  Applying changes" -ForegroundColor White
                            if (Save-F5Config) {
                                Write-Host "  [ OK ]" -NoNewline -ForegroundColor Green; Write-Host "  Saving configuration" -ForegroundColor White
                                $currentSuccess = $true
                            } else {
                                Write-Host "  [FAIL]" -NoNewline -ForegroundColor Red; Write-Host "  Saving configuration" -ForegroundColor White
                            }
                        } else {
                            Write-Host "  [FAIL]" -NoNewline -ForegroundColor Red; Write-Host "  Applying changes" -ForegroundColor White
                        }
                    }
                    
                    if (-not $currentSuccess) {
                        Write-Host ""
                        Write-LogError "Failed to apply changes to current device."
                        Write-Host "  Continue deploying to fleet anyway? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $contFleet = Read-Host
                        if ($contFleet -ne "yes") { Write-LogInfo "Deploy aborted."; Press-EnterToContinue; continue }
                    }
                    
                    $currentStatus = $(if ($currentSuccess) { "OK" } else { "FAIL" })
                    $currentMessage = $(if ($currentSuccess) { "Deployed and saved" } else { "Failed to apply" })
                    if ($currentSuccess) {
                        $originalKeys.Clear(); $originalValues.Clear()
                        foreach ($k in $workingKeys) { $originalKeys.Add($k) | Out-Null }
                        foreach ($v in $workingValues) { $originalValues.Add($v) | Out-Null }
                    }
                }
                
                # ── Deploy to fleet ──
                $fleetStepNum = $(if ($hasPending) { 3 } else { 2 })
                Write-Host ""
                Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
                Write-Host "    STEP ${fleetStepNum}: DEPLOYING TO FLEET" -ForegroundColor White
                Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
                
                # Build merge data
                $additionsJson = @()
                $deletionsList = @()
                if ($deployMode -eq "merge" -and $hasPending) {
                    if ($changes.Additions.Count -gt 0) {
                        if ($EditType -eq "datagroup") {
                            foreach ($addKey in $changes.Additions) {
                                $idx = $workingKeys.IndexOf($addKey)
                                if ($idx -ge 0) {
                                    if ($workingValues[$idx]) { $additionsJson += @{ name = $addKey; data = $workingValues[$idx] } }
                                    else { $additionsJson += @{ name = $addKey } }
                                }
                            }
                        } else {
                            $additionsJson = ConvertTo-UrlObjects -Urls $changes.Additions
                        }
                    }
                    $deletionsList = $changes.Deletions
                }
                
                # Build deploy action scriptblock
                if ($EditType -eq "datagroup") {
                    $records = ConvertTo-RecordsJson -Keys @($workingKeys) -Values @($workingValues)
                    $deployAction = {
                        param($h, $s)
                        Deploy-DatagroupToHost -HostName $h -Partition $Partition -DgName $DgName -DgType $dgType `
                            -RecordsJson $records -SiteId $s -DeployMode $deployMode `
                            -AdditionsJson $additionsJson -DeletionsList $deletionsList
                    }
                } else {
                    $urlObjects = ConvertTo-UrlObjects -Urls @($workingKeys)
                    $deployAction = {
                        param($h, $s)
                        Deploy-UrlCategoryToHost -HostName $h -CatName $CatName -UrlsJson $urlObjects -SiteId $s `
                            -DeployMode $deployMode -AdditionsJson $additionsJson -DeletionsList $deletionsList
                    }
                }
                
                $objectName = $(if ($EditType -eq "datagroup") { $DgName } else { $CatName })
                Invoke-FleetDeploy -ObjectType $EditType -ObjectName $objectName -Partition $Partition `
                    -ValidationResults $validationResults `
                    -DeployAction $deployAction -CurrentHost $script:RemoteHost `
                    -CurrentStatus $currentStatus -CurrentMessage $currentMessage
                
                Press-EnterToContinue
            }
            "q" {
                if (Test-PendingChanges) {
                    Write-Host ""
                    Write-LogWarn "You have unapplied changes that will be discarded."
                    Write-Host "  Discard changes and exit? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $confirmExit = Read-Host
                    if ($confirmExit -ne "yes") { continue }
                    Write-LogInfo "Changes discarded."
                }
                return
            }
        }
    }
}

# =============================================================================
# MAIN
# =============================================================================

# =============================================================================
# BOOTSTRAP FUNCTIONS
# =============================================================================

function Invoke-Bootstrap {
    Write-LogSection "Bootstrap"
    
    while ($true) {
        Write-Host ""
        Write-Host "  Bootstrap Options:" -ForegroundColor White
        Write-Host -NoNewline "    "; Write-Host -NoNewline "1" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Create Bootstrap config" -ForegroundColor White
        Write-Host -NoNewline "    "; Write-Host -NoNewline "2" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Import Bootstrap config" -ForegroundColor White
        Write-Host -NoNewline "    "; Write-Host -NoNewline "0" -ForegroundColor Yellow; Write-Host -NoNewline ")" -ForegroundColor White; Write-Host " Cancel" -ForegroundColor White
        Write-Host ""
        $choice = Read-Host "  Select [0-2]"
        
        switch ($choice) {
            "1" { Invoke-BootstrapCreate }
            "2" { Invoke-BootstrapImport; return }
            default {
                Write-LogInfo "Cancelled."
                Press-EnterToContinue
                return
            }
        }
    }
}

function Invoke-BootstrapCreate {
    $bootstrapFile = Join-Path $script:BACKUP_DIR "bootstrap.conf"
    
    if (Test-Path $bootstrapFile) {
        Write-LogWarn "Bootstrap config already exists: $bootstrapFile"
        Write-LogInfo "Delete or rename the existing file to create a new one."
        return
    }
    
    $template = @"
# DGCat-Admin Bootstrap Configuration
# https://github.com/hauptem/F5-SSL-Orchestrator-Tools
#
# This file defines datagroups and URL categories to create across your fleet.
# Use 'Import Bootstrap' to validate and then deploy.
#
# Format: object|name|attribute
#
# object:    dg  = Datagroup
#            cat = URL Category
#
# name:      Must start with a letter. No spaces allowed.
#
# Permitted attributes: 
# dg:  string, address, integer
# cat: allow, block, confirm
#
# Examples:
# dg|bypass-clients|address
# dg|bypass-servers|address
# dg|bypass-host|string
# dg|bypass-port|integer
# cat|Bypass-hosts|allow
# cat|Pinners|allow
# cat|IPS-Only|allow
# cat|DLP-Only|allow
"@
    
    try {
        $template | Out-File -FilePath $bootstrapFile -Encoding UTF8
        Write-LogOk "Bootstrap config created: $bootstrapFile"
        Write-LogInfo "Edit the file to define your objects, then use Import to deploy."
    } catch {
        Write-LogError "Could not create bootstrap config. Check backup directory permissions."
    }
}

function Invoke-BootstrapImport {
    $bootstrapFile = Join-Path $script:BACKUP_DIR "bootstrap.conf"
    
    if (-not (Test-Path $bootstrapFile)) {
        Write-LogError "Bootstrap config not found: $bootstrapFile"
        Write-LogInfo "Use 'Create Bootstrap config' to generate a template."
        Press-EnterToContinue
        return
    }
    
    # Parse and validate
    $lineNum = 0
    $errors = 0
    $dgNames = @()
    $dgTypes = @()
    $catNames = @()
    $catActions = @()
    $seenDgNames = @{}
    $seenCatNames = @{}
    
    foreach ($line in (Get-Content $bootstrapFile)) {
        $lineNum++
        
        # Skip comments and empty lines
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        
        # Split on pipe
        $parts = $line.Split('|')
        if ($parts.Count -lt 3) {
            Write-LogError "Line ${lineNum}: Expected format object|name|attribute"
            $errors++
            continue
        }
        
        $obj = $parts[0].Trim()
        $name = $parts[1].Trim()
        $attr = $parts[2].Trim()
        
        # Validate field count
        if ([string]::IsNullOrWhiteSpace($obj) -or [string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($attr)) {
            Write-LogError "Line ${lineNum}: Expected format object|name|attribute"
            $errors++
            continue
        }
        
        # Validate object type
        if ($obj -ne "dg" -and $obj -ne "cat") {
            Write-LogError "Line ${lineNum}: Invalid object '$obj'. Must be 'dg' or 'cat'."
            $errors++
            continue
        }
        
        # Validate name - no spaces
        if ($name -match '\s') {
            Write-LogError "Line ${lineNum}: Name '$name' contains spaces."
            $errors++
            continue
        }
        
        # Validate name - must start with a letter
        if ($name -match '^[^a-zA-Z]') {
            Write-LogError "Line ${lineNum}: Name '$name' must start with a letter."
            $errors++
            continue
        }
        
        # Validate attribute and check for duplicates
        if ($obj -eq "dg") {
            if ($attr -ne "string" -and $attr -ne "address" -and $attr -ne "integer") {
                Write-LogError "Line ${lineNum}: Invalid attribute '$attr' for datagroup. Must be string, address, or integer."
                $errors++
                continue
            }
            
            if ($seenDgNames.ContainsKey($name)) {
                Write-LogError "Line ${lineNum}: Duplicate datagroup name '$name'."
                $errors++
                continue
            }
            
            $seenDgNames[$name] = $true
            $dgNames += $name
            $dgTypes += $attr
            
        } elseif ($obj -eq "cat") {
            if ($attr -ne "allow" -and $attr -ne "block" -and $attr -ne "confirm") {
                Write-LogError "Line ${lineNum}: Invalid attribute '$attr' for URL category. Must be allow, block, or confirm."
                $errors++
                continue
            }
            
            if ($seenCatNames.ContainsKey($name)) {
                Write-LogError "Line ${lineNum}: Duplicate URL category name '$name'."
                $errors++
                continue
            }
            
            $seenCatNames[$name] = $true
            $catNames += $name
            $catActions += $attr
        }
    }
    
    if ($errors -gt 0) {
        Write-Host ""
        Write-LogError "$errors validation error(s) found. Fix bootstrap.conf and try again."
        Press-EnterToContinue
        return
    }
    
    $totalObjects = $dgNames.Count + $catNames.Count
    if ($totalObjects -eq 0) {
        Write-LogWarn "No entries found in bootstrap.conf."
        Press-EnterToContinue
        return
    }
    
    # Display plan
    Write-Host ""
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "    BOOTSTRAP PLAN" -ForegroundColor White
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    if ($dgNames.Count -gt 0) {
        Write-Host ""
        Write-Host "  Datagroups ($($dgNames.Count)):" -ForegroundColor White
        for ($i = 0; $i -lt $dgNames.Count; $i++) {
            $line = "    {0,-35} ({1})" -f $dgNames[$i], $dgTypes[$i]
            Write-Host $line -ForegroundColor White
        }
    }
    
    if ($catNames.Count -gt 0) {
        Write-Host ""
        Write-Host "  URL Categories ($($catNames.Count)):" -ForegroundColor White
        for ($i = 0; $i -lt $catNames.Count; $i++) {
            $line = "    {0,-35} ({1})" -f $catNames[$i], $catActions[$i]
            Write-Host $line -ForegroundColor White
        }
    }
    
    Write-Host ""
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "    Total: $totalObjects objects" -ForegroundColor White
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    # Get partition for datagroups
    $partition = ""
    if ($dgNames.Count -gt 0) {
        if ($script:PARTITIONS.Count -gt 1) {
            $partition = Select-Partition -Prompt "Select partition for datagroups"
            if ([string]::IsNullOrWhiteSpace($partition)) {
                Write-LogInfo "Cancelled."
                Press-EnterToContinue
                return
            }
        } else {
            $partition = $script:PARTITIONS[0]
        }
    }
    
    # Select deployment scope
    $deployTargets = @()
    if (Test-FleetAvailable) {
        $scopeResult = Select-DeployScope -ObjectType "bootstrap" -ObjectName "bootstrap.conf" -IncludeSelf $true
        if ($scopeResult.Count -eq 0) {
            Write-LogInfo "Cancelled."
            Press-EnterToContinue
            return
        }
        $deployTargets = @($scopeResult)
    } else {
        $deployTargets = @($script:RemoteHost)
    }
    
    # Confirm
    Write-Host ""
    Write-LogInfo "Targets: $($deployTargets.Count) host(s)"
    foreach ($t in $deployTargets) {
        Write-LogInfo "  $t"
    }
    Write-Host ""
    Write-Host "  Proceed? (yes/no) " -NoNewline; Write-Host "[" -NoNewline -ForegroundColor Green; Write-Host "no" -NoNewline -ForegroundColor Red; Write-Host "]" -NoNewline -ForegroundColor Green; Write-Host ": " -NoNewline; $confirm = Read-Host
    if ($confirm -ne "yes") {
        Write-LogInfo "Cancelled."
        Press-EnterToContinue
        return
    }
    
    # Deploy to all targets
    $origHost = $script:RemoteHost
    $totalOk = 0; $totalFail = 0; $totalSkip = 0
    
    foreach ($host_ in $deployTargets) {
        $script:RemoteHost = $host_
        $hostSite = Get-HostSite -Hostname $host_
        
        # Test connectivity
        $testResult = Invoke-F5Get -Endpoint "/mgmt/tm/sys/version"
        if (-not $testResult.Success) {
            Write-LogError "$host_ ($hostSite) - Connection failed. Skipped."
            $totalSkip++
            continue
        }
        
        # Create objects
        $rc = Invoke-BootstrapCreateObjects -Partition $partition -DgNames $dgNames -DgTypes $dgTypes -CatNames $catNames -CatActions $catActions
        
        # Save on target
        Save-F5Config | Out-Null
        
        if ($rc -eq 0) {
            $totalOk++
        } else {
            $totalFail++
        }
    }
    
    $script:RemoteHost = $origHost
    
    Write-Host ""
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-LogInfo "Bootstrap: $totalOk succeeded, $totalFail failed, $totalSkip skipped"
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    Press-EnterToContinue
}

function Invoke-BootstrapCreateObjects {
    param(
        [string]$Partition,
        [string[]]$DgNames,
        [string[]]$DgTypes,
        [string[]]$CatNames,
        [string[]]$CatActions
    )
    
    $created = 0; $skipped = 0; $failed = 0
    
    Write-Host ""
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "    BOOTSTRAP: $($script:RemoteHost)" -ForegroundColor White
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    # Create datagroups
    for ($i = 0; $i -lt $DgNames.Count; $i++) {
        $name = $DgNames[$i]
        $type = $DgTypes[$i]
        $apiType = $type
        if ($apiType -eq "address") { $apiType = "ip" }
        
        if (Test-DatagroupExistsRemote -Partition $Partition -Name $name) {
            Write-LogInfo "Datagroup '$name' already exists. Skipped."
            $skipped++
            continue
        }
        
        Write-LogStep "Creating datagroup '$name' ($type)..."
        if (New-DatagroupRemote -Partition $Partition -Name $name -Type $apiType) {
            Write-LogOk "Created."
            $created++
        } else {
            Write-LogError "Failed to create '$name'."
            $failed++
        }
    }
    
    # Create URL categories
    for ($i = 0; $i -lt $CatNames.Count; $i++) {
        $name = $CatNames[$i]
        $action = $CatActions[$i]
        
        if (Test-UrlCategoryExistsRemote -Name $name) {
            Write-LogInfo "URL category '$name' already exists. Skipped."
            $skipped++
            continue
        }
        
        Write-LogStep "Creating URL category '$name' ($action)..."
        if (New-UrlCategoryRemote -Name $name -DefaultAction $action -Urls @()) {
            Write-LogOk "Created."
            $created++
        } else {
            Write-LogError "Failed to create '$name'."
            $failed++
        }
    }
    
    Write-Host "  ──────────────────────────────────────────────────────────────" -ForegroundColor Cyan
    Write-LogInfo "Result: $created created, $skipped skipped, $failed failed"
    
    return $failed
}

function Main {
    # Initialize SSL bypass for self-signed BIG-IP management certs
    Initialize-SslBypass
    
    # Welcome banner
    Clear-Host
    Write-Host ""
    Write-Host "  ╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║" -NoNewline -ForegroundColor Cyan
    Write-Host "                    DGCAT-Admin v5.1                        " -NoNewline -ForegroundColor White
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ║" -NoNewline -ForegroundColor Cyan
    Write-Host "               F5 BIG-IP Administration Tool                " -NoNewline -ForegroundColor White
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    
    # Setup backup directory and log
    if (-not (Test-Path $script:BACKUP_DIR)) {
        New-Item -Path $script:BACKUP_DIR -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }
    
    $script:FLEET_CONFIG_FILE = Join-Path $script:BACKUP_DIR "fleet.conf"
    $script:Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    
    if ($script:LOGGING_ENABLED -eq 1) {
        $script:LogFile = Join-Path $script:BACKUP_DIR "dgcat-admin-$($script:Timestamp).log"
        try {
            @(
                "DGCat-Admin - F5 BIG-IP Administration Tool",
                "Started: $(Get-Date)",
                "Mode: REST API"
            ) | Out-File -FilePath $script:LogFile -Encoding UTF8
        } catch {}
    } else {
        $script:LogFile = ""
    }
    
    # Run pre-flight checks (runs once)
    Invoke-PreFlightChecks
    
    # Update log with target
    if ($script:LogFile) {
        try { "Target: $($script:RemoteHost)" | Out-File -FilePath $script:LogFile -Append -Encoding UTF8 } catch {}
    }
    
    Start-Sleep -Seconds 2
    
    # Session loop — option 0 returns here for new connection
    while ($true) {
        # Main menu loop
        $reconnect = $false
        while ($true) {
            Show-MainMenu
            
            $choice = Read-Host "  Select option [0-8]"
            
            switch ($choice) {
                "1" { Invoke-CreateEmpty }
                "2" { Invoke-CreateFromCsv }
                "3" { Invoke-DeleteMenu }
                "4" { Invoke-ExportToCsv }
                "5" { Invoke-EditMenu }
                "6" { Invoke-FleetLookingGlass }
                "7" { Invoke-FleetBackup }
                "8" { Invoke-Bootstrap }
                "0" {
                    $reconnect = $true
                    break
                }
                default {
                    Write-LogWarn "Invalid selection."
                    Press-EnterToContinue
                }
            }
            
            if ($reconnect) { break }
        }
        
        # Clear screen and reset connection variables
        Clear-Host
        $script:RemoteHost = ""
        $script:RemoteUser = ""
        $script:RemotePass = ""
        $script:RemoteHostname = ""
        $script:AuthHeader = ""
        $script:PartitionCache = @{}
        $script:UrlCategoryDbCached = ""
        
        # Re-connect (Initialize-RemoteConnection handles exit on "0")
        while ($true) {
            if (Initialize-RemoteConnection) { break }
            Write-Host ""
            $retry = Read-Host "  Retry connection? (yes/no) [yes]"
            if ([string]::IsNullOrWhiteSpace($retry)) { $retry = "yes" }
            if ($retry -ne "yes") {
                Write-LogInfo "Exiting."
                Write-Host "  Latest version: https://github.com/hauptem/F5-SSL-Orchestrator-Tools" -ForegroundColor Cyan
                exit 0
            }
        }
        
        # Validate partitions on new host
        Write-LogStep "Validating partitions on target system..."
        $invalidCount = 0
        foreach ($partition in $script:PARTITIONS) {
            if (-not (Test-PartitionExists -Partition $partition)) {
                Write-LogWarn "Partition '$partition' not found on $($script:RemoteHost)"
                $invalidCount++
            }
        }
        if ($invalidCount -eq 0) {
            Write-LogOk "All partitions verified"
        }
        
        # Check URL category database
        if (Test-UrlCategoryDbAvailable) {
            Write-LogOk "URL category database available"
        } else {
            Write-LogInfo "URL category database not available (URL category features disabled)"
        }
        
        Start-Sleep -Seconds 2
    }
}

# Run
Main
