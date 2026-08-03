param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,

    [string]$OutputCsv = "",

    [double]$IntervalSeconds = 0.5
)

$ErrorActionPreference = "Stop"

if ($OutputCsv -eq "") {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputCsv = Join-Path $PSScriptRoot "..\..\profiling\$stamp\memory.csv"
}

$OutputCsv = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputCsv)
$outputDir = Split-Path -Parent $OutputCsv
if (!(Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

function Get-ProcessSample([int]$TargetProcessId) {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $TargetProcessId" -ErrorAction SilentlyContinue
    if ($null -eq $proc) {
        return $null
    }

    # WorkingSetSize / PrivatePageCount are bytes.
    $wsKb = [int]([math]::Round($proc.WorkingSetSize / 1024.0))
    $privateKb = [int]([math]::Round($proc.PrivatePageCount / 1024.0))
    $virtualKb = [int]([math]::Round($proc.VirtualSize / 1024.0))
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    return [pscustomobject]@{
        timestamp_sec = ("{0:F3}" -f $now)
        rss_kb = $wsKb
        private_kb = $privateKb
        virtual_kb = $virtualKb
    }
}

"timestamp_sec,rss_kb,private_kb,virtual_kb" | Set-Content -Path $OutputCsv -Encoding utf8
Write-Host "Sampling PID $ProcessId every $IntervalSeconds s -> $OutputCsv"

while ($true) {
    $sample = Get-ProcessSample -TargetProcessId $ProcessId
    if ($null -eq $sample) {
        Write-Host "Process $ProcessId is no longer running"
        break
    }

    "$($sample.timestamp_sec),$($sample.rss_kb),$($sample.private_kb),$($sample.virtual_kb)" |
        Add-Content -Path $OutputCsv -Encoding utf8
    Start-Sleep -Seconds $IntervalSeconds
}
