param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$Version = 'v0.2.0'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repeat = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
try {
    & "$PSScriptRoot/package.ps1" -Version $Version -OutputDirectory $OutputDirectory
    $manifest = @(Get-Content -LiteralPath "$OutputDirectory/SHA256SUMS")
    if ($manifest.Count -ne 2) { throw 'Expected two checksums' }
    foreach ($arch in @('amd64', 'arm64')) {
        $name = "winpathlint_${Version}_windows_${arch}.zip"
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath "$OutputDirectory/$name").Hash.ToLowerInvariant()
        if ($manifest -cnotcontains "$hash  $name") { throw "Checksum mismatch: $name" }
        $zip = [IO.Compression.ZipFile]::OpenRead("$OutputDirectory/$name")
        try {
            if (($zip.Entries.FullName -join ',') -cne 'winpathlint.exe,LICENSE') { throw 'Unexpected archive contents' }
            $licenseReader = [IO.StreamReader]::new($zip.GetEntry('LICENSE').Open())
            try { $license = $licenseReader.ReadToEnd() } finally { $licenseReader.Dispose() }
            if ($license -cne [IO.File]::ReadAllText("$PSScriptRoot/../LICENSE")) { throw 'License differs' }
            $stream = $zip.GetEntry('winpathlint.exe').Open()
            $memory = [IO.MemoryStream]::new()
            try { $stream.CopyTo($memory); $bytes = $memory.ToArray() } finally { $stream.Dispose(); $memory.Dispose() }
            $header = [BitConverter]::ToInt32($bytes, 60)
            $machine = [BitConverter]::ToUInt16($bytes, $header + 4)
            $expected = if ($arch -eq 'amd64') { 0x8664 } else { 0xAA64 }
            if ($machine -ne $expected) { throw "Wrong architecture: $arch" }
        } finally { $zip.Dispose() }
    }
    & "$PSScriptRoot/package.ps1" -Version $Version -OutputDirectory $repeat
    if ([IO.File]::ReadAllText("$OutputDirectory/SHA256SUMS") -cne [IO.File]::ReadAllText("$repeat/SHA256SUMS")) {
        throw 'Repeated builds produced different archives'
    }
    $rejected = $false
    try { & "$PSScriptRoot/package.ps1" -Version '../bad' -OutputDirectory "$repeat/invalid" } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid version accepted' }
    $rejected = $false
    try { & "$PSScriptRoot/package.ps1" -Version $Version -OutputDirectory $OutputDirectory } catch { $rejected = $true }
    if (-not $rejected) { throw 'Existing output directory accepted' }
    Write-Output 'PASS: archives, licenses, PE architectures, checksums, repeatability, invalid inputs'
} finally {
    if (Test-Path -LiteralPath $repeat) { Remove-Item -LiteralPath $repeat -Recurse -Force }
}
