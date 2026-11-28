' launch-hidden.vbs - runs a PowerShell script of the bokador-link kit without any window.
' Used by the scheduled tasks in Interactive mode (docs/DESIGN.md, section 4.6):
'   wscript.exe "<bin>\launch-hidden.vbs" "<bin>\<script>.ps1"
' The launcher waits for the script and returns its exit code, so the task stays "running"
' for as long as the script runs. Keep this file plain ASCII.
Option Explicit

Dim shell, fileSystem, scriptPath, systemRoot, powershellExe, commandLine, exitCode

If WScript.Arguments.Count < 1 Then
    WScript.Quit 2
End If

scriptPath = WScript.Arguments(0)
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

' The path ends up between double quotes on a command line: refuse anything unusual.
If InStr(scriptPath, Chr(34)) > 0 Then
    WScript.Quit 2
End If
If LCase(Right(scriptPath, 4)) <> ".ps1" Then
    WScript.Quit 2
End If
If Not fileSystem.FileExists(scriptPath) Then
    WScript.Quit 3
End If

systemRoot = shell.ExpandEnvironmentStrings("%SystemRoot%")
powershellExe = systemRoot & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fileSystem.FileExists(powershellExe) Then
    WScript.Quit 4
End If

commandLine = Chr(34) & powershellExe & Chr(34) & _
    " -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
    Chr(34) & scriptPath & Chr(34)

' 0 = hidden window, True = wait for the end of the process.
exitCode = shell.Run(commandLine, 0, True)
WScript.Quit exitCode
