import { getPreferenceValues } from "@raycast/api";
import { getUserSelectedLanguages } from "../hooks";
import * as swiftBridge from "swift:../../swift";
import type { RecognitionOutcome } from "./types";

const { detectBarcode: detectBarcodeSwift, recognizeText: recognizeTextSwift } =
  swiftBridge;

// Converts the Swift CaptureOutcome. Cancellation and failures are separate
// statuses, so they are never treated as recognized text.
function toOutcome(value: unknown, failure: string): RecognitionOutcome {
  const outcome = (value && typeof value === "object" ? value : {}) as {
    status?: unknown;
    text?: unknown;
    message?: unknown;
  };
  if (outcome.status === "cancelled") return { status: "cancelled" };
  if (outcome.status === "recognized" && typeof outcome.text === "string") {
    return outcome.text.trim().length > 0
      ? { status: "recognized", text: outcome.text }
      : { status: "no-text" };
  }
  if (outcome.status === "error") {
    return {
      status: "error",
      message:
        typeof outcome.message === "string" && outcome.message.trim()
          ? outcome.message
          : failure,
    };
  }
  return { status: "error", message: failure };
}

export const recognizeText = async (
  isFullScreen = false,
): Promise<RecognitionOutcome> => {
  const preference = getPreferenceValues<Preferences>();

  try {
    const languages = await getUserSelectedLanguages();

    const outcome = await recognizeTextSwift(
      isFullScreen,
      preference.keepImage,
      preference.ocrMode === "fast",
      preference.languageCorrection,
      preference.ignoreLineBreaks,
      preference.customWordsList ? preference.customWordsList.split(",") : [],
      languages.map((lang) => lang.value),
      Boolean(preference.playSound),
    );

    return toOutcome(outcome, "Failed to recognize text");
  } catch (error) {
    console.error(error);
    return { status: "error", message: "Failed to recognize text" };
  }
};

export const detectBarcode = async (): Promise<RecognitionOutcome> => {
  const preference = getPreferenceValues<Preferences>();

  try {
    const outcome = await detectBarcodeSwift(
      preference.keepImage,
      Boolean(preference.playSound),
    );

    return toOutcome(outcome, "Failed to detect barcode");
  } catch (error) {
    console.error(error);
    return { status: "error", message: "Failed to detect barcode" };
  }
};
