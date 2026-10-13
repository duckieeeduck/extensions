## Description

Windows follow-up to #30884. macOS code is unchanged.

**Escape cancellation without polling.** The selection overlay used to check Escape by reading the keyboard state every 30 ms, because Windows does not always give a newly shown overlay keyboard focus. It now registers Escape as a hot key (`RegisterHotKey`) only while the overlay is open and releases it when the overlay closes. Escape works without clicking first, and the key press no longer reaches the application underneath the overlay.

**Barcode and QR-code detection on Windows.** Detect Barcode/QR Code previously reported "available only on macOS". The helper now returns the selected region as luminance bytes, and the extension decodes it with `@zxing/library` (0.21.3; 0.22+ declares Node 24 and logs a warning for every reader miss). It finds several codes in one selection and light-on-dark codes. Results are copied, as on macOS.

**Clear errors when organization policy blocks the helper.** Constrained Language mode (App Control or AppLocker), an execution policy that blocks the script, and a blocked PowerShell start each get a specific message instead of "Windows text recognition failed". The helper reports these policies; it does not try to work around them.

**Less startup work.** The Windows Runtime OCR types load after capture instead of before the overlay. Clipboard recognition skips the native setup it does not use, and images go to the OCR decoder as BMP instead of PNG. The shared resize code is also consolidated. Development builds print helper timings, DPI mode and hot-key status (`SCREENOCR_DEBUG`).

**Clipboard quality.** The PNG clipboard format that browsers and Office publish is used first, so transparent images stay readable. Copied photo files are rotated according to their EXIF orientation.

**Hardening of copied-file handling.** Recognize Text in Clipboard Image now refuses a copied file on a network path (`\\server\share\...`, `\\?\`, `\\.\`) without opening it, because opening it contacts that server and can send the user's Windows credentials to it. Copied files are decoded only when their content starts with a PNG, JPEG, GIF, BMP or TIFF signature, and the decoded format is checked again; previously GDI+ chose the decoder from the content, so a metafile named `.png` reached the metafile parser. The clipboard PNG format gets the same signature check. The barcode image payload from the helper must be canonical, padded base64. Each change was first reproduced by a failing test on Windows CI.

**Docs.** The Windows requirement is now Windows 11, the version it was tested on. README troubleshooting, CHANGELOG and TESTING updated.

## Verification

- `npm test`: 103 mocked tests pass, including 39 that feed malformed helper output (bad JSON, extra keys, wrong types, oversized dimensions, non-canonical base64, a full 2048 x 2048 payload) and expect a clean error.
- ESLint and Prettier pass. `tsc --noEmit` needs the `raycast-env.d.ts` that `ray build` generates.
- Native tests on GitHub Actions (`windows-latest` x64 and `windows-11-arm`, real Windows PowerShell 5.1 and Windows OCR): CI_RESULT_LINE
- Reproductions before the fixes (run RUN_REPRO): a network-path file and a metafile named `.png` were both opened and their text recognized; a 30000 x 30000 PNG was already refused with bounded memory (103 MB peak, 0.5 s), now kept as a regression test.
- `ray build -e dist` on `macos-latest` compiles the unchanged Swift code.
- Desktop checks pending: see `docs/TESTING.md` -> "Windows improvements - verification".

## Screencast

Not applicable (no new command).

## Checklist

- [x] I read the [extension guidelines](https://developers.raycast.com/basics/prepare-an-extension-for-store)
- [x] I read the [documentation about publishing](https://developers.raycast.com/basics/publish-an-extension)
- [ ] I ran `npm run build` and [tested this distribution build in Raycast](https://developers.raycast.com/basics/prepare-an-extension-for-store#metadata-and-configuration) (pending a Windows run)
- [x] I checked that files in the `assets` folder are used by the extension itself
- [x] I checked that assets used by the `README` are placed outside of the `metadata` folder
