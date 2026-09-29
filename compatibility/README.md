# Compatibility corpus

This SHA-pinned corpus records a native-Windows run of `winpathlint` against
exactly 10 public Git indexes. `repositories.json` freezes source and license
metadata. `results.json` contains aggregate census measurements and adjudicated
findings; it contains no checkout locations or general upstream path inventory.

Both the verified v0.2.0 amd64 release asset and a build from main at
`1acb7e99dca24b18f9b26f6a65340c30d9f8b427` scanned each eligible repository
three times with `--max-path 240`. Eligibility, exact SHA, and declared witness
paths were validated for every candidate before any scanner ran.

## Result

- 10 eligible and scanned repositories.
- 60 scan events: 10 repositories x 2 binaries x 3 repetitions.
- Identical output across each triple and between release and main.
- Unchanged Git index and NUL-delimited path stream around every scan.
- One true-positive case collision in frozen `NousResearch/hermes-agent`.
- Zero false positives, misses, unresolved findings, or rejected-candidate scans.
- No tracked path exceeded the 240 UTF-16-unit policy budget.

The independent census applied the documented collision, reserved-name,
illegal-character, trailing-dot-or-space, control-character, and path-length
predicates directly to each NUL-delimited index path stream. Its candidates
matched scanner output. This bounded corpus is compatibility evidence, not a
claim about all repositories, filesystems, or future revisions.

## Reproduce

Use new output directories; the runner refuses to overwrite an existing run:

```powershell
.\scripts\dogfood.ps1 `
  -Manifest .\compatibility\repositories.json `
  -RunRoot $newRunRoot `
  -MainBinary $mainBinary `
  -ReleaseBinary $verifiedReleaseBinary
```

`-OfflineSourceRoot` may point to a local tree laid out as `owner\repository`.
Offline mode copies its existing Git object databases and never retains remotes
or object alternates. Missing local objects fail closed; no network fallback is
used. Raw run evidence stays outside this repository.
