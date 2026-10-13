## Description

Fixes two macOS issues that predate Windows support. Windows code is unchanged.

1. **Cancelling a selection copied error text.** When a screen selection was cancelled with Escape, Swift returned the string `"Error: failed to capture image"`. TypeScript treated it as recognized text: it was copied to the clipboard with a success toast and returned to cross-extension callbacks as `text`.
2. **Cancelling with "Keep image in clipboard" could recognize an older image.** With `screencapture -c`, a cancelled selection leaves the clipboard unchanged, and the extension read whatever image was already there.

Swift now returns a structured `CaptureOutcome` (`recognized`, `cancelled` or `error`) instead of encoding failures as text. A cancelled selection is detected from the missing capture file or, with "Keep image in clipboard", from an unchanged `NSPasteboard.changeCount`. Cancellation is silent and leaves the clipboard unchanged. Failures show an error toast, and callbacks receive them in `error` (documented in `docs/API.md`). Successful recognition behaves as before.

## Verification

- `npm test`: 61 mocked tests pass, including cancellation, failure and legacy-string results for all three macOS commands and both callback cases.
- ESLint passes. `tsc --noEmit` needs the generated `raycast-env.d.ts`. Prettier flags only `docs/TESTING.md`, which is unformatted on main and is fixed in the Windows PR.
- `ray build -e dist` on GitHub Actions `macos-latest` compiles the Swift change: https://github.com/duckieeeduck/extensions/actions/runs/38354201809
- On-device check pending: cancel region OCR, full-screen OCR and barcode detection, with and without "Keep image in clipboard".
- This PR and the Windows PR both add an entry at the top of CHANGELOG.md; whichever merges second needs a one-line rebase.

## Screencast

Not applicable (no new command).

## Checklist

- [x] I read the [extension guidelines](https://developers.raycast.com/basics/prepare-an-extension-for-store)
- [x] I read the [documentation about publishing](https://developers.raycast.com/basics/publish-an-extension)
- [ ] I ran `npm run build` and [tested this distribution build in Raycast](https://developers.raycast.com/basics/prepare-an-extension-for-store#metadata-and-configuration)
- [x] I checked that files in the `assets` folder are used by the extension itself
- [x] I checked that assets used by the `README` are placed outside of the `metadata` folder
