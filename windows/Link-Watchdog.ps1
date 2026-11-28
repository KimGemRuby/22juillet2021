# Link-Watchdog.ps1 - one turn of the feedback loop (docs/DESIGN.md, section 4.5,
# task "BokadorLink-Watchdog"): measure, decide, repair, re-measure, record.
# Exit code: 0 when the link is healthy (or another watchdog is already running), 1 otherwise.
# Target: Windows PowerShell 5.1. Keep this file plain ASCII.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\BokadorLink.Common.ps1')

$script:BudgetSec = 150
$script:MaxDepth = 3
$script:Clock = [System.Diagnostics.Stopwatch]::StartNew()
$script:Repairs = New-Object 'System.Collections.Generic.List[string]'

function Write-WatchdogLog {
    param(
        [string]$Level = 'INFO',
        [string]$Message = ''
    )
    Write-BLLog -Name 'watchdog' -Level $Level -Message $Message
}

function Get-RemainingSec {
    return [int][Math]::Floor($script:BudgetSec - $script:Clock.Elapsed.TotalSeconds)
}

# Timeout of one ssh call: 30 seconds, less when the budget of the turn is nearly spent.
function Get-SshTimeoutSec {
    $remaining = Get-RemainingSec
    return [int][Math]::Max(5, [Math]::Min(30, $remaining))
}

# Splits the output of a remote command into lines without their line ending.
function Get-OutputLines {
    param(
        [AllowEmptyString()]
        [string]$Text = ''
    )
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrEmpty($Text)) {
        foreach ($line in ($Text -split "`n")) {
            $lines.Add($line.TrimEnd("`r"))
        }
    }
    return $lines.ToArray()
}

# Short one-line description of a failed ssh call, for the log.
function Get-SshFailureText {
    param(
        [Parameter(Mandatory = $true)]
        $Result
    )
    $text = ''
    foreach ($line in @(Get-OutputLines -Text ([string]$Result.StdErr))) {
        if ($line.Trim().Length -gt 0) {
            $text = $line.Trim()
        }
    }
    if ($text.Length -gt 200) {
        $text = $text.Substring(0, 200)
    }
    return ('code ' + $Result.ExitCode + ', delai depasse=' + $Result.TimedOut + ', ssh : ' + $text)
}

# Measure step: returns @{ Supervisor; Tunnel; Probe; Forwards; ProbeCause; VpsView }.
function Measure-BLLink {
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        $Paths
    )
    $measure = @{
        Supervisor = $false
        Tunnel     = $false
        Probe      = $false
        Forwards   = $false
        ProbeCause = 'none'
        VpsView    = 'unknown'
    }

    $supervisor = Get-BLTrackedProcess -Path $Paths.SupervisorPid -ExpectedName 'powershell'
    if ($null -ne $supervisor) {
        $measure.Supervisor = $true
        $supervisor.Dispose()
    }
    $tunnel = Get-BLTrackedProcess -Path $Paths.TunnelPid -ExpectedName 'ssh'
    if ($null -ne $tunnel) {
        $measure.Tunnel = $true
        $tunnel.Dispose()
    }

    # Probe: a brand new connection that checks network, host key and authentication end
    # to end, and drops the heartbeat on the VPS.
    $probe = $null
    if ($Config.VpsSideInstalled) {
        $remote = [string]$Config.VpsHelper + ' heartbeat ' + [string]$Config.ClientLabel
        $probe = Invoke-BLSsh -Config $Config -RemoteCommand $remote -TimeoutSec (Get-SshTimeoutSec)
        foreach ($line in @(Get-OutputLines -Text ([string]$probe.StdOut))) {
            $match = [regex]::Match($line, '\ABOKADOR_LINK_OK ([0-9]+) (up|down|unknown)\z')
            if ($match.Success) {
                $measure.Probe = $true
                $measure.VpsView = $match.Groups[2].Value
            }
        }
    }
    else {
        $probe = Invoke-BLSsh -Config $Config -RemoteCommand 'echo BOKADOR_LINK_OK' -TimeoutSec (Get-SshTimeoutSec)
        foreach ($line in @(Get-OutputLines -Text ([string]$probe.StdOut))) {
            if ($line.Trim() -ceq 'BOKADOR_LINK_OK') {
                $measure.Probe = $true
            }
        }
    }
    if (-not $measure.Probe) {
        $measure.ProbeCause = Get-BLClassifiedSshFailure -Result $probe
        Write-WatchdogLog -Level 'WARN' -Message ('Sonde en echec (' + $measure.ProbeCause + ') : ' + (Get-SshFailureText -Result $probe))
    }

    # Forwards: R entries are checked from the VPS, L entries locally. True when empty.
    $forwardsOk = $true
    foreach ($forward in @($Config.Forwards)) {
        $info = ConvertTo-BLForwardInfo -Forward $forward
        if ($null -eq $info) {
            $forwardsOk = $false
            continue
        }
        if ($info.Kind -ceq 'R') {
            if (-not $Config.VpsSideInstalled) {
                # No helper on the VPS: remote ports cannot be probed, they are ignored.
                continue
            }
            if (-not $measure.Probe) {
                # The VPS cannot be reached right now: the port cannot be vouched for.
                $forwardsOk = $false
                continue
            }
            $remote = [string]$Config.VpsHelper + ' probe-port ' + [string][int]$info.BindPort
            $portResult = Invoke-BLSsh -Config $Config -RemoteCommand $remote -TimeoutSec (Get-SshTimeoutSec)
            $expected = 'PORT ' + [string][int]$info.BindPort + ' OPEN'
            $open = $false
            foreach ($line in @(Get-OutputLines -Text ([string]$portResult.StdOut))) {
                if ($line.Trim() -ceq $expected) {
                    $open = $true
                }
            }
            if (-not $open) {
                $forwardsOk = $false
                Write-WatchdogLog -Level 'WARN' -Message ('Redirection distante fermee : port ' + $info.BindPort + ' sur le VPS')
            }
        }
        else {
            if (-not (Test-BLTcp -HostName '127.0.0.1' -Port ([int]$info.BindPort) -TimeoutMs 3000)) {
                $forwardsOk = $false
                Write-WatchdogLog -Level 'WARN' -Message ('Redirection locale fermee : port ' + $info.BindPort)
            }
        }
    }
    $measure.Forwards = $forwardsOk
    return $measure
}

# Reason recorded in state.json for an unhealthy measure.
function Get-FailureReason {
    param(
        [Parameter(Mandatory = $true)]
        $Measure
    )
    if (-not $Measure.Probe) {
        if (@('network', 'auth', 'hostkey', 'timeout') -contains $Measure.ProbeCause) {
            return [string]$Measure.ProbeCause
        }
        return 'unknown'
    }
    if (-not $Measure.Supervisor) {
        return 'supervisor'
    }
    if (-not $Measure.Tunnel) {
        return 'tunnel'
    }
    if (-not $Measure.Forwards) {
        return 'forwards'
    }
    return 'none'
}

# Repair action: the supervisor is not running. Repairs the tunnel task if needed, then
# starts it. Never throws.
function Restart-Supervisor {
    $names = Get-BLTaskNames
    foreach ($action in @(Repair-BLTask -Name $names.Tunnel -LogName 'watchdog')) {
        $script:Repairs.Add([string]$action)
    }
    try {
        $taskInfo = Test-BLTask -Name $names.Tunnel
        if ($taskInfo.State -eq 'Running') {
            # The task claims to run but no supervisor is tracked: stop the stale instance,
            # otherwise the scheduler would ignore the new start.
            Stop-ScheduledTask -TaskName $names.Tunnel -TaskPath '\' -ErrorAction Stop | Out-Null
            Start-Sleep -Seconds 2
        }
        Start-ScheduledTask -TaskName $names.Tunnel -TaskPath '\' -ErrorAction Stop | Out-Null
        $script:Repairs.Add('start:' + $names.Tunnel)
        Write-WatchdogLog -Level 'WARN' -Message 'Superviseur absent : tache tunnel demarree.'
    }
    catch {
        Write-WatchdogLog -Level 'ERROR' -Message ('Demarrage de la tache tunnel impossible : ' + $_.Exception.Message)
    }
}

# Repair action: the tunnel is missing or its forwards are dead while the VPS answers.
# Kills the tracked ssh (only the one of run\tunnel.pid); the supervisor starts a new one.
# A tunnel younger than 20 seconds is left alone: it may still be connecting. Never throws.
function Reset-Tunnel {
    param(
        [Parameter(Mandatory = $true)]
        $Paths
    )
    $tunnel = $null
    try {
        $tunnel = Get-BLTrackedProcess -Path $Paths.TunnelPid -ExpectedName 'ssh'
        if ($null -eq $tunnel) {
            Write-WatchdogLog -Level 'INFO' -Message 'Aucun tunnel suivi : attente de la relance par le superviseur.'
            return
        }
        $ageSec = ([DateTime]::UtcNow - $tunnel.StartTime.ToUniversalTime()).TotalSeconds
        # A negative age (clock stepped back) also counts as young: the tunnel may still be connecting.
        if ($ageSec -lt 20) {
            Write-WatchdogLog -Level 'INFO' -Message 'Tunnel tout juste lance : pas d''arret, nouvelle mesure a suivre.'
            return
        }
        Stop-BLProcessTree -Process $tunnel
        $script:Repairs.Add('kill-tunnel')
        Write-WatchdogLog -Level 'WARN' -Message ('Tunnel defaillant arrete (pid ' + $tunnel.Id + ') : le superviseur va le relancer.')
    }
    catch {
        Write-WatchdogLog -Level 'ERROR' -Message ('Arret du tunnel impossible : ' + $_.Exception.Message)
    }
    finally {
        if ($null -ne $tunnel) {
            $tunnel.Dispose()
        }
    }
}

# Decision and repair step. Recursive: after each action the link is measured again and
# the function calls itself, up to a depth of 3.
# Returns @{ Measure; Reason; NeedsHuman } for the last measure taken.
function Invoke-BLRepairCycle {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Depth,
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        $Paths,
        [Parameter(Mandatory = $true)]
        $Measure
    )
    $outcome = @{
        Measure    = $Measure
        Reason     = 'none'
        NeedsHuman = $false
    }

    # Everything is true: healthy.
    if ($Measure.Supervisor -and $Measure.Tunnel -and $Measure.Probe -and $Measure.Forwards) {
        return $outcome
    }
    $outcome.Reason = Get-FailureReason -Measure $Measure

    if (-not $Measure.Probe) {
        # The VPS is not even reachable in TCP: nothing can be repaired from here.
        if (-not (Test-BLTcp -HostName ([string]$Config.VpsHost) -Port ([int]$Config.VpsPort) -TimeoutMs 5000)) {
            $outcome.Reason = 'network'
            Write-WatchdogLog -Level 'WARN' -Message 'VPS injoignable en TCP : cause reseau, rien a reparer localement.'
            return $outcome
        }
        # Authentication or host key problem: never any automatic action (a changed host
        # key is never accepted automatically).
        if (($Measure.ProbeCause -eq 'auth') -or ($Measure.ProbeCause -eq 'hostkey')) {
            $outcome.Reason = [string]$Measure.ProbeCause
            $outcome.NeedsHuman = $true
            Write-WatchdogLog -Level 'ERROR' -Message ('Intervention humaine requise (' + $Measure.ProbeCause + ') : aucune action automatique.')
            return $outcome
        }
    }

    if ($Depth -ge $script:MaxDepth) {
        Write-WatchdogLog -Level 'WARN' -Message ('Profondeur maximale atteinte (' + $Depth + ') : le prochain tour reprendra.')
        return $outcome
    }
    if ((Get-RemainingSec) -lt 45) {
        Write-WatchdogLog -Level 'WARN' -Message 'Budget de temps presque epuise : le prochain tour reprendra.'
        return $outcome
    }
    if ([System.IO.File]::Exists($Paths.StopFlag)) {
        Write-WatchdogLog -Level 'WARN' -Message 'run\stop.flag present : aucune reparation.'
        return $outcome
    }

    if (-not $Measure.Supervisor) {
        Restart-Supervisor | Out-Null
    }
    elseif ($Measure.Probe -and ((-not $Measure.Tunnel) -or (-not $Measure.Forwards))) {
        Reset-Tunnel -Paths $Paths | Out-Null
    }
    else {
        # The probe fails for another reason while the supervisor is alive: the supervisor
        # keeps retrying by itself, nothing to do here.
        return $outcome
    }

    Start-Sleep -Seconds 15
    $nextMeasure = Measure-BLLink -Config $Config -Paths $Paths
    return (Invoke-BLRepairCycle -Depth ($Depth + 1) -Config $Config -Paths $Paths -Measure $nextMeasure)
}

$exitCode = 1
$mutexInfo = $null
try {
    $mutexInfo = Enter-BLMutex -Name 'BokadorLink-Watchdog'
    if (-not $mutexInfo.Acquired) {
        # Another turn is still running: let it finish.
        Write-WatchdogLog -Level 'INFO' -Message 'Un autre chien de garde est en cours : sortie.'
        $exitCode = 0
    }
    else {
        $paths = Get-BLPaths
        $names = Get-BLTaskNames
        $state = Read-BLState
        $nowText = Get-BLUtcNowText

        $measure = @{
            Supervisor = $false
            Tunnel     = $false
            Probe      = $false
            Forwards   = $false
            ProbeCause = 'none'
            VpsView    = 'unknown'
        }
        $reason = 'unknown'
        $needsHuman = $false
        $healthy = $false

        $config = $null
        try {
            $config = Read-BLConfig
        }
        catch {
            Write-WatchdogLog -Level 'ERROR' -Message $_.Exception.Message
        }

        if ($null -eq $config) {
            $reason = 'unknown'
        }
        elseif ([System.IO.File]::Exists($paths.StopFlag)) {
            # The link was stopped on purpose (reinstall or uninstall in progress).
            Write-WatchdogLog -Level 'WARN' -Message 'run\stop.flag present : liaison arretee volontairement, aucune mesure ni reparation.'
            $reason = 'supervisor'
        }
        else {
            # 2. measure, 3. decide and repair (recursive).
            $firstMeasure = Measure-BLLink -Config $config -Paths $paths
            $outcome = Invoke-BLRepairCycle -Depth 1 -Config $config -Paths $paths -Measure $firstMeasure
            $measure = $outcome.Measure
            $reason = [string]$outcome.Reason
            $needsHuman = [bool]$outcome.NeedsHuman

            # 4. self-check: the watchdog repairs the supervisor's task.
            foreach ($action in @(Repair-BLTask -Name $names.Tunnel -LogName 'watchdog')) {
                $script:Repairs.Add([string]$action)
            }

            $healthy = [bool]($measure.Supervisor -and $measure.Tunnel -and $measure.Probe -and $measure.Forwards)
        }

        # 5. record the state and one summary line.
        $state.LastRunUtc = $nowText
        $state.Healthy = $healthy
        if ($healthy) {
            $state.LastOkUtc = $nowText
            $state.ConsecutiveFailures = 0
            $state.LastFailureReason = 'none'
            $reason = 'none'
        }
        else {
            $state.ConsecutiveFailures = [int]$state.ConsecutiveFailures + 1
            if ($reason -eq 'none') {
                $reason = 'unknown'
            }
            $state.LastFailureReason = $reason
        }
        $state.NeedsHuman = $needsHuman
        if ($script:Repairs.Count -gt 0) {
            $state.RepairsTotal = [int]$state.RepairsTotal + $script:Repairs.Count
            $state.LastRepairUtc = $nowText
            $state.LastRepairAction = ($script:Repairs.ToArray() -join ',')
        }
        $state.VpsView = [string]$measure.VpsView
        $state.Checks.Supervisor = [bool]$measure.Supervisor
        $state.Checks.Tunnel = [bool]$measure.Tunnel
        $state.Checks.Probe = [bool]$measure.Probe
        $state.Checks.Forwards = [bool]$measure.Forwards
        Write-BLState -State $state

        $summary = 'Synthese : sain=' + $healthy +
            ' superviseur=' + $measure.Supervisor +
            ' tunnel=' + $measure.Tunnel +
            ' sonde=' + $measure.Probe +
            ' redirections=' + $measure.Forwards +
            ' cause=' + $reason +
            ' vps=' + $measure.VpsView +
            ' reparations=' + $script:Repairs.Count +
            ' echecs_consecutifs=' + $state.ConsecutiveFailures +
            ' duree=' + [int]$script:Clock.Elapsed.TotalSeconds + 's'
        $level = 'INFO'
        if (-not $healthy) {
            $level = 'WARN'
        }
        Write-WatchdogLog -Level $level -Message $summary

        if ($healthy) {
            $exitCode = 0
        }
    }
}
catch {
    Write-WatchdogLog -Level 'ERROR' -Message ('Erreur inattendue du chien de garde : ' + $_.Exception.Message)
    $exitCode = 1
}
finally {
    Exit-BLMutex -MutexInfo $mutexInfo
}
exit $exitCode
