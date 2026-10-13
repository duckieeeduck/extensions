# ScreenOCR work plan (resumable)

This file is the single source of truth for this work. Read it first when resuming.
It lives only on branch `claude/inspiring-allen-9zhzvv` at the repo root. Never commit it to an `ext/` or `ci/` branch.

Owner: GitHub `duckieeeduck`, Raycast `duck69`. Plain words, blunt, no filler. Label anything unverified [Unverified] / [Inference].
Never add anything that evades or bypasses security tooling or policy.

## How to resume
1. `cd /home/user/extensions && git fetch origin` and check out the branches in "Branches" below. If the container is new, rebuild them: see "Rebuild from scratch".
2. Find the first row in "Task board" whose status is not `done` and continue it.
3. After every finished task, update its row (status, commit, evidence) and the "Log", then commit this file on `claude/inspiring-allen-9zhzvv` and push.

## Roles (owner decision 2026-10-13)
- Opus: planner and final reviewer. Writes this plan, assigns tasks, does the last review before any upstream PR.
- Haiku workers (launched by Opus, `model: haiku`): one narrow task each. Write the reproducing test first, then the fix in a separate task.
- Sonnet checker (launched by Opus, `model: sonnet`): checks every Haiku result before Opus sees it: does the test fail for the stated reason before the fix, pass after, and are lint/tsc/prettier/tests green.
- A helper agent cannot launch its own helpers (verified 2026-10-13), so Opus does the launching.
- Bug rule (owner): for every finding, first a test that reproduces it, then a separate worker fixes it and proves it with the now-passing test.

## Owner decisions
- 2026-09-23 (from HANDOFF.md): Windows PR first, then macOS PR. Tesseract not planned. CAPTUREBLT, CRLF, concealed clipboard rejected.
- 2026-10-13: Dependency PR (@raycast/api 2.x) dropped. The esbuild advisory GHSA-g7r4-m6w7-qqqr affects only a developer's machine; `npm audit` on 2026-10-13 shows only that (2 low). Do not bump.
- 2026-10-13: Rust migration on hold indefinitely. Security hardening of the current TypeScript/PowerShell/Swift code instead.
- 2026-10-13: Windows AI Text Recognition skipped for now (see "Parked: Windows AI OCR").
- 2026-10-13: Audit scope: Windows helper, macOS Swift helper, TypeScript + npm deps, fork CI workflow, plus anything else valuable in ScreenOCR, as separate PRs where sensible.
- 2026-10-13: Allowed to push `ext/*` and `ci/*` branches to the fork and to open draft PRs to raycast/extensions.

## Branches
| Branch | Base | Purpose | Upstream? |
|---|---|---|---|
| `claude/inspiring-allen-9zhzvv` | fork main | this plan file only | no |
| `ext/screenocr-windows-improvements` | upstream main b6cd2e2cf | PR 1 (handoff) + Windows hardening commits | yes, draft PR |
| `ext/screenocr-macos-cancel-fix` | upstream main b6cd2e2cf | PR 3 (handoff) + macOS hardening commits | yes, draft PR |
| `ci/screenocr-windows-improvements` | ext branch + workflow commit | fork CI only | never |
| `ci/screenocr-macos-cancel-fix` | ext branch + workflow commit | fork CI only | never |

Local layout (container-specific): the main checkout `/home/user/extensions` is sparse (only `/SCREENOCR_WORKPLAN.md`, `/extensions/screenocr/`, `/.github/`) because a full checkout fills the disk. Work happens in sparse worktrees under the scratchpad: `wt-windows`, `wt-macos` (ext branches), `ci-windows`, `ci-macos` (ci branches). Logs: scratchpad `logs/`. In a new container: `git worktree add --no-checkout <dir> <branch>`, then `git sparse-checkout set --no-cone /extensions/screenocr/` and `git checkout`.

Rebuild from scratch: the handoff zip is at `/root/.claude/uploads/0bbc14b4-8b6f-5b98-827a-8afb5baac351/0842f38e-screenocr-handoff_1.zip` (only in the original container). Branches pushed to the fork are the durable copy once task P1.3 is done.
`git am` was used; it strips `[ScreenOCR]` from the subject. Task P1.1 restores it.

## Task board
Status: `todo` / `doing` / `done` / `dropped` / `blocked`.

### Phase 1: baseline
| ID | Task | Who | Status | Evidence |
|---|---|---|---|---|
| P1.0 | Re-create both ext branches from the handoff patches on upstream main | Opus | done | both applied cleanly incl. CHANGELOG; Windows branch 52ccea50a, macOS branch 2d1a9f547 |
| P1.1 | Restore `[ScreenOCR]` subject prefix on both commits (`git commit --amend`, keep author) | Opus | done | Windows 13f87d516, macOS 63ab0f8d9; author duckieeeduck kept |
| P1.2 | Baseline checks on both ext branches: `npm ci`, `npm test`, `npx tsc --noEmit`, `npx eslint src`, `npx prettier --check .` | Haiku, Sonnet checks | doing | Windows branch: 64/64 tests pass (2026-10-13) |
| P1.3 | Install PowerShell 7 (`pwsh`) in the container for parse checks of .ps1 files; if not possible, record it and rely on fork CI | Haiku | doing | |
| P1.4 | Build `ci/` branches (ext branch + workflow commit from handoff `screenocr-windows-native.yml`), push `ext/*` and `ci/*` to the fork, read the Actions results | Opus | doing | pushed 2026-10-13: ci windows cc3cfca00, ci macOS bc27a9005; Actions results pending |

### Phase 2: confirm candidate findings with reproducing tests
Each row: a Haiku worker writes a test that fails on the current code for the stated reason. Sonnet confirms. Findings whose test cannot be made to fail are marked `dropped` with the reason.
Windows-native tests go in `tests/windows-native.ps1` and run on fork CI (`windows-latest`, `windows-11-arm`). TypeScript tests go in `tests/ocr.test.cjs`.

| ID | Area | Candidate finding | Test idea | Status |
|---|---|---|---|---|
| W1 | ocr.ps1 clipboard files | A copied file list may contain a network (UNC) path such as `\\host\share\a.png`. Opening it makes Windows connect to that host and may send the user's Windows credentials (NTLM) to it; it can also hang until the 90 s timeout. [Inference: standard Windows SMB behavior] | Factor path check into a function; native test passes `\\127.0.0.1\x\a.png`, `\\?\UNC\...`, `\\.\...` and expects rejection without opening | todo |
| W2 | ocr.ps1 image decoding | `Image.FromStream` picks the decoder from the file content, not the extension, so a `.png` that is really an EMF/WMF metafile is parsed by the GDI+ metafile parser (larger attack surface). Same for the clipboard `PNG` stream. | Native test: write EMF bytes to `x.png`, put on clipboard file list; expect `clipboard-unsupported`, currently decoded | todo |
| W3 | ocr.ps1 decompression | Pixel-count limit is checked after the image is decoded. A small PNG with huge dimensions (for example 30000 x 30000) may allocate a lot of memory before the check. | Native test: generate such a PNG (few hundred KB); expect `clipboard-too-large` quickly with bounded memory; measure working set | todo |
| W4 | windows.ts | Helper is started with `-ExecutionPolicy Bypass`. Verified (Microsoft Learn): Group Policy execution policy (MachinePolicy/UserPolicy) overrides the command-line Process scope, so this does not defeat a policy an organization sets. It is a pattern many security tools log or alert on [Inference]. | No code change without owner decision. Options in "Owner questions". | blocked (owner) |
| W5 | ocr.ps1 | `Add-Type` compiles C# at run time (starts csc.exe, writes temp files); a pattern some security tools watch [Inference]. Removing it needs a shipped binary. | Document only. | dropped (document) |
| W6 | ocr.ps1 | No `Set-StrictMode`; typos in variable names fail silently. | Add `Set-StrictMode -Version 2.0`, run all native tests | todo |
| M1 | ScreenOCR.swift | `silencingStdout` ignores failures of `dup`/`open`. If `dup(1)` fails, stdout is never restored and the result is lost; if `open` fails, Vision logs reach stdout and corrupt the protocol. | Extract into a testable function; macOS CI test with a failing open (fd exhaustion via `setrlimit`) | todo |
| M2 | ScreenOCR.swift | Region capture writes a PNG of the screen into the per-user temp folder; it is removed by `defer`, but stays if the process is killed. | Check whether `screencapture` can write to a private 0700 subfolder; test asserts no file is left after cancel and after error | todo |
| T1 | npm deps | Lockfile: every `resolved` URL is registry.npmjs.org and has an `integrity` hash; no install scripts in new deps (@zxing/library, raycast-cross-extension). | Script check; fail on any deviation | todo |
| T2 | macos-commands.ts | Any installed extension can launch Recognize Text with `callbackLaunchOptions` and receive the recognized text. The user still has to make a visible selection. By design of raycast-cross-extension. | Confirm in code; document in README; no change unless owner wants | todo |
| T3 | windows.ts | Protocol parsing: confirm strict validation covers every payload (exact keys, sizes, base64, dimension cap). Fuzz the parser with malformed JSON. | Add fuzz-style mocked tests | todo |
| C1 | fork workflow | Actions referenced by tag (`@v4`), checkout keeps the token on disk, no job timeout. | Pin actions to full commit SHAs, `persist-credentials: false`, `timeout-minutes` | todo |

### Phase 3: fixes (one Haiku worker per confirmed finding; Sonnet checks; small commits)
| ID | Fix | Branch | Status | Commit |
|---|---|---|---|---|
| F-W1 | Accept only local absolute paths (drive letter); reject UNC, `\\?\`, `\\.\` paths before opening | windows | todo | |
| F-W2 | Check file signature (PNG, JPEG, GIF, BMP, TIFF) before decoding; check `RawFormat` after decoding; same for clipboard PNG stream | windows | todo | |
| F-W3 | Read width/height from the header before full decode, or decode with `validateImageData:$false` and check size first (whichever the W3 test proves bounded) | windows | todo | |
| F-W6 | `Set-StrictMode -Version 2.0` | windows | todo | |
| F-M1 | Check `dup`/`open` results; skip silencing if either fails | macOS | todo | |
| F-M2 | Per-run private temp folder, removed on every exit path | macOS | todo | |
| F-T3 | Any parser gaps found by T3 | windows | todo | |
| F-C1 | Workflow hardening | ci only | todo | |
Each fix also adds a CHANGELOG line under the existing unreleased entry.

### Phase 4: native verification
| ID | Task | Status |
|---|---|---|
| P4.1 | Rebuild `ci/` branches from updated ext branches, push, read Actions results (Windows x64, Windows ARM, macOS). Report the Escape test as skipped if the runner has no interactive desktop | todo |
| P4.2 | Fix any failure via the same test-first loop | todo |

### Phase 5: final review and PRs
| ID | Task | Status |
|---|---|---|
| P5.1 | Opus final review of each ext branch diff (correctness and security) | todo |
| P5.2 | Push ext branches; open draft PR to raycast/extensions for Windows (PR-1-windows.md + CI links + hardening section) | todo |
| P5.3 | Open draft PR for macOS (PR-3-macos.md + CI links; note CHANGELOG conflict with the Windows PR) | todo |
| P5.4 | Subscribe to both PRs; drive to green | todo |

### Phase 6: owner on-device checks (from handoff, plus hardening)
Windows: Escape before clicking must not reach the app underneath; QR code on screen; transparent image copied from a browser; rotated phone photo; time to overlay with SCREENOCR_DEBUG=1 (`npm run dev -- --target release`); copy a file from a network share and confirm the new message. Mac: cancel region OCR, full-screen OCR and barcode, with and without "Keep image in clipboard".

## Owner questions (open)
- W4 `-ExecutionPolicy Bypass`: (a) keep as is and document in README that organization policy still applies; (b) switch to `RemoteSigned` (works only if Raycast's downloaded assets carry no internet-zone mark, [Unverified]; still a command-line policy flag); (c) remove the flag (the helper then fails on the Windows client default `Restricted`, which breaks most users). Recommendation: (a). Ask before Phase 5.

## Parked: Windows AI OCR (skipped 2026-10-13)
Verified on Microsoft Learn 2026-10-13: Text Recognition runs only on a Copilot+ PC NPU, needs Windows 11 25H2 (build 26200.7309) or later, and the calling app needs package identity (MSIX or a signed sparse package) with the `systemAIModels` capability; otherwise `UnauthorizedAccessException`. Readiness check is `TextRecognizer.GetReadyState()`. Raycast extensions have no install-time hook [Inference]; a check would run on first use. Feasibility test design is in the 2026-10-13 conversation: run unpackaged (expect failure), run with a self-signed sparse package (expect Ready), try registration on a managed laptop.

## Parked: Rust
On hold indefinitely. Neither a script nor an unsigned program is "safe" by default; code signing and the organization's policy decide.

## Log
- 2026-10-13: Session start. Answered owner questions. Recreated ext branches from patches on upstream main b6cd2e2cf. Baseline on Windows branch: 64/64 mocked tests pass; npm audit: only esbuild GHSA-g7r4-m6w7-qqqr (2 low). Container has no pwsh/dotnet/swift. Wrote this plan.
