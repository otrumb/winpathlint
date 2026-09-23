# winpathlint

Read-only Windows checkout compatibility audit for **every Git-index tracked
path**, not just staged changes. Small Go CLI, standard library only. No network
access, hooks, renames, working-tree writes, or external Go dependencies.

Intended initial release: **v0.1.0**. No public repository or release is required
to build locally. Requires Go 1.24+ to build and Git on PATH to run.

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

Before publishing v0.1.0, choose the public repository/module location, run these
checks in a clean checkout, and review license ownership. This local project
does not create a remote, tag, or release.

## License

MIT. Copyright (c) 2026 Ngoc Trung.
