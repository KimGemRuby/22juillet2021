# Get-BokadorLinkStatus.ps1 - human readable state of the link (docs/DESIGN.md, section 4.7).
# Shows the configuration (the key is shown as a path only, never its content), the state
# of the scheduled tasks, the tracked processes, state.json and the last 10 lines of the
# watchdog log. With -Json the same data is written as one JSON document.
# Exit code: 0 when the last watchdog turn found the link healthy, 1 otherwise.
# Target: Windows PowerShell 5.1. Keep this file plain ASCII.

param(
    [switch]$Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\BokadorLink.Common.ps1')

# Describes a tracked process: @{ Running; Pid; StartTimeUtc }.
function Get-TrackedProcessInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedName
    )
    $info = [ordered]@{
        Running      = $false
        Pid          = 0
        StartTimeUtc = ''
    }
    $process = $null
    try {
        $process = Get-BLTrackedProcess -Path $Path -ExpectedName $ExpectedName
        if ($null -ne $process) {
            $info.Running = $true
            $info.Pid = [int]$process.Id
            $info.StartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }
    }
    catch {
        $info.Running = $false
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
    return $info
}

function Format-YesNo {
    param(
        $Value
    )
    if ($Value -eq $true) {
        return 'oui'
    }
    return 'non'
}

function Format-OrDash {
    param(
        $Value
    )
    $text = [string]$Value
    if ([string]::IsNullOrEmpty($text)) {
        return '-'
    }
    return $text
}

# Existence of a task: 'inconnu' when the scheduler did not answer ($null).
function Format-ExistsText {
    param(
        $Value
    )
    if ($null -eq $Value) {
        return 'inconnu'
    }
    return (Format-YesNo -Value $Value)
}

$exitCode = 1
try {
    $paths = Get-BLPaths
    $names = Get-BLTaskNames
    $installed = [System.IO.File]::Exists($paths.Config)

    $config = $null
    $configError = ''
    if ($installed) {
        try {
            $config = Read-BLConfig
        }
        catch {
            $configError = [string]$_.Exception.Message
        }
    }
    else {
        $configError = 'Le kit n''est pas installe (configuration introuvable : ' + $paths.Config + ').'
    }

    $tunnelTask = Test-BLTask -Name $names.Tunnel
    $watchdogTask = Test-BLTask -Name $names.Watchdog
    $supervisorInfo = Get-TrackedProcessInfo -Path $paths.SupervisorPid -ExpectedName 'powershell'
    $tunnelInfo = Get-TrackedProcessInfo -Path $paths.TunnelPid -ExpectedName 'ssh'
    $state = Read-BLState
    $logTail = @(Get-BLFileTail -Path $paths.WatchdogLog -Count 10)
    $stopRequested = [System.IO.File]::Exists($paths.StopFlag)
    # state.json is written by the watchdog only: its healthy flag is trusted only while the last
    # turn is recent (two watchdog periods plus the 150 s budget of one turn).
    $lastRunUtc = ConvertTo-BLUtcDate -Value $state.LastRunUtc
    $lastTurnFresh = $false
    if (($null -ne $config) -and ($null -ne $lastRunUtc)) {
        $turnAgeSec = ([DateTime]::UtcNow - $lastRunUtc).TotalSeconds
        $allowedSec = (2 * [int]$config.WatchdogMinutes * 60) + 150
        if ($turnAgeSec -le $allowedSec) {
            $lastTurnFresh = $true
        }
    }
    $healthy = $installed -and ($null -ne $config) -and [bool]$state.Healthy -and $lastTurnFresh

    if ($Json) {
        $report = [ordered]@{
            Root            = [string]$paths.Root
            Installed       = [bool]$installed
            Healthy         = [bool]$healthy
            StopRequested   = [bool]$stopRequested
            ConfigError     = [string]$configError
            Config          = $config
            Tasks           = [ordered]@{
                Tunnel   = [ordered]@{
                    Name    = [string]$names.Tunnel
                    Exists  = [bool]$tunnelTask.Exists
                    Enabled = [bool]$tunnelTask.Enabled
                    State   = [string]$tunnelTask.State
                }
                Watchdog = [ordered]@{
                    Name    = [string]$names.Watchdog
                    Exists  = [bool]$watchdogTask.Exists
                    Enabled = [bool]$watchdogTask.Enabled
                    State   = [string]$watchdogTask.State
                }
            }
            Processes       = [ordered]@{
                Supervisor = $supervisorInfo
                Tunnel     = $tunnelInfo
            }
            State           = $state
            WatchdogLogTail = [string[]]$logTail
        }
        Write-Output (ConvertTo-Json -InputObject $report -Depth 5)
    }
    else {
        Write-Output '=== bokador-link : etat de la liaison ==='
        Write-Output ('Repertoire        : ' + $paths.Root)
        Write-Output ''
        Write-Output 'Configuration'
        if ($null -ne $config) {
            Write-Output ('  VPS             : ' + $config.VpsUser + '@' + $config.VpsHost + ' port ' + $config.VpsPort + ' (alias ' + $config.HostAlias + ')')
            Write-Output ('  Cle (chemin)    : ' + $config.IdentityFile)
            Write-Output ('  ssh.exe         : ' + $config.SshExe)
            $forwards = @($config.Forwards)
            if ($forwards.Count -eq 0) {
                Write-Output '  Redirections    : aucune (session maintenue ouverte)'
            }
            else {
                foreach ($forward in $forwards) {
                    Write-Output ('  Redirection     : ' + $forward)
                }
            }
            Write-Output ('  Chien de garde  : toutes les ' + $config.WatchdogMinutes + ' min')
            if ($config.VpsSideInstalled) {
                Write-Output ('  Assistant VPS   : installe (' + $config.VpsHelper + ')')
            }
            else {
                Write-Output '  Assistant VPS   : non installe (sonde simple)'
            }
            Write-Output ('  Etiquette       : ' + $config.ClientLabel)
            Write-Output ('  Mode des taches : ' + $config.TaskMode)
            Write-Output ('  Installe le     : ' + (Format-OrDash -Value $config.InstalledAtUtc))
        }
        else {
            Write-Output ('  ' + $configError)
        }
        Write-Output ''
        Write-Output 'Taches planifiees'
        Write-Output ('  ' + $names.Tunnel + '   : ' + $tunnelTask.State + ', existe=' + (Format-ExistsText -Value $tunnelTask.Exists) + ', active=' + (Format-YesNo -Value $tunnelTask.Enabled))
        Write-Output ('  ' + $names.Watchdog + ' : ' + $watchdogTask.State + ', existe=' + (Format-ExistsText -Value $watchdogTask.Exists) + ', active=' + (Format-YesNo -Value $watchdogTask.Enabled))
        Write-Output ''
        Write-Output 'Processus suivis'
        if ($supervisorInfo.Running) {
            Write-Output ('  Superviseur     : pid ' + $supervisorInfo.Pid + ', demarre le ' + $supervisorInfo.StartTimeUtc)
        }
        else {
            Write-Output '  Superviseur     : absent'
        }
        if ($tunnelInfo.Running) {
            Write-Output ('  Tunnel ssh      : pid ' + $tunnelInfo.Pid + ', demarre le ' + $tunnelInfo.StartTimeUtc)
        }
        else {
            Write-Output '  Tunnel ssh      : absent'
        }
        if ($stopRequested) {
            Write-Output '  run\stop.flag present : la liaison est arretee volontairement.'
        }
        Write-Output ''
        Write-Output 'Etat (state.json)'
        Write-Output ('  Sain                  : ' + (Format-YesNo -Value $healthy))
        Write-Output ('  Dernier tour          : ' + (Format-OrDash -Value $state.LastRunUtc))
        if ([bool]$state.Healthy -and (-not $lastTurnFresh)) {
            Write-Output '  ATTENTION             : dernier tour trop ancien : le chien de garde ne tourne plus (tache desactivee ou en echec ?).'
        }
        Write-Output ('  Dernier tour sain     : ' + (Format-OrDash -Value $state.LastOkUtc))
        Write-Output ('  Echecs consecutifs    : ' + $state.ConsecutiveFailures)
        Write-Output ('  Cause du dernier echec: ' + $state.LastFailureReason)
        Write-Output ('  Intervention humaine  : ' + (Format-YesNo -Value $state.NeedsHuman))
        Write-Output ('  Reparations (total)   : ' + $state.RepairsTotal)
        Write-Output ('  Derniere reparation   : ' + (Format-OrDash -Value $state.LastRepairUtc) + ' ' + $state.LastRepairAction)
        Write-Output ('  Vue du VPS            : ' + $state.VpsView)
        Write-Output ('  Controles             : superviseur=' + (Format-YesNo -Value $state.Checks.Supervisor) + ' tunnel=' + (Format-YesNo -Value $state.Checks.Tunnel) + ' sonde=' + (Format-YesNo -Value $state.Checks.Probe) + ' redirections=' + (Format-YesNo -Value $state.Checks.Forwards))
        Write-Output ''
        Write-Output 'Journal du chien de garde (10 dernieres lignes)'
        if ($logTail.Count -eq 0) {
            Write-Output '  (vide)'
        }
        else {
            foreach ($line in $logTail) {
                Write-Output ('  ' + $line)
            }
        }
    }

    if ($healthy) {
        $exitCode = 0
    }
}
catch {
    Write-Output ('ERREUR : ' + $_.Exception.Message)
    $exitCode = 1
}
exit $exitCode
