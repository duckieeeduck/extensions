import {
  BinaryBitmap,
  ChecksumException,
  DecodeHintType,
  FormatException,
  HybridBinarizer,
  InvertedLuminanceSource,
  LuminanceSource,
  MultiFormatReader,
  NotFoundException,
  Result,
  RGBLuminanceSource,
} from "@zxing/library";

const MAX_CODES = 8;
const TIME_BUDGET_MS = 2_500;

type Region = { left: number; top: number; width: number; height: number };

// Decodes every barcode or QR code found in a grayscale image. zxing reports one
// code per pass and cannot separate several QR codes in one image, so each pass
// tries the whole image and then overlapping halves and quarters. A found code is
// masked before the next pass. Codes drawn light-on-dark (common in dark themes)
// are retried on the inverted image. The slower exhaustive search runs once, on
// the whole image, only when nothing has been found yet.
export function decodeBarcodes(
  luminance: Uint8ClampedArray,
  width: number,
  height: number,
): string[] {
  const fastReader = new MultiFormatReader();
  fastReader.setHints(new Map());
  const thoroughReader = new MultiFormatReader();
  thoroughReader.setHints(new Map([[DecodeHintType.TRY_HARDER, true]]));
  const pixels = new Uint8ClampedArray(luminance);
  const values: string[] = [];
  const deadline = Date.now() + TIME_BUDGET_MS;
  const whole: Region = { left: 0, top: 0, width, height };

  for (let pass = 0; pass < MAX_CODES && Date.now() < deadline; pass++) {
    let found: { result: Result; region: Region } | undefined;
    for (const region of searchRegions(width, height)) {
      if (Date.now() >= deadline) break;
      const result = decodeRegion(fastReader, pixels, width, height, region);
      if (result) {
        found = { result, region };
        break;
      }
    }
    if (!found && values.length === 0 && Date.now() < deadline) {
      const result = decodeRegion(thoroughReader, pixels, width, height, whole);
      if (result) found = { result, region: whole };
    }
    if (!found) break;
    const text = found.result.getText();
    if (text && !values.includes(text)) values.push(text);
    if (!maskResult(pixels, width, height, found.result, found.region)) break;
  }
  return values;
}

function searchRegions(width: number, height: number): Region[] {
  const regions: Region[] = [{ left: 0, top: 0, width, height }];
  for (const parts of [2, 3]) {
    const columns = splitAxis(width, parts);
    const rows = splitAxis(height, parts);
    for (const [left, regionWidth] of columns)
      regions.push({ left, top: 0, width: regionWidth, height });
    for (const [top, regionHeight] of rows)
      regions.push({ left: 0, top, width, height: regionHeight });
    for (const [top, regionHeight] of rows)
      for (const [left, regionWidth] of columns)
        regions.push({ left, top, width: regionWidth, height: regionHeight });
  }
  // Drop duplicates produced when an axis is too small to split.
  const seen = new Set<string>();
  return regions.filter((region) => {
    const key = `${region.left},${region.top},${region.width},${region.height}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

// Splits one axis into overlapping windows so a code on a boundary stays whole.
function splitAxis(size: number, parts: number): [number, number][] {
  if (size / parts < 120) return [[0, size]];
  const span = Math.min(size, Math.ceil(size / parts + size * 0.2));
  const step = (size - span) / (parts - 1);
  return Array.from({ length: parts }, (_, index) => [
    Math.round(index * step),
    span,
  ]);
}

function decodeRegion(
  reader: MultiFormatReader,
  pixels: Uint8ClampedArray,
  width: number,
  height: number,
  region: Region,
): Result | undefined {
  const source = new RGBLuminanceSource(
    pixels,
    region.width,
    region.height,
    width,
    height,
    region.left,
    region.top,
  );
  const sources: LuminanceSource[] = [
    source,
    new InvertedLuminanceSource(source),
  ];
  for (const candidate of sources) {
    try {
      return reader.decodeWithState(
        new BinaryBitmap(new HybridBinarizer(candidate)),
      );
    } catch (error) {
      // No code, or an unreadable one, in this variant of the image.
      if (
        !(error instanceof NotFoundException) &&
        !(error instanceof ChecksumException) &&
        !(error instanceof FormatException)
      ) {
        throw error;
      }
    } finally {
      reader.reset();
    }
  }
  return undefined;
}

// Paints the area around a decoded code white so the next pass can find others.
// Returns false when the code's position is unknown, which ends the search.
function maskResult(
  pixels: Uint8ClampedArray,
  width: number,
  height: number,
  result: Result,
  region: Region,
): boolean {
  const points = (result.getResultPoints() ?? []).filter(Boolean);
  if (points.length === 0) return false;
  const xs = points.map((point) => point.getX() + region.left);
  const ys = points.map((point) => point.getY() + region.top);
  let left = Math.min(...xs);
  let right = Math.max(...xs);
  let top = Math.min(...ys);
  let bottom = Math.max(...ys);
  const size = Math.max(right - left, bottom - top, 20);
  // Result points mark finder patterns or scan-line ends, not the full symbol.
  const padding = size * 0.35;
  left = Math.max(0, Math.floor(left - padding));
  right = Math.min(width - 1, Math.ceil(right + padding));
  top = Math.max(0, Math.floor(top - padding));
  bottom = Math.min(height - 1, Math.ceil(bottom + padding));
  for (let y = top; y <= bottom; y++) {
    pixels.fill(255, y * width + left, y * width + right + 1);
  }
  return true;
}
