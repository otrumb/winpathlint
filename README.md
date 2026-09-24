# winpathlint

Read-only Windows checkout compatibility audit for **every Git-index tracked
path**, not just staged changes. Small Go CLI, standard library only. No network
access, hooks, renames, working-tree writes, or external Go dependencies.

Requires Git on PATH to run. Source builds require Go 1.24+.

## Install v0.2.0 (PowerShell)

The commands below target **v0.2.0**, available after its tag and release are
published. Preparing this repository locally does not publish either.

### Download a Windows binary

Open [the v0.2.0 release](https://github.com/otrumb/winpathlint/releases/tag/v0.2.0)
and download `SHA256SUMS` plus one ZIP into the same directory:

- `winpathlint_v0.2.0_windows_amd64.zip` for x64 Windows.
- `winpathlint_v0.2.0_windows_arm64.zip` for ARM64 Windows.

Verify before extracting; change `$archive` for ARM64:

```powershell
$archive = 'winpathlint_v0.2.0_windows_amd64.zip'
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
if (@(Get-Content -LiteralPath SHA256SUMS) -cnotcontains "$hash  $archive") {
    throw 'Checksum mismatch: do not extract or run this download'
}
Expand-Archive -LiteralPath $archive -DestinationPath .\winpathlint-v0.2.0
.\winpathlint-v0.2.0\winpathlint.exe --help
.\winpathlint-v0.2.0\winpathlint.exe --repo 'C:\src\my-project' --format json
```

Each ZIP contains `winpathlint.exe` and `LICENSE` at its root. Optionally add
the extracted directory to your user PATH. Checksums detect damaged or changed
downloads; they are not signatures or independent proof of publisher identity.

### Install with Go

```powershell
$env:CGO_ENABLED = '0'
go install github.com/otrumb/winpathlint@v0.2.0
```

Go installs into `GOBIN`, or `bin` under `GOPATH` when `GOBIN` is unset (normally
`$HOME\go\bin`). Add that directory to PATH, then run `winpathlint --help`.

## Build and run (PowerShell)

```powershell
$env:CGO_ENABLED = '0'
go build -trimpath -o winpathlint.exe .
.\winpathlint.exe --help
.\winpathlint.exe --repo 'C:\src\my-project'
$LASTEXITCODE
.\winpathlint.exe --repo 'C:\src\my-project' --format json --max-path 200
```

`--repo` defaults to `.`. A subdirectory still audits the whole index. Paths in
reports are relative to the repository root, always with `/` separators.
Bare repositories and Git metadata directories are rejected. Linked worktrees
use their own index. An empty index is clean; no commit is required.

| Exit | Meaning |
| --- | --- |
| 0 | Clean, or help requested |
| 1 | One or more findings |
| 2 | Invalid arguments, not a worktree, Git failure, invalid index encoding, or output failure |

Help and errors go to stderr. Findings go to stdout. Use the built binary for
exit-code checks: `go run` wraps nonzero program exits.

## Rules

| Rule | Detection |
| --- | --- |
| `case_collision` | Different spellings of the same uppercased path prefix, including directory components |
| `reserved_device_name` | CON, PRN, AUX, NUL, COM1-9, LPT1-9, including superscript 1/2/3 device digits, case-insensitive, in every component and before the first extension |
| `illegal_character` | Any of `< > : " \ | ? *` within a component; `/` is a separator |
| `trailing_dot_or_space` | A component ending in ASCII dot or space |
| `control_character` | U+0001 through U+001F in a component; NUL cannot occur in Git paths |
| `path_too_long` | Repository-relative path exceeds `--max-path` UTF-16 code units, including separators |

`--max-path` defaults to **240**, must be positive, and is a portable policy
budget, **not** the absolute Win32 MAX_PATH limit. Equality is allowed. Account
for your checkout root length when choosing a budget. Supplementary Unicode
characters count as two UTF-16 units. Reserved-name checks trim spaces before
the first dot, so `CON .txt` is also reported.

## Stable output

Both formats sort by `path`, `rule`, `component`, then `related`, using Go string
byte order. Duplicate index entries (such as merge stages) and identical
findings collapse. Each collision points to the first byte-sorted tracked path
with that uppercased prefix; reports do not enumerate every pair.

Text has four tab-separated columns: rule, quoted path, quoted component,
quoted related path. Strings use Go quoting, escaping controls and newlines.
Empty optional columns appear as `""`. Clean text output is empty.

JSON is an array, never `null`; clean output is `[]`. Optional fields are omitted.

```json
[{"path":"NUL.txt","rule":"reserved_device_name","component":"NUL.txt"},{"path":"foo","rule":"case_collision","component":"foo","related":"Foo"}]
```

## Scope and limitations

- Reads `git -C <repo> ls-files --full-name -z -- :/`. NUL separation preserves
  whitespace, tabs and newlines. The root pathspec includes paths outside the
  supplied subdirectory. Git has a one-minute operation budget.
- Index only: includes tracked paths missing from disk and unresolved index
  stages; excludes untracked files and history. Does not inspect file contents.
- Submodule entries are audited as paths; submodule indexes are not traversed.
- UTF-8 paths are required. Invalid UTF-8 is an error, not silently replaced in
  JSON. Git environment variables, including alternate-index settings, apply.
- Case matching uses Go Unicode uppercase, not exact NTFS upcase tables or
  per-directory case-sensitivity settings. No Unicode normalization or 8.3 alias
  simulation. Some filesystem-specific collisions may be missed or overreported.
- Not a checkout guarantee: no component-length limit, symlink policy, ACL,
  filesystem capacity, Git-specific protected-name, or absolute-path audit.
- No remediation, rename mode, revision selection, hook installation, remote
  access, or repository mutation. Git must already be installed.

## Development

```powershell
gofmt -l .
go test -shuffle=on -count=1 -cover ./...
go vet ./...
$env:CGO_ENABLED = '0'
go build -trimpath -o winpathlint.exe .
.\winpathlint.exe --repo . --format json
```

Tests create isolated temporary Git repositories. Plumbing inserts collisions
and Windows-invalid names directly into the index, without trying to create
those paths on Windows. Tests cover index immutability, subdirectory scans,
invalid arguments, writer failures, corrupt indexes, and built-binary exits.
Race instrumentation is deliberately excluded: it requires cgo on Windows and
this project has a no-cgo contract. CI runs Windows checks with pinned actions.

### Local release packaging

From the repository root, use a new output directory whose parent exists:

```powershell
$output = Join-Path $env:TEMP ('winpathlint-' + [guid]::NewGuid())
.\scripts\test-package.ps1 -Version v0.2.0 -OutputDirectory $output
```

This builds Windows amd64 and arm64 with `CGO_ENABLED=0`, verifies ZIP members,
license bytes, PE architectures and SHA256 checksums, then repeats both builds
to check identical archive hashes. Output contains both ZIPs and `SHA256SUMS`.
`scripts/package.ps1` is the shared local/workflow packager. It rejects invalid
versions and existing output directories rather than overwriting artifacts.
ZIP timestamps are fixed; builds omit local paths and VCS metadata. Repeatability
is checked within the same Go/.NET toolchain, not promised across toolchain versions.

The release workflow runs only on pushed `v*.*.*` tags, validates strict `vX.Y.Z`
versions, checks out the event's exact SHA, runs quality gates and packaging checks,
then publishes the three verified assets. Build has read-only permissions; only
the separate publish job can write releases. If no release exists, publish creates
a draft. If a draft exists, reruns reuse it and replace the exact three assets
before verifying them and publishing. A published release blocks reruns; the
workflow never overwrites or deletes releases. Local checks never create a
remote, tag, or release.

## License

MIT. Copyright (c) 2026 Ngoc Trung.
