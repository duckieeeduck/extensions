const assert = require("node:assert/strict");
const { describe, test } = require("node:test");
const {
  BarcodeFormat,
  EncodeHintType,
  QRCodeWriter,
} = require("@zxing/library");
const { createHost } = require("./helpers.cjs");

const callbackOptions = {
  name: "caller",
  extensionName: "example",
  ownerOrAuthorName: "example",
};
const outputs = (host) =>
  host.calls.filter(([name]) => ["copy", "paste"].includes(name));

test("Windows preserves Unicode and real Error-prefixed OCR text", async () => {
  const text = "Error: this is real OCR\n日本語";
  const host = createHost({
    stdout: JSON.stringify({ status: "recognized", text }),
  });
  assert.deepEqual(
    await host.load("src/ocr/windows.ts").recognizeWindows("clipboard"),
    { status: "recognized", text },
  );
});

for (const [outcome, expected] of [
  [{ status: "recognized", text: "Result" }, { text: "Result" }],
  [{ status: "no-text" }, { text: null, error: "No text detected" }],
  [{ status: "cancelled" }, { text: null, error: "Recognition cancelled" }],
  [
    { status: "error", message: "No OCR pack" },
    { text: null, error: "No OCR pack" },
  ],
]) {
  test(`callback ${outcome.status} skips ordinary clipboard actions`, async () => {
    const host = createHost({ preferences: { resultAction: "both" } });
    await host
      .load("src/ocr/result.ts")
      .handleRecognitionOutcome(outcome, { callbackOptions });
    assert.deepEqual(host.calls, [["callback", callbackOptions, expected]]);
  });
}

test("failed callback delivery is reported and never retried", async () => {
  const host = createHost({ callbackError: new Error("Caller unavailable") });
  await host
    .load("src/recognize-text.tsx")
    .default({ launchContext: { callbackLaunchOptions: callbackOptions } });
  assert.equal(host.calls.filter(([name]) => name === "callback").length, 1);
  assert.equal(host.calls.filter(([name]) => name === "failure").length, 1);
  assert.deepEqual(outputs(host), []);
});

test("window-close failures reach a callback once without running recognition", async () => {
  const host = createHost({ closeError: new Error("Unable to close") });
  await host
    .load("src/recognize-text.tsx")
    .default({ launchContext: { callbackLaunchOptions: callbackOptions } });
  assert.deepEqual(host.calls, [
    ["close"],
    ["callback", callbackOptions, { text: null, error: "Unable to close" }],
  ]);
});

test("ordinary cancellation has no output or notification", async () => {
  const host = createHost();
  await host
    .load("src/ocr/result.ts")
    .handleRecognitionOutcome({ status: "cancelled" });
  assert.deepEqual(host.calls, []);
});

for (const [action, expected] of [
  ["copy", ["copy"]],
  ["paste", ["paste"]],
  ["both", ["copy", "paste"]],
  [undefined, ["copy"]],
  ["invalid", ["copy"]],
]) {
  test(`ordinary result action ${action} has bounded clipboard effects`, async () => {
    const host = createHost({ preferences: { resultAction: action } });
    await host
      .load("src/ocr/result.ts")
      .handleRecognitionOutcome({ status: "recognized", text: "Text" });
    assert.deepEqual(
      outputs(host).map(([name]) => name),
      expected,
    );
    assert.equal(host.calls.filter(([name]) => name === "toast").length, 1);
  });
}

test("copy-and-paste reports partial failure without claiming success", async () => {
  const host = createHost({
    preferences: { resultAction: "both" },
    pasteError: new Error("Paste denied"),
  });
  await host
    .load("src/ocr/result.ts")
    .handleRecognitionOutcome({ status: "recognized", text: "Text" });
  assert.deepEqual(
    outputs(host).map(([name]) => name),
    ["copy", "paste"],
  );
  assert.equal(
    host.calls.some(([name]) => name === "toast"),
    false,
  );
  assert.equal(
    host.calls.at(-1)[2].title,
    "Text was copied, but could not be pasted",
  );
});

test("failed copy prevents the paste half of copy-and-paste", async () => {
  const host = createHost({
    preferences: { resultAction: "both" },
    copyError: new Error("Busy clipboard"),
  });
  await host
    .load("src/ocr/result.ts")
    .handleRecognitionOutcome({ status: "recognized", text: "Text" });
  assert.deepEqual(
    outputs(host).map(([name]) => name),
    ["copy"],
  );
});

test("disabled notifications suppress result messages without changing clipboard actions", async () => {
  const host = createHost({ preferences: { showToast: false } });
  const { handleRecognitionOutcome } = host.load("src/ocr/result.ts");
  await handleRecognitionOutcome({ status: "recognized", text: "Text" });
  await handleRecognitionOutcome({ status: "no-text" });
  await handleRecognitionOutcome({ status: "error", message: "Failure" });
  assert.deepEqual(host.calls, [["copy", "Text"]]);
});

for (const [entry, mode] of [
  ["src/recognize-text.tsx", "area"],
  ["src/recognize-text-fullscreen.ts", "fullscreen"],
  ["src/recognize-clipboard.ts", "clipboard"],
]) {
  test(`${mode} command invokes Windows without initializing Swift`, async () => {
    const host = createHost();
    await host.load(entry).default({});
    const processCall = host.calls.find(([name]) => name === "process");
    const args = processCall[2];
    assert.equal(args[args.indexOf("-Mode") + 1], mode);
    assert.equal(
      host.imports.some((name) => name.startsWith("swift:")),
      false,
    );
    assert.deepEqual(outputs(host), [["copy", "Example text"]]);
  });
}

test("Windows process uses an absolute executable, safe argument array and bounded execution", async () => {
  const host = createHost({
    storage: { WindowsRecognitionLanguage: "ja-JP" },
    preferences: { ignoreLineBreaks: true },
  });
  await host.load("src/ocr/windows.ts").recognizeWindows("area");
  const [, executable, args, settings] = host.calls[0];
  assert.match(
    executable,
    /^[A-Za-z]:\\.*\\WindowsPowerShell\\v1\.0\\powershell\.exe$/,
  );
  for (const arg of ["-NoProfile", "-STA", "-File", "-IgnoreLineBreaks"])
    assert.ok(args.includes(arg));
  assert.equal(args[args.indexOf("-ExecutionPolicy") + 1], "Bypass");
  assert.equal(args[args.indexOf("-Language") + 1], "ja-JP");
  assert.equal(settings.shell, undefined);
  assert.equal(settings.windowsHide, true);
  assert.equal(settings.encoding, "utf8");
  assert.ok(settings.timeout > 0 && settings.timeout <= 300_000);
  assert.ok(settings.maxBuffer > 0 && settings.maxBuffer <= 16 * 1024 * 1024);
});

for (const stdout of [
  "",
  'noise\n{"status":"recognized","text":"secret"}',
  "null",
  "[]",
  '{"status":"recognized","text":""}',
  '{"status":"recognized","text":"  "}',
  '{"status":"recognized","text":"secret","extra":true}',
  '{"status":"no-text","text":"stale"}',
]) {
  test(`Windows rejects invalid helper output ${JSON.stringify(stdout)}`, async () => {
    const host = createHost({ stdout });
    const outcome = await host
      .load("src/ocr/windows.ts")
      .recognizeWindows("clipboard");
    assert.equal(outcome.status, "error");
    assert.equal(outcome.message.includes("secret"), false);
  });
}

for (const [error, stdout, status, message] of [
  [{ code: 2 }, "", "cancelled", undefined],
  [{ code: 3 }, "", "error", /ja-JP.*not installed/],
  [
    { code: 4 },
    '{"status":"error","code":"clipboard-corrupt"}',
    "error",
    /could not be decoded/,
  ],
  [
    { code: 4 },
    '{"status":"error","code":"clipboard-unsupported"}',
    "error",
    /not a supported image/,
  ],
  [
    { code: 4 },
    '{"status":"error","code":"clipboard-busy"}',
    "error",
    /clipboard is busy/,
  ],
  [
    { code: 4 },
    '{"status":"error","code":"__proto__"}',
    "error",
    /supported image/,
  ],
  [
    { code: 4 },
    '{"status":"error","code":"clipboard-too-large"}',
    "error",
    /too large/,
  ],
  [
    { code: 4 },
    '{"status":"error","code":"clipboard-unreadable"}',
    "error",
    /could not be read/,
  ],
  [
    { code: 6 },
    "",
    "error",
    /Another Windows screen capture is already in progress.*cancel it.*try again/,
  ],
  [{ code: "ENOENT" }, "", "error", /PowerShell 5.1/],
  [{ killed: true, signal: "SIGTERM" }, "", "error", /timed out/],
  [
    { code: "ERR_CHILD_PROCESS_STDIO_MAXBUFFER", killed: true },
    "",
    "error",
    /size limit/,
  ],
  [{ code: 5 }, "", "error", /recognition failed/],
]) {
  test(`Windows maps process outcome ${JSON.stringify(error)} safely`, async () => {
    const host = createHost({
      processError: error,
      stdout,
      storage: { WindowsRecognitionLanguage: "ja-JP" },
    });
    const outcome = await host
      .load("src/ocr/windows.ts")
      .recognizeWindows("area");
    assert.equal(outcome.status, status);
    if (message) assert.match(outcome.message, message);
  });
}

test("invalid saved language is rejected before PowerShell instead of falling back", async () => {
  const host = createHost({
    storage: { WindowsRecognitionLanguage: "ja-JP; Write-Output bad" },
  });
  const outcome = await host
    .load("src/ocr/windows.ts")
    .recognizeWindows("area");
  assert.equal(outcome.status, "error");
  assert.equal(host.calls.length, 0);
});

test("Windows language selection and inventory preserve macOS selections", async () => {
  const savedMacLanguages = '[{"value":"fr-FR","title":"French"}]';
  const host = createHost({
    storage: { SelectedLanguages: savedMacLanguages },
    stdout:
      '{"status":"languages","languages":[{"tag":"ja-JP","displayName":"Japanese"}]}',
  });
  const windows = host.load("src/ocr/windows.ts");
  assert.equal(await windows.getWindowsRecognitionLanguage(), "auto");
  assert.deepEqual(await windows.getAvailableWindowsLanguages(), [
    { tag: "ja-JP", displayName: "Japanese" },
  ]);
  await windows.setWindowsRecognitionLanguage("ja-JP");
  assert.equal(await windows.getWindowsRecognitionLanguage(), "ja-JP");
  assert.equal(host.storage.get("SelectedLanguages"), savedMacLanguages);
  await assert.rejects(windows.setWindowsRecognitionLanguage("--invalid"));
});

for (const entry of [
  "src/recognize-text.tsx",
  "src/recognize-text-fullscreen.ts",
  "src/detect-barcode.tsx",
]) {
  test(`${entry} retains macOS copy behavior and never invokes PowerShell`, async () => {
    const mac = createHost({
      platform: "darwin",
      preferences: { resultAction: "both" },
    });
    await mac.load(entry).default({});
    assert.deepEqual(outputs(mac), [["copy", "Example text"]]);
    assert.equal(
      mac.calls.some(([name]) => name === "process"),
      false,
    );
  });
}

test("macOS OCR retains selected languages and the original raw Swift contract", async () => {
  const mac = createHost({
    platform: "darwin",
    storage: { SelectedLanguages: '[{"title":"French","value":"fr-FR"}]' },
    swiftResult: "Known text",
  });
  await mac
    .load("src/recognize-text.tsx")
    .default({ launchContext: { callbackLaunchOptions: callbackOptions } });
  const swift = mac.calls.find(([name]) => name === "swift");
  assert.equal(swift[1], "recognizeText");
  assert.deepEqual(swift[2][6], ["fr-FR", "en-US"]);
  assert.deepEqual(outputs(mac), []);
  assert.deepEqual(
    mac.calls.find(([name]) => name === "callback"),
    ["callback", callbackOptions, { text: "Known text" }],
  );
});

test("clipboard command reports Windows limitation on macOS without native calls", async () => {
  const mac = createHost({ platform: "darwin" });
  await mac.load("src/recognize-clipboard.ts").default();
  assert.deepEqual(outputs(mac), []);
  assert.equal(
    mac.calls.some(([name]) => name === "swift" || name === "process"),
    false,
  );
  assert.match(
    String(mac.calls.find(([name]) => name === "failure")[1]),
    /Windows/i,
  );
});

// Renders QR codes into one grayscale image, as the helper's barcode mode would.
function qrImage(codes, { width = 900, height = 400, invert = false } = {}) {
  const pixels = new Uint8ClampedArray(width * height).fill(invert ? 0 : 255);
  for (const { text, x, y, size = 240 } of codes) {
    const matrix = new QRCodeWriter().encode(
      text,
      BarcodeFormat.QR_CODE,
      size,
      size,
      new Map([
        [EncodeHintType.CHARACTER_SET, "UTF-8"],
        [EncodeHintType.MARGIN, 4],
      ]),
    );
    for (let row = 0; row < matrix.getHeight(); row++)
      for (let column = 0; column < matrix.getWidth(); column++) {
        const dark = matrix.get(column, row) !== invert;
        pixels[(y + row) * width + x + column] = dark ? 0 : 255;
      }
  }
  return JSON.stringify({
    status: "image",
    width,
    height,
    luminance: Buffer.from(pixels).toString("base64"),
  });
}

test("barcode on Windows decodes the selected region without loading Swift", async () => {
  const text = "https://example.com/ScreenOCR?ref=äß漢字";
  const win = createHost({ stdout: qrImage([{ text, x: 40, y: 40 }]) });
  await win.load("src/detect-barcode.tsx").default();
  const processCall = win.calls.find(([name]) => name === "process");
  assert.deepEqual(processCall[2].slice(-2), ["-Mode", "barcode"]);
  assert.equal(processCall[3].timeout, 300_000);
  assert.equal(
    win.imports.some((name) => name.startsWith("swift:")),
    false,
  );
  assert.deepEqual(outputs(win), [["copy", text]]);
  assert.equal(
    win.calls.at(-1)[1].title,
    "Copied barcode/QR code to clipboard",
  );
});

test("barcode on Windows ignores the paste preference", async () => {
  const win = createHost({
    preferences: { resultAction: "paste" },
    stdout: qrImage([{ text: "COPY-ONLY", x: 40, y: 40 }]),
  });
  await win.load("src/detect-barcode.tsx").default();
  assert.deepEqual(outputs(win), [["copy", "COPY-ONLY"]]);
});

test("barcode on Windows returns every code, including light-on-dark codes", async () => {
  const barcode = createHost().load("src/ocr/barcode.ts");
  const image = JSON.parse(
    qrImage([
      { text: "FIRST", x: 40, y: 60 },
      { text: "SECOND", x: 560, y: 60, size: 280 },
    ]),
  );
  const pixels = new Uint8ClampedArray(Buffer.from(image.luminance, "base64"));
  assert.deepEqual(
    [...barcode.decodeBarcodes(pixels, image.width, image.height)].sort(),
    ["FIRST", "SECOND"],
  );

  const row = JSON.parse(
    qrImage(
      [
        { text: "A", x: 50, y: 100, size: 250 },
        { text: "B", x: 650, y: 100, size: 250 },
        { text: "C", x: 1250, y: 100, size: 250 },
      ],
      { width: 1600, height: 500 },
    ),
  );
  assert.deepEqual(
    [
      ...barcode.decodeBarcodes(
        new Uint8ClampedArray(Buffer.from(row.luminance, "base64")),
        row.width,
        row.height,
      ),
    ].sort(),
    ["A", "B", "C"],
  );

  const inverted = JSON.parse(
    qrImage([{ text: "DARK MODE", x: 100, y: 60 }], { invert: true }),
  );
  assert.deepEqual(
    barcode.decodeBarcodes(
      new Uint8ClampedArray(Buffer.from(inverted.luminance, "base64")),
      inverted.width,
      inverted.height,
    ),
    ["DARK MODE"],
  );
});

test("barcode on Windows reports an empty selection as no code", async () => {
  const win = createHost({ stdout: qrImage([]) });
  await win.load("src/detect-barcode.tsx").default();
  assert.deepEqual(outputs(win), []);
  assert.equal(win.calls.at(-1)[2].title, "No barcodes or QR codes detected");
});

test("barcode cancellation on Windows is silent", async () => {
  const win = createHost({ processError: { code: 2 }, stdout: "" });
  await win.load("src/detect-barcode.tsx").default();
  assert.deepEqual(
    win.calls.map(([name]) => name),
    ["close", "process"],
  );
});

for (const [label, payload] of [
  ["wrong pixel count", { width: 10, height: 10, luminance: "AAAA" }],
  ["invalid base64", { width: 1, height: 1, luminance: "!!!!" }],
  [
    "oversized image",
    {
      width: 4096,
      height: 1,
      luminance: Buffer.alloc(4096).toString("base64"),
    },
  ],
  ["extra fields", { width: 1, height: 1, luminance: "AA==", text: "secret" }],
  ["fractional size", { width: 1.5, height: 1, luminance: "AA==" }],
]) {
  test(`barcode on Windows rejects helper image with ${label}`, async () => {
    const barcode = await createHost({
      stdout: JSON.stringify({ status: "image", ...payload }),
    })
      .load("src/ocr/windows.ts")
      .detectBarcodeWindows();
    assert.equal(barcode.status, "error");
    assert.match(barcode.message, /invalid image/);
  });
}

for (const [label, processError, stderr, message] of [
  ["Constrained Language mode", { code: 7 }, "", /Constrained Language mode/],
  [
    "a blocked execution policy",
    { code: 1 },
    "File C:\\ocr.ps1 cannot be loaded.\r\n    + FullyQualifiedErrorId : UnauthorizedAccess",
    /execution policy/,
  ],
  [
    "a policy-blocked PowerShell start",
    { code: "EACCES" },
    "",
    /prevented PowerShell from starting/,
  ],
  [
    "an unrelated helper failure",
    { code: 5 },
    "System.UnauthorizedAccessException: Access denied",
    /^Windows text recognition failed\.$/,
  ],
]) {
  test(`Windows reports ${label} specifically`, async () => {
    const outcome = await createHost({ processError, stdout: "", stderr })
      .load("src/ocr/windows.ts")
      .recognizeWindows("fullscreen");
    assert.equal(outcome.status, "error");
    assert.match(outcome.message, message);
  });
}

test("Windows requests helper diagnostics only in development builds", async (t) => {
  const logged = [];
  t.mock.method(console, "error", (...args) => logged.push(args.join(" ")));

  const production = createHost({ stderr: "screenocr 10ms forms-ready" });
  await production.load("src/ocr/windows.ts").recognizeWindows("fullscreen");
  assert.equal(production.calls[0][3].env, undefined);
  assert.deepEqual(logged, []);

  const development = createHost({
    isDevelopment: true,
    stderr: "screenocr 10ms forms-ready",
  });
  await development.load("src/ocr/windows.ts").recognizeWindows("fullscreen");
  assert.equal(development.calls[0][3].env.SCREENOCR_DEBUG, "1");
  assert.deepEqual(logged, ["ScreenOCR helper: screenocr 10ms forms-ready"]);
});

test("Windows language manager respects the toast preference", async () => {
  const host = createHost({ preferences: { showToast: false } });
  const { showSuccessToast, showFailureToast } = host.load("src/utils.ts");
  await showSuccessToast("Saved");
  await showFailureToast(new Error("Failed"));
  assert.deepEqual(host.calls, []);
});

describe("Windows helper protocol rejects malformed output", () => {
  const errorOutcome = (message) => ({ status: "error", message });
  const invalidResponse = errorOutcome(
    "The Windows OCR helper returned an invalid response.",
  );
  const invalidResult = errorOutcome(
    "The Windows OCR helper returned an invalid result.",
  );
  const invalidImage = errorOutcome(
    "The Windows OCR helper returned an invalid image.",
  );
  const genericClipboard = errorOutcome(
    "The clipboard does not contain a supported image.",
  );
  const language = (overrides = {}) => ({
    tag: "ja-JP",
    displayName: "Japanese",
    ...overrides,
  });
  const imagePayload = (overrides = {}) =>
    JSON.stringify({
      status: "image",
      width: 2,
      height: 2,
      luminance: Buffer.alloc(4).toString("base64"),
      ...overrides,
    });

  const malformedRecognitions = [
    [
      "empty output",
      "",
      errorOutcome("The Windows OCR helper returned an empty response."),
    ],
    ["null", "null", invalidResponse],
    ["an array", "[]", invalidResponse],
    ["a bare string", '"text"', invalidResponse],
    ["recognized without text", '{"status":"recognized"}', invalidResult],
    [
      "recognized with empty text",
      '{"status":"recognized","text":""}',
      invalidResult,
    ],
    [
      "recognized with whitespace text",
      '{"status":"recognized","text":"   "}',
      invalidResult,
    ],
    [
      "recognized with non-string text",
      '{"status":"recognized","text":5}',
      invalidResult,
    ],
    [
      "recognized with an extra key",
      '{"status":"recognized","text":"a","extra":1}',
      invalidResult,
    ],
    ["no-text with an extra key", '{"status":"no-text","x":1}', invalidResult],
    [
      "a __proto__ key shadowing status",
      '{"__proto__":{"status":"recognized"},"text":"a"}',
      invalidResult,
    ],
    [
      "two concatenated JSON objects",
      '{"status":"recognized","text":"a"}{"status":"recognized","text":"b"}',
      invalidResponse,
    ],
  ];
  for (const [label, stdout, expected] of malformedRecognitions) {
    test(`recognizeWindows rejects ${label}`, async () => {
      const host = createHost({ stdout });
      assert.deepEqual(
        await host.load("src/ocr/windows.ts").recognizeWindows("clipboard"),
        expected,
      );
    });
  }

  test("recognizeWindows accepts a 7 MB valid payload", async () => {
    const text = "a".repeat(7 * 1024 * 1024);
    const host = createHost({
      stdout: JSON.stringify({ status: "recognized", text }),
    });
    const outcome = await host
      .load("src/ocr/windows.ts")
      .recognizeWindows("clipboard");
    assert.equal(outcome.status, "recognized");
    assert.ok(
      outcome.text === text,
      "recognized text differs from the payload",
    );
  });

  const malformedImages = [
    ["zero width", { width: 0 }],
    ["width above the barcode limit", { width: 2049 }],
    ["fractional width", { width: 1.5 }],
    ["negative width", { width: -2 }],
    ["luminance that is not base64", { luminance: "!!!!" }],
    ["luminance with a space", { luminance: "AAAA AA==" }],
    ["luminance with a newline", { luminance: "AAAA\nAA==" }],
    [
      "unpadded luminance with an invalid length",
      { width: 1, height: 2, luminance: "AAA" },
    ],
    [
      "luminance shorter than width times height",
      { luminance: Buffer.alloc(3).toString("base64") },
    ],
    [
      "luminance one byte longer than width times height",
      { luminance: Buffer.alloc(5).toString("base64") },
    ],
    ["an extra key", { text: "secret" }],
  ];
  for (const [label, fields] of malformedImages) {
    test(`detectBarcodeWindows rejects an image with ${label}`, async () => {
      const host = createHost({ stdout: imagePayload(fields) });
      const outcome = await host
        .load("src/ocr/windows.ts")
        .detectBarcodeWindows();
      assert.deepEqual(outcome, invalidImage);
    });
  }

  const malformedLanguageLists = [
    [
      "duplicate tags differing only by case",
      [language(), language({ tag: "JA-jp" })],
    ],
    ["the auto tag", [language({ tag: "auto" })]],
    ["a tag with spaces", [language({ tag: "ja JP" })]],
    ["an empty display name", [language({ displayName: "" })]],
    ["a whitespace display name", [language({ displayName: "   " })]],
    ["a non-string display name", [language({ displayName: 5 })]],
    ["an extra key on a language", [{ ...language(), extra: 1 }]],
  ];
  for (const [label, languages] of malformedLanguageLists) {
    test(`getAvailableWindowsLanguages rejects ${label}`, async () => {
      const host = createHost({
        stdout: JSON.stringify({ status: "languages", languages }),
      });
      await assert.rejects(
        host.load("src/ocr/windows.ts").getAvailableWindowsLanguages(),
        {
          message: "The Windows OCR helper returned an invalid language list.",
        },
      );
    });
  }

  test("getAvailableWindowsLanguages rejects an extra key on the payload", async () => {
    const host = createHost({
      stdout: JSON.stringify({
        status: "languages",
        languages: [language()],
        extra: 1,
      }),
    });
    await assert.rejects(
      host.load("src/ocr/windows.ts").getAvailableWindowsLanguages(),
      {
        message: "The Windows OCR helper returned an invalid language list.",
      },
    );
  });

  for (const [label, stdout] of [
    ["an unknown code string", { status: "error", code: "clipboard-unknown" }],
    ["the __proto__ code", { status: "error", code: "__proto__" }],
    ["the constructor code", { status: "error", code: "constructor" }],
    ["the toString code", { status: "error", code: "toString" }],
    [
      "a known code with an extra key",
      { status: "error", code: "clipboard-busy", extra: 1 },
    ],
    ["a non-error status", { status: "recognized", code: "clipboard-busy" }],
  ]) {
    test(`clipboard exit 4 with ${label} maps to the generic message`, async () => {
      const host = createHost({
        processError: { code: 4 },
        stdout: JSON.stringify(stdout),
      });
      assert.deepEqual(
        await host.load("src/ocr/windows.ts").recognizeWindows("clipboard"),
        genericClipboard,
      );
    });
  }
});
