# BokadorLink.Common.ps1 - shared functions of the bokador-link kit (docs/DESIGN.md, section 4.4).
# This file is dot-sourced from the top level of every script of the kit. It only defines
# functions and a few script-scope constants: it has no other side effect.
# Target: Windows PowerShell 5.1. Keep this file plain ASCII.

Set-StrictMode -Version 2.0

# Directory of this library (<root>\bin\lib once installed, <repo>\windows\lib otherwise).
$script:BLLibraryDir = $PSScriptRoot
$script:BLMaxLogBytes = 1048576
$script:BLLogArchives = 3

# ---------------------------------------------------------------------------
# Small generic helpers
# ---------------------------------------------------------------------------

function Get-BLUtf8NoBom {
    return (New-Object System.Text.UTF8Encoding($false))
}

function Get-BLUtcNowText {
    return [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
}

# Safe read of an optional member: works on PSCustomObject and on dictionaries, never throws
# under StrictMode.
function Get-BLProperty {
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) {
        return $Default
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $Default
    }
    $member = $Object.PSObject.Properties[$Name]
    if ($null -eq $member) {
        return $Default
    }
    return $member.Value
}

# Returns a UTC [DateTime], or $null when the value is not a usable date.
# (ConvertFrom-Json keeps ISO 8601 text as a string in 5.1 but newer hosts return a DateTime.)
function ConvertTo-BLUtcDate {
    param(
        $Value
    )
    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime()
    }
    $text = [string]$Value
    if ([string]::IsNullOrEmpty($text)) {
        return $null
    }
    $parsed = [DateTime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ([DateTime]::TryParse($text, $culture, $styles, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    return $null
}

# Normalises a date-like value to ISO 8601 text ('' when empty or unusable).
function ConvertTo-BLDateText {
    param(
        $Value
    )
    $date = ConvertTo-BLUtcDate -Value $Value
    if ($null -eq $date) {
        return ''
    }
    return $date.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
}

# Returns the value as [long] when it is an integral number, $null otherwise.
function ConvertTo-BLInteger {
    param(
        $Value
    )
    if ($null -eq $Value) {
        return $null
    }
    if (($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [int16]) -or ($Value -is [byte])) {
        return [long]$Value
    }
    if (($Value -is [double]) -or ($Value -is [decimal]) -or ($Value -is [single])) {
        $asDouble = [double]$Value
        if (($asDouble -eq [Math]::Floor($asDouble)) -and ([Math]::Abs($asDouble) -lt 1000000000)) {
            return [long]$asDouble
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Root directory and paths (design 4.1)
# ---------------------------------------------------------------------------

function Get-BLRoot {
    $fromEnv = [Environment]::GetEnvironmentVariable('BOKADORLINK_HOME')
    if (-not [string]::IsNullOrEmpty($fromEnv)) {
        $trimmed = $fromEnv.Trim()
        if ($trimmed.Length -gt 3) {
            $trimmed = $trimmed.TrimEnd('\')
        }
        return $trimmed
    }
    # A script located in <root>\bin\ loads this file from <root>\bin\lib\.
    $libDir = $script:BLLibraryDir
    if (-not [string]::IsNullOrEmpty($libDir)) {
        $binDir = Split-Path -Parent $libDir
        if ((-not [string]::IsNullOrEmpty($binDir)) -and ((Split-Path -Leaf $binDir) -ieq 'bin')) {
            $candidate = Split-Path -Parent $binDir
            if (-not [string]::IsNullOrEmpty($candidate)) {
                if ([System.IO.File]::Exists((Join-Path $candidate 'config.json'))) {
                    return $candidate
                }
            }
        }
    }
    $localAppData = $env:LOCALAPPDATA
    if ([string]::IsNullOrEmpty($localAppData)) {
        $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    }
    if ([string]::IsNullOrEmpty($localAppData)) {
        throw 'Impossible de determiner le repertoire d''installation (LOCALAPPDATA vide). Definir BOKADORLINK_HOME.'
    }
    return (Join-Path $localAppData 'BokadorLink')
}

function Get-BLUserProfileDir {
    $userProfile = $env:USERPROFILE
    if ([string]::IsNullOrEmpty($userProfile)) {
        $userProfile = [Environment]::GetFolderPath('UserProfile')
    }
    return $userProfile
}

function Get-BLTaskNames {
    return @{
        Tunnel   = 'BokadorLink-Tunnel'
        Watchdog = 'BokadorLink-Watchdog'
    }
}

function Get-BLPaths {
    param(
        [string]$Root = ''
    )
    if ([string]::IsNullOrEmpty($Root)) {
        $Root = Get-BLRoot
    }
    $names = Get-BLTaskNames
    $bin = Join-Path $Root 'bin'
    $logs = Join-Path $Root 'logs'
    $run = Join-Path $Root 'run'
    $tasks = Join-Path $Root 'tasks'
    return @{
        Root             = $Root
        Config           = (Join-Path $Root 'config.json')
        SshConfig        = (Join-Path $Root 'ssh_config')
        KnownHosts       = (Join-Path $Root 'known_hosts')
        State            = (Join-Path $Root 'state.json')
        Bin              = $bin
        Lib              = (Join-Path $bin 'lib')
        Logs             = $logs
        Run              = $run
        Tasks            = $tasks
        SupervisorScript = (Join-Path $bin 'Link-Supervisor.ps1')
        WatchdogScript   = (Join-Path $bin 'Link-Watchdog.ps1')
        StatusScript     = (Join-Path $bin 'Get-BokadorLinkStatus.ps1')
        UninstallScript  = (Join-Path $bin 'Uninstall-BokadorLink.ps1')
        CommonLib        = (Join-Path $bin 'lib\BokadorLink.Common.ps1')
        LaunchVbs        = (Join-Path $bin 'launch-hidden.vbs')
        VpsHelperCopy    = (Join-Path $bin 'vps\bokador-link')
        SupervisorLog    = (Join-Path $logs 'supervisor.log')
        WatchdogLog      = (Join-Path $logs 'watchdog.log')
        InstallLog       = (Join-Path $logs 'install.log')
        TunnelErrLog     = (Join-Path $logs 'ssh-tunnel.err.log')
        SupervisorPid    = (Join-Path $run 'supervisor.pid')
        TunnelPid        = (Join-Path $run 'tunnel.pid')
        StopFlag         = (Join-Path $run 'stop.flag')
        TunnelTaskXml    = (Join-Path $tasks ($names.Tunnel + '.xml'))
        WatchdogTaskXml  = (Join-Path $tasks ($names.Watchdog + '.xml'))
    }
}

# ---------------------------------------------------------------------------
# Files: atomic writes, JSON, logs
# ---------------------------------------------------------------------------

# Writes a text file through a temporary file then replaces the target (design 4.1).
# Never uses Out-File / Set-Content: the default encoding is UTF-8 without BOM.
function Write-BLTextFileAtomic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [AllowEmptyString()]
        [string]$Text = '',
        [System.Text.Encoding]$Encoding = $null
    )
    if ($null -eq $Encoding) {
        $Encoding = Get-BLUtf8NoBom
    }
    # The parent directory is never created here: writing into a directory removed by the
    # uninstaller must fail instead of resurrecting it.
    $temp = $Path + '.tmp.' + $PID
    [System.IO.File]::WriteAllText($temp, $Text, $Encoding)
    $lastError = $null
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            if ([System.IO.File]::Exists($Path)) {
                # [NullString]::Value: a plain $null would be marshalled as an empty string.
                [System.IO.File]::Replace($temp, $Path, [NullString]::Value)
            }
            else {
                [System.IO.File]::Move($temp, $Path)
            }
            return
        }
        catch {
            # The target is probably open in another process (a reader): retry shortly.
            $lastError = $_
            Start-Sleep -Milliseconds 100
        }
    }
    try {
        [System.IO.File]::Delete($temp)
    }
    catch {
        # The temporary file is left behind: nothing more can be done here.
        $temp = $temp
    }
    $reason = 'erreur inconnue'
    if ($null -ne $lastError) {
        $reason = $lastError.Exception.Message
    }
    throw ('Ecriture impossible de ' + $Path + ' : ' + $reason)
}

# Reads a JSON file and returns the object, or $null when the file is absent, unreadable,
# empty or not a JSON object. Never throws.
function Read-BLJsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    try {
        if (-not [System.IO.File]::Exists($Path)) {
            return $null
        }
        $text = [System.IO.File]::ReadAllText($Path, (Get-BLUtf8NoBom))
        if ([string]::IsNullOrEmpty($text) -or ($text.Trim().Length -eq 0)) {
            return $null
        }
        $parsed = ConvertFrom-Json -InputObject $text -ErrorAction Stop
        if ($null -eq $parsed) {
            return $null
        }
        if ($parsed -is [System.Management.Automation.PSCustomObject]) {
            return $parsed
        }
        return $null
    }
    catch {
        return $null
    }
}

# Rotates <Path> when it reaches 1 MB: <Path>.1 is the most recent archive, 3 are kept.
# Never throws.
function Invoke-BLLogRotation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    try {
        if (-not [System.IO.File]::Exists($Path)) {
            return
        }
        $info = New-Object System.IO.FileInfo($Path)
        if ($info.Length -lt $script:BLMaxLogBytes) {
            return
        }
        $oldest = $Path + '.' + $script:BLLogArchives
        if ([System.IO.File]::Exists($oldest)) {
            [System.IO.File]::Delete($oldest)
        }
        for ($index = $script:BLLogArchives - 1; $index -ge 1; $index--) {
            $source = $Path + '.' + $index
            $target = $Path + '.' + ($index + 1)
            if ([System.IO.File]::Exists($source)) {
                [System.IO.File]::Move($source, $target)
            }
        }
        [System.IO.File]::Move($Path, ($Path + '.1'))
    }
    catch {
        # A log that cannot be rotated right now (file in use) is rotated at a later call.
        return
    }
}

# Appends one line to logs\<Name>.log. Logging never throws and never creates the root
# directory by itself (so a dry run or a missing installation leaves no trace).
function Write-BLLog {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('supervisor', 'watchdog', 'install')]
        [string]$Name,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',
        [AllowEmptyString()]
        [string]$Message = ''
    )
    try {
        $paths = Get-BLPaths
        if (-not [System.IO.Directory]::Exists($paths.Root)) {
            return
        }
        if (-not [System.IO.Directory]::Exists($paths.Logs)) {
            [void][System.IO.Directory]::CreateDirectory($paths.Logs)
        }
        $file = Join-Path $paths.Logs ($Name + '.log')
        Invoke-BLLogRotation -Path $file
        $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        $flat = ($Message -replace '[\r\n]+', ' | ')
        $line = $stamp + ' [' + $Level + '] [' + $PID + '] ' + $flat + "`r`n"
        [System.IO.File]::AppendAllText($file, $line, (Get-BLUtf8NoBom))
    }
    catch {
        return
    }
}

# Returns the last <Count> lines of a text file (an empty array when absent or unreadable).
# The file is opened with full sharing: it may be written by another process.
function Get-BLFileTail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$Count = 10
    )
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $stream = $null
    $reader = $null
    try {
        if ([System.IO.File]::Exists($Path)) {
            $share = [System.IO.FileShare]'ReadWrite, Delete'
            $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
            # Only the last 64 KB are read: enough for a tail, whatever the file size.
            $window = 65536
            if ($stream.Length -gt $window) {
                [void]$stream.Seek(-$window, [System.IO.SeekOrigin]::End)
            }
            $reader = New-Object System.IO.StreamReader($stream, (Get-BLUtf8NoBom))
            $text = $reader.ReadToEnd()
            foreach ($line in ($text -split "`n")) {
                $clean = $line.TrimEnd("`r")
                if ($clean.Length -gt 0) {
                    $lines.Add($clean)
                }
            }
        }
    }
    catch {
        $lines.Clear()
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
    $skip = [Math]::Max(0, $lines.Count - $Count)
    $tail = New-Object 'System.Collections.Generic.List[string]'
    for ($index = $skip; $index -lt $lines.Count; $index++) {
        $tail.Add($lines[$index])
    }
    return $tail.ToArray()
}

# ---------------------------------------------------------------------------
# Configuration (design 4.2) and generated ssh_config (design 4.3)
# ---------------------------------------------------------------------------

# \A and \z are used instead of ^ and $ so that a trailing line feed can never slip through.
$script:BLPatternHostName = '\A[A-Za-z0-9]([A-Za-z0-9.\-]{0,252}[A-Za-z0-9])?\z'
$script:BLPatternHostIPv6 = '\A[0-9A-Fa-f:]{2,39}\z'
$script:BLPatternUser = '\A[a-z_][a-z0-9_\-]{0,31}\z'
$script:BLPatternAlias = '\A[A-Za-z0-9][A-Za-z0-9\-]{0,62}\z'
$script:BLPatternHelper = '\A/[A-Za-z0-9/._\-]{1,200}\z'
$script:BLPatternLabel = '\A[A-Za-z0-9._\-]{1,64}\z'
$script:BLPatternForward = '\A(L|R) (127\.0\.0\.1|localhost):([0-9]{1,5}) ([A-Za-z0-9.\-]{1,253}):([0-9]{1,5})\z'

# Case-sensitive, culture-invariant match of a whole value (never use -match here: it
# ignores case).
function Test-BLPattern {
    param(
        $Value,
        [string]$Pattern
    )
    if (-not ($Value -is [string])) {
        return $false
    }
    return [regex]::IsMatch($Value, $Pattern)
}

# Parses one Forwards entry. Returns a hashtable, or $null when the entry is invalid.
function ConvertTo-BLForwardInfo {
    param(
        $Forward
    )
    if (-not ($Forward -is [string])) {
        return $null
    }
    $match = [regex]::Match($Forward, $script:BLPatternForward)
    if (-not $match.Success) {
        return $null
    }
    $bindPort = [int]$match.Groups[3].Value
    $destPort = [int]$match.Groups[5].Value
    if (($bindPort -lt 1) -or ($bindPort -gt 65535) -or ($destPort -lt 1) -or ($destPort -gt 65535)) {
        return $null
    }
    return @{
        Kind     = $match.Groups[1].Value
        BindHost = $match.Groups[2].Value
        BindPort = $bindPort
        DestHost = $match.Groups[4].Value
        DestPort = $destPort
    }
}

# Returns the Forwards field as a clean list of strings (ConvertFrom-Json may hand back
# $null, a single string or an array).
function Get-BLForwardList {
    param(
        $Config
    )
    $list = New-Object 'System.Collections.Generic.List[string]'
    $raw = Get-BLProperty -Object $Config -Name 'Forwards'
    if ($null -ne $raw) {
        foreach ($item in @($raw)) {
            if ($null -ne $item) {
                $list.Add([string]$item)
            }
        }
    }
    return $list.ToArray()
}

# Returns '' when the value is an absolute path of an existing file without double quote
# nor line break, an error text otherwise.
function Get-BLFilePathError {
    param(
        $Value
    )
    if ((-not ($Value -is [string])) -or ($Value.Length -eq 0)) {
        return 'valeur absente'
    }
    if ($Value.IndexOfAny([char[]]@([char]34, [char]10, [char]13, [char]0)) -ge 0) {
        return 'guillemet ou saut de ligne interdit'
    }
    if (-not [regex]::IsMatch($Value, '\A([A-Za-z]:[\\/]|\\\\)')) {
        return 'chemin non absolu'
    }
    if (-not [System.IO.File]::Exists($Value)) {
        return 'fichier introuvable'
    }
    return ''
}

# Returns the list of validation errors (empty when the configuration is valid).
function Test-BLConfigObject {
    param(
        $Config,
        [switch]$SkipIdentityFile
    )
    $errors = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Config) {
        $errors.Add('configuration absente ou illisible')
        return $errors.ToArray()
    }

    $schema = ConvertTo-BLInteger -Value (Get-BLProperty -Object $Config -Name 'SchemaVersion')
    if (($null -eq $schema) -or ($schema -ne 1)) {
        $errors.Add('SchemaVersion : valeur attendue 1')
    }

    $vpsHost = Get-BLProperty -Object $Config -Name 'VpsHost'
    $hostOk = (Test-BLPattern -Value $vpsHost -Pattern $script:BLPatternHostName)
    if (-not $hostOk) {
        $hostOk = (Test-BLPattern -Value $vpsHost -Pattern $script:BLPatternHostIPv6)
    }
    if (-not $hostOk) {
        $errors.Add('VpsHost : nom d''hote ou adresse invalide')
    }

    if (-not (Test-BLPattern -Value (Get-BLProperty -Object $Config -Name 'VpsUser') -Pattern $script:BLPatternUser)) {
        $errors.Add('VpsUser : nom d''utilisateur invalide')
    }

    $port = ConvertTo-BLInteger -Value (Get-BLProperty -Object $Config -Name 'VpsPort')
    if (($null -eq $port) -or ($port -lt 1) -or ($port -gt 65535)) {
        $errors.Add('VpsPort : entier attendu entre 1 et 65535')
    }

    if (-not (Test-BLPattern -Value (Get-BLProperty -Object $Config -Name 'HostAlias') -Pattern $script:BLPatternAlias)) {
        $errors.Add('HostAlias : alias invalide')
    }

    if (-not (Test-BLPattern -Value (Get-BLProperty -Object $Config -Name 'VpsHelper') -Pattern $script:BLPatternHelper)) {
        $errors.Add('VpsHelper : chemin distant invalide')
    }

    if (-not (Test-BLPattern -Value (Get-BLProperty -Object $Config -Name 'ClientLabel') -Pattern $script:BLPatternLabel)) {
        $errors.Add('ClientLabel : etiquette invalide')
    }

    $minutes = ConvertTo-BLInteger -Value (Get-BLProperty -Object $Config -Name 'WatchdogMinutes')
    if (($null -eq $minutes) -or ($minutes -lt 1) -or ($minutes -gt 60)) {
        $errors.Add('WatchdogMinutes : entier attendu entre 1 et 60')
    }

    $index = 0
    foreach ($forward in @(Get-BLForwardList -Config $Config)) {
        if ($null -eq (ConvertTo-BLForwardInfo -Forward $forward)) {
            $errors.Add('Forwards[' + $index + '] : redirection invalide (attendu : "L|R 127.0.0.1:port hote:port")')
        }
        $index++
    }

    if (-not $SkipIdentityFile) {
        $identityError = Get-BLFilePathError -Value (Get-BLProperty -Object $Config -Name 'IdentityFile')
        if ($identityError.Length -gt 0) {
            $errors.Add('IdentityFile : ' + $identityError)
        }
    }

    $sshError = Get-BLFilePathError -Value (Get-BLProperty -Object $Config -Name 'SshExe')
    if ($sshError.Length -gt 0) {
        $errors.Add('SshExe : ' + $sshError)
    }

    if (-not ((Get-BLProperty -Object $Config -Name 'VpsSideInstalled') -is [bool])) {
        $errors.Add('VpsSideInstalled : booleen attendu')
    }

    $taskMode = Get-BLProperty -Object $Config -Name 'TaskMode'
    if (-not (($taskMode -is [string]) -and (($taskMode -ceq 'S4U') -or ($taskMode -ceq 'Interactive')))) {
        $errors.Add('TaskMode : S4U ou Interactive attendu')
    }

    return $errors.ToArray()
}

# Builds the canonical configuration record (fixed field order, plain types) from any
# object that passed Test-BLConfigObject.
function ConvertTo-BLConfigRecord {
    param(
        $Config
    )
    $identity = Get-BLProperty -Object $Config -Name 'IdentityFile' -Default ''
    if ($null -eq $identity) {
        $identity = ''
    }
    return [pscustomobject][ordered]@{
        SchemaVersion    = 1
        HostAlias        = [string](Get-BLProperty -Object $Config -Name 'HostAlias')
        VpsHost          = [string](Get-BLProperty -Object $Config -Name 'VpsHost')
        VpsPort          = [int](ConvertTo-BLInteger -Value (Get-BLProperty -Object $Config -Name 'VpsPort'))
        VpsUser          = [string](Get-BLProperty -Object $Config -Name 'VpsUser')
        IdentityFile     = [string]$identity
        SshExe           = [string](Get-BLProperty -Object $Config -Name 'SshExe')
        Forwards         = [string[]]@(Get-BLForwardList -Config $Config)
        WatchdogMinutes  = [int](ConvertTo-BLInteger -Value (Get-BLProperty -Object $Config -Name 'WatchdogMinutes'))
        VpsHelper        = [string](Get-BLProperty -Object $Config -Name 'VpsHelper')
        VpsSideInstalled = [bool](Get-BLProperty -Object $Config -Name 'VpsSideInstalled')
        ClientLabel      = [string](Get-BLProperty -Object $Config -Name 'ClientLabel')
        TaskMode         = [string](Get-BLProperty -Object $Config -Name 'TaskMode')
        InstalledAtUtc   = (ConvertTo-BLDateText -Value (Get-BLProperty -Object $Config -Name 'InstalledAtUtc'))
    }
}

# Reads and validates config.json. Throws a clear error when it is absent or invalid.
function Read-BLConfig {
    $paths = Get-BLPaths
    if (-not [System.IO.File]::Exists($paths.Config)) {
        throw ('Configuration introuvable : ' + $paths.Config + ' (le kit est-il installe ?)')
    }
    $raw = Read-BLJsonFile -Path $paths.Config
    $problems = @(Test-BLConfigObject -Config $raw)
    if ($problems.Count -gt 0) {
        throw ('Configuration invalide (' + $paths.Config + ') : ' + ($problems -join ' ; '))
    }
    return (ConvertTo-BLConfigRecord -Config $raw)
}

# Validates then writes config.json (atomic, UTF-8 without BOM).
function Write-BLConfig {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )
    $problems = @(Test-BLConfigObject -Config $Config)
    if ($problems.Count -gt 0) {
        throw ('Configuration invalide, rien n''est ecrit : ' + ($problems -join ' ; '))
    }
    $record = ConvertTo-BLConfigRecord -Config $Config
    $json = ConvertTo-Json -InputObject $record -Depth 5
    $paths = Get-BLPaths
    Write-BLTextFileAtomic -Path $paths.Config -Text ($json + "`n")
}

# Path as written in ssh_config or after -i: forward slashes, and optionally a doubled
# percent sign (IdentityFile goes through %-token expansion in every OpenSSH version).
function ConvertTo-BLSshPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [switch]$EscapePercent
    )
    if ($Path.IndexOfAny([char[]]@([char]34, [char]10, [char]13, [char]0)) -ge 0) {
        throw ('Chemin inutilisable par ssh (guillemet ou saut de ligne) : ' + $Path)
    }
    if ($Path.Contains('${')) {
        throw ('Chemin inutilisable par ssh (sequence "${") : ' + $Path)
    }
    $converted = $Path.Replace('\', '/')
    if ($EscapePercent) {
        $converted = $converted.Replace('%', '%%')
    }
    elseif ($converted.Contains('%')) {
        # known_hosts paths are %-expanded by recent OpenSSH only: no portable escaping.
        throw ('Chemin inutilisable par ssh (caractere "%") : ' + $Path)
    }
    return $converted
}

# Returns the text of the generated ssh_config (design 4.3). Every path is absolute.
function New-BLSshConfigText {
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [AllowEmptyCollection()]
        [string[]]$KnownHostsFiles = @()
    )
    $problems = @(Test-BLConfigObject -Config $Config)
    if ($problems.Count -gt 0) {
        throw ('Configuration invalide : ' + ($problems -join ' ; '))
    }
    $files = New-Object 'System.Collections.Generic.List[string]'
    foreach ($file in @($KnownHostsFiles)) {
        if (-not [string]::IsNullOrEmpty($file)) {
            $files.Add($file)
        }
    }
    if ($files.Count -eq 0) {
        $paths = Get-BLPaths
        $files.Add($paths.KnownHosts)
        $files.Add((Join-Path (Get-BLUserProfileDir) '.ssh\known_hosts'))
    }
    $quoted = New-Object 'System.Collections.Generic.List[string]'
    foreach ($file in $files) {
        $quoted.Add('"' + (ConvertTo-BLSshPath -Path $file) + '"')
    }
    $identity = ConvertTo-BLSshPath -Path ([string]$Config.IdentityFile) -EscapePercent
    $lines = @(
        ('Host ' + [string]$Config.HostAlias),
        ('    HostName ' + [string]$Config.VpsHost),
        ('    Port ' + [string][int]$Config.VpsPort),
        ('    User ' + [string]$Config.VpsUser),
        ('    IdentityFile "' + $identity + '"'),
        '    IdentitiesOnly yes',
        '    BatchMode yes',
        '    PasswordAuthentication no',
        '    StrictHostKeyChecking yes',
        ('    UserKnownHostsFile ' + ($quoted.ToArray() -join ' ')),
        '    ServerAliveInterval 30',
        '    ServerAliveCountMax 3',
        '    TCPKeepAlive yes',
        '    ConnectTimeout 15',
        '    ConnectionAttempts 1',
        '    ExitOnForwardFailure yes',
        '    LogLevel ERROR'
    )
    return (($lines -join "`n") + "`n")
}

# Writes <root>\ssh_config. The user's own ~/.ssh/config is never touched.
function Write-BLSshConfig {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )
    $paths = Get-BLPaths
    $text = New-BLSshConfigText -Config $Config
    Write-BLTextFileAtomic -Path $paths.SshConfig -Text $text
}

# Turns the Forwards entries into ssh arguments:
# 'R 127.0.0.1:22022 127.0.0.1:3389' gives '-R', '127.0.0.1:22022:127.0.0.1:3389'.
function ConvertTo-BLForwardArgs {
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Forwards = @()
    )
    $arguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($forward in @($Forwards)) {
        if ($null -eq $forward) {
            continue
        }
        $info = ConvertTo-BLForwardInfo -Forward $forward
        if ($null -eq $info) {
            throw ('Redirection invalide : ' + $forward)
        }
        $arguments.Add('-' + $info.Kind)
        $arguments.Add($info.BindHost + ':' + $info.BindPort + ':' + $info.DestHost + ':' + $info.DestPort)
    }
    return $arguments.ToArray()
}

# ---------------------------------------------------------------------------
# Native processes
# ---------------------------------------------------------------------------

# Builds one Windows command line from an argument list, following the rules of
# CommandLineToArgvW: quotes when the argument is empty or holds a space, a tab or a quote;
# backslashes are doubled only when they precede a quote (or the closing quote).
function Join-BLArguments {
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$ArgumentList = @()
    )
    $backslash = [char]92
    $quote = [char]34
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in @($ArgumentList)) {
        $argument = ''
        if ($null -ne $item) {
            $argument = [string]$item
        }
        if ($argument.Length -eq 0) {
            $parts.Add('""')
            continue
        }
        if (-not [regex]::IsMatch($argument, '[\s"]')) {
            $parts.Add($argument)
            continue
        }
        $builder = New-Object System.Text.StringBuilder
        [void]$builder.Append($quote)
        $pending = 0
        foreach ($character in $argument.ToCharArray()) {
            if ($character -eq $backslash) {
                $pending++
            }
            elseif ($character -eq $quote) {
                [void]$builder.Append($backslash, (($pending * 2) + 1))
                [void]$builder.Append($quote)
                $pending = 0
            }
            else {
                if ($pending -gt 0) {
                    [void]$builder.Append($backslash, $pending)
                    $pending = 0
                }
                [void]$builder.Append($character)
            }
        }
        if ($pending -gt 0) {
            [void]$builder.Append($backslash, ($pending * 2))
        }
        [void]$builder.Append($quote)
        $parts.Add($builder.ToString())
    }
    return ($parts.ToArray() -join ' ')
}

# Kills a process and all its descendants (taskkill /T /F), then makes sure the root
# process itself is gone. The Process object keeps a handle open, so its pid cannot have
# been reused by an unrelated process. Never throws.
function Stop-BLProcessTree {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process
    )
    $killer = $null
    try {
        if ($Process.HasExited) {
            return
        }
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = (Join-Path $env:SystemRoot 'System32\taskkill.exe')
        $startInfo.Arguments = '/PID ' + $Process.Id + ' /T /F'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $killer = [System.Diagnostics.Process]::Start($startInfo)
        if ($null -ne $killer) {
            [void]$killer.WaitForExit(10000)
        }
    }
    catch {
        # Falls through to the direct kill below.
        $killer = $killer
    }
    finally {
        if ($null -ne $killer) {
            $killer.Dispose()
        }
    }
    try {
        if (-not $Process.HasExited) {
            $Process.Kill()
        }
        [void]$Process.WaitForExit(5000)
    }
    catch {
        return
    }
}

# Result text of a ReadToEndAsync task ('' when it did not complete in time or failed).
function Get-BLTaskText {
    param(
        $Task,
        [int]$WaitMs = 5000
    )
    if ($null -eq $Task) {
        return ''
    }
    try {
        if ($Task.Wait($WaitMs)) {
            $text = $Task.Result
            if ($null -eq $text) {
                return ''
            }
            return [string]$text
        }
    }
    catch {
        return ''
    }
    return ''
}

# Runs a native executable without a window and returns
# @{ ExitCode; StdOut; StdErr; TimedOut }. Never throws: ExitCode is -2 when the process
# could not be started and -1 when it was killed after the timeout.
function Invoke-BLNative {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$ArgumentList = @(),
        [byte[]]$StdinBytes = $null,
        [int]$TimeoutSec = 30
    )
    $result = @{
        ExitCode = -1
        StdOut   = ''
        StdErr   = ''
        TimedOut = $false
    }
    if ($TimeoutSec -lt 1) {
        $TimeoutSec = 1
    }
    $process = New-Object System.Diagnostics.Process
    $outReader = $null
    $errReader = $null
    $outTask = $null
    $errTask = $null
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $FilePath
        $startInfo.Arguments = Join-BLArguments -ArgumentList $ArgumentList
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = Get-BLUtf8NoBom
        $startInfo.StandardErrorEncoding = Get-BLUtf8NoBom
        $process.StartInfo = $startInfo
        try {
            [void]$process.Start()
        }
        catch {
            $result.ExitCode = -2
            $result.StdErr = 'Lancement impossible de ' + $FilePath + ' : ' + $_.Exception.Message
            return $result
        }

        # Both outputs are drained asynchronously from the start: no pipe can fill up.
        $outReader = $process.StandardOutput
        $errReader = $process.StandardError
        $outTask = $outReader.ReadToEndAsync()
        $errTask = $errReader.ReadToEndAsync()

        # The raw stream is used (and closed) directly: closing the StreamWriter wrapper
        # could emit an encoding preamble into the child's stdin.
        $stdin = $process.StandardInput.BaseStream
        $writeTask = $null
        if (($null -ne $StdinBytes) -and ($StdinBytes.Length -gt 0)) {
            try {
                $writeTask = $stdin.WriteAsync($StdinBytes, 0, $StdinBytes.Length)
            }
            catch {
                $writeTask = $null
            }
        }

        $stdinOpen = $true
        $exited = $false
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            if ($stdinOpen -and (($null -eq $writeTask) -or $writeTask.IsCompleted)) {
                # Input fully written (or no input at all): close stdin at once.
                try {
                    $stdin.Close()
                }
                catch {
                    $stdinOpen = $false
                }
                $stdinOpen = $false
            }
            $slice = 200
            if ($stdinOpen) {
                $slice = 25
            }
            if ($process.WaitForExit($slice)) {
                $exited = $true
                break
            }
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSec) {
                break
            }
        }

        if (-not $exited) {
            $result.TimedOut = $true
            Stop-BLProcessTree -Process $process
        }
        if ($null -ne $writeTask) {
            # Observe the outcome of the write (a broken pipe is expected when the child
            # exits early).
            try {
                [void]$writeTask.Wait(3000)
            }
            catch {
                $writeTask = $null
            }
        }
        if ($stdinOpen) {
            try {
                $stdin.Close()
            }
            catch {
                $stdinOpen = $false
            }
        }

        $result.StdOut = Get-BLTaskText -Task $outTask -WaitMs 5000
        $result.StdErr = Get-BLTaskText -Task $errTask -WaitMs 5000
        if (-not $result.TimedOut) {
            $result.ExitCode = $process.ExitCode
        }
        return $result
    }
    catch {
        $result.ExitCode = -2
        $result.StdErr = 'Erreur pendant l''execution de ' + $FilePath + ' : ' + $_.Exception.Message
        try {
            Stop-BLProcessTree -Process $process
        }
        catch {
            $result.ExitCode = -2
        }
        return $result
    }
    finally {
        # Process.Dispose does not close the redirected readers. They are closed here, but
        # only once their read has completed (closing a pipe with a blocked read may hang).
        try {
            if (($null -ne $outReader) -and ($null -ne $outTask) -and $outTask.IsCompleted) {
                $outReader.Dispose()
            }
            if (($null -ne $errReader) -and ($null -ne $errTask) -and $errTask.IsCompleted) {
                $errReader.Dispose()
            }
        }
        catch {
            $outReader = $null
        }
        $process.Dispose()
    }
}

# Runs: ssh.exe -F <ssh_config> [options] <HostAlias> <RemoteCommand>
# Same result as Invoke-BLNative. The configuration must come from Read-BLConfig.
function Invoke-BLSsh {
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        [string]$RemoteCommand,
        [byte[]]$StdinBytes = $null,
        [int]$TimeoutSec = 30,
        [AllowEmptyCollection()]
        [string[]]$ExtraOptions = @()
    )
    $paths = Get-BLPaths
    $arguments = New-Object 'System.Collections.Generic.List[string]'
    $arguments.Add('-F')
    $arguments.Add($paths.SshConfig)
    foreach ($option in @($ExtraOptions)) {
        if (-not [string]::IsNullOrEmpty($option)) {
            $arguments.Add($option)
        }
    }
    $arguments.Add([string]$Config.HostAlias)
    $arguments.Add($RemoteCommand)
    return (Invoke-BLNative -FilePath ([string]$Config.SshExe) -ArgumentList $arguments.ToArray() -StdinBytes $StdinBytes -TimeoutSec $TimeoutSec)
}

# Classifies a failed ssh call: network | auth | hostkey | timeout | unknown.
# Only exit code 255 is classified as an error of ssh itself. ssh passes the exit code of the
# remote command through, so 255 may also come from the remote command.
function Get-BLClassifiedSshFailure {
    param(
        [Parameter(Mandatory = $true)]
        $Result
    )
    if ([bool](Get-BLProperty -Object $Result -Name 'TimedOut' -Default $false)) {
        return 'timeout'
    }
    $exitCode = Get-BLProperty -Object $Result -Name 'ExitCode' -Default (-1)
    if ($exitCode -ne 255) {
        return 'unknown'
    }
    $stderr = [string](Get-BLProperty -Object $Result -Name 'StdErr' -Default '')
    if ($stderr -match 'REMOTE HOST IDENTIFICATION HAS CHANGED') {
        return 'hostkey'
    }
    if ($stderr -match 'Host key verification failed') {
        return 'hostkey'
    }
    if ($stderr -match 'Permission denied') {
        return 'auth'
    }
    if ($stderr -match 'Connection refused|Could not resolve hostname|No route to host|Network is unreachable') {
        return 'network'
    }
    if ($stderr -match 'Connection timed out') {
        return 'timeout'
    }
    return 'unknown'
}

# Raw TCP connection test. Returns $true when the port accepts a connection in time.
function Test-BLTcp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [int]$TimeoutMs = 5000
    )
    $addresses = New-Object 'System.Collections.Generic.List[System.Net.IPAddress]'
    try {
        $literal = $null
        if ([System.Net.IPAddress]::TryParse($HostName, [ref]$literal)) {
            $addresses.Add($literal)
        }
        else {
            $lookup = [System.Net.Dns]::BeginGetHostAddresses($HostName, $null, $null)
            if ($lookup.AsyncWaitHandle.WaitOne($TimeoutMs)) {
                foreach ($address in @([System.Net.Dns]::EndGetHostAddresses($lookup))) {
                    if (($null -ne $address) -and ($addresses.Count -lt 4)) {
                        $addresses.Add($address)
                    }
                }
            }
        }
    }
    catch {
        return $false
    }
    foreach ($address in $addresses) {
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient($address.AddressFamily)
            $pending = $client.BeginConnect($address, $Port, $null, $null)
            if ($pending.AsyncWaitHandle.WaitOne($TimeoutMs)) {
                $client.EndConnect($pending)
                if ($client.Connected) {
                    return $true
                }
            }
        }
        catch {
            # Refused, unreachable or reset: try the next address.
            continue
        }
        finally {
            if ($null -ne $client) {
                $client.Close()
            }
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Pid files and tracked processes (design 4.1)
# ---------------------------------------------------------------------------

# Writes { "Pid": n, "StartTimeUtc": "<ISO 8601>" } for the given process.
function Write-BLPidFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process
    )
    $startText = Get-BLUtcNowText
    try {
        $startText = $Process.StartTime.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        # Process already gone: the file will simply not match any live process.
        $startText = Get-BLUtcNowText
    }
    $record = [pscustomobject][ordered]@{
        Pid          = [int]$Process.Id
        StartTimeUtc = [string]$startText
    }
    $json = ConvertTo-Json -InputObject $record -Depth 5
    Write-BLTextFileAtomic -Path $Path -Text ($json + "`n")
}

# Returns the live process described by a pid file, or $null. The process is "ours" only
# when the pid exists, the name matches and the start time agrees within 5 seconds.
# The caller owns the returned Process object (Dispose it).
function Get-BLTrackedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedName
    )
    $record = Read-BLJsonFile -Path $Path
    if ($null -eq $record) {
        return $null
    }
    $pidValue = ConvertTo-BLInteger -Value (Get-BLProperty -Object $record -Name 'Pid')
    $expectedStart = ConvertTo-BLUtcDate -Value (Get-BLProperty -Object $record -Name 'StartTimeUtc')
    if (($null -eq $pidValue) -or ($pidValue -le 0) -or ($pidValue -gt 2147483647) -or ($null -eq $expectedStart)) {
        return $null
    }
    $process = $null
    $ours = $false
    try {
        $process = [System.Diagnostics.Process]::GetProcessById([int]$pidValue)
        if (-not $process.HasExited) {
            if ($process.ProcessName -ieq $ExpectedName) {
                $delta = ($process.StartTime.ToUniversalTime() - $expectedStart).TotalSeconds
                if ([Math]::Abs($delta) -le 5) {
                    $ours = $true
                }
            }
        }
    }
    catch {
        # No such pid, or a process we may not query: not ours.
        $ours = $false
    }
    if ($ours) {
        return $process
    }
    if ($null -ne $process) {
        $process.Dispose()
    }
    return $null
}

# Kills the process described by a pid file (and its children), only when it is ours.
# Returns $true when a process was killed. Never throws.
function Stop-BLTrackedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedName
    )
    $killed = $false
    $process = $null
    try {
        $process = Get-BLTrackedProcess -Path $Path -ExpectedName $ExpectedName
        if ($null -ne $process) {
            Stop-BLProcessTree -Process $process
            $killed = $true
        }
    }
    catch {
        $killed = $false
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
    return $killed
}

# ---------------------------------------------------------------------------
# Watchdog state (design 4.5)
# ---------------------------------------------------------------------------

function New-BLDefaultState {
    return [pscustomobject][ordered]@{
        SchemaVersion       = 1
        LastRunUtc          = ''
        Healthy             = $false
        LastOkUtc           = ''
        ConsecutiveFailures = 0
        LastFailureReason   = 'none'
        NeedsHuman          = $false
        RepairsTotal        = 0
        LastRepairUtc       = ''
        LastRepairAction    = ''
        VpsView             = 'unknown'
        Checks              = [pscustomobject][ordered]@{
            Supervisor = $false
            Tunnel     = $false
            Probe      = $false
            Forwards   = $false
        }
    }
}

function ConvertTo-BLBoolean {
    param(
        $Value
    )
    if ($Value -is [bool]) {
        return $Value
    }
    return $false
}

function ConvertTo-BLCount {
    param(
        $Value
    )
    $number = ConvertTo-BLInteger -Value $Value
    if (($null -eq $number) -or ($number -lt 0)) {
        return 0
    }
    return [int]$number
}

# Copies any state-like object into a fresh, fully populated state record with plain types.
function ConvertTo-BLStateRecord {
    param(
        $State
    )
    $record = New-BLDefaultState
    if ($null -eq $State) {
        return $record
    }
    $record.LastRunUtc = ConvertTo-BLDateText -Value (Get-BLProperty -Object $State -Name 'LastRunUtc')
    $record.Healthy = ConvertTo-BLBoolean -Value (Get-BLProperty -Object $State -Name 'Healthy')
    $record.LastOkUtc = ConvertTo-BLDateText -Value (Get-BLProperty -Object $State -Name 'LastOkUtc')
    $record.ConsecutiveFailures = ConvertTo-BLCount -Value (Get-BLProperty -Object $State -Name 'ConsecutiveFailures')
    $reason = Get-BLProperty -Object $State -Name 'LastFailureReason'
    $knownReasons = @('none', 'network', 'auth', 'hostkey', 'timeout', 'tunnel', 'supervisor', 'forwards', 'unknown')
    if (($reason -is [string]) -and ($knownReasons -ccontains $reason)) {
        $record.LastFailureReason = [string]$reason
    }
    $record.NeedsHuman = ConvertTo-BLBoolean -Value (Get-BLProperty -Object $State -Name 'NeedsHuman')
    $record.RepairsTotal = ConvertTo-BLCount -Value (Get-BLProperty -Object $State -Name 'RepairsTotal')
    $record.LastRepairUtc = ConvertTo-BLDateText -Value (Get-BLProperty -Object $State -Name 'LastRepairUtc')
    $action = Get-BLProperty -Object $State -Name 'LastRepairAction'
    if ($action -is [string]) {
        $record.LastRepairAction = [string]$action
    }
    $view = Get-BLProperty -Object $State -Name 'VpsView'
    if (($view -is [string]) -and (@('up', 'down', 'unknown') -ccontains $view)) {
        $record.VpsView = [string]$view
    }
    $checks = Get-BLProperty -Object $State -Name 'Checks'
    if ($null -ne $checks) {
        $record.Checks.Supervisor = ConvertTo-BLBoolean -Value (Get-BLProperty -Object $checks -Name 'Supervisor')
        $record.Checks.Tunnel = ConvertTo-BLBoolean -Value (Get-BLProperty -Object $checks -Name 'Tunnel')
        $record.Checks.Probe = ConvertTo-BLBoolean -Value (Get-BLProperty -Object $checks -Name 'Probe')
        $record.Checks.Forwards = ConvertTo-BLBoolean -Value (Get-BLProperty -Object $checks -Name 'Forwards')
    }
    return $record
}

# Reads state.json. Defaults are returned when the file is absent or corrupted.
function Read-BLState {
    $paths = Get-BLPaths
    return (ConvertTo-BLStateRecord -State (Read-BLJsonFile -Path $paths.State))
}

# Writes state.json (atomic, UTF-8 without BOM).
function Write-BLState {
    param(
        [Parameter(Mandatory = $true)]
        $State
    )
    $record = ConvertTo-BLStateRecord -State $State
    $json = ConvertTo-Json -InputObject $record -Depth 5
    $paths = Get-BLPaths
    Write-BLTextFileAtomic -Path $paths.State -Text ($json + "`n")
}

# ---------------------------------------------------------------------------
# Scheduled tasks (ScheduledTasks module only)
# ---------------------------------------------------------------------------

# Returns @{ Exists; Enabled; State }. State is the task state text, 'Absent' when the task
# does not exist, 'Unknown' when the scheduler could not be queried. Never throws.
function Test-BLTask {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    $result = @{
        Exists  = $false
        Enabled = $false
        State   = 'Absent'
    }
    $task = $null
    try {
        $found = @(Get-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction Stop)
        if ($found.Count -gt 0) {
            $task = $found[0]
        }
    }
    catch {
        $notFound = $false
        if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) {
            $notFound = $true
        }
        if ([string]$_.FullyQualifiedErrorId -match 'NotFound') {
            $notFound = $true
        }
        if (-not $notFound) {
            # Unknown, not absent: Exists is $null so that no caller acts on a guess.
            $result.Exists = $null
            $result.State = 'Unknown'
        }
        return $result
    }
    if ($null -eq $task) {
        return $result
    }
    $result.Exists = $true
    $result.State = 'Unknown'
    try {
        $result.State = [string]$task.State
        $result.Enabled = ([bool]$task.Settings.Enabled) -and ($result.State -ne 'Disabled')
    }
    catch {
        # The task exists but could not be inspected: assume it is enabled, never guess
        # that it must be re-registered.
        $result.Enabled = $true
    }
    return $result
}

# Rewrites an exported task definition so that it can be registered without elevation:
# no boot trigger, interactive logon, hidden launcher. Used only as a fallback by
# Repair-BLTask when the original definition is refused.
function ConvertTo-BLInteractiveTaskXml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Xml,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    $paths = Get-BLPaths
    $names = Get-BLTaskNames
    $scriptPath = $paths.WatchdogScript
    if ($Name -eq $names.Tunnel) {
        $scriptPath = $paths.SupervisorScript
    }
    $document = New-Object System.Xml.XmlDocument
    $document.LoadXml($Xml)
    $namespaces = New-Object System.Xml.XmlNamespaceManager($document.NameTable)
    $namespaces.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
    foreach ($node in @($document.SelectNodes('//t:Triggers/t:BootTrigger', $namespaces))) {
        [void]$node.ParentNode.RemoveChild($node)
    }
    foreach ($node in @($document.SelectNodes('//t:Principals/t:Principal/t:LogonType', $namespaces))) {
        $node.InnerText = 'InteractiveToken'
    }
    foreach ($node in @($document.SelectNodes('//t:Actions/t:Exec/t:Command', $namespaces))) {
        $node.InnerText = (Join-Path $env:SystemRoot 'System32\wscript.exe')
    }
    foreach ($node in @($document.SelectNodes('//t:Actions/t:Exec/t:Arguments', $namespaces))) {
        $node.InnerText = '"' + $paths.LaunchVbs + '" "' + $scriptPath + '"'
    }
    return $document.OuterXml
}

# Re-registers a task of the kit from tasks\<Name>.xml when it is absent, re-enables it when
# it is disabled. Returns the list of actions done (empty when nothing was needed).
# Never throws: failures are logged in logs\<LogName>.log.
function Repair-BLTask {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [ValidateSet('supervisor', 'watchdog', 'install')]
        [string]$LogName = 'watchdog'
    )
    $actions = New-Object 'System.Collections.Generic.List[string]'
    try {
        $names = Get-BLTaskNames
        if (($Name -ne $names.Tunnel) -and ($Name -ne $names.Watchdog)) {
            Write-BLLog -Name $LogName -Level 'ERROR' -Message ('Reparation refusee : tache inconnue ' + $Name)
            return $actions.ToArray()
        }
        $paths = Get-BLPaths
        if ([System.IO.File]::Exists($paths.StopFlag)) {
            # A stop was requested (reinstall or uninstall in progress): repairing now
            # would resurrect a task that is being removed on purpose.
            return $actions.ToArray()
        }
        $info = Test-BLTask -Name $Name
        if ($null -eq $info.Exists) {
            # The scheduler did not answer: a task is never registered on an unknown state.
            Write-BLLog -Name $LogName -Level 'WARN' -Message ('Etat de la tache ' + $Name + ' inconnu (planificateur ne repond pas) : aucune reparation.')
            return $actions.ToArray()
        }
        if (-not $info.Exists) {
            $xmlPath = Join-Path $paths.Tasks ($Name + '.xml')
            if (-not [System.IO.File]::Exists($xmlPath)) {
                Write-BLLog -Name $LogName -Level 'ERROR' -Message ('Tache ' + $Name + ' absente et definition introuvable : ' + $xmlPath)
                return $actions.ToArray()
            }
            $xml = [System.IO.File]::ReadAllText($xmlPath, [System.Text.Encoding]::Unicode)
            $registered = $false
            try {
                # No -Force: an existing task is never overwritten by a repair.
                Register-ScheduledTask -TaskName $Name -TaskPath '\' -Xml $xml -ErrorAction Stop | Out-Null
                $registered = $true
                $actions.Add('register:' + $Name)
            }
            catch {
                Write-BLLog -Name $LogName -Level 'WARN' -Message ('Re-enregistrement de ' + $Name + ' refuse (' + $_.Exception.Message + '), essai en mode interactif')
            }
            if (-not $registered) {
                $fallbackXml = ConvertTo-BLInteractiveTaskXml -Xml $xml -Name $Name
                Register-ScheduledTask -TaskName $Name -TaskPath '\' -Xml $fallbackXml -ErrorAction Stop | Out-Null
                $actions.Add('register-interactive:' + $Name)
            }
            Write-BLLog -Name $LogName -Level 'WARN' -Message ('Tache ' + $Name + ' absente : re-enregistree depuis ' + $xmlPath)
        }
        elseif (-not $info.Enabled) {
            Enable-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction Stop | Out-Null
            $actions.Add('enable:' + $Name)
            Write-BLLog -Name $LogName -Level 'WARN' -Message ('Tache ' + $Name + ' desactivee : reactivee')
        }
    }
    catch {
        Write-BLLog -Name $LogName -Level 'ERROR' -Message ('Reparation de la tache ' + $Name + ' impossible : ' + $_.Exception.Message)
    }
    return $actions.ToArray()
}

# ---------------------------------------------------------------------------
# Named mutexes
# ---------------------------------------------------------------------------

# Tries to take the named mutex Global\<Name> (Local\<Name> when the global namespace is
# refused) without waiting. Returns @{ Mutex; Acquired; FullName }. An abandoned mutex
# counts as acquired. When no mutex object can be created at all, Acquired is $true and
# Mutex is $null (the scheduler's "ignore new instance" rule remains the only guard).
function Enter-BLMutex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [int]$TimeoutMs = 0
    )
    $result = @{
        Mutex    = $null
        Acquired = $false
        FullName = ''
    }
    foreach ($prefix in @('Global\', 'Local\')) {
        $fullName = $prefix + $Name
        $mutex = $null
        try {
            $mutex = New-Object System.Threading.Mutex($false, $fullName)
        }
        catch {
            $mutex = $null
        }
        if ($null -eq $mutex) {
            continue
        }
        $result.Mutex = $mutex
        $result.FullName = $fullName
        try {
            $result.Acquired = [bool]$mutex.WaitOne($TimeoutMs)
        }
        catch {
            $abandoned = $false
            $exception = $_.Exception
            while ($null -ne $exception) {
                if ($exception -is [System.Threading.AbandonedMutexException]) {
                    $abandoned = $true
                }
                $exception = $exception.InnerException
            }
            # The previous owner died without releasing: the mutex is ours now.
            $result.Acquired = $abandoned
        }
        break
    }
    if ($null -eq $result.Mutex) {
        $result.Acquired = $true
    }
    return $result
}

# Releases and disposes what Enter-BLMutex returned. Call it from a finally block.
function Exit-BLMutex {
    param(
        $MutexInfo
    )
    if ($null -eq $MutexInfo) {
        return
    }
    $mutex = Get-BLProperty -Object $MutexInfo -Name 'Mutex'
    if ($null -eq $mutex) {
        return
    }
    try {
        if ([bool](Get-BLProperty -Object $MutexInfo -Name 'Acquired' -Default $false)) {
            $mutex.ReleaseMutex()
        }
    }
    catch {
        # Not owned by this thread any more: nothing to release.
        $mutex = $mutex
    }
    try {
        $mutex.Dispose()
    }
    catch {
        return
    }
}
