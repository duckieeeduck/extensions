# ScreenOCR Changelog

## [Windows Improvements] - {PR_MERGE_DATE}

- Added barcode and QR-code detection on Windows. Codes in the selected region are decoded locally, including several codes at once and light-on-dark codes.
- Escape now cancels the Windows selection overlay without clicking it first, and no longer reaches the application underneath. The overlay no longer polls the keyboard.
- Windows reports organization policies that block the helper (Constrained Language mode, execution policy or a blocked PowerShell start) instead of a generic failure.
- Less startup work on Windows: the selection overlay no longer waits for the OCR engine to load, clipboard recognition skips unneeded native setup, and images reach the OCR engine without PNG re-encoding.
- Clipboard images copied from browsers and Office keep their transparency, and copied photo files are rotated according to their EXIF orientation.
- Windows requirements now state Windows 11, the tested version.
- Copied files on network paths are refused without being opened.
- Copied files are decoded only when their content is a PNG, JPEG, GIF, BMP or TIFF image.

## [Windows Support] - 2026-09-20

- Added Windows support for region, full-desktop and clipboard-image recognition using the local Windows OCR engine.
- Added installed Windows OCR-language selection with separate Windows and macOS preferences.
- Added optional paste/copy-and-paste result actions on Windows; macOS retains its existing copy behavior.
- Preserved existing command IDs and the cross-extension result shape; Windows callbacks distinguish cancellation and failure from recognized text.
- Preserved the existing macOS Swift source, recognition settings and command behavior.
- Kept barcode and QR-code recognition available on macOS with an explicit Windows limitation.

## [Fix macOS 26 (Tahoe) and macOS 27 (Golden Gate) Support] - 2026-07-23

- Fixed all commands failing with "Failed to recognize text" on macOS 26 (Tahoe) and macOS 27 (Golden Gate). The system text recognition models log diagnostics to stdout, which the extension uses to return its result, corrupting the output; recognition now runs with stdout muted.
- Fixed full-screen recognition returning no image: replaced the deprecated `CGWindowListCreateImage` with ScreenCaptureKit (`SCScreenshotManager`), capturing at native pixel resolution for better accuracy.
- Migrated text and barcode recognition to the modern Vision Swift API (`RecognizeTextRequest` / `DetectBarcodesRequest`).
- Raised the minimum macOS version to 15.0.

## [Improvements] - 2026-07-22

- Added more Apple Vision recognition languages to the primary and additional language selectors

## [Improvements] - 2026-01-19

- Added [cross-extension support](https://github.com/LitoMore/raycast-cross-extension-conventions) to enable OCR results to be used by other extensions
- Added documentation to include [cross-extension usage](docs/cross-extension-usage.md)
- Improved type safety for cross-extension callbacks by introducing `OCRResult` and `LaunchContext` types with `satisfies` validation
- Refactored code to use early returns for improved readability
- Modernized error handling using `@raycast/utils` while respecting user preferences
- Updated dependencies

## [Improvements] - 2026-01-17

- Fix caching issues

## [Improvements] - 2025-11-13

- Added option to hide toast messages
- Added option to mute shutter sound

## [Improvements] - 2025-07-13

- Added support for Arabic and Najdi languages
- Added support for detecting barcodes and QR codes

## [Improvements] - 2024-10-07

- Migrated codebase to use new Swift macros
- Replaced all HUDs with emojis with styled toast messages for user feedback
- Added list section to the `Select Recognition Languages` command
- Grouped checkbox preferences into a single section

## [Fixes & Improvements] - 2024-05-21

- Selecting an area for text recognition left the original image in the clipboard
- Users can choose whether to copy the original image to the clipboard or not

## [Improvements] - 2023-10-24

- Ignore line breaks feature
- Support for Thai and Vietnamese languages
- Custom words list
- Bug causing some languages not to work
- Formatting issues

## [Initial Version] - 2023-04-26
