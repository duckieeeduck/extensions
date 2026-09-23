import { Clipboard, closeMainWindow, LaunchProps } from "@raycast/api";
import { callbackLaunchCommand } from "raycast-cross-extension";
import { OCRResult, LaunchContext } from "../types";
import { showFailureToast, showSuccessToast } from "../utils";
import { detectBarcode, recognizeText } from "./macos";

export async function recognizeTextCommand({
  launchContext,
}: LaunchProps<{ launchContext?: LaunchContext }>) {
  await closeMainWindow();

  const callbackOptions = launchContext?.callbackLaunchOptions;
  const outcome = await recognizeText();

  // A cancelled selection leaves the clipboard unchanged and shows no error.
  if (outcome.status === "cancelled") {
    if (callbackOptions) {
      await callbackLaunchCommand(callbackOptions, {
        text: null,
        error: "Recognition cancelled",
      } satisfies OCRResult);
    }
    return;
  }

  if (outcome.status === "error") {
    await showFailureToast(outcome.message, { title: "Failed detecting text" });
    if (callbackOptions) {
      await callbackLaunchCommand(callbackOptions, {
        text: null,
        error: outcome.message,
      } satisfies OCRResult);
    }
    return;
  }

  if (outcome.status === "no-text") {
    await showFailureToast("No text detected", { title: "No text detected" });

    if (callbackOptions) {
      await callbackLaunchCommand(callbackOptions, {
        text: null,
        error: "No text detected",
      } satisfies OCRResult);
    }

    return;
  }

  if (callbackOptions) {
    await callbackLaunchCommand(callbackOptions, {
      text: outcome.text,
    } satisfies OCRResult);
    return;
  }

  try {
    await Clipboard.copy(outcome.text);
    await showSuccessToast("Copied text to clipboard");
  } catch (e) {
    console.error(e);
    await showFailureToast(e, { title: "Failed to copy recognized text" });
  }
}

export async function recognizeTextFullscreenCommand() {
  await closeMainWindow();

  const outcome = await recognizeText(true);
  if (outcome.status === "cancelled") return;
  if (outcome.status === "error") {
    await showFailureToast(outcome.message, { title: "Failed detecting text" });
    return;
  }
  if (outcome.status === "no-text") {
    await showFailureToast("No text detected", { title: "No text detected" });
    return;
  }

  try {
    await Clipboard.copy(outcome.text);
    await showSuccessToast("Copied text to clipboard");
  } catch (e) {
    console.error(e);
    await showFailureToast(e, { title: "Failed to copy recognized text" });
  }
}

export async function detectBarcodeCommand() {
  await closeMainWindow();

  const outcome = await detectBarcode();
  if (outcome.status === "cancelled") return;
  if (outcome.status === "error") {
    await showFailureToast(outcome.message, {
      title: "Failed detecting barcode/QR code",
    });
    return;
  }
  if (outcome.status === "no-text") {
    await showFailureToast("No barcodes or QR codes detected", {
      title: "No barcodes or QR codes detected",
    });
    return;
  }

  try {
    await Clipboard.copy(outcome.text);
    await showSuccessToast("Copied barcode/QR code to clipboard");
  } catch (e) {
    console.error(e);
    await showFailureToast(e, { title: "Failed to copy barcode/QR code" });
  }
}
