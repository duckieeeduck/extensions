import { environment, getPreferenceValues, LocalStorage } from "@raycast/api";
import { execFile } from "node:child_process";
import path from "node:path";
import type { CaptureMode, RecognitionOutcome } from "./types";

export const WINDOWS_LANGUAGE_STORAGE_KEY = "WindowsRecognitionLanguage";

export type WindowsRecognizerLanguage = {
  tag: string;
  displayName: string;
};

type RecognitionPayload =
  | { status: "recognized"; text: string }
  | { status: "no-text" };

type ImagePayload = {
  status: "image";
  width: number;
  height: number;
  luminance: string;
};

type LanguagesPayload = {
  status: "languages";
  languages: WindowsRecognizerLanguage[];
};

type ErrorPayload = {
  status: "error";
  code:
    | "clipboard-empty"
    | "clipboard-unsupported"
    | "clipboard-corrupt"
    | "clipboard-busy"
    | "clipboard-too-large"
    | "clipboard-unreadable";
};

// Exit codes of assets/ocr.ps1; keep both lists in sync.
export const HELPER_EXIT = {
  cancelled: 2,
  languageUnavailable: 3,
  clipboardInput: 4,
  failed: 5,
  captureBusy: 6,
  restrictedLanguage: 7,
} as const;

const MAX_OUTPUT_BYTES = 1024 * 1024 * 8;
const PROCESS_TIMEOUT_MS = 90_000;
const SELECTION_TIMEOUT_MS = 300_000;
const MAX_BARCODE_DIMENSION = 2048;
const LANGUAGE_TAG = /^(auto|[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,3})$/;
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;

const RESTRICTED_LANGUAGE_MESSAGE =
  "Your organization runs PowerShell in Constrained Language mode, which blocks the ScreenOCR helper. ScreenOCR cannot run on this device unless your administrator allows it.";
const EXECUTION_POLICY_MESSAGE =
  "Your organization's PowerShell execution policy blocks the ScreenOCR helper script.";
const SPAWN_BLOCKED_MESSAGE =
  "Windows prevented PowerShell from starting. Your organization may block it.";

class ProtocolError extends Error {}

function powershellPath(): string {
  const windowsRoot = [process.env.SystemRoot, process.env.WINDIR].find(
    (value): value is string =>
      typeof value === "string" && /^[A-Za-z]:[\\/]/.test(value),
  );
  return path.win32.resolve(
    windowsRoot || "C:\\Windows",
    "System32",
    "WindowsPowerShell",
    "v1.0",
    "powershell.exe",
  );
}

function helperPath(): string {
  return path.join(environment.assetsPath, "ocr.ps1");
}

function invokeHelper(
  arguments_: string[],
  timeout = PROCESS_TIMEOUT_MS,
): Promise<{ stdout: string; stderr: string }> {
  const isDevelopment = environment.isDevelopment === true;
  return new Promise((resolve, reject) => {
    execFile(
      powershellPath(),
      [
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-STA",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        helperPath(),
        ...arguments_,
      ],
      {
        encoding: "utf8",
        windowsHide: true,
        timeout,
        maxBuffer: MAX_OUTPUT_BYTES,
        // Development builds ask the helper for timing and DPI diagnostics on stderr.
        ...(isDevelopment
          ? { env: { ...process.env, SCREENOCR_DEBUG: "1" } }
          : {}),
      },
      (error, stdout, stderr) => {
        if (isDevelopment && stderr.trim()) {
          console.error(`ScreenOCR helper: ${stderr.trim().slice(0, 4000)}`);
        }
        if (error) {
          reject(Object.assign(error, { stdout, stderr }));
          return;
        }
        resolve({ stdout, stderr });
      },
    );
  });
}

function parsePayload<T>(stdout: string): T {
  const raw = stdout.trim();
  if (!raw)
    throw new ProtocolError(
      "The Windows OCR helper returned an empty response.",
    );

  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new ProtocolError(
      "The Windows OCR helper returned an invalid response.",
    );
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ProtocolError(
      "The Windows OCR helper returned an invalid response.",
    );
  }
  return value as T;
}

function hasExactKeys(value: object, keys: string[]): boolean {
  return Object.keys(value).sort().join(",") === [...keys].sort().join(",");
}

function processError(error: unknown, language?: string): RecognitionOutcome {
  if (error instanceof ProtocolError)
    return { status: "error", message: error.message };
  const processFailure = (
    error && typeof error === "object" ? error : {}
  ) as NodeJS.ErrnoException & {
    killed?: boolean;
    signal?: string | null;
    stdout?: string;
    stderr?: string;
  };
  if (processFailure.code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER") {
    return {
      status: "error",
      message: "The Windows OCR response exceeded its size limit.",
    };
  }
  if (processFailure.killed || processFailure.signal) {
    return { status: "error", message: "Windows text recognition timed out." };
  }

  const exitCode =
    typeof processFailure.code === "number" ? processFailure.code : undefined;
  if (exitCode === HELPER_EXIT.cancelled) return { status: "cancelled" };
  if (exitCode === HELPER_EXIT.languageUnavailable) {
    return {
      status: "error",
      message:
        language && language !== "auto"
          ? `The Windows OCR language pack for ${language} is not installed.`
          : "Windows could not create an OCR engine from your profile languages.",
    };
  }
  if (exitCode === HELPER_EXIT.clipboardInput) {
    try {
      const payload = parsePayload<ErrorPayload>(processFailure.stdout || "");
      const messages: Record<ErrorPayload["code"], string> = {
        "clipboard-empty": "The clipboard does not contain an image.",
        "clipboard-unsupported":
          "The copied file is not a supported image format.",
        "clipboard-corrupt": "The copied image file could not be decoded.",
        "clipboard-busy": "The clipboard is busy. Try again.",
        "clipboard-too-large":
          "The copied image is too large to process safely.",
        "clipboard-unreadable": "The copied image file could not be read.",
      };
      if (
        payload.status === "error" &&
        hasExactKeys(payload, ["code", "status"]) &&
        typeof payload.code === "string" &&
        Object.hasOwn(messages, payload.code)
      ) {
        return { status: "error", message: messages[payload.code] };
      }
    } catch {
      // The exit code remains authoritative when an older helper has no payload.
    }
    return {
      status: "error",
      message: "The clipboard does not contain a supported image.",
    };
  }
  if (exitCode === HELPER_EXIT.captureBusy) {
    return {
      status: "error",
      message:
        "Another Windows screen capture is already in progress. Finish or cancel it, then try again.",
    };
  }
  if (exitCode === HELPER_EXIT.restrictedLanguage) {
    return { status: "error", message: RESTRICTED_LANGUAGE_MESSAGE };
  }
  if (processFailure.code === "ENOENT") {
    return {
      status: "error",
      message: "Windows PowerShell 5.1 could not be started.",
    };
  }
  if (
    processFailure.code === "EACCES" ||
    processFailure.code === "EPERM" ||
    processFailure.code === "UNKNOWN"
  ) {
    return { status: "error", message: SPAWN_BLOCKED_MESSAGE };
  }
  // PowerShell refuses to load a script blocked by execution policy before the
  // helper runs. The error identifiers below are not localized.
  if (
    exitCode !== HELPER_EXIT.failed &&
    /PSSecurityException|UnauthorizedAccess/.test(processFailure.stderr || "")
  ) {
    return { status: "error", message: EXECUTION_POLICY_MESSAGE };
  }
  return { status: "error", message: "Windows text recognition failed." };
}

export async function getWindowsRecognitionLanguage(): Promise<string> {
  const value = await LocalStorage.getItem<string>(
    WINDOWS_LANGUAGE_STORAGE_KEY,
  );
  return typeof value === "string" && value.length > 0 ? value : "auto";
}

export async function setWindowsRecognitionLanguage(
  tag: string,
): Promise<void> {
  if (!LANGUAGE_TAG.test(tag))
    throw new Error("Invalid Windows OCR language tag.");
  await LocalStorage.setItem(WINDOWS_LANGUAGE_STORAGE_KEY, tag);
}

export async function getAvailableWindowsLanguages(): Promise<
  WindowsRecognizerLanguage[]
> {
  let stdout: string;
  try {
    ({ stdout } = await invokeHelper(["-ListLanguages"], 15_000));
  } catch (error) {
    const outcome = processError(error);
    throw new Error(
      outcome.status === "error"
        ? outcome.message
        : "Could not load Windows OCR languages.",
    );
  }
  const payload = parsePayload<LanguagesPayload>(stdout);
  const seenTags = new Set<string>();
  if (
    payload.status !== "languages" ||
    !hasExactKeys(payload, ["languages", "status"]) ||
    !Array.isArray(payload.languages) ||
    payload.languages.some((language) => {
      if (
        !language ||
        typeof language !== "object" ||
        Array.isArray(language) ||
        !hasExactKeys(language, ["displayName", "tag"]) ||
        typeof language.tag !== "string" ||
        !LANGUAGE_TAG.test(language.tag) ||
        language.tag === "auto" ||
        typeof language.displayName !== "string" ||
        language.displayName.trim().length === 0
      ) {
        return true;
      }
      const normalizedTag = language.tag.toLowerCase();
      if (seenTags.has(normalizedTag)) return true;
      seenTags.add(normalizedTag);
      return false;
    })
  ) {
    throw new Error(
      "The Windows OCR helper returned an invalid language list.",
    );
  }
  return payload.languages.map(({ tag, displayName }) => ({
    tag,
    displayName,
  }));
}

export async function recognizeWindows(
  mode: CaptureMode,
): Promise<RecognitionOutcome> {
  let language: string | undefined;
  try {
    const preferences = getPreferenceValues<Preferences>();
    language = await getWindowsRecognitionLanguage();
    if (!LANGUAGE_TAG.test(language)) {
      return {
        status: "error",
        message:
          "The saved Windows OCR language is invalid. Choose a language in Select Recognition Languages.",
      };
    }
    const arguments_ = ["-Mode", mode, "-Language", language];
    if (preferences.ignoreLineBreaks) arguments_.push("-IgnoreLineBreaks");

    const { stdout } = await invokeHelper(
      arguments_,
      mode === "area" ? SELECTION_TIMEOUT_MS : PROCESS_TIMEOUT_MS,
    );
    const payload = parsePayload<RecognitionPayload>(stdout);
    if (payload.status === "no-text" && hasExactKeys(payload, ["status"]))
      return { status: "no-text" };
    if (
      payload.status === "recognized" &&
      typeof payload.text === "string" &&
      payload.text.trim().length > 0 &&
      hasExactKeys(payload, ["status", "text"])
    ) {
      return { status: "recognized", text: payload.text };
    }
    return {
      status: "error",
      message: "The Windows OCR helper returned an invalid result.",
    };
  } catch (error) {
    return processError(error, language);
  }
}

function parseImagePayload(stdout: string): {
  luminance: Uint8ClampedArray;
  width: number;
  height: number;
} {
  const payload = parsePayload<ImagePayload>(stdout);
  const isDimension = (value: unknown): value is number =>
    typeof value === "number" &&
    Number.isInteger(value) &&
    value > 0 &&
    value <= MAX_BARCODE_DIMENSION;
  if (
    payload.status !== "image" ||
    !hasExactKeys(payload, ["height", "luminance", "status", "width"]) ||
    !isDimension(payload.width) ||
    !isDimension(payload.height) ||
    typeof payload.luminance !== "string" ||
    payload.luminance.length % 4 !== 0 ||
    !BASE64.test(payload.luminance)
  ) {
    throw new ProtocolError(
      "The Windows OCR helper returned an invalid image.",
    );
  }
  const bytes = Buffer.from(payload.luminance, "base64");
  if (bytes.length !== payload.width * payload.height) {
    throw new ProtocolError(
      "The Windows OCR helper returned an invalid image.",
    );
  }
  return {
    luminance: new Uint8ClampedArray(
      bytes.buffer,
      bytes.byteOffset,
      bytes.length,
    ),
    width: payload.width,
    height: payload.height,
  };
}

export async function detectBarcodeWindows(): Promise<RecognitionOutcome> {
  let image: ReturnType<typeof parseImagePayload>;
  try {
    const { stdout } = await invokeHelper(
      ["-Mode", "barcode"],
      SELECTION_TIMEOUT_MS,
    );
    image = parseImagePayload(stdout);
  } catch (error) {
    return processError(error);
  }
  try {
    // Loaded on demand so text recognition does not initialize the barcode decoder.
    const { decodeBarcodes } = await import("./barcode");
    const values = decodeBarcodes(image.luminance, image.width, image.height);
    return values.length > 0
      ? { status: "recognized", text: values.join("\n") }
      : { status: "no-text" };
  } catch {
    return {
      status: "error",
      message: "The selected barcode or QR code could not be decoded.",
    };
  }
}
