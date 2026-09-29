param(
    [Parameter(Mandatory)][string]$Manifest,
    [Parameter(Mandatory)][string]$RunRoot,
    [Parameter(Mandatory)][string]$MainBinary,
    [Parameter(Mandatory)][string]$ReleaseBinary,
    [string]$OfflineSourceRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$savedEnvironment = @($env:GIT_MASTER, $env:GIT_TERMINAL_PROMPT, $env:GCM_INTERACTIVE)

function Quote-Argument([string]$Value) {
    '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-Native([string]$File, [string[]]$Arguments, [int]$TimeoutSeconds = 300) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $File
    $info.Arguments = (($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) { throw "Could not start $File" }
    $stdout = [IO.MemoryStream]::new()
    $stderr = [IO.MemoryStream]::new()
    $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
    $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill()
        throw "Command timed out after $TimeoutSeconds seconds: $File"
    }
    $null = $stdoutTask.GetAwaiter().GetResult()
    $null = $stderrTask.GetAwaiter().GetResult()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout.ToArray()
        Stderr = $stderr.ToArray()
    }
}

function Invoke-Git([string]$Repository, [string[]]$Arguments) {
    $result = Invoke-Native 'git' (@('-C', $Repository) + $Arguments)
    if ($result.ExitCode -ne 0) {
        throw "git $Arguments failed: $($utf8.GetString($result.Stderr))"
    }
    return $result
}

function Get-Hash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

function Get-IndexHash([string]$Repository) {
    $path = $utf8.GetString((Invoke-Git $Repository @('rev-parse', '--git-path', 'index')).Stdout).Trim()
    if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $Repository $path }
    Get-Hash ([IO.File]::ReadAllBytes($path))
}

function Get-Paths([string]$Repository) {
    $bytes = (Invoke-Git $Repository @('ls-files', '--full-name', '-z', '--', ':/')).Stdout
    $paths = [Collections.Generic.List[string]]::new()
    $start = 0
    for ($position = 0; $position -lt $bytes.Length; $position++) {
        if ($bytes[$position] -eq 0) {
            $paths.Add($utf8.GetString($bytes, $start, $position - $start))
            $start = $position + 1
        }
    }
    if ($start -ne $bytes.Length) { throw 'Git path stream is not NUL terminated' }
    [pscustomobject]@{ Bytes = $bytes; Paths = @($paths) }
}

function Get-Census([string]$Repository) {
    $stream = Get-Paths $Repository
    $caseMap = @{}
    $reserved = [Collections.Generic.List[string]]::new()
    $illegal = [Collections.Generic.List[string]]::new()
    $trailing = [Collections.Generic.List[string]]::new()
    $control = [Collections.Generic.List[string]]::new()
    $maxDepth = 0
    $maxUtf16 = 0
    $nonAscii = 0
    foreach ($path in $stream.Paths) {
        $components = $path.Split('/')
        $maxDepth = [Math]::Max($maxDepth, $components.Count)
        $maxUtf16 = [Math]::Max($maxUtf16, $path.Length)
        if ($path -match '[^\x00-\x7F]') { $nonAscii++ }
        $prefix = ''
        foreach ($component in $components) {
            $prefix += $component
            $key = $prefix.ToUpperInvariant()
            if (-not $caseMap.ContainsKey($key)) { $caseMap[$key] = [Collections.Generic.List[string]]::new() }
            if (-not $caseMap[$key].Contains($prefix)) { $caseMap[$key].Add($prefix) }
            $prefix += '/'
            $dot = $component.IndexOf('.')
            $base = $(if ($dot -ge 0) { $component.Substring(0, $dot) } else { $component }).TrimEnd(' ').ToUpperInvariant()
            if ($base -match '^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])$') { $reserved.Add($path) }
            if ($component.IndexOfAny([char[]]'<>:"\|?*') -ge 0) { $illegal.Add($path) }
            if ($component.EndsWith('.') -or $component.EndsWith(' ')) { $trailing.Add($path) }
            if (@($component.ToCharArray() | Where-Object { [int]$_ -ge 1 -and [int]$_ -le 31 }).Count) { $control.Add($path) }
        }
    }
    $caseGroups = @($caseMap.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 } | Sort-Object Key | ForEach-Object {
        [ordered]@{ key = $_.Key; paths = @($_.Value | Sort-Object) }
    })
    [ordered]@{
        tracked_count = $stream.Paths.Count
        path_stream_sha256 = Get-Hash $stream.Bytes
        max_depth = $maxDepth
        max_utf16 = $maxUtf16
        over_240 = @($stream.Paths | Where-Object { $_.Length -gt 240 }).Count
        non_ascii = $nonAscii
        casefold_groups = $caseGroups
        reserved_paths = @($reserved | Sort-Object -Unique)
        illegal_paths = @($illegal | Sort-Object -Unique)
        trailing_paths = @($trailing | Sort-Object -Unique)
        control_paths = @($control | Sort-Object -Unique)
    }
}

function Convert-Findings([byte[]]$Bytes) {
    try { $parsed = $utf8.GetString($Bytes) | ConvertFrom-Json -ErrorAction Stop } catch { throw "Scanner returned malformed JSON: $($_.Exception.Message)" }
    if ($null -eq $parsed) { return @() }
    @($parsed | ForEach-Object {
        if (-not $_.path -or -not $_.rule) { throw 'Scanner finding lacks path or rule' }
        [ordered]@{
            path = [string]$_.path
            rule = [string]$_.rule
            component = if ($_.PSObject.Properties.Name -contains 'component') { [string]$_.component } else { '' }
            related = if ($_.PSObject.Properties.Name -contains 'related') { [string]$_.related } else { '' }
        }
    } | Sort-Object path, rule, component, related)
}

try {
    $env:GIT_MASTER = '1'
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GCM_INTERACTIVE = 'Never'
    $root = [IO.Path]::GetFullPath($RunRoot)
    if (Test-Path -LiteralPath $root) { throw 'Run root must not already exist' }
    $parent = Split-Path -Parent $root
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Run root parent must exist' }
    try { $document = Get-Content -Raw -LiteralPath $Manifest | ConvertFrom-Json -ErrorAction Stop } catch { throw "Invalid manifest JSON: $($_.Exception.Message)" }
    $targets = @($document.repositories)
    if ($document.schema_version -ne 1 -or $targets.Count -eq 0) { throw 'Manifest requires schema_version 1 and repositories' }
    New-Item -ItemType Directory -Path $root, "$root/repos", "$root/raw" | Out-Null
    $eligible = [Collections.Generic.List[object]]::new()
    foreach ($target in @($targets | Sort-Object repository)) {
        if ($target.repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $target.sha -notmatch '^[0-9a-f]{40}$') { throw 'Invalid repository or SHA in manifest' }
        $name = $target.repository -replace '/', '--'
        $repository = Join-Path $root "repos/$name"
        $source = if ($OfflineSourceRoot) { Join-Path ([IO.Path]::GetFullPath($OfflineSourceRoot)) ($target.repository -replace '/', '\') } else { [string]$target.source_url }
        if ($OfflineSourceRoot -and -not (Test-Path -LiteralPath $source -PathType Container)) { throw "Offline source missing: $($target.repository)" }
        $clone = Invoke-Native 'git' @('clone', '--quiet', '--no-checkout', '--no-tags', $source, $repository)
        if ($clone.ExitCode -ne 0) { throw "Clone failed: $($target.repository): $($utf8.GetString($clone.Stderr))" }
        Invoke-Git $repository @('update-ref', 'HEAD', $target.sha) | Out-Null
        Invoke-Git $repository @('read-tree', $target.sha) | Out-Null
        $head = $utf8.GetString((Invoke-Git $repository @('rev-parse', 'HEAD')).Stdout).Trim()
        if ($head -cne $target.sha) { throw "Exact SHA mismatch: $($target.repository)" }
        $census = Get-Census $repository
        $pathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        (Get-Paths $repository).Paths | ForEach-Object { [void]$pathSet.Add($_) }
        foreach ($witness in @($target.expected_paths)) {
            if (-not $pathSet.Contains([string]$witness)) { throw "Expected path missing: $($target.repository): $witness" }
        }
        $eligible.Add([pscustomobject]@{ Target = $target; Repository = $repository; Name = $name; Census = $census })
    }
    $scans = [Collections.Generic.List[object]]::new()
    $findingsByRepo = @{}
    $anyFindings = $false
    foreach ($item in $eligible) {
        $repoFindings = $null
        $referenceHash = $null
        foreach ($binary in @([ordered]@{ name = 'main'; path = $MainBinary }, [ordered]@{ name = 'release'; path = $ReleaseBinary })) {
            $binaryHashes = [Collections.Generic.List[string]]::new()
            foreach ($iteration in 1..3) {
                $preIndex = Get-IndexHash $item.Repository
                $prePaths = Get-Paths $item.Repository
                $arguments = @('--repo', $item.Repository, '--format', 'json', '--max-path', '240')
                $command = [string]$binary.path
                if ($command.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) {
                    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $command) + $arguments
                    $command = 'powershell.exe'
                }
                $result = Invoke-Native $command $arguments 120
                [IO.File]::WriteAllBytes("$root/raw/$($item.Name).$($binary.name).$iteration.stdout", $result.Stdout)
                [IO.File]::WriteAllBytes("$root/raw/$($item.Name).$($binary.name).$iteration.stderr", $result.Stderr)
                $postIndex = Get-IndexHash $item.Repository
                $postPaths = Get-Paths $item.Repository
                if ($preIndex -cne $postIndex -or (Get-Hash $prePaths.Bytes) -cne (Get-Hash $postPaths.Bytes)) { throw "Repository mutation detected: $($item.Target.repository)" }
                if ($result.ExitCode -notin @(0, 1)) { throw "Scanner exit $($result.ExitCode): $($item.Target.repository)" }
                $findings = @(Convert-Findings $result.Stdout)
                if (($result.ExitCode -eq 0) -ne ($findings.Count -eq 0)) { throw "Scanner exit disagrees with findings: $($item.Target.repository)" }
                $stdoutHash = Get-Hash $result.Stdout
                $binaryHashes.Add($stdoutHash)
                if ($null -eq $referenceHash) { $referenceHash = $stdoutHash; $repoFindings = $findings }
                elseif ($referenceHash -cne $stdoutHash) { throw "Non-deterministic or binary-mismatched output: $($item.Target.repository)" }
                $scans.Add([ordered]@{ repository = $item.Target.repository; binary = $binary.name; iteration = $iteration; exit = $result.ExitCode; stdout_sha256 = $stdoutHash; stderr_sha256 = Get-Hash $result.Stderr; index_unchanged = $true; paths_unchanged = $true })
            }
            if (@($binaryHashes | Select-Object -Unique).Count -ne 1) { throw "Repeat mismatch: $($item.Target.repository)" }
        }
        $findingsByRepo[$item.Target.repository] = @($repoFindings)
        if (@($repoFindings).Count) { $anyFindings = $true }
    }
    $repositories = @($eligible | ForEach-Object {
        [ordered]@{ repository = $_.Target.repository; sha = $_.Target.sha; census = $_.Census; findings = @($findingsByRepo[$_.Target.repository]) }
    })
    $output = [ordered]@{ schema_version = 1; repositories = $repositories; scans = @($scans) } | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText("$root/results.json", $output + "`n", [Text.UTF8Encoding]::new($false))
    if ($anyFindings) { exit 1 }
    exit 0
} catch {
    [Console]::Error.WriteLine("dogfood: $($_.Exception.Message)")
    exit 2
} finally {
    $env:GIT_MASTER, $env:GIT_TERMINAL_PROMPT, $env:GCM_INTERACTIVE = $savedEnvironment
}
