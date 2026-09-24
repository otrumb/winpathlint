$ErrorActionPreference = 'Stop'
$workflow = [IO.File]::ReadAllText("$PSScriptRoot/../.github/workflows/release.yml")
$lookup = [regex]::Match($workflow, '(?ms)^          (?:function Get-Release|\$releaseJson = gh api).*?(?=^          foreach \(\$asset in @\(\$assets)')
if (-not $lookup.Success) { throw 'Release lookup block not found' }
$code = [scriptblock]::Create(($lookup.Value -replace '(?m)^          ', ''))
$saved = @($env:GH_REPO, $env:RELEASE_TAG)
$env:GH_REPO = 'fixture/repository'
$env:RELEASE_TAG = 'v0.2.0'
try {
    foreach ($scenario in @('draft', 'absent', 'published', 'api-error', 'invalid-json', 'duplicate')) {
        & {
            $state = @{ Creates = 0; Calls = 0 }
            function gh {
                $global:LASTEXITCODE = 0
                if ($args[0] -eq 'release' -and $args[1] -eq 'create') {
                    $state.Creates++
                    if ($scenario -ne 'absent') { throw 'Attempted duplicate release creation' }
                    return
                }
                if ($args[0] -ne 'api') { throw "Unexpected command: $args" }
                $state.Calls++
                if ($scenario -eq 'api-error') {
                    $global:LASTEXITCODE = 1
                    return 'gh: Forbidden (HTTP 403)'
                }
                if ($scenario -eq 'invalid-json') { return 'invalid JSON' }
                if ($args[1] -like '*/releases/tags/*') {
                    if ($scenario -eq 'published') { return '{"id":42,"draft":false,"tag_name":"v0.2.0"}' }
                    $global:LASTEXITCODE = 1
                    return 'gh: Not Found (HTTP 404)'
                }
                if ($args[1] -ne 'repos/fixture/repository/releases?per_page=100' -or
                    $args -notcontains '--paginate' -or $args -notcontains '--slurp') {
                    throw "Unexpected listing request: $args"
                }
                if ($scenario -eq 'absent' -and $state.Creates -eq 0) { return '[[]]' }
                if ($scenario -eq 'published') { return '[[{"id":42,"draft":false,"tag_name":"v0.2.0"}]]' }
                if ($scenario -eq 'duplicate') { return '[[{"id":42,"draft":true,"tag_name":"v0.2.0"},{"id":43,"draft":true,"tag_name":"v0.2.0"}]]' }
                return '[[{"id":41,"draft":false,"tag_name":"v0.1.0"}],[{"id":42,"draft":true,"tag_name":"v0.2.0"}]]'
            }
            $failure = $null
            $releaseId = $null
            try { . $code } catch { $failure = $_.Exception.Message }
            switch ($scenario) {
                'draft' {
                    if ($failure -or $releaseId -ne '42' -or $state.Creates -ne 0) { throw "Draft reuse failed: $failure; id=$releaseId; creates=$($state.Creates)" }
                }
                'absent' {
                    if ($failure -or $releaseId -ne '42' -or $state.Creates -ne 1 -or $state.Calls -ne 2) { throw "Draft creation failed: $failure" }
                }
                'published' {
                    if ($failure -notlike '*already published*' -or $state.Creates -ne 0) { throw 'Published release protection failed' }
                }
                default {
                    if (-not $failure -or $state.Creates -ne 0 -or $releaseId) { throw "Failed to stop safely: $scenario" }
                }
            }
            Write-Output "PASS: $scenario"
        }
    }
} finally {
    $env:GH_REPO, $env:RELEASE_TAG = $saved
}
