$ErrorActionPreference = "Stop"
$probeRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$results = @()
foreach ($mode in @("control", "nullrsp")) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $probeRoot "null-rsp-probe.exe"
    $info.Arguments = $mode
    $info.WorkingDirectory = $probeRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $started = $false
    try {
        if (-not $process.Start()) { throw "No se pudo abrir la prueba." }
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit(15000)
        if ($timedOut) {
            try { $process.Kill() } catch { if (-not $process.HasExited) { throw } }
            if (-not $process.WaitForExit(5000)) { throw "El proceso de prueba no se cerro." }
        }
        $clock.Stop()
        $results += [pscustomobject]@{
            mode = $mode
            timedOut = $timedOut
            exitCode = $process.ExitCode
            elapsedMilliseconds = $clock.ElapsedMilliseconds
            stdout = $stdoutTask.Result
            stderr = $stderrTask.Result
        }
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill() }
        $process.Dispose()
    }
}
$resultFile = Join-Path $probeRoot "resultado-windows.json"
[pscustomobject]@{ operatingSystem = [Environment]::OSVersion.VersionString; is64BitOS = [Environment]::Is64BitOperatingSystem; results = $results } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $resultFile -Encoding UTF8
Write-Host "Prueba terminada. Resultado: resultado-windows.json"
