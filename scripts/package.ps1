param(
    [Parameter(Mandatory)][ValidatePattern('^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')][string]$Version,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'Output directory must not already exist' }
$parent = Split-Path -Parent $output
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Output parent must exist' }
$saved = @($env:GOOS, $env:GOARCH, $env:CGO_ENABLED)
$stage = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $output, $stage | Out-Null
Push-Location "$PSScriptRoot/.."
try {
    $env:GOOS = 'windows'
    $env:CGO_ENABLED = '0'
    $checksums = foreach ($arch in @('amd64', 'arm64')) {
        $env:GOARCH = $arch
        go build -trimpath -buildvcs=false -o "$stage/winpathlint.exe" .
        if ($LASTEXITCODE -ne 0) { throw "Build failed: $arch" }
        $name = "winpathlint_${Version}_windows_${arch}.zip"
        $zip = [IO.Compression.ZipFile]::Open("$output/$name", [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($file in @('winpathlint.exe', 'LICENSE')) {
                $source = if ($file -eq 'LICENSE') { "$PSScriptRoot/../LICENSE" } else { "$stage/$file" }
                $entry = $zip.CreateEntry($file)
                $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $entry.ExternalAttributes = 0
                $inputStream = [IO.File]::OpenRead($source)
                try {
                    $outputStream = $entry.Open()
                    try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
                } finally { $inputStream.Dispose() }
            }
        } finally { $zip.Dispose() }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath "$output/$name").Hash.ToLowerInvariant()
        "$hash  $name"
    }
    [IO.File]::WriteAllText("$output/SHA256SUMS", ($checksums -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
} finally {
    Pop-Location
    $env:GOOS, $env:GOARCH, $env:CGO_ENABLED = $saved
    Remove-Item -LiteralPath $stage -Recurse -Force
}
