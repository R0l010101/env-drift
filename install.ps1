# Env Drift Checker installer - run it by double-clicking install.cmd. Safe to run again.
# 1. Adds this folder to your user PATH, so `drift` works in PowerShell, CMD, Git Bash and Claude Code.
# 2. Asks for your project folders (backend and frontend git repos) and saves them in projects.txt.
$dir = $PSScriptRoot
$projectsFile = Join-Path $dir 'projects.txt'

function Get-Kind($p) {
    if (Test-Path (Join-Path $p 'artisan')) { return 'BE' }
    if (Test-Path (Join-Path $p 'package.json')) { return 'FE' }
    return 'repo'
}

# ---------------------------------------------------------------- 1. PATH
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
$keep = @(); $removed = @()
foreach ($p in ($userPath -split ';' | Where-Object { $_ })) {
    $isOtherDrift = ($p -ne $dir) -and (Test-Path (Join-Path $p 'drift.ps1'))
    if ($isOtherDrift) { $removed += $p } else { $keep += $p }
}
if ($keep -notcontains $dir) { $keep += $dir }
$newPath = $keep -join ';'
if ($newPath -ne $userPath) {
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "PATH       : set to $dir"
    foreach ($r in $removed) { Write-Host "PATH       : removed old entry $r" }
} else {
    Write-Host 'PATH       : already set'
}

# ---------------------------------------------------------------- 2. projects
$projects = @()
if (Test-Path $projectsFile) {
    $projects = @(Get-Content $projectsFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}
# first run: reuse the project list of Local Dev Doctor if it is installed next to this folder
if ($projects.Count -eq 0) {
    foreach ($f in (Get-ChildItem (Split-Path $dir) -Directory -ErrorAction SilentlyContinue)) {
        $pf = Join-Path $f.FullName 'projects.txt'
        if ($f.FullName -ne $dir -and (Test-Path (Join-Path $f.FullName 'doctor.ps1')) -and (Test-Path $pf)) {
            $projects = @(Get-Content $pf | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') -and (Test-Path $_) })
            if ($projects.Count) { Write-Host "projects   : copied your project list from $($f.FullName)" -ForegroundColor Green; break }
        }
    }
}

function Show-Projects {
    Write-Host ''
    Write-Host '=== Projects that drift will check ===' -ForegroundColor Cyan
    if ($projects.Count -eq 0) {
        Write-Host '  (none yet)'
    } else {
        $n = 1
        foreach ($p in $projects) { Write-Host "  $n. $p  [$(Get-Kind $p)]"; $n++ }
    }
    Write-Host ''
}

Show-Projects
if ($projects.Count -eq 0) {
    Write-Host 'Add your backend and frontend folders now.' -ForegroundColor Yellow
}
Write-Host 'Do you want to ADD another project to this list?'
Write-Host '  YES -> type its FULL folder path, e.g.  C:\xampp\htdocs\my-app'
Write-Host '         (tip: you can drag the folder from File Explorer into this window)'
Write-Host '  NO  -> just press ENTER'
Write-Host ''
while ($true) {
    $answer = (Read-Host 'Add project (ENTER = no, continue)').Trim().Trim('"')
    if (-not $answer) { break }
    if ($answer -notmatch '^[A-Za-z]:\\|^\\\\') {
        Write-Host "  '$answer' is not a folder path. Type the FULL path starting with the drive, like C:\..., or press ENTER." -ForegroundColor Yellow
        continue
    }
    if (-not (Test-Path $answer)) { Write-Host "  folder not found: $answer" -ForegroundColor Yellow; continue }
    $top = & git -C $answer rev-parse --show-toplevel 2>$null
    if (-not $top) { Write-Host "  not a git repository: $answer" -ForegroundColor Yellow; continue }
    $full = ($top -replace '/', '\').TrimEnd('\')
    if ($projects -contains $full) { Write-Host '  already in the list - it will be checked.' -ForegroundColor Green; continue }
    $projects += $full
    Write-Host "  added [$(Get-Kind $full)]" -ForegroundColor Green
}
Show-Projects
Set-Content $projectsFile ($projects) -Encoding UTF8

Write-Host 'Install done.' -ForegroundColor Green

# ---------------------------------------------------------------- 3. test it right away
if ($projects.Count -gt 0) {
    Write-Host ''
    $run = (Read-Host 'Test it now? Shows YOUR tickets in prod that are not in qa yet. Nothing is changed. (ENTER = yes, n = no)').Trim()
    if ($run -notmatch '^[nN]') {
        & (Join-Path $dir 'drift.ps1') qa -Mine
    }
}

Write-Host ''
Write-Host 'From now on: close this window, open a NEW terminal, and type for example:' -ForegroundColor Green
Write-Host '   drift ESCM-13883 simulation' -ForegroundColor Green
Write-Host '(in Claude Code type:  !drift ESCM-13883 simulation)' -ForegroundColor Green
