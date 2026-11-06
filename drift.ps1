# Env Drift Checker - is it safe to port a ticket from prod to qa / staging / simulation?
# Read-only: only runs git log / grep / ls-tree / show (and git fetch unless -NoFetch). Never checks out, never touches a DB.
#
#   drift ESCM-13883 simulation   is it safe to port ESCM-13883 to simulation?
#   drift ESCM-13883              same, for every environment in drift.config
#   drift qa                      overview: tickets in prod (last 60 days) that are not in qa yet
param(
    [Parameter(Position = 0)][string]$First,
    [Parameter(Position = 1)][string]$Second,
    [int]$Days = 60,
    [int]$Lookback = 180,
    [string]$Path,
    [switch]$NoFetch,
    [switch]$Mine
)
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$script:totalFail = 0

function New-Set { return , (New-Object 'System.Collections.Generic.HashSet[string]') }

# ---------------------------------------------------------------- config
$sourceBranch = 'prod'
$prefix = ''
$envs = [ordered]@{}
$cfgFile = Join-Path $PSScriptRoot 'drift.config'
if (Test-Path $cfgFile) {
    foreach ($line in Get-Content $cfgFile) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        if ($l -match '^([\w-]+)\s*=\s*(.+)$') {
            $k = $matches[1].ToLower(); $v = $matches[2].Trim()
            if ($k -eq 'source') { $sourceBranch = $v }
            elseif ($k -eq 'ticket_prefix') { $prefix = $v }
            else { $envs[$k] = $v }
        }
    }
}
if ($envs.Count -eq 0) { $envs['qa'] = 'qa'; $envs['staging'] = 'staging' }

if ($prefix) { $tkRe = '(?i)(' + [regex]::Escape($prefix) + ')-?(\d+)' } else { $tkRe = '\b([A-Z]{2,10})-?(\d{3,7})\b' }
function Get-Tickets([string]$text) {
    $r = @()
    foreach ($m in [regex]::Matches($text, $tkRe)) { $r += ($m.Groups[1].Value.ToUpper() + '-' + $m.Groups[2].Value) }
    return ($r | Select-Object -Unique)
}

function Show-Usage {
    Write-Host 'Env Drift Checker - is it safe to port a ticket from prod to another environment?'
    Write-Host ''
    Write-Host '  drift ESCM-13883 simulation   check before porting ESCM-13883 to simulation'
    Write-Host '  drift ESCM-13883              same, for every environment'
    Write-Host '  drift qa                      tickets in prod (last 60 days) that are not in qa yet'
    Write-Host ''
    Write-Host "Environments: $(@($envs.Keys) -join ', ')   (source: $sourceBranch, edit drift.config)"
    Write-Host '  drift qa -Mine                same, only your own commits'
    Write-Host ''
    Write-Host 'Options: -Days N (overview window, default 60), -Lookback N (how far back to look for related tickets, default 180),'
    Write-Host '         -NoFetch (skip git fetch), -Path <repo> (one repo only)'
}

# ---------------------------------------------------------------- arguments
$ticket = $null; $envArg = $null
if ($First -match '^([A-Za-z]{2,10})-?(\d{2,7})$') { $ticket = $matches[1].ToUpper() + '-' + $matches[2]; $envArg = $Second }
elseif ($First -match '^\d{2,7}$' -and $prefix) { $ticket = $prefix.ToUpper() + '-' + $First; $envArg = $Second }
elseif ($First) { $envArg = $First }
else { Show-Usage; exit 0 }

$envNames = @()
if ($envArg) {
    $a = $envArg.ToLower()
    $hit = @($envs.Keys | Where-Object { $_ -eq $a })
    if ($hit.Count -eq 0) { $hit = @($envs.Keys | Where-Object { $_.StartsWith($a) }) }
    if ($hit.Count -ne 1) {
        Write-Host "Unknown environment or ticket: '$envArg'" -ForegroundColor Yellow
        Write-Host ''
        Show-Usage
        exit 2
    }
    $envNames = $hit
} else {
    $envNames = @($envs.Keys)
}

# ---------------------------------------------------------------- output
$script:envFail = 0; $script:envWarn = 0
function Out-Line($tag, $msg) {
    $color = @{ 'OK' = 'Green'; 'INFO' = 'Gray'; 'WARN' = 'Yellow'; 'FAIL' = 'Red' }[$tag]
    if ($tag -eq 'FAIL') { $script:envFail++; $script:totalFail++ }
    if ($tag -eq 'WARN') { $script:envWarn++ }
    Write-Host ('[{0,-4}] ' -f $tag) -ForegroundColor $color -NoNewline
    Write-Host $msg
}
function Out-Sub($msg) { Write-Host "         $msg" -ForegroundColor DarkGray }

# ---------------------------------------------------------------- git helpers
$script:repo = $null
function G([string[]]$a) { & git -C $script:repo @a 2>$null }

function Get-Toplevel($p) {
    $t = & git -C $p rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $t) { return ($t -replace '/', '\') }
    return $null
}

# a config value is a branch on origin; a local branch, tag or commit also works
function Resolve-EnvRef($b) {
    if (G @('rev-parse', '--verify', '-q', "origin/$b")) { return "origin/$b" }
    if (G @('rev-parse', '--verify', '-q', $b)) { return $b }
    return "origin/$b"
}

$script:envCache = @{}
function Get-EnvData($ref) {
    $key = "$($script:repo)|$ref"
    if ($script:envCache.ContainsKey($key)) { return $script:envCache[$key] }
    $lines = [string[]]@(G @('log', $ref, '--format=%s'))
    $subjects = New-Object 'System.Collections.Generic.HashSet[string]' (, $lines)
    $tickets = New-Set
    foreach ($m in [regex]::Matches(($lines -join "`n"), $tkRe)) { [void]$tickets.Add($m.Groups[1].Value.ToUpper() + '-' + $m.Groups[2].Value) }
    $tree = New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]@(G @('ls-tree', '-r', '--name-only', $ref)))
    $d = @{ Subjects = $subjects; Tickets = $tickets; Tree = $tree }
    $script:envCache[$key] = $d
    return $d
}

# names defined as `function <name>(` in a ref (PHP)
function Get-DefinedFunctions($ref, $names) {
    $found = New-Set
    $list = @($names)
    for ($i = 0; $i -lt $list.Count; $i += 60) {
        $chunk = $list[$i..([Math]::Min($i + 59, $list.Count - 1))]
        $pat = 'function[[:space:]]+&?(' + ($chunk -join '|') + ')[[:space:]]*\('
        foreach ($l in (G @('grep', '-h', '-o', '-E', $pat, $ref, '--', '*.php'))) {
            if ($l -match 'function\s+&?(\w+)') { [void]$found.Add($matches[1]) }
        }
    }
    return , $found
}

$script:showCache = @{}
function Get-FileAt($ref, $file) {
    $key = "$($script:repo)|$ref|$file"
    if (-not $script:showCache.ContainsKey($key)) { $script:showCache[$key] = ((G @('show', "${ref}:$file")) -join "`n") }
    return $script:showCache[$key]
}

function Resolve-JsImport($fromFile, $rel, $tree) {
    $dir = ($fromFile -replace '/[^/]*$', '')
    if ($dir -eq $fromFile) { $dir = '' }
    $parts = New-Object System.Collections.ArrayList
    foreach ($p in (($dir + '/' + $rel) -split '/')) {
        if (-not $p -or $p -eq '.') { continue }
        if ($p -eq '..') { if ($parts.Count) { $parts.RemoveAt($parts.Count - 1) } ; continue }
        [void]$parts.Add($p)
    }
    $base = $parts -join '/'
    foreach ($c in @($base, "$base.js", "$base.jsx", "$base.ts", "$base.tsx", "$base/index.js", "$base/index.jsx", "$base/index.ts", "$base/index.tsx")) {
        if ($tree.Contains($c)) { return $c }
    }
    return $null
}

$lockFiles = '(^|/)(package-lock\.json|yarn\.lock|composer\.lock|pnpm-lock\.yaml)$'
$phpStop = @('if','for','foreach','while','switch','array','list','isset','unset','empty','function','fn','return','echo','print','catch','elseif','match','new','and','or','not','use','exit','die','eval','include','require','static','self','parent','compact','extract','count','date','now')
$colTypes = 'string|integer|bigInteger|unsignedBigInteger|unsignedInteger|tinyInteger|smallInteger|mediumInteger|boolean|decimal|double|float|date|dateTime|timestamp|time|year|text|longText|mediumText|json|enum|char|foreignId|uuid|binary|renameColumn'
$colStop = @('name','code','status','type','amount','remarks','description','created_at','updated_at','deleted_at','created_by','updated_by','deleted_by','is_active','user_id','email','date','total','quantity','price','notes','title','value','active')

# ---------------------------------------------------------------- ticket mode
function Test-Ticket {
    $src = "origin/$sourceBranch"
    $num = ($ticket -split '-')[1]
    $tp = ($ticket -split '-')[0]
    $gitRe = "$tp-?$num([^0-9]|$)"
    $fmt = '--format=>>%H|%ct|%s'
    $base = @('--no-merges', '-E', '-i', "--grep=$gitRe", '-p', '-U0', '--no-color', '--no-ext-diff', $fmt)

    $inSource = $true
    $raw = @(G (@('log', $src) + $base))
    if (-not ($raw | Where-Object { $_.StartsWith('>>') })) {
        $inSource = $false
        $raw = @(G (@('log', '--all') + $base))
    }
    if (-not ($raw | Where-Object { $_.StartsWith('>>') })) {
        Out-Line 'INFO' "$ticket has no commits in this repo - nothing to check"
        return
    }

    # parse the ticket's own commits (deduped by subject: the _qa/_staging ports repeat them)
    $seen = New-Set; $commits = @(); $added = @{}; $files = New-Set; $newFiles = New-Set
    $skip = $false; $cur = $null
    foreach ($line in $raw) {
        if ($line.StartsWith('>>')) {
            $p = $line.Substring(2).Split('|', 3)
            $skip = -not $seen.Add($p[2])
            if (-not $skip) { $commits += [pscustomobject]@{ Hash = $p[0]; Time = [long]$p[1]; Subject = $p[2] } }
            $cur = $null; continue
        }
        if ($skip) { continue }
        if ($line -match '^diff --git a/(.+) b/(.+)$') { $cur = $matches[2]; [void]$files.Add($cur); continue }
        if ($line.StartsWith('new file mode')) { if ($cur) { [void]$newFiles.Add($cur) }; continue }
        if ($line.StartsWith('+++') -or $line.StartsWith('---')) { continue }
        if ($line.StartsWith('+') -and $cur) {
            if (-not $added.ContainsKey($cur)) { $added[$cur] = New-Object Text.StringBuilder }
            [void]$added[$cur].AppendLine($line.Substring(1))
        }
    }
    $newest = ($commits | Sort-Object Time -Descending)[0]
    $where = if ($inSource) { "in $sourceBranch" } else { "NOT in $sourceBranch yet - using your branch" }
    Out-Line 'INFO' "$ticket : $($commits.Count) commit(s), $($files.Count) file(s), $where"

    # other commits that touched the same files before this ticket
    $fileList = @($files | Where-Object { $_ -notmatch $lockFiles })
    $since = [DateTimeOffset]::FromUnixTimeSeconds($newest.Time - [long]$Lookback * 86400).ToString('yyyy-MM-dd')
    $deps = @()
    for ($i = 0; $i -lt $fileList.Count; $i += 150) {
        $chunk = $fileList[$i..([Math]::Min($i + 149, $fileList.Count - 1))]
        $c = $null
        foreach ($line in (G (@('log', $newest.Hash, '--no-merges', "--since=$since", '--name-only', $fmt, '--') + $chunk))) {
            if ($line.StartsWith('>>')) {
                $p = $line.Substring(2).Split('|', 3)
                $c = [pscustomobject]@{ Hash = $p[0]; Time = [long]$p[1]; Subject = $p[2]; Files = (New-Set) }
                $deps += $c
            } elseif ($line -and $c) { [void]$c.Files.Add($line) }
        }
    }
    $depByHash = @{}
    foreach ($d in $deps) {
        if ($seen.Contains($d.Subject)) { continue }
        if ((Get-Tickets $d.Subject) -contains $ticket) { continue }
        if ($depByHash.ContainsKey($d.Hash)) { foreach ($f in $d.Files) { [void]$depByHash[$d.Hash].Files.Add($f) } }
        else { $depByHash[$d.Hash] = $d }
    }
    $groups = @{}
    foreach ($d in $depByHash.Values) {
        $tk = @(Get-Tickets $d.Subject)
        $key = if ($tk.Count) { $tk[0] } else { '(no ticket) ' + $d.Subject }
        if (-not $groups.ContainsKey($key)) { $groups[$key] = @() }
        $groups[$key] += $d
    }

    # text the ticket adds, split by kind
    $phpText = New-Object Text.StringBuilder; $allText = New-Object Text.StringBuilder
    foreach ($f in $added.Keys) {
        [void]$allText.Append($added[$f].ToString())
        if ($f -like '*.php' -and $f -notlike 'database/migrations/*') { [void]$phpText.Append($added[$f].ToString()) }
    }
    $phpText = $phpText.ToString(); $allText = $allText.ToString()
    $srcTree = New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]@(G @('ls-tree', '-r', '--name-only', $newest.Hash)))

    # PHP: functions/methods called by the ticket and not defined by it
    $ownDefs = New-Set
    foreach ($m in [regex]::Matches($allText, 'function\s+&?(\w+)')) { [void]$ownDefs.Add($m.Groups[1].Value) }
    $calls = New-Set
    foreach ($m in [regex]::Matches($phpText, '(?:->|::)\s*(\w+)\s*\(|(?<![\w$>:\\])([a-z_]\w*)\s*\(')) {
        $n = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        if ($n.Length -ge 3 -and $phpStop -notcontains $n.ToLower() -and -not $ownDefs.Contains($n)) { [void]$calls.Add($n) }
    }
    $srcDefs = New-Set
    if ($calls.Count) { $srcDefs = Get-DefinedFunctions $newest.Hash $calls }
    $classUses = New-Set
    foreach ($m in [regex]::Matches($phpText, '(?m)^\s*use\s+(App\\[\w\\]+)\s*;')) { [void]$classUses.Add($m.Groups[1].Value) }

    # migrations: columns/tables created by migrations, used by the ticket
    $migTokens = @{}; $migUsed = @{}
    $hasMig = $srcTree | Where-Object { $_ -like 'database/migrations/*' } | Select-Object -First 1
    if ($hasMig) {
        $nonMig = New-Object Text.StringBuilder
        foreach ($f in $added.Keys) { if ($f -notlike 'database/migrations/*') { [void]$nonMig.Append($added[$f].ToString()) } }
        $nonMig = $nonMig.ToString()
        foreach ($l in (G @('grep', '-E', '-i', "Schema::(create|table)|->($colTypes)\(|ADD[[:space:]]|CREATE TABLE|ALTER TABLE|'[a-z]+_[a-z0-9_]+'", $newest.Hash, '--', 'database/migrations'))) {
            if ($l -notmatch '^[0-9a-f]+:([^:]+):(.*)$') { continue }
            $mf = $matches[1]; $code = $matches[2]
            if ($newFiles.Contains($mf)) { continue }
            $toks = @()
            foreach ($m in [regex]::Matches($code, "->(?:$colTypes)\(\s*['""](\w+)['""]")) { $toks += $m.Groups[1].Value }
            foreach ($m in [regex]::Matches($code, "Schema::(?:create|table)\(\s*['""](\w+)['""]")) { $toks += $m.Groups[1].Value }
            # names kept in arrays, e.g. private $flags = ['set_as_ecr_recipient', ...]
            foreach ($m in [regex]::Matches($code, "'([a-z]+_[a-z0-9_]+)'")) { $toks += $m.Groups[1].Value }
            foreach ($m in [regex]::Matches($code, '(?i)(?:ADD\s+(?:COLUMN\s+)?|CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?|ALTER\s+TABLE\s+)`?(\w+)`?')) { $toks += $m.Groups[1].Value }
            foreach ($t in $toks) {
                if ($t.Length -lt 5 -or $colStop -contains $t.ToLower() -or $t -match '^(column|index|unique|primary|constraint|foreign|after|null)$') { continue }
                if (-not $migUsed.ContainsKey($t)) { $migUsed[$t] = ($nonMig -match ('\b' + [regex]::Escape($t) + '\b')) }
                if ($migUsed[$t]) {
                    if (-not $migTokens.ContainsKey($t)) { $migTokens[$t] = New-Object System.Collections.ArrayList }
                    if (-not $migTokens[$t].Contains($mf)) { [void]$migTokens[$t].Add($mf) }
                }
            }
        }
    }

    foreach ($envName in $envNames) {
        $envRef = Resolve-EnvRef $envs[$envName]
        Write-Host ''
        Write-Host "--- $envName ($envRef)" -ForegroundColor Cyan
        if (-not (G @('rev-parse', '--verify', '-q', $envRef))) { Out-Line 'INFO' "branch $envRef not found in this repo - skipped"; continue }
        $script:envFail = 0; $script:envWarn = 0
        $ed = Get-EnvData $envRef

        # the ticket itself
        $have = @($commits | Where-Object { $ed.Subjects.Contains($_.Subject) }).Count
        if ($have -eq $commits.Count) { Out-Line 'INFO' "$ticket is already in $envName (all $have commits)" }
        elseif ($have -gt 0) { Out-Line 'INFO' "$ticket is partly in $envName ($have of $($commits.Count) commits)" }
        else { Out-Line 'INFO' "$ticket is not in $envName yet" }

        # 1. other tickets that touched the same files
        $okCount = 0; $missing = @()
        foreach ($key in $groups.Keys) {
            $list = $groups[$key]
            $in = @($list | Where-Object { $ed.Subjects.Contains($_.Subject) }).Count
            $tkInEnv = (-not $key.StartsWith('(no ticket)')) -and $ed.Tickets.Contains($key)
            if ($in -eq $list.Count -or ($in -eq 0 -and $tkInEnv)) { $okCount++; continue }
            $touched = New-Set
            foreach ($d in $list) { foreach ($f in $d.Files) { [void]$touched.Add($f) } }
            $missing += [pscustomobject]@{ Key = $key; In = $in; Total = $list.Count; Files = @($touched); Time = ($list | Measure-Object Time -Maximum).Maximum; List = $list }
        }
        if ($okCount) { Out-Line 'OK' "$okCount other ticket(s) that changed your files (last $Lookback days) are in $envName" }
        foreach ($m in ($missing | Sort-Object @{ Expression = { $_.Files.Count }; Descending = $true }, @{ Expression = 'Time'; Descending = $true })) {
            $when = [DateTimeOffset]::FromUnixTimeSeconds($m.Time).ToLocalTime().ToString('yyyy-MM-dd')
            $fl = (@($m.Files | Select-Object -First 3) -join ', ')
            if ($m.Files.Count -gt 3) { $fl += " (+$($m.Files.Count - 3) more)" }
            if ($m.Key.StartsWith('(no ticket)')) {
                Out-Line 'WARN' "commit not in ${envName}: '$($m.List[0].Subject)' ($when) - changed $fl"
            } elseif ($m.In -gt 0) {
                Out-Line 'WARN' "$($m.Key) is only partly in $envName ($($m.In) of $($m.Total) commits, $when) - changed $fl"
                foreach ($d in ($m.List | Where-Object { -not $ed.Subjects.Contains($_.Subject) } | Select-Object -First 3)) { Out-Sub "missing: $($d.Subject)" }
            } else {
                Out-Line 'WARN' "$($m.Key) is NOT in $envName ($when) - it changed $fl"
                Out-Sub $m.List[0].Subject
            }
        }

        # 2. database columns / tables
        if ($migTokens.Count) {
            $envFound = New-Set
            $missFile = @{}
            foreach ($t in $migTokens.Keys) {
                $mf = @($migTokens[$t] | Where-Object { -not $ed.Tree.Contains($_) })
                if ($mf.Count) { $missFile[$t] = $mf[0] }
            }
            $toks = @($missFile.Keys)
            for ($i = 0; $i -lt $toks.Count; $i += 60) {
                $chunk = $toks[$i..([Math]::Min($i + 59, $toks.Count - 1))]
                $pat = '(' + ($chunk -join '|') + ')'
                foreach ($l in (G @('grep', '-h', '-o', '-w', '-E', $pat, $envRef, '--', 'database/migrations'))) { [void]$envFound.Add($l) }
            }
            foreach ($t in $toks) {
                if (-not $envFound.Contains($t)) {
                    Out-Line 'FAIL' "your code uses '$t', but no migration in $envName creates it"
                    $by = @(G @('log', $newest.Hash, '--diff-filter=A', '--format=%s', '--', $missFile[$t])) | Select-Object -Last 1
                    $byTk = @(Get-Tickets "$by")
                    $byTxt = if ($byTk.Count) { " (added by $($byTk[0]) - port it first)" } else { '' }
                    Out-Sub "comes from $($missFile[$t]), which is not in $envName$byTxt"
                }
            }
        }

        # 3. functions / classes / imports your code needs
        if ($srcDefs.Count) {
            $envDefs = Get-DefinedFunctions $envRef $srcDefs
            foreach ($n in $srcDefs) { if (-not $envDefs.Contains($n)) { Out-Line 'FAIL' "your code calls $n(), which does not exist in $envName" } }
        }
        foreach ($cls in $classUses) {
            $pf = 'app/' + (($cls.Substring(4)) -replace '\\', '/') + '.php'
            if ($srcTree.Contains($pf) -and -not $newFiles.Contains($pf) -and -not $ed.Tree.Contains($pf)) {
                Out-Line 'FAIL' "your code uses $cls, which does not exist in $envName"
            }
        }
        foreach ($f in $added.Keys) {
            if ($f -notmatch '\.(js|jsx|ts|tsx)$') { continue }
            $text = $added[$f].ToString()
            foreach ($m in [regex]::Matches($text, "import\s+([\s\S]*?)\s+from\s+['""](\.{1,2}/[^'""]+)['""]")) {
                $target = Resolve-JsImport $f $m.Groups[2].Value $srcTree
                if (-not $target -or $newFiles.Contains($target)) { continue }
                if (-not $ed.Tree.Contains($target)) {
                    Out-Line 'FAIL' "$f imports $target, which does not exist in $envName"
                    continue
                }
                $clause = $m.Groups[1].Value
                if ($clause -notmatch '\{([^}]*)\}') { continue }
                $ownAdd = if ($added.ContainsKey($target)) { $added[$target].ToString() } else { '' }
                foreach ($raw in ($matches[1] -split ',')) {
                    $name = (($raw.Trim() -replace '^type\s+', '') -split '\s+as\s+')[0].Trim()
                    if (-not $name -or $ownAdd -match ('\b' + [regex]::Escape($name) + '\b')) { continue }
                    $exp = '(?m)export\s+(?:default\s+)?(?:const|let|var|function\*?|class|async\s+function)\s+' + [regex]::Escape($name) + '\b|export\s*\{[^}]*\b' + [regex]::Escape($name) + '\b'
                    $envCode = Get-FileAt $envRef $target
                    if ($envCode -match 'export\s+\*' -or $envCode -match $exp) { continue }
                    if ((Get-FileAt $newest.Hash $target) -match $exp) {
                        Out-Line 'FAIL' "$f imports { $name } from $target, but $envName's $target does not export it"
                    }
                }
            }
        }

        if ($script:envFail) { Write-Host "=> NOT SAFE to port to ${envName}: fix the FAIL items first (port what is missing, or adjust your code)" -ForegroundColor Red }
        elseif ($script:envWarn) { Write-Host "=> CHECK FIRST: tickets that changed the same files are missing in $envName. Port them first if your code depends on them" -ForegroundColor Yellow }
        else { Write-Host "=> SAFE to port to $envName" -ForegroundColor Green }
    }
}

# ---------------------------------------------------------------- overview mode
function Show-Overview {
    $src = "origin/$sourceBranch"
    foreach ($envName in $envNames) {
        $envRef = Resolve-EnvRef $envs[$envName]
        $who = if ($Mine) { ', only your commits' } else { '' }
        Write-Host "--- $sourceBranch -> $envName, last $Days days$who" -ForegroundColor Cyan
        if (-not (G @('rev-parse', '--verify', '-q', $envRef))) { Out-Line 'INFO' "branch $envRef not found in this repo - skipped"; continue }
        $ed = Get-EnvData $envRef
        $groups = [ordered]@{}; $noTicket = @()
        $logArgs = @('log', $src, '--no-merges', "--since=$Days.days.ago", '--format=%ct|%an|%s')
        if ($Mine) {
            $me = (G @('config', 'user.email'))
            if ($me) { $logArgs += "--author=$me" }
        }
        foreach ($line in (G $logArgs)) {
            $p = $line.Split('|', 3)
            $c = [pscustomobject]@{ Time = [long]$p[0]; Author = $p[1]; Subject = $p[2] }
            $tk = @(Get-Tickets $c.Subject)
            if ($tk.Count) {
                if (-not $groups.Contains($tk[0])) { $groups[$tk[0]] = @() }
                $groups[$tk[0]] += $c
            } elseif (-not $ed.Subjects.Contains($c.Subject)) { $noTicket += $c }
        }
        $notIn = @(); $partly = @(); $okCount = 0
        foreach ($k in $groups.Keys) {
            $list = $groups[$k]
            $in = @($list | Where-Object { $ed.Subjects.Contains($_.Subject) }).Count
            if ($in -eq $list.Count -or ($in -eq 0 -and $ed.Tickets.Contains($k))) { $okCount++ }
            elseif ($in -eq 0) { $notIn += [pscustomobject]@{ Key = $k; List = $list } }
            else { $partly += [pscustomobject]@{ Key = $k; List = $list; In = $in } }
        }
        Out-Line 'INFO' "$($groups.Count) ticket(s) changed $sourceBranch; $okCount already in $envName"
        if ($notIn.Count) {
            Out-Line 'WARN' "$($notIn.Count) ticket(s) in $sourceBranch but NOT in ${envName}:"
            foreach ($t in $notIn) {
                $last = $t.List[0]
                $when = [DateTimeOffset]::FromUnixTimeSeconds($last.Time).ToLocalTime().ToString('yyyy-MM-dd')
                Write-Host ('         {0,-11} {1}  {2,-18} {3}' -f $t.Key, $when, $last.Author, $last.Subject)
            }
        }
        if ($partly.Count) {
            Out-Line 'WARN' "$($partly.Count) ticket(s) only partly in ${envName}:"
            foreach ($t in $partly) { Write-Host ('         {0,-11} {1} of {2} commits' -f $t.Key, $t.In, $t.List.Count) }
        }
        if ($noTicket.Count) {
            Out-Line 'INFO' "$($noTicket.Count) commit(s) without a ticket ID are not in ${envName}, e.g.:"
            foreach ($c in ($noTicket | Select-Object -First 5)) { Out-Sub "$($c.Author): $($c.Subject)" }
        }
        if (-not $notIn.Count -and -not $partly.Count) { Out-Line 'OK' "$envName has every ticket from the last $Days days" }
        Write-Host ''
    }
}

# ---------------------------------------------------------------- targets
$targets = @()
if ($Path) {
    $t = Get-Toplevel $Path
    if (-not $t) { Write-Host "Not a git repository: $Path" -ForegroundColor Red; exit 2 }
    $targets = @($t)
} else {
    $pf = Join-Path $PSScriptRoot 'projects.txt'
    if (Test-Path $pf) { $targets = @(Get-Content $pf | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') -and (Test-Path $_) }) }
    $here = Get-Toplevel (Get-Location).Path
    if ($here -and -not ($targets | Where-Object { $_ -ieq $here })) { $targets += $here }
}
if (-not $targets.Count) {
    Write-Host 'No projects to check. Run install.cmd to add your backend and frontend folders, or run drift inside a project folder.' -ForegroundColor Yellow
    exit 2
}

foreach ($r in $targets) {
    $script:repo = $r
    $kind = if (Test-Path (Join-Path $r 'artisan')) { 'BE' } elseif (Test-Path (Join-Path $r 'package.json')) { 'FE' } else { 'repo' }
    Write-Host ''
    Write-Host "Drift - $r [$kind]" -ForegroundColor White
    if (-not $NoFetch) {
        Write-Host '         fetching latest branches...' -ForegroundColor DarkGray
        G @('fetch', 'origin', '--quiet', '--no-tags') | Out-Null
        if ($LASTEXITCODE -ne 0) { Out-Line 'WARN' 'git fetch failed - using the branches you already have locally (may be outdated)' }
    }
    if (-not (G @('rev-parse', '--verify', '-q', "origin/$sourceBranch"))) { Out-Line 'INFO' "no origin/$sourceBranch in this repo - skipped"; continue }
    if ($ticket) { Test-Ticket } else { Show-Overview }
}
Write-Host ''
if ($script:totalFail) { exit 1 } else { exit 0 }
