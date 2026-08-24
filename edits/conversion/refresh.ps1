#Requires -Version 5.1
# Git workflow around an ax4 conversion: converted/ + edits/ pair, then import to master.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$StampPath = "edits/conversion/stamp"
$ConvertCmd = Join-Path $PSScriptRoot "convert.cmd"

function Show-Usage {
    @"
Usage: refresh.cmd <command> [options]

  start --buildid ID --reasons REASONS [--date YYYY-MM-DD] [--skip-convert]
        [--] [convert options]
                    Create converted/DATE-bID-reasons, run convert, commit stamp
  rebase            Replay edits/latest onto the current converted/ branch
  replay [sha...]   Cherry-pick commits onto the current converted/ branch
                    (default: converted/latest..edits/latest)
  continue          Resume rebase or cherry-pick after resolving conflicts
  abort             Abort rebase or cherry-pick
  import            Copy src/, src-steam/, and stamp from edits/latest onto master

Reasons: dr, jpexs, ax4 (any subset; stored as dr > jpexs > ax4).
Convert flags after -- go to convert.cmd.
"@
}

function Die([string]$Message) {
    [Console]::Error.WriteLine("error: $Message")
    exit 1
}

Set-Location -LiteralPath $Root
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die "git is required" }
git rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Die "not a git repository" }

function Get-StatePath { (git rev-parse --git-path drh-refresh-suffix).Trim() }

function Test-Rebase {
    $merge = git rev-parse --git-path rebase-merge
    $apply = git rev-parse --git-path rebase-apply
    return (Test-Path -LiteralPath $merge) -or (Test-Path -LiteralPath $apply)
}

function Test-CherryPick {
    Test-Path -LiteralPath (git rev-parse --git-path CHERRY_PICK_HEAD)
}

function Assert-NoSequencer {
    if ((Test-Rebase) -or (Test-CherryPick)) {
        Die "rebase or cherry-pick in progress (use continue or abort)"
    }
}

function Test-Ref([string]$Ref) {
    git rev-parse --verify --quiet $Ref 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Save-Suffix([string]$Suffix) {
    Set-Content -LiteralPath (Get-StatePath) -Value $Suffix -NoNewline
}

function Read-Suffix {
    $path = Get-StatePath
    if (-not (Test-Path -LiteralPath $path)) { Die "no in-progress conversion (run start first)" }
    (Get-Content -LiteralPath $path -Raw).Trim()
}

function Invoke-Git {
    git @args
    if ($LASTEXITCODE -ne 0) { Die "git $($args -join ' ') failed ($LASTEXITCODE)" }
}

function Normalize-Reasons([string]$Raw) {
    $hasDr = $false; $hasJpexs = $false; $hasAx4 = $false
    foreach ($part in $Raw.Split('+')) {
        switch ($part) {
            "dr" { $hasDr = $true }
            "jpexs" { $hasJpexs = $true }
            "ax4" { $hasAx4 = $true }
            "" { }
            default { Die "unknown reason '$part' (expected dr, jpexs, ax4)" }
        }
    }
    $out = @()
    if ($hasDr) { $out += "dr" }
    if ($hasJpexs) { $out += "jpexs" }
    if ($hasAx4) { $out += "ax4" }
    if ($out.Count -eq 0) { Die "need at least one reason (dr, jpexs, ax4)" }
    $out -join '+'
}

function Get-SiblingHead([string]$Name) {
    $dir = Join-Path (Split-Path -Parent $Root) $Name
    if (Test-Path -LiteralPath (Join-Path $dir ".git")) {
        $sha = git -C $dir rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0) { return $sha.Trim() }
    }
    ""
}

function Write-Stamp([string]$Suffix, [string]$StampDate, [string]$Id, [string]$StampReasons) {
    $full = Join-Path $Root $StampPath
    $dir = Split-Path -Parent $full
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $text = @"
branch=$Suffix
date=$StampDate
buildid=$Id
reasons=$StampReasons
jpexs=$(Get-SiblingHead 'jpexs-decompiler')
ax4=$(Get-SiblingHead 'ax4')
"@
    [System.IO.File]::WriteAllText($full, $text.TrimEnd() + "`n")
}

function Get-ConvertedSuffix {
    $branch = (git branch --show-current).Trim()
    if ($branch -notlike "converted/*" -or $branch -eq "converted/latest") {
        Die "current branch must be converted/<date>-b<id>-<reasons> (on $branch)"
    }
    $branch.Substring("converted/".Length)
}

function Point-Latest([string]$Suffix) {
    Invoke-Git branch -f "converted/latest" "converted/$Suffix"
    Invoke-Git branch -f "edits/latest" "edits/$Suffix"
    $state = Get-StatePath
    if (Test-Path -LiteralPath $state) { Remove-Item -LiteralPath $state }
    Write-Host "converted/latest and edits/latest -> $Suffix"
}

function Invoke-Start([string[]]$Argv) {
    $buildId = $null
    $reasons = $null
    $stampDate = $null
    $skipConvert = $false
    $convertArgs = @()
    $i = 0
    while ($i -lt $Argv.Count) {
        switch ($Argv[$i]) {
            "--buildid" { $buildId = $Argv[$i + 1]; $i += 2 }
            "--reasons" { $reasons = $Argv[$i + 1]; $i += 2 }
            "--date" { $stampDate = $Argv[$i + 1]; $i += 2 }
            "--skip-convert" { $skipConvert = $true; $i += 1 }
            "--" { $i += 1; if ($i -lt $Argv.Count) { $convertArgs = $Argv[$i..($Argv.Count - 1)] }; $i = $Argv.Count }
            default { Die "unknown option: $($Argv[$i])" }
        }
    }
    if (-not $buildId) { Die "start requires --buildid" }
    if ($buildId -notmatch '^[0-9]+$') { Die "buildid must be numeric" }
    if (-not $reasons) { Die "start requires --reasons" }
    $reasons = Normalize-Reasons $reasons
    if (-not $stampDate) { $stampDate = Get-Date -Format "yyyy-MM-dd" }
    if ($stampDate -notmatch '^\d{4}-\d{2}-\d{2}$') { Die "date must be YYYY-MM-DD" }

    Assert-NoSequencer

    $suffix = "$stampDate-b$buildId-$reasons"
    $branch = "converted/$suffix"
    if (Test-Ref "refs/heads/$branch") { Die "branch already exists: $branch" }

    if (Test-Ref "refs/heads/converted/latest") { Invoke-Git checkout converted/latest }
    Invoke-Git checkout -b $branch
    Save-Suffix $suffix

    if (-not $skipConvert) {
        & $ConvertCmd @convertArgs
        if ($LASTEXITCODE -ne 0) { Die "convert failed ($LASTEXITCODE)" }
    }

    Write-Stamp $suffix $stampDate $buildId $reasons
    Invoke-Git add -- src src-steam $StampPath
    $jpexs = Get-SiblingHead "jpexs-decompiler"
    $ax4 = Get-SiblingHead "ax4"
    $msg = @"
Convert $stampDate b$buildId ($reasons)

BuildID: $buildId
reasons: $reasons
jpexs: $jpexs
ax4:   $ax4
"@
    Invoke-Git commit -m $msg
    Write-Host "created $branch"
    if (Test-Ref "refs/heads/edits/latest") {
        Write-Host "next: refresh.cmd rebase"
    }
    else {
        Invoke-Git branch "edits/$suffix"
        Point-Latest $suffix
        Write-Host "first pair: add stack commits on edits/$suffix, then refresh.cmd import"
    }
}

function Invoke-RebaseCmd {
    Assert-NoSequencer
    $suffix = Get-ConvertedSuffix
    Save-Suffix $suffix
    if (-not (Test-Ref "refs/heads/edits/latest")) { Die "no edits/latest" }
    if (-not (Test-Ref "refs/heads/converted/latest")) { Die "no converted/latest" }
    Invoke-Git rebase --onto "converted/$suffix" converted/latest edits/latest
    Invoke-Git branch -f "edits/$suffix"
    Point-Latest $suffix
}

function Invoke-Replay([string[]]$Shas) {
    Assert-NoSequencer
    $suffix = Get-ConvertedSuffix
    Save-Suffix $suffix
    if ($Shas.Count -eq 0) {
        if (-not (Test-Ref "refs/heads/edits/latest")) { Die "no edits/latest and no commit list" }
        if (-not (Test-Ref "refs/heads/converted/latest")) { Die "no converted/latest" }
        $Shas = @(git rev-list --reverse "converted/latest..edits/latest")
        if ($LASTEXITCODE -ne 0 -or $Shas.Count -eq 0) {
            Die "edits/latest has no commits beyond converted/latest"
        }
    }
    Invoke-Git checkout -B "edits/$suffix" "converted/$suffix"
    foreach ($sha in $Shas) { Invoke-Git cherry-pick $sha }
    Point-Latest $suffix
}

function Invoke-Continue {
    $suffix = Read-Suffix
    if (Test-Rebase) {
        Invoke-Git rebase --continue
        Invoke-Git branch -f "edits/$suffix"
        Point-Latest $suffix
        return
    }
    if (Test-CherryPick) {
        Invoke-Git cherry-pick --continue
        if (Test-CherryPick) {
            Write-Host "cherry-pick continues; resolve the next commit then refresh.cmd continue"
            return
        }
        Invoke-Git branch -f "edits/$suffix"
        Point-Latest $suffix
        return
    }
    Die "no rebase or cherry-pick in progress"
}

function Invoke-Abort {
    if (Test-Rebase) { Invoke-Git rebase --abort; Write-Host "rebase aborted"; return }
    if (Test-CherryPick) { Invoke-Git cherry-pick --abort; Write-Host "cherry-pick aborted"; return }
    Die "no rebase or cherry-pick in progress"
}

function Invoke-Import {
    Assert-NoSequencer
    if (-not (Test-Ref "refs/heads/edits/latest")) { Die "no edits/latest" }
    $current = (git branch --show-current).Trim()
    if ($current -ne "master") { Invoke-Git checkout master }
    $source = (git rev-parse --abbrev-ref edits/latest).Trim()
    Invoke-Git checkout edits/latest -- src src-steam $StampPath
    Invoke-Git commit -m "Refresh src from $source"
}

if ($args.Count -eq 0) { Show-Usage; exit 1 }
$Command = $args[0]
$Argv = @()
if ($args.Count -gt 1) { $Argv = [string[]]$args[1..($args.Count - 1)] }

switch ($Command) {
    "start" { Invoke-Start $Argv }
    "rebase" { Invoke-RebaseCmd }
    "replay" { Invoke-Replay $Argv }
    "continue" { Invoke-Continue }
    "abort" { Invoke-Abort }
    "import" { Invoke-Import }
    { $_ -in @("-h", "--help") } { Show-Usage }
    default { Show-Usage; Die "unknown command: $Command" }
}
