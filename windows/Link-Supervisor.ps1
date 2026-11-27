# Link-Supervisor.ps1 - long-lived process that keeps the SSH tunnel up
# (docs/DESIGN.md, section 4.5, task "BokadorLink-Tunnel").
# It only ends when run\stop.flag exists or when another supervisor already holds the mutex.
# Target: Windows PowerShell 5.1. Keep this file plain ASCII.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\BokadorLink.Common.ps1')

$script:LastWatchdogRepairUtc = [DateTime]::MinValue

function Write-SupervisorLog {
    param(
        [string]$Level = 'INFO',
        [string]$Message = ''
    )
    Write-BLLog -Name 'supervisor' -Level $Level -Message $Message
}

# A stop is requested by run\stop.flag. A root directory that no longer exists (the kit was
# uninstalled under a surviving supervisor) is treated the same way.
function Test-StopRequested {
    param(
        [Parameter(Mandatory = $true)]
        $Paths
    )
    if ([System.IO.File]::Exists($Paths.StopFlag)) {
        return $true
    }
    if (-not [System.IO.Directory]::Exists($Paths.Root)) {
        return $true
    }
    return $false
}

# Housekeeping done from every wait slice: keeps run\supervisor.pid present and, every
# 10 minutes, repairs the watchdog task (the supervisor repairs the watchdog).
# Never throws.
function Invoke-PeriodicDuties {
    param(
        [Parameter(Mandatory = $true)]
        $Paths,
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$SelfProcess
    )
    try {
        if (-not [System.IO.File]::Exists($Paths.SupervisorPid)) {
            Write-BLPidFile -Path $Paths.SupervisorPid -Process $SelfProcess
            Write-SupervisorLog -Level 'WARN' -Message 'run\supervisor.pid avait disparu : fichier recree.'
        }
        $elapsed = ([DateTime]::UtcNow - $script:LastWatchdogRepairUtc).TotalMinutes
        if (($elapsed -ge 10) -or ($elapsed -lt 0)) {
            $script:LastWatchdogRepairUtc = [DateTime]::UtcNow
            $names = Get-BLTaskNames
            $actions = @(Repair-BLTask -Name $names.Watchdog -LogName 'supervisor')
            if ($actions.Count -gt 0) {
                Write-SupervisorLog -Level 'WARN' -Message ('Chien de garde repare : ' + ($actions -join ', '))
            }
        }
    }
    catch {
        Write-SupervisorLog -Level 'ERROR' -Message ('Entretien periodique en echec : ' + $_.Exception.Message)
    }
}

# Sleeps for the given time in slices of at most 1 second. Returns $true as soon as a stop
# is requested, $false when the whole time has elapsed.
function Wait-OrStop {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Milliseconds,
        [Parameter(Mandatory = $true)]
        $Paths,
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$SelfProcess
    )
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if (Test-StopRequested -Paths $Paths) {
            return $true
        }
        $left = $Milliseconds - [int]$watch.ElapsedMilliseconds
        if ($left -le 0) {
            return $false
        }
        Start-Sleep -Milliseconds ([Math]::Min($left, 1000))
        # Out-Null: a stray output object here would corrupt the boolean returned above.
        Invoke-PeriodicDuties -Paths $Paths -SelfProcess $SelfProcess | Out-Null
    }
}

$exitCode = 0
$mutexInfo = $null
$tunnel = $null
$selfProcess = $null
try {
    $paths = Get-BLPaths
    $mutexInfo = Enter-BLMutex -Name 'BokadorLink-Supervisor'
    if (-not $mutexInfo.Acquired) {
        # Another supervisor is alive: this instance has nothing to do.
        Write-SupervisorLog -Level 'INFO' -Message 'Un autre superviseur detient deja le mutex : sortie.'
    }
    else {
        $selfProcess = [System.Diagnostics.Process]::GetCurrentProcess()
        if ([System.IO.Directory]::Exists($paths.Root)) {
            if (-not [System.IO.Directory]::Exists($paths.Run)) {
                [void][System.IO.Directory]::CreateDirectory($paths.Run)
            }
            Write-BLPidFile -Path $paths.SupervisorPid -Process $selfProcess
        }
        $mutexText = 'aucun (creation refusee)'
        if ($null -ne $mutexInfo.Mutex) {
            $mutexText = [string]$mutexInfo.FullName
        }
        Write-SupervisorLog -Level 'INFO' -Message ('Superviseur demarre, pid ' + $PID + ', mutex ' + $mutexText + ', racine ' + $paths.Root)

        $delaySec = 2
        $random = New-Object System.Random
        $stopRequested = $false

        while (-not $stopRequested) {
            try {
                # a. stop flag: kill the tracked tunnel and leave.
                if (Test-StopRequested -Paths $paths) {
                    $stopRequested = $true
                    break
                }

                $config = Read-BLConfig
                foreach ($directory in @($paths.Logs, $paths.Run)) {
                    if (-not [System.IO.Directory]::Exists($directory)) {
                        [void][System.IO.Directory]::CreateDirectory($directory)
                    }
                }

                # A tunnel left behind by a previous supervisor would keep the forwarded
                # ports busy: only one tracked ssh may live.
                if (Stop-BLTrackedProcess -Path $paths.TunnelPid -ExpectedName 'ssh') {
                    Write-SupervisorLog -Level 'WARN' -Message 'Ancien tunnel orphelin arrete avant relance.'
                }
                Invoke-BLLogRotation -Path $paths.TunnelErrLog

                # b. start ssh. No stream is redirected: ssh writes its diagnostics to the
                # -E file, so nothing can block on a full pipe and the pid is the one of ssh.
                $sshArguments = New-Object 'System.Collections.Generic.List[string]'
                $sshArguments.Add('-F')
                $sshArguments.Add($paths.SshConfig)
                $sshArguments.Add('-E')
                $sshArguments.Add($paths.TunnelErrLog)
                $sshArguments.Add('-n')
                $sshArguments.Add('-N')
                $sshArguments.Add('-T')
                foreach ($forwardArgument in @(ConvertTo-BLForwardArgs -Forwards $config.Forwards)) {
                    $sshArguments.Add($forwardArgument)
                }
                $sshArguments.Add([string]$config.HostAlias)

                $startInfo = New-Object System.Diagnostics.ProcessStartInfo
                $startInfo.FileName = [string]$config.SshExe
                $startInfo.Arguments = Join-BLArguments -ArgumentList $sshArguments.ToArray()
                $startInfo.UseShellExecute = $false
                $startInfo.CreateNoWindow = $true
                $startedUtc = [DateTime]::UtcNow
                $tunnel = [System.Diagnostics.Process]::Start($startInfo)
                if ($null -eq $tunnel) {
                    throw ('Lancement impossible de ' + [string]$config.SshExe)
                }
                Write-BLPidFile -Path $paths.TunnelPid -Process $tunnel
                Write-SupervisorLog -Level 'INFO' -Message ('Tunnel lance, pid ' + $tunnel.Id + ', redirections : ' + (@($config.Forwards).Count))

                # c. wait for the end in 5 second slices.
                while (-not $tunnel.WaitForExit(5000)) {
                    if (Test-StopRequested -Paths $paths) {
                        $stopRequested = $true
                        break
                    }
                    Invoke-PeriodicDuties -Paths $paths -SelfProcess $selfProcess | Out-Null
                }
                if ($stopRequested) {
                    break
                }

                # d. the tunnel ended: log, compute the delay, wait, start again.
                $durationSec = [int]([DateTime]::UtcNow - $startedUtc).TotalSeconds
                $tunnelExit = $tunnel.ExitCode
                $tunnel.Dispose()
                $tunnel = $null
                $lastLines = @(Get-BLFileTail -Path $paths.TunnelErrLog -Count 1)
                $lastText = ''
                if ($lastLines.Count -gt 0) {
                    $lastText = ' ; derniere ligne de ssh : ' + [string]$lastLines[0]
                }
                if ($durationSec -ge 300) {
                    $delaySec = 2
                }
                else {
                    $delaySec = [Math]::Min($delaySec * 2, 60)
                }
                Write-SupervisorLog -Level 'WARN' -Message ('Tunnel termine, code ' + $tunnelExit + ', duree ' + $durationSec + ' s, relance dans ' + $delaySec + ' s' + $lastText)
                $waitMs = ($delaySec * 1000) + $random.Next(0, 1001)
                if (Wait-OrStop -Milliseconds $waitMs -Paths $paths -SelfProcess $selfProcess) {
                    $stopRequested = $true
                }
            }
            catch {
                # 3. anything unexpected is logged, then the loop goes on after 30 seconds.
                Write-SupervisorLog -Level 'ERROR' -Message ('Erreur inattendue : ' + $_.Exception.Message)
                if ($null -ne $tunnel) {
                    # Never leave an untracked ssh behind.
                    try {
                        Stop-BLProcessTree -Process $tunnel
                        $tunnel.Dispose()
                    }
                    catch {
                        Write-SupervisorLog -Level 'ERROR' -Message ('Arret du tunnel impossible : ' + $_.Exception.Message)
                    }
                    $tunnel = $null
                }
                try {
                    if (Wait-OrStop -Milliseconds 30000 -Paths $paths -SelfProcess $selfProcess) {
                        $stopRequested = $true
                    }
                }
                catch {
                    Start-Sleep -Seconds 30
                }
            }
        }

        # Stop requested: kill the tunnel of this run and whatever run\tunnel.pid tracks.
        if ($null -ne $tunnel) {
            Stop-BLProcessTree -Process $tunnel
            $tunnel.Dispose()
            $tunnel = $null
        }
        [void](Stop-BLTrackedProcess -Path $paths.TunnelPid -ExpectedName 'ssh')
        foreach ($pidFile in @($paths.TunnelPid, $paths.SupervisorPid)) {
            try {
                if ([System.IO.File]::Exists($pidFile)) {
                    [System.IO.File]::Delete($pidFile)
                }
            }
            catch {
                Write-SupervisorLog -Level 'WARN' -Message ('Suppression impossible de ' + $pidFile)
            }
        }
        Write-SupervisorLog -Level 'INFO' -Message 'Arret demande (run\stop.flag ou kit desinstalle) : tunnel arrete, fin du superviseur.'
    }
}
catch {
    # Failure outside the loop (paths, mutex, first pid file): nothing can be supervised.
    Write-SupervisorLog -Level 'ERROR' -Message ('Arret du superviseur sur erreur fatale : ' + $_.Exception.Message)
    $exitCode = 1
}
finally {
    if ($null -ne $tunnel) {
        try {
            Stop-BLProcessTree -Process $tunnel
            $tunnel.Dispose()
        }
        catch {
            $tunnel = $null
        }
    }
    if ($null -ne $selfProcess) {
        $selfProcess.Dispose()
    }
    Exit-BLMutex -MutexInfo $mutexInfo
}
exit $exitCode
