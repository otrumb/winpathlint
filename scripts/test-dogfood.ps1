param([string]$Runner = "$PSScriptRoot/dogfood.ps1")
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
$sourceRoot = Join-Path $sandbox 'sources'
$scanner = Join-Path $sandbox 'scanner.ps1'
$counter = Join-Path $sandbox 'scanner-count.txt'
$savedGitMaster = $env:GIT_MASTER

function Invoke-Git([string]$Repository, [string[]]$Arguments) {
    $env:GIT_MASTER = '1'
    $output = & git -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $Arguments failed: $output" }
    ($output -join "`n").Trim()
}

function New-Repository([string]$Name, [string[]]$Paths) {
    $path = Join-Path $sourceRoot ($Name -replace '/', '\')
    New-Item -ItemType Directory -Path $path | Out-Null
    Invoke-Git $path @('init', '--quiet') | Out-Null
    Invoke-Git $path @('config', 'user.name', 'Dogfood Test') | Out-Null
    Invoke-Git $path @('config', 'user.email', 'dogfood@example.invalid') | Out-Null
    foreach ($item in $Paths) {
        $file = Join-Path $path ($item -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
        [IO.File]::WriteAllText($file, $item, $utf8)
    }
    Invoke-Git $path @('add', '--all') | Out-Null
    Invoke-Git $path @('commit', '--quiet', '-m', 'fixture') | Out-Null
    Invoke-Git $path @('rev-parse', 'HEAD')
}

function Write-Manifest([string]$Path, [object[]]$Repositories) {
    [ordered]@{ schema_version = 1; repositories = $Repositories } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-Target([string]$Name, [string]$Sha, [string[]]$Witness = @()) {
    [ordered]@{
        repository = $Name
        sha = $Sha
        source_url = "https://example.invalid/$Name.git"
        license = [ordered]@{ spdx = 'MIT'; url = "https://example.invalid/$Name/LICENSE" }
        dimensions = @('fixture')
        expected_paths = $Witness
    }
}

function Invoke-Runner([string]$Manifest, [string]$Output, [string]$Mode) {
    $env:FAKE_SCANNER_MODE = $Mode
    $env:FAKE_SCANNER_COUNTER = $counter
    $env:FAKE_SCANNER_SOURCE_ROOT = $sourceRoot
    $preference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Runner -Manifest $Manifest -RunRoot $Output `
            -MainBinary $scanner -ReleaseBinary $scanner -OfflineSourceRoot $sourceRoot *> (Join-Path $sandbox 'runner.log')
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $preference }
    $code
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message; got '$Actual', want '$Expected'" }
}

function Scanner-Count {
    if (-not (Test-Path -LiteralPath $counter)) { return 0 }
    [int](Get-Content -Raw -LiteralPath $counter)
}

try {
    New-Item -ItemType Directory -Path $sourceRoot | Out-Null
    $alphaSha = New-Repository 'fixture/alpha' @('tracked.txt', 'witness/alpha.txt')
    $zetaSha = New-Repository 'fixture/zeta' @('tracked.txt')
    @'
param([string]$repo, [string]$format, [int]$maxPath)
$ErrorActionPreference = 'Stop'
if ($env:GIT_MASTER -cne '1') { [Console]::Error.WriteLine('GIT_MASTER missing'); exit 2 }
$count = if (Test-Path -LiteralPath $env:FAKE_SCANNER_COUNTER) { [int](Get-Content -Raw $env:FAKE_SCANNER_COUNTER) } else { 0 }
[IO.File]::WriteAllText($env:FAKE_SCANNER_COUNTER, [string]($count + 1))
switch ($env:FAKE_SCANNER_MODE) {
    'clean' { [Console]::Out.WriteLine('[]'); exit 0 }
    'finding' { [Console]::Out.WriteLine('[{"path":"z","rule":"reserved_device_name","component":"z"},{"path":"a","rule":"case_collision","component":"a","related":"A"}]'); exit 1 }
    'malformed' { [Console]::Out.WriteLine('{'); exit 1 }
    'mutate' { $env:GIT_MASTER = '1'; & git -C $repo update-index --assume-unchanged tracked.txt; [Console]::Out.WriteLine('[]'); exit 0 }
    default { [Console]::Error.WriteLine('scanner failure'); exit 2 }
}
'@ | Set-Content -LiteralPath $scanner -Encoding UTF8

    $manifest = Join-Path $sandbox 'manifest.json'
    Write-Manifest $manifest @(
        (New-Target 'fixture/zeta' $zetaSha),
        (New-Target 'fixture/alpha' $alphaSha @('witness/alpha.txt'))
    )

    $findingRun = Join-Path $sandbox 'finding-run'
    Assert-Equal (Invoke-Runner $manifest $findingRun 'finding') 1 'Finding run exit'
    Assert-Equal (Scanner-Count) 12 'Two repos must receive two binaries times three repeats'
    $resultText = [IO.File]::ReadAllText((Join-Path $findingRun 'results.json'))
    $results = $resultText | ConvertFrom-Json
    Assert-Equal $results.repositories[0].repository 'fixture/alpha' 'Repositories must sort deterministically'
    Assert-Equal $results.repositories[0].findings[0].path 'a' 'Findings must sort deterministically'
    Assert-Equal @($results.scans).Count 12 'Every accepted scanner event must be retained'
    foreach ($group in @($results.scans | Group-Object repository, binary)) {
        Assert-Equal @($group.Group.stdout_sha256 | Select-Object -Unique).Count 1 'Three repeats must match'
    }
    if ($resultText.Contains($sandbox) -or $resultText.Contains($sourceRoot)) { throw 'Results leaked local paths' }
    $runConfig = [IO.File]::ReadAllText((Join-Path $findingRun 'repos/fixture--alpha/.git/config'))
    if ($runConfig -match '(?m)^\s*url\s*=' -or (Test-Path -LiteralPath (Join-Path $findingRun 'repos/fixture--alpha/.git/objects/info/alternates'))) {
        throw 'Offline run retained network or source object dependency'
    }
    Write-Output 'PASS: exit 1, repeats, Git env, sorting, sanitization, offline sources'

    [IO.File]::WriteAllText($counter, '0')
    $missingWitness = Join-Path $sandbox 'missing-witness.json'
    Write-Manifest $missingWitness @(
        (New-Target 'fixture/alpha' $alphaSha @('witness/alpha.txt')),
        (New-Target 'fixture/zeta' $zetaSha @('missing.txt'))
    )
    Assert-Equal (Invoke-Runner $missingWitness (Join-Path $sandbox 'missing-run') 'clean') 2 'Missing witness exit'
    Assert-Equal (Scanner-Count) 0 'Witness rejection must precede every scan'

    $wrongSha = Join-Path $sandbox 'wrong-sha.json'
    Write-Manifest $wrongSha @((New-Target 'fixture/alpha' ('0' * 40)))
    Assert-Equal (Invoke-Runner $wrongSha (Join-Path $sandbox 'wrong-sha-run') 'clean') 2 'SHA mismatch exit'
    Assert-Equal (Scanner-Count) 0 'SHA rejection must precede every scan'
    Write-Output 'PASS: exact SHA and path eligibility form global pre-scan barrier'

    Assert-Equal (Invoke-Runner $manifest $findingRun 'clean') 2 'Existing output exit'
    Assert-Equal (Scanner-Count) 0 'Existing output must stop before scans'
    [IO.File]::WriteAllText($counter, '0')
    Assert-Equal (Invoke-Runner $manifest (Join-Path $sandbox 'malformed-run') 'malformed') 2 'Malformed JSON exit'
    Assert-Equal (Scanner-Count) 1 'Malformed JSON must stop bounded run'
    [IO.File]::WriteAllText($counter, '0')
    Assert-Equal (Invoke-Runner $manifest (Join-Path $sandbox 'mutation-run') 'mutate') 2 'Index mutation exit'
    Assert-Equal (Scanner-Count) 1 'Index mutation must stop bounded run'
    Write-Output 'PASS: existing output, malformed JSON, and index mutation fail closed'

    [IO.File]::WriteAllText($counter, '0')
    Assert-Equal (Invoke-Runner $manifest (Join-Path $sandbox 'clean-run') 'clean') 0 'Clean run exit'
    Assert-Equal (Scanner-Count) 12 'Clean run scan count'
    [IO.File]::WriteAllText($counter, '0')
    Assert-Equal (Invoke-Runner $manifest (Join-Path $sandbox 'scanner-error-run') 'error') 2 'Scanner error exit'
    Write-Output 'PASS: runner exits 0, 1, and 2 by contract'
} finally {
    $env:GIT_MASTER = $savedGitMaster
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}
