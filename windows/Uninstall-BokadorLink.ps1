# Uninstall-BokadorLink.ps1 - complete removal of the bokador-link kit
# (docs/DESIGN.md, section 4.7).
# Creates run\stop.flag, stops and removes both scheduled tasks, kills the tracked tunnel,
# runs "<VpsHelper> uninstall" on the VPS (unless -KeepVps or VPS side not installed), then
# removes the installation directory (logs\ is kept with -KeepLogs).
# Never touches the user's keys, ~\.ssh\config or ~\.ssh\known_hosts.
# Exit code: 0 when everything was removed, 1 otherwise.
# Target: Windows PowerShell 5.1. Keep this file plain ASCII.

param(
    [switch]$KeepVps,
    [switch]$KeepLogs
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\BokadorLink.Common.ps1')

$script:Failures = 0

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
        $script:Failures++
    }
    Write-Host ($prefix + $Message)
    Write-BLLog -Name 'install' -Level $Level -Message ('[desinstallation] ' + $Message)
}

# Stops and unregisters the tasks of the kit that exist. Returns the number of tasks that
# still exist afterwards. Never throws.
function Remove-KitTasks {
    $names = Get-BLTaskNames
    $remaining = 0
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
        try {
            Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false -ErrorAction Stop | Out-Null
            Write-Step -Message ('Tache supprimee : ' + $name)
        }
        catch {
            Write-Step -Level 'WARN' -Message ('Suppression de la tache ' + $name + ' : ' + $_.Exception.Message)
        }
        $after = Test-BLTask -Name $name
        if ($after.Exists) {
            $remaining++
        }
    }
    return $remaining
}

# Deletes a file or a directory tree, with a few retries (a file may still be held for a
# moment by a process that was just killed). Returns $true when the path is gone.
function Remove-PathWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        try {
            if ([System.IO.Directory]::Exists($Path)) {
                [System.IO.Directory]::Delete($Path, $true)
            }
            elseif ([System.IO.File]::Exists($Path)) {
                [System.IO.File]::SetAttributes($Path, [System.IO.FileAttributes]::Normal)
                [System.IO.File]::Delete($Path)
            }
            return $true
        }
        catch {
            # Read-only files block Directory.Delete: clear the attribute and retry.
            try {
                if ([System.IO.Directory]::Exists($Path)) {
                    foreach ($file in [System.IO.Directory]::GetFiles($Path, '*', [System.IO.SearchOption]::AllDirectories)) {
                        [System.IO.File]::SetAttributes($file, [System.IO.FileAttributes]::Normal)
                    }
                }
            }
            catch {
                Start-Sleep -Milliseconds 100
            }
            Start-Sleep -Milliseconds 500
        }
    }
    return (-not ([System.IO.Directory]::Exists($Path) -or [System.IO.File]::Exists($Path)))
}

# Refuses to delete anything that does not look like an installation directory of the kit.
# Returns '' when the directory may be removed, the reason of the refusal otherwise.
function Get-RootRefusal {
    param(
        [Parameter(Mandatory = $true)]
        $Paths
    )
    $root = [System.IO.Path]::GetFullPath([string]$Paths.Root).TrimEnd('\')
    if ($root.Length -lt 4) {
        return 'chemin trop court'
    }
    $drive = [string][System.IO.Path]::GetPathRoot($root)
    if ($drive.TrimEnd('\') -ieq $root) {
        return 'racine d''un lecteur'
    }
    foreach ($protected in @($env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $env:SystemRoot, $env:ProgramFiles)) {
        if ((-not [string]::IsNullOrEmpty($protected)) -and ($protected.TrimEnd('\') -ieq $root)) {
            return 'repertoire systeme ou de profil'
        }
    }
    if ([System.IO.Directory]::Exists((Join-Path $root '.git'))) {
        return 'depot git'
    }
    $markers = @($Paths.Config, $Paths.CommonLib, $Paths.SupervisorScript, $Paths.State, $Paths.Logs)
    foreach ($marker in $markers) {
        if ([System.IO.File]::Exists($marker) -or [System.IO.Directory]::Exists($marker)) {
            return ''
        }
    }
    return 'aucun fichier du kit dans ce repertoire'
}

$exitCode = 1
try {
    $paths = Get-BLPaths
    $rootExists = [System.IO.Directory]::Exists($paths.Root)
    Write-Step -Message ('Desinstallation de bokador-link : ' + $paths.Root)

    # The configuration is read first: it is needed for the VPS side.
    $config = $null
    if ([System.IO.File]::Exists($paths.Config)) {
        try {
            $config = Read-BLConfig
        }
        catch {
            Write-Step -Level 'WARN' -Message ('Configuration illisible, le cote VPS ne sera pas traite : ' + $_.Exception.Message)
        }
    }

    # 1. stop flag: the supervisor ends by itself, and no repair resurrects a task.
    if ($rootExists) {
        if (-not [System.IO.Directory]::Exists($paths.Run)) {
            [void][System.IO.Directory]::CreateDirectory($paths.Run)
        }
        [System.IO.File]::WriteAllText($paths.StopFlag, (Get-BLUtcNowText), (Get-BLUtf8NoBom))
    }

    # 2. tasks.
    $remainingTasks = Remove-KitTasks

    # 3. tracked processes: give the supervisor a few seconds to leave, then kill what is
    # left (only the processes described by the pid files).
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 10) {
        $running = Get-BLTrackedProcess -Path $paths.SupervisorPid -ExpectedName 'powershell'
        if ($null -eq $running) {
            break
        }
        $running.Dispose()
        Start-Sleep -Milliseconds 500
    }
    if (Stop-BLTrackedProcess -Path $paths.SupervisorPid -ExpectedName 'powershell') {
        Write-Step -Message 'Superviseur arrete.'
    }
    if (Stop-BLTrackedProcess -Path $paths.TunnelPid -ExpectedName 'ssh') {
        Write-Step -Message 'Tunnel arrete.'
    }

    # 4. VPS side.
    if ($KeepVps) {
        Write-Step -Message '-KeepVps : le cote VPS est conserve.'
    }
    elseif ($null -eq $config) {
        Write-Step -Message 'Pas de configuration valide : rien a faire cote VPS.'
    }
    elseif (-not $config.VpsSideInstalled) {
        Write-Step -Message 'Cote VPS non installe : rien a faire sur le VPS.'
    }
    else {
        $remote = [string]$config.VpsHelper + ' uninstall'
        $result = Invoke-BLSsh -Config $config -RemoteCommand $remote -TimeoutSec 60
        $done = $false
        foreach ($line in ([string]$result.StdOut -split "`n")) {
            if ($line.Trim() -ceq 'BOKADOR_LINK_UNINSTALLED') {
                $done = $true
            }
        }
        if ($done) {
            Write-Step -Message 'Assistant desinstalle du VPS.'
        }
        else {
            Write-Step -Level 'ERROR' -Message ('Desinstallation cote VPS en echec (code ' + $result.ExitCode + ') : ' + ([string]$result.StdErr).Trim())
            Write-Step -Message ('A faire a la main sur le VPS : ' + $remote)
        }
    }

    # 5. second pass on the tasks: a repair that was already running may have registered
    # one again before it saw the stop flag.
    Start-Sleep -Seconds 2
    $remainingTasks = Remove-KitTasks
    if ($remainingTasks -gt 0) {
        Write-Step -Level 'ERROR' -Message ('Des taches planifiees n''ont pas pu etre supprimees (' + $remainingTasks + ').')
    }

    # 6. installation directory.
    if (-not $rootExists) {
        Write-Step -Message 'Repertoire d''installation absent : rien a supprimer.'
    }
    else {
        $refusal = Get-RootRefusal -Paths $paths
        if ($refusal.Length -gt 0) {
            Write-Step -Level 'ERROR' -Message ('Suppression refusee pour ' + $paths.Root + ' : ' + $refusal)
        }
        else {
            # A process whose current directory is inside the tree would block its removal.
            $safeDirectory = [System.IO.Path]::GetTempPath()
            $rootPrefix = $paths.Root.TrimEnd('\') + '\'
            $currentDirectory = [Environment]::CurrentDirectory.TrimEnd('\') + '\'
            if ($currentDirectory.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                [Environment]::CurrentDirectory = $safeDirectory
            }
            $location = (Get-Location).ProviderPath.TrimEnd('\') + '\'
            if ($location.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                Set-Location -LiteralPath $safeDirectory
            }

            if ($KeepLogs) {
                Write-BLLog -Name 'install' -Level 'INFO' -Message '[desinstallation] Suppression des fichiers, journaux conserves.'
                $leftovers = 0
                $entries = New-Object 'System.Collections.Generic.List[string]'
                foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($paths.Root)) {
                    $entries.Add([string]$entry)
                }
                foreach ($entry in $entries) {
                    if ($entry.TrimEnd('\') -ieq $paths.Logs.TrimEnd('\')) {
                        continue
                    }
                    if (-not (Remove-PathWithRetry -Path $entry)) {
                        $leftovers++
                    }
                }
                if ($leftovers -gt 0) {
                    Write-Step -Level 'ERROR' -Message ('Suppression incomplete de ' + $paths.Root + ' (' + $leftovers + ' element(s) restant(s)).')
                }
                else {
                    Write-Step -Message ('Fichiers supprimes, journaux conserves dans ' + $paths.Logs)
                }
            }
            else {
                if (Remove-PathWithRetry -Path $paths.Root) {
                    Write-Host ('Repertoire supprime : ' + $paths.Root)
                }
                else {
                    $script:Failures++
                    Write-Host ('ERREUR : suppression incomplete de ' + $paths.Root + ' (fichier ouvert ailleurs ?). Fermer les programmes concernes et supprimer ce repertoire a la main.')
                }
            }
        }
    }

    if ($script:Failures -eq 0) {
        Write-Host 'Desinstallation terminee. Les cles SSH et le known_hosts de l''utilisateur n''ont pas ete modifies.'
        $exitCode = 0
    }
    else {
        Write-Host ('Desinstallation terminee avec ' + $script:Failures + ' erreur(s).')
        $exitCode = 1
    }
}
catch {
    Write-Host ('ERREUR : ' + $_.Exception.Message)
    $exitCode = 1
}
exit $exitCode
