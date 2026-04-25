param()

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Invoke-ZigCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "zig"
    $psi.Arguments = ($Arguments | ForEach-Object {
        if ($_ -match '[\s\"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        } else {
            $_
        }
    }) -join ' '
    $psi.WorkingDirectory = (Get-Location).Path
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut = $stdout
        StdErr = $stderr
        Output = ($stdout + $stderr)
    }
}

function Pass($message) {
    Write-Host "PASS: $message" -ForegroundColor Green
}

function Fail($message) {
    Write-Host "FAIL: $message" -ForegroundColor Red
    exit 1
}

function Info($message) {
    Write-Host "INFO: $message" -ForegroundColor Yellow
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
Set-Location $projectRoot

Write-Host "=== ZigZag Windows Verification ==="
Write-Host ""
Info "Running on Windows PowerShell"

$zigVersion = zig version
Write-Host "Zig version: $zigVersion"
Write-Host ""

Write-Host -NoNewline "Windows-targeted build... "
$buildResult = Invoke-ZigCapture @("build", "-Dtarget=x86_64-windows-gnu", "-Diocp=true", "-Depoll=false", "-Dio_uring=false", "-Dkqueue=false")
if ($buildResult.ExitCode -ne 0) {
    if ($buildResult.Output) {
        Write-Host ""
        $buildResult.Output
    }
    Fail "Windows-targeted IOCP build failed"
}
Pass "Windows IOCP configuration builds"

Write-Host -NoNewline "Running runtime suite... "
$testResult = Invoke-ZigCapture @("build", "test", "--summary", "all")
if ($testResult.ExitCode -ne 0) {
    Write-Host ""
    $testResult.Output
    Fail "tests failed"
}

$summary = $testResult.Output | Select-String "tests passed"
if (-not $summary) {
    Fail "unable to parse test summary"
}
Pass "tests ($($summary.Line.Trim()))"

Write-Host -NoNewline "IOCP-focused smoke tests... "
$iocpResult = Invoke-ZigCapture @("build", "test-windows-iocp", "--summary", "all")
if ($iocpResult.ExitCode -ne 0) {
    if ($iocpResult.Output) {
        Write-Host ""
        $iocpResult.Output
    }
    Fail "focused Windows IOCP smoke tests failed"
}
Pass "test-windows-iocp"

Write-Host -NoNewline "File-watching smoke tests... "
$filewatchResult = Invoke-ZigCapture @("build", "test-windows-filewatch", "--summary", "all")
if ($filewatchResult.ExitCode -ne 0) {
    if ($filewatchResult.Output) {
        Write-Host ""
        $filewatchResult.Output
    }
    Fail "focused Windows file-watching smoke tests failed"
}
Pass "test-windows-filewatch"

Write-Host -NoNewline "Windows stress smoke tests... "
$stressResult = Invoke-ZigCapture @("build", "test-windows-stress", "--summary", "all")
if ($stressResult.ExitCode -ne 0) {
    if ($stressResult.Output) {
        Write-Host ""
        $stressResult.Output
    }
    Fail "focused Windows stress smoke tests failed"
}
Pass "test-windows-stress"

Write-Host ""
Write-Host "Current Windows support scope:"
Write-Host "  - IOCP timers (CreateTimerQueueTimer)"
Write-Host "  - Wake/user events (PostQueuedCompletionStatus)"
Write-Host "  - WinSock socket I/O (WSARecv/WSASend)"
Write-Host "  - Native file watching via ReadDirectoryChangesW (FileWatcher)"
Write-Host "  - Generic addFd(): NOT supported on Windows"

Write-Host ""
Write-Host "=== Verification complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Runtime-verified on Windows using PowerShell, including focused IOCP smoke tests."
