# Install-BokadorLink.ps1 - installer of the bokador-link kit (docs/DESIGN.md, section 4.6).
# Run it from the repository. It is idempotent: running it again stops the existing link,
# replaces the files and registers the tasks again.
# Exit codes: 0 healthy link (or successful dry run), 1 failure, 2 human action required
# (no working key: the public key to authorize is displayed), 3 OpenSSH client missing.
# Target: Windows PowerShell 5.1. Keep this file plain ASCII.

param(
    [Parameter(Mandatory = $true)]
    [string]$VpsHost,
    [string]$VpsUser = 'root',
    [int]$VpsPort = 22,
    [string]$IdentityFile = '',
    [string[]]$Forward = @(),
    [int]$WatchdogMinutes = 3,
    [switch]$SkipVps,
    [switch]$InteractiveOnly,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:LogEnabled = $false

# Console message, copied to logs\install.log once the installation directory exists.
function Write-Step {
    param(
        [AllowEmptyString()]
        [string]$Message = '',
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $prefix = ''
    if ($Level -eq 'WARN') {
        $prefix = 'ATTENTION : '
    }
    if ($Level -eq 'ERROR') {
        $prefix = 'ERREUR : '
    }
    Write-Host ($prefix + $Message)
    if ($script:LogEnabled) {
        Write-BLLog -Name 'install' -Level $Level -Message $Message
    }
}

# Step 1 helper: full path of an OpenSSH tool, '' when it is not installed.
function Find-OpenSshTool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    $found = @(Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
    if ($found.Count -gt 0) {
        $candidate = [string]$found[0].Path
        if ((-not [string]::IsNullOrEmpty($candidate)) -and [System.IO.File]::Exists($candidate)) {
            return $candidate
        }
    }
    if (-not [string]::IsNullOrEmpty($env:SystemRoot)) {
        $candidate = Join-Path $env:SystemRoot ('System32\OpenSSH\' + $Name)
        if ([System.IO.File]::Exists($candidate)) {
            return $candidate
        }
    }
    return ''
}

# Lines of a command output, without line endings and without empty lines.
function Get-TextLines {
    param(
        [AllowEmptyString()]
        [string]$Text = ''
    )
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrEmpty($Text)) {
        foreach ($line in ($Text -split "`n")) {
            $clean = $line.Trim()
            if ($clean.Length -gt 0) {
                $lines.Add($clean)
            }
        }
    }
    return $lines.ToArray()
}

# True when one line of the text is exactly the marker, or starts with the marker followed
# by a space.
function Test-OutputMarker {
    param(
        [AllowEmptyString()]
        [string]$Text = '',
        [Parameter(Mandatory = $true)]
        [string]$Marker
    )
    foreach ($line in @(Get-TextLines -Text $Text)) {
        if (($line -ceq $Marker) -or $line.StartsWith($Marker + ' ', [System.StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}

# Copy of a byte array with every CRLF turned into LF (the VPS helper must reach bash with
# LF line endings whatever the checkout did).
function ConvertTo-LfBytes {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )
    $stream = New-Object System.IO.MemoryStream
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        $current = $Bytes[$index]
        if (($current -eq 13) -and (($index + 1) -lt $Bytes.Length) -and ($Bytes[$index + 1] -eq 10)) {
            continue
        }
        $stream.WriteByte($current)
    }
    $converted = $stream.ToArray()
    $stream.Dispose()
    # The comma keeps the byte array whole on its way out of the function.
    return , $converted
}

# Step 2 helper: tests one candidate key without writing anything in the kit directory.
# Returns @{ Works; Cause; Detail }.
function Test-KeyCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath,
        [Parameter(Mandatory = $true)]
        [string]$SshExe,
        [Parameter(Mandatory = $true)]
        [string[]]$HostKeyOptions,
        [Parameter(Mandatory = $true)]
        [string]$Target,
        [Parameter(Mandatory = $true)]
        [int]$Port
    )
    $arguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in @('-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=10')) {
        $arguments.Add($item)
    }
    foreach ($item in @($HostKeyOptions)) {
        $arguments.Add($item)
    }
    $arguments.Add('-i')
    $arguments.Add((ConvertTo-BLSshPath -Path $KeyPath -EscapePercent))
    $arguments.Add('-p')
    $arguments.Add([string]$Port)
    $arguments.Add($Target)
    $arguments.Add('echo BOKADOR_LINK_OK')
    $result = Invoke-BLNative -FilePath $SshExe -ArgumentList $arguments.ToArray() -TimeoutSec 40
    $outcome = @{
        Works  = $false
        Cause  = 'unknown'
        Detail = ''
    }
    if (Test-OutputMarker -Text ([string]$result.StdOut) -Marker 'BOKADOR_LINK_OK') {
        $outcome.Works = $true
        $outcome.Cause = 'none'
        return $outcome
    }
    $outcome.Cause = Get-BLClassifiedSshFailure -Result $result
    $errorLines = @(Get-TextLines -Text ([string]$result.StdErr))
    if ($errorLines.Count -gt 0) {
        $outcome.Detail = [string]$errorLines[$errorLines.Count - 1]
    }
    else {
        $outcome.Detail = 'code de sortie ' + $result.ExitCode
    }
    return $outcome
}

# Step 6 helper: registers both tasks in the given mode ('S4U' or 'Interactive').
# Throws when the scheduler refuses one of them.
function Register-KitTasks {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('S4U', 'Interactive')]
        [string]$Mode,
        [Parameter(Mandatory = $true)]
        $Paths,
        [Parameter(Mandatory = $true)]
        [string]$UserId,
        [Parameter(Mandatory = $true)]
        [int]$Minutes
    )
    $names = Get-BLTaskNames
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $wscriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $definitions = @(
        @{ Name = $names.Tunnel; Script = $Paths.SupervisorScript; Kind = 'Tunnel' },
        @{ Name = $names.Watchdog; Script = $Paths.WatchdogScript; Kind = 'Watchdog' }
    )
    foreach ($definition in $definitions) {
        $scriptPath = [string]$definition.Script
        if ($scriptPath.Contains('"')) {
            throw ('Chemin de script inutilisable : ' + $scriptPath)
        }
        if ($Mode -eq 'S4U') {
            # Direct action: no window at all, runs without an open session.
            $argumentText = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
            $action = New-ScheduledTaskAction -Execute $powershellExe -Argument $argumentText
            $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType S4U -RunLevel Limited
        }
        else {
            # Interactive session: the VBS launcher avoids a flashing console window.
            $argumentText = '"' + [string]$Paths.LaunchVbs + '" "' + $scriptPath + '"'
            $action = New-ScheduledTaskAction -Execute $wscriptExe -Argument $argumentText
            $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited
        }

        $triggers = New-Object 'System.Collections.Generic.List[object]'
        if ($definition.Kind -eq 'Watchdog') {
            # Repeats forever: no repetition duration is given.
            $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $Minutes)
            $triggers.Add($repeat)
        }
        $triggers.Add((New-ScheduledTaskTrigger -AtLogOn -User $UserId))
        if ($Mode -eq 'S4U') {
            $triggers.Add((New-ScheduledTaskTrigger -AtStartup))
        }

        if ($definition.Kind -eq 'Tunnel') {
            # Zero execution time limit means unlimited.
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
            $description = 'bokador-link : superviseur du tunnel SSH vers le VPS.'
        }
        else {
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
            $description = 'bokador-link : chien de garde de la liaison SSH.'
        }

        Register-ScheduledTask -TaskName ([string]$definition.Name) -TaskPath '\' -Action $action -Trigger $triggers.ToArray() -Principal $principal -Settings $settings -Description $description -Force -ErrorAction Stop | Out-Null
    }
}

# Stops (when asked) and removes the tasks of the kit that exist. Never throws.
function Remove-KitTasks {
    param(
        [switch]$StopOnly
    )
    $names = Get-BLTaskNames
    foreach ($name in @($names.Watchdog, $names.Tunnel)) {
        $info = Test-BLTask -Name $name
        if (-not $info.Exists) {
            continue
        }
        try {
            Stop-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Step -Level 'WARN' -Message ('Arret de la tache ' + $name + ' : ' + $_.Exception.Message)
        }
        if ($StopOnly) {
            continue
        }
        try {
            Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Step -Level 'WARN' -Message ('Suppression de la tache ' + $name + ' : ' + $_.Exception.Message)
        }
    }
}

# Exports both task definitions to tasks\<Name>.xml (UTF-16, as the scheduler expects)
# for the self-repair of Repair-BLTask.
function Export-KitTasks {
    param(
        [Parameter(Mandatory = $true)]
        $Paths
    )
    $names = Get-BLTaskNames
    foreach ($name in @($names.Tunnel, $names.Watchdog)) {
        $xml = [string](Export-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction Stop)
        if ([string]::IsNullOrEmpty($xml)) {
            throw ('Export vide pour la tache ' + $name)
        }
        $target = Join-Path $Paths.Tasks ($name + '.xml')
        Write-BLTextFileAtomic -Path $target -Text $xml -Encoding ([System.Text.Encoding]::Unicode)
    }
}

# Step 7 helper: waits until the supervisor and its ssh are tracked.
# Returns @{ Supervisor; Tunnel }.
function Wait-TunnelStart {
    param(
        [Parameter(Mandatory = $true)]
        $Paths,
        [int]$TimeoutSec = 45
    )
    $seen = @{
        Supervisor = $false
        Tunnel     = $false
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $supervisor = Get-BLTrackedProcess -Path $Paths.SupervisorPid -ExpectedName 'powershell'
        if ($null -ne $supervisor) {
            $seen.Supervisor = $true
            $supervisor.Dispose()
        }
        $tunnel = Get-BLTrackedProcess -Path $Paths.TunnelPid -ExpectedName 'ssh'
        if ($null -ne $tunnel) {
            $seen.Tunnel = $true
            $tunnel.Dispose()
            break
        }
        Start-Sleep -Milliseconds 500
    }
    return $seen
}

# ---------------------------------------------------------------------------
# Step 0: parse every script of the kit. Nothing has been modified yet.
# ---------------------------------------------------------------------------

$windowsDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $windowsDir
$repoVpsHelper = Join-Path $repoRoot 'vps\bokador-link'
$commonLibrary = Join-Path $windowsDir 'lib\BokadorLink.Common.ps1'

# Source file (in the repository) and its place under <root>\bin.
$kitFiles = @(
    @{ Source = (Join-Path $windowsDir 'Link-Supervisor.ps1'); Target = 'Link-Supervisor.ps1' },
    @{ Source = (Join-Path $windowsDir 'Link-Watchdog.ps1'); Target = 'Link-Watchdog.ps1' },
    @{ Source = (Join-Path $windowsDir 'Get-BokadorLinkStatus.ps1'); Target = 'Get-BokadorLinkStatus.ps1' },
    @{ Source = (Join-Path $windowsDir 'Uninstall-BokadorLink.ps1'); Target = 'Uninstall-BokadorLink.ps1' },
    @{ Source = $commonLibrary; Target = 'lib\BokadorLink.Common.ps1' },
    @{ Source = (Join-Path $windowsDir 'launch-hidden.vbs'); Target = 'launch-hidden.vbs' },
    @{ Source = $repoVpsHelper; Target = 'vps\bokador-link' }
)

try {
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Host 'ERREUR : Windows PowerShell 5.1 ou plus recent est requis.'
        exit 1
    }
    $toParse = New-Object 'System.Collections.Generic.List[string]'
    $toParse.Add((Join-Path $windowsDir 'Install-BokadorLink.ps1'))
    $kitIncomplete = $false
    foreach ($kitFile in $kitFiles) {
        if (-not [System.IO.File]::Exists([string]$kitFile.Source)) {
            Write-Host ('ERREUR : fichier du kit introuvable : ' + [string]$kitFile.Source)
            $kitIncomplete = $true
            continue
        }
        if ([string]$kitFile.Source -like '*.ps1') {
            $toParse.Add([string]$kitFile.Source)
        }
    }
    if ($kitIncomplete) {
        Write-Host 'Le depot est incomplet : rien n''a ete modifie.'
        exit 1
    }
    $parseFailed = $false
    foreach ($file in $toParse) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$parseErrors)
        foreach ($parseError in @($parseErrors)) {
            if ($null -eq $parseError) {
                continue
            }
            $parseFailed = $true
            Write-Host ('ERREUR de syntaxe : ' + $file + ' ligne ' + $parseError.Extent.StartLineNumber + ' : ' + $parseError.Message)
        }
    }
    if ($parseFailed) {
        Write-Host 'Analyse syntaxique en echec : rien n''a ete modifie.'
        exit 1
    }
}
catch {
    Write-Host ('ERREUR pendant l''analyse du kit : ' + $_.Exception.Message)
    exit 1
}

. $commonLibrary

# ---------------------------------------------------------------------------
# Steps 1 to 7
# ---------------------------------------------------------------------------

$exitCode = 1
$tempDir = $null
try {
    if ([Environment]::Is64BitOperatingSystem -and (-not [Environment]::Is64BitProcess)) {
        Write-Step -Level 'ERROR' -Message 'Lancer l''installateur depuis un PowerShell 64 bits (le client OpenSSH n''est pas visible en 32 bits).'
        exit 1
    }
    if ($DryRun) {
        Write-Step -Message 'Mode -DryRun : description seule, rien n''est modifie.'
    }

    # --- Step 1: OpenSSH client -------------------------------------------------
    $sshExe = Find-OpenSshTool -Name 'ssh.exe'
    $sshKeygenExe = Find-OpenSshTool -Name 'ssh-keygen.exe'
    if (($sshExe.Length -eq 0) -or ($sshKeygenExe.Length -eq 0)) {
        Write-Step -Level 'ERROR' -Message 'Client OpenSSH introuvable (ssh.exe et ssh-keygen.exe).'
        Write-Step -Message 'Pour l''installer, ouvrir un PowerShell en administrateur et lancer :'
        Write-Step -Message '    Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0'
        Write-Step -Message 'puis relancer cet installateur.'
        exit 3
    }
    Write-Step -Message ('[1/7] Client OpenSSH : ' + $sshExe)

    # --- Parameters: everything is validated before the first command line -------
    $VpsHost = $VpsHost.Trim()
    $VpsUser = $VpsUser.Trim()
    $forwardList = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in @($Forward)) {
        if ($null -eq $item) {
            continue
        }
        # With "powershell -File", several values arrive as one comma separated string.
        foreach ($part in ([string]$item -split ',')) {
            $clean = $part.Trim()
            if ($clean.Length -gt 0) {
                $forwardList.Add($clean)
            }
        }
    }
    $clientLabel = ([string]$env:COMPUTERNAME) -replace '[^A-Za-z0-9._\-]', '-'
    if ($clientLabel.Length -gt 64) {
        $clientLabel = $clientLabel.Substring(0, 64)
    }
    if ($clientLabel.Length -eq 0) {
        $clientLabel = 'pc'
    }
    $draft = @{
        SchemaVersion    = 1
        HostAlias        = 'bokador-link-vps'
        VpsHost          = $VpsHost
        VpsPort          = $VpsPort
        VpsUser          = $VpsUser
        IdentityFile     = ''
        SshExe           = $sshExe
        Forwards         = [string[]]$forwardList.ToArray()
        WatchdogMinutes  = $WatchdogMinutes
        VpsHelper        = '/usr/local/sbin/bokador-link'
        VpsSideInstalled = $false
        ClientLabel      = $clientLabel
        TaskMode         = 'Interactive'
        InstalledAtUtc   = (Get-BLUtcNowText)
    }
    $problems = @(Test-BLConfigObject -Config $draft -SkipIdentityFile)
    if ($problems.Count -gt 0) {
        Write-Step -Level 'ERROR' -Message 'Parametres invalides :'
        foreach ($problem in $problems) {
            Write-Step -Message ('    ' + $problem)
        }
        exit 1
    }

    $paths = Get-BLPaths
    $names = Get-BLTaskNames
    $userSshDir = Join-Path (Get-BLUserProfileDir) '.ssh'
    $userKnownHosts = Join-Path $userSshDir 'known_hosts'
    $target = $VpsUser + '@' + $VpsHost
    Write-Step -Message ('Repertoire d''installation : ' + $paths.Root)
    Write-Step -Message ('Cible : ' + $target + ' port ' + $VpsPort)

    # --- Step 3 (prepared before step 2): host key policy -------------------------
    # ssh-keygen -F needs the form [host]:port when the port is not 22.
    $hostSpec = $VpsHost
    if ($VpsPort -ne 22) {
        $hostSpec = '[' + $VpsHost + ']:' + $VpsPort
    }
    $hostKnownByUser = $false
    if ([System.IO.File]::Exists($userKnownHosts)) {
        $lookup = Invoke-BLNative -FilePath $sshKeygenExe -ArgumentList @('-F', $hostSpec, '-f', $userKnownHosts) -TimeoutSec 20
        if (($lookup.ExitCode -eq 0) -and (([string]$lookup.StdOut).Trim().Length -gt 0)) {
            $hostKnownByUser = $true
        }
    }
    $hostKeyOptions = New-Object 'System.Collections.Generic.List[string]'
    $tempKnownHosts = ''
    $hostKeyOptions.Add('-o')
    if ($hostKnownByUser) {
        Write-Step -Message '[3/7] Cle d''hote deja connue dans le known_hosts de l''utilisateur : verification stricte.'
        $hostKeyOptions.Add('StrictHostKeyChecking=yes')
    }
    else {
        # First contact (trust on first use). The key is recorded in a temporary file,
        # seeded with the kit's own known_hosts so that a changed key is still refused.
        Write-Step -Message '[3/7] Cle d''hote inconnue de l''utilisateur : premier contact (accept-new) dans le known_hosts du kit.'
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('bokador-link-' + [Guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($tempDir)
        $tempKnownHosts = Join-Path $tempDir 'known_hosts'
        if ([System.IO.File]::Exists($paths.KnownHosts)) {
            [System.IO.File]::Copy($paths.KnownHosts, $tempKnownHosts, $true)
        }
        $hostKeyOptions.Add('StrictHostKeyChecking=accept-new')
        $hostKeyOptions.Add('-o')
        $hostKeyOptions.Add('UserKnownHostsFile="' + (ConvertTo-BLSshPath -Path $tempKnownHosts) + '"')
    }

    # --- Step 2: choice of the key -----------------------------------------------
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrEmpty($IdentityFile)) {
        $resolved = ''
        try {
            $resolved = [string](Resolve-Path -LiteralPath $IdentityFile -ErrorAction Stop).ProviderPath
        }
        catch {
            $resolved = ''
        }
        $identityError = Get-BLFilePathError -Value $resolved
        if ($identityError.Length -gt 0) {
            Write-Step -Level 'ERROR' -Message ('-IdentityFile ' + $IdentityFile + ' : ' + $identityError)
            exit 1
        }
        if ($resolved -like '*.pub') {
            Write-Step -Level 'ERROR' -Message '-IdentityFile doit designer la cle privee, pas le fichier .pub.'
            exit 1
        }
        $candidates.Add($resolved)
    }
    elseif ([System.IO.Directory]::Exists($userSshDir)) {
        # Files of %USERPROFILE%\.ssh that have a .pub twin, names containing "vps" first.
        $others = New-Object 'System.Collections.Generic.List[string]'
        foreach ($file in @(Get-ChildItem -LiteralPath $userSshDir -File -ErrorAction SilentlyContinue | Sort-Object -Property Name)) {
            if ($file.Name -like '*.pub') {
                continue
            }
            if (-not [System.IO.File]::Exists($file.FullName + '.pub')) {
                continue
            }
            if ($file.Name -match 'vps') {
                $candidates.Add([string]$file.FullName)
            }
            else {
                $others.Add([string]$file.FullName)
            }
        }
        foreach ($other in $others) {
            $candidates.Add($other)
        }
    }

    Write-Step -Message ('[2/7] Recherche d''une cle fonctionnelle (' + $candidates.Count + ' candidate(s)).')
    $chosenKey = ''
    $authFailures = 0
    $otherFailure = ''
    foreach ($candidate in $candidates) {
        $test = Test-KeyCandidate -KeyPath $candidate -SshExe $sshExe -HostKeyOptions $hostKeyOptions.ToArray() -Target $target -Port $VpsPort
        if ($test.Works) {
            Write-Step -Message ('    ' + $candidate + ' : fonctionne.')
            $chosenKey = $candidate
            break
        }
        Write-Step -Message ('    ' + $candidate + ' : refusee (' + $test.Cause + ') ' + $test.Detail)
        if ($test.Cause -eq 'hostkey') {
            Write-Step -Level 'ERROR' -Message 'La cle d''hote du VPS ne correspond pas a celle deja enregistree. Installation arretee.'
            Write-Step -Message 'Verifier l''empreinte du serveur avant toute chose ; le kit n''accepte jamais une cle d''hote modifiee.'
            exit 1
        }
        if (($test.Cause -eq 'network') -or ($test.Cause -eq 'timeout')) {
            Write-Step -Level 'ERROR' -Message ('VPS injoignable (' + $test.Cause + ') : verifier l''adresse, le port et le reseau, puis relancer.')
            exit 1
        }
        if ($test.Cause -eq 'auth') {
            $authFailures++
        }
        else {
            $otherFailure = [string]$test.Detail
        }
    }

    if ((-not $hostKnownByUser) -and [System.IO.File]::Exists($tempKnownHosts)) {
        $fingerprint = Invoke-BLNative -FilePath $sshKeygenExe -ArgumentList @('-l', '-f', $tempKnownHosts) -TimeoutSec 20
        $fingerprintLines = @(Get-TextLines -Text ([string]$fingerprint.StdOut))
        if ($fingerprintLines.Count -gt 0) {
            Write-Step -Message 'Empreinte de la cle d''hote enregistree (a verifier aupres du VPS) :'
            foreach ($line in $fingerprintLines) {
                Write-Step -Message ('    ' + $line)
            }
        }
    }

    if ($chosenKey.Length -eq 0) {
        if (($candidates.Count -gt 0) -and ($authFailures -eq 0)) {
            Write-Step -Level 'ERROR' -Message ('Aucune cle n''a pu etre testee correctement : ' + $otherFailure)
            exit 1
        }
        # No working key: a new key of the kit is generated (never an existing one touched)
        # and its PUBLIC half is displayed.
        $newKey = Join-Path $userSshDir 'bokador-link_ed25519'
        $newPublicKey = $newKey + '.pub'
        if ((-not [System.IO.File]::Exists($newKey)) -and (-not [System.IO.File]::Exists($newPublicKey))) {
            if ($DryRun) {
                Write-Step -Message ('Aucune cle fonctionnelle. Sans -DryRun, une cle serait generee : ' + $newKey)
                exit 2
            }
            if (-not [System.IO.Directory]::Exists($userSshDir)) {
                [void][System.IO.Directory]::CreateDirectory($userSshDir)
            }
            # The empty passphrase must reach ssh-keygen as an empty argument.
            $generation = Invoke-BLNative -FilePath $sshKeygenExe -ArgumentList @('-q', '-t', 'ed25519', '-N', '', '-C', ('bokador-link@' + $clientLabel), '-f', $newKey) -TimeoutSec 60
            if (($generation.ExitCode -ne 0) -or (-not [System.IO.File]::Exists($newPublicKey))) {
                Write-Step -Level 'ERROR' -Message ('Generation de la cle impossible : ' + ([string]$generation.StdErr).Trim())
                exit 1
            }
            Write-Step -Message ('Nouvelle cle generee : ' + $newKey)
        }
        if (-not [System.IO.File]::Exists($newPublicKey)) {
            Write-Step -Level 'ERROR' -Message ('Cle publique introuvable : ' + $newPublicKey)
            exit 1
        }
        $publicKeyText = [System.IO.File]::ReadAllText($newPublicKey).Trim()
        Write-Step -Level 'WARN' -Message 'Aucune cle existante n''est acceptee par le VPS.'
        Write-Step -Message ('Sur le VPS, ajouter la ligne suivante au fichier ~/.ssh/authorized_keys de l''utilisateur ' + $VpsUser + ' :')
        Write-Step -Message ''
        Write-Step -Message $publicKeyText
        Write-Step -Message ''
        Write-Step -Message 'Puis relancer cet installateur avec les memes parametres.'
        exit 2
    }

    $draft.IdentityFile = $chosenKey
    $pushHelper = (-not $SkipVps) -and ($VpsUser -ceq 'root')

    if ($DryRun) {
        Write-Step -Message 'Ce qui serait fait sans -DryRun :'
        Write-Step -Message ('    [4/7] creer ' + $paths.Root + ', copier les scripts dans bin\, ecrire config.json et ssh_config')
        Write-Step -Message ('          cle retenue : ' + $chosenKey)
        if ($pushHelper) {
            Write-Step -Message ('    [5/7] envoyer l''assistant sur le VPS : ' + [string]$draft.VpsHelper)
        }
        else {
            Write-Step -Message '    [5/7] cote VPS non installe (-SkipVps ou utilisateur non root) : sonde simple'
        }
        Write-Step -Message ('    [6/7] enregistrer les taches ' + $names.Tunnel + ' et ' + $names.Watchdog + ' (toutes les ' + $WatchdogMinutes + ' min)')
        Write-Step -Message '    [7/7] demarrer le tunnel, lancer un tour de chien de garde, afficher l''etat'
        exit 0
    }

    # --- Step 4: files -------------------------------------------------------------
    Write-Step -Message '[4/7] Arret de l''existant et copie des fichiers.'
    if ([System.IO.Directory]::Exists($paths.Root)) {
        if (-not [System.IO.Directory]::Exists($paths.Run)) {
            [void][System.IO.Directory]::CreateDirectory($paths.Run)
        }
        [System.IO.File]::WriteAllText($paths.StopFlag, (Get-BLUtcNowText), (Get-BLUtf8NoBom))
    }
    Remove-KitTasks -StopOnly
    $stopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopWatch.Elapsed.TotalSeconds -lt 10) {
        $running = Get-BLTrackedProcess -Path $paths.SupervisorPid -ExpectedName 'powershell'
        if ($null -eq $running) {
            break
        }
        $running.Dispose()
        Start-Sleep -Milliseconds 500
    }
    [void](Stop-BLTrackedProcess -Path $paths.SupervisorPid -ExpectedName 'powershell')
    [void](Stop-BLTrackedProcess -Path $paths.TunnelPid -ExpectedName 'ssh')

    foreach ($directory in @($paths.Root, $paths.Bin, $paths.Lib, (Join-Path $paths.Bin 'vps'), $paths.Logs, $paths.Run, $paths.Tasks)) {
        if (-not [System.IO.Directory]::Exists($directory)) {
            [void][System.IO.Directory]::CreateDirectory($directory)
        }
    }
    # From here on the stop flag guards the whole installation, and messages are logged.
    [System.IO.File]::WriteAllText($paths.StopFlag, (Get-BLUtcNowText), (Get-BLUtf8NoBom))
    $script:LogEnabled = $true
    Write-BLLog -Name 'install' -Level 'INFO' -Message ('Installation vers ' + $paths.Root + ', cible ' + $target + ' port ' + $VpsPort + ', cle ' + $chosenKey)

    foreach ($kitFile in $kitFiles) {
        # Byte for byte copy: the VPS helper keeps its LF line endings.
        $destination = Join-Path $paths.Bin ([string]$kitFile.Target)
        [System.IO.File]::Copy([string]$kitFile.Source, $destination, $true)
        try {
            Unblock-File -LiteralPath $destination -ErrorAction Stop
        }
        catch {
            Write-BLLog -Name 'install' -Level 'WARN' -Message ('Unblock-File impossible sur ' + $destination)
        }
    }
    if ((-not $hostKnownByUser) -and [System.IO.File]::Exists($tempKnownHosts)) {
        [System.IO.File]::Copy($tempKnownHosts, $paths.KnownHosts, $true)
    }
    Write-BLConfig -Config $draft
    $config = Read-BLConfig
    Write-BLSshConfig -Config $config

    # The generated ssh_config is what every later call uses: check it end to end now.
    $check = Invoke-BLSsh -Config $config -RemoteCommand 'echo BOKADOR_LINK_OK' -TimeoutSec 40
    if (-not (Test-OutputMarker -Text ([string]$check.StdOut) -Marker 'BOKADOR_LINK_OK')) {
        Write-Step -Level 'ERROR' -Message ('La configuration SSH generee ne fonctionne pas (' + (Get-BLClassifiedSshFailure -Result $check) + ') : ' + ([string]$check.StdErr).Trim())
        exit 1
    }

    # --- Step 5: VPS side ------------------------------------------------------------
    $vpsSideInstalled = $false
    if ($SkipVps) {
        Write-Step -Message '[5/7] -SkipVps : rien n''est installe sur le VPS (sonde simple).'
    }
    elseif (-not $pushHelper) {
        Write-Step -Level 'WARN' -Message ('[5/7] L''utilisateur ' + $VpsUser + ' n''est pas root : cote VPS non installe (sonde simple).')
    }
    else {
        Write-Step -Message ('[5/7] Installation de l''assistant sur le VPS : ' + [string]$config.VpsHelper)
        $helperBytes = ConvertTo-LfBytes -Bytes ([System.IO.File]::ReadAllBytes($repoVpsHelper))
        $helper = [string]$config.VpsHelper
        $remoteInstall = 'umask 022; cat > ' + $helper + '.new && chmod 755 ' + $helper + '.new && mv -f ' + $helper + '.new ' + $helper + ' && ' + $helper + ' install'
        $push = Invoke-BLSsh -Config $config -RemoteCommand $remoteInstall -StdinBytes $helperBytes -TimeoutSec 90
        if (Test-OutputMarker -Text ([string]$push.StdOut) -Marker 'BOKADOR_LINK_INSTALLED') {
            $vpsSideInstalled = $true
            Write-Step -Message '    Assistant installe sur le VPS.'
        }
        else {
            Write-Step -Level 'WARN' -Message ('    Installation cote VPS en echec (code ' + $push.ExitCode + ') : ' + ([string]$push.StdErr).Trim())
            Write-Step -Level 'WARN' -Message '    Le chien de garde utilisera la sonde simple.'
        }
    }
    $draft.VpsSideInstalled = $vpsSideInstalled

    # --- Step 6: scheduled tasks -------------------------------------------------------
    $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $taskMode = 'Interactive'
    if (-not $InteractiveOnly) {
        try {
            Register-KitTasks -Mode 'S4U' -Paths $paths -UserId $userId -Minutes $WatchdogMinutes
            $taskMode = 'S4U'
        }
        catch {
            Write-Step -Level 'WARN' -Message ('[6/7] Mode S4U refuse (' + $_.Exception.Message + ') : repli sur le mode Interactive.')
            Remove-KitTasks
        }
    }
    if ($taskMode -ne 'S4U') {
        Register-KitTasks -Mode 'Interactive' -Paths $paths -UserId $userId -Minutes $WatchdogMinutes
    }
    Export-KitTasks -Paths $paths
    $draft.TaskMode = $taskMode
    Write-BLConfig -Config $draft
    $config = Read-BLConfig
    Write-Step -Message ('[6/7] Taches planifiees enregistrees en mode ' + $taskMode + '.')

    # --- Step 7: start and verify --------------------------------------------------------
    Write-Step -Message '[7/7] Demarrage du tunnel.'
    [System.IO.File]::Delete($paths.StopFlag)
    Start-ScheduledTask -TaskName $names.Tunnel -TaskPath '\' -ErrorAction Stop
    $started = Wait-TunnelStart -Paths $paths -TimeoutSec 45
    if ((-not $started.Supervisor) -and ($taskMode -eq 'S4U')) {
        # The S4U task was accepted but never ran (typically no "log on as a batch job"
        # right): same fallback as a refusal at registration.
        Write-Step -Level 'WARN' -Message '    La tache S4U ne demarre pas : repli sur le mode Interactive.'
        [System.IO.File]::WriteAllText($paths.StopFlag, (Get-BLUtcNowText), (Get-BLUtf8NoBom))
        Remove-KitTasks
        $taskMode = 'Interactive'
        Register-KitTasks -Mode 'Interactive' -Paths $paths -UserId $userId -Minutes $WatchdogMinutes
        Export-KitTasks -Paths $paths
        $draft.TaskMode = $taskMode
        Write-BLConfig -Config $draft
        $config = Read-BLConfig
        [System.IO.File]::Delete($paths.StopFlag)
        Start-ScheduledTask -TaskName $names.Tunnel -TaskPath '\' -ErrorAction Stop
        $started = Wait-TunnelStart -Paths $paths -TimeoutSec 45
    }
    if (-not $started.Tunnel) {
        Write-Step -Level 'WARN' -Message '    run\tunnel.pid n''est pas apparu en 45 s : le chien de garde va preciser la cause.'
    }

    Write-Step -Message '    Tour de chien de garde en cours (jusqu''a 150 s)...'
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $turnStartUtc = [DateTime]::UtcNow.AddSeconds(-2)
    $turn = Invoke-BLNative -FilePath $powershellExe -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $paths.WatchdogScript) -TimeoutSec 240
    # The state must have been written by a turn that ran after the start of the tunnel.
    # Exit code 0 with a stale state means a scheduled turn held the mutex: wait for the
    # state it is about to write.
    $waitState = [System.Diagnostics.Stopwatch]::StartNew()
    $state = Read-BLState
    $fresh = $false
    while ($true) {
        $lastRun = ConvertTo-BLUtcDate -Value $state.LastRunUtc
        if (($null -ne $lastRun) -and ($lastRun -ge $turnStartUtc)) {
            $fresh = $true
            break
        }
        if (($turn.ExitCode -ne 0) -or ($waitState.Elapsed.TotalSeconds -ge 170)) {
            break
        }
        Start-Sleep -Seconds 3
        $state = Read-BLState
    }
    $healthy = $fresh -and [bool]$state.Healthy
    if (-not $fresh) {
        Write-Step -Level 'WARN' -Message ('    Le chien de garde n''a pas ecrit son etat (code ' + $turn.ExitCode + ') : ' + ([string]$turn.StdErr).Trim())
    }
    Write-BLLog -Name 'install' -Level 'INFO' -Message ('Tour de chien de garde : code ' + $turn.ExitCode + ', sain=' + $healthy + ', cause=' + $state.LastFailureReason)

    $status = Invoke-BLNative -FilePath $powershellExe -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $paths.StatusScript) -TimeoutSec 90
    Write-Host ''
    Write-Host ([string]$status.StdOut)

    if ($healthy) {
        Write-Step -Message 'Installation terminee : la liaison est saine.'
        $exitCode = 0
    }
    else {
        Write-Step -Level 'ERROR' -Message ('Installation terminee mais la liaison n''est pas saine (cause : ' + $state.LastFailureReason + ').')
        Write-Step -Message ('Journaux : ' + $paths.Logs)
        $exitCode = 1
    }
}
catch {
    Write-Step -Level 'ERROR' -Message $_.Exception.Message
    $exitCode = 1
}
finally {
    if (($null -ne $tempDir) -and [System.IO.Directory]::Exists($tempDir)) {
        try {
            [System.IO.Directory]::Delete($tempDir, $true)
        }
        catch {
            Write-Host ('ATTENTION : repertoire temporaire non supprime : ' + $tempDir)
        }
    }
}
exit $exitCode
