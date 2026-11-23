param([Parameter(Mandatory)][string]$Godot)
$ErrorActionPreference = 'Stop'
$editor = (Resolve-Path -LiteralPath $Godot).Path
$project = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$logs = Join-Path (Join-Path $project '.review') ("checks-" + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Force -Path $logs)

function Start-Check([string]$Role, [string]$Label = $Role) {
    $log = Join-Path $logs "$Label.log"
    $arguments = @('--headless', '--path', ('"{0}"' -f $project), '--log-file',
        ('"{0}"' -f $log), '--script', 'res://tests/check.gd', '--', $Role)
    Start-Process -FilePath $editor -ArgumentList $arguments -WindowStyle Hidden -PassThru
}

function Confirm-Check($Process, [string]$Role, [string]$Label = $Role) {
    if (-not $Process.WaitForExit(35000)) {
        $Process.Kill()
        throw "$Role timed out."
    }
    $report = Get-Content -LiteralPath (Join-Path $logs "$Label.log") -Raw
    if ($Process.ExitCode -ne 0 -or $report -match '(?m)^(SCRIPT ERROR|ERROR|FAILED):' -or $report -notmatch "PASS $Role") {
        throw "$Role failed. $report"
    }
    Write-Output "PASS $Role"
}

function Wait-ForHost($Server, [string]$Role) {
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    $hostLog = Join-Path $logs "$Role.log"
    do {
        Start-Sleep -Milliseconds 200
        $ready = (Test-Path -LiteralPath $hostLog) -and
            (Select-String -LiteralPath $hostLog -Pattern 'Hosting Breakwater' -Quiet)
    } until ($ready -or $server.HasExited -or [DateTime]::UtcNow -gt $deadline)
    if (-not $ready) { throw 'The test host could not start.' }
}

Confirm-Check (Start-Check 'flight') 'flight'
$server = Start-Check 'host'
try {
    Wait-ForHost $server 'host'
    Confirm-Check (Start-Check 'client') 'client'
    Confirm-Check $server 'host'
} finally {
    if (-not $server.HasExited) { $server.Kill() }
}

$server = Start-Check 'squad_host'
$clients = @()
try {
    Wait-ForHost $server 'squad_host'
    foreach ($n in 1..3) { $clients += Start-Check 'squad_client' "pilot-$n" }
    foreach ($n in 1..3) { Confirm-Check $clients[($n-1)] 'squad_client' "pilot-$n" }
    Confirm-Check $server 'squad_host'
} finally {
    foreach ($worker in ($clients + $server)) { if (-not $worker.HasExited) { $worker.Kill() } }
}
