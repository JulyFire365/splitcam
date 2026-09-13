# September 2026 verification

## Build and assets

- Debug iOS Simulator build and Release iPhone build: checked with Xcode 26.2 SDK / iOS 26.3 simulator. Code signing disabled for local builds; no upload performed.
- Four new alternate icons are present in both build configurations and in the compiled app's CFBundleAlternateIcons dictionary. Final artwork is 1024 × 1024 with no alpha channel.
- ASO boards were initially 1320 × 2868 (6.9-inch). The revised upload set targets the user's ASC 6.5-inch slot at 1284 × 2778, without alpha. The original-size raw app screenshots are internal inputs, not upload files.
- Localized string tables and Info.plist pass plutil; git diff --check passes.
- Existing VideoComposer Swift 6 sendability warnings remain; this project builds in Swift 5 language mode.
- Release binary does not contain the Debug simulator screenshot routes or demo file names. Demo images stay under Metadata, outside the app bundle.

## Real video encoding check

Compile and run from the repository root (requires macOS media encoding services):

```sh
swiftc -parse-as-library Core/CameraEngine/VideoQuality.swift Shared/Extensions/String+L10n.swift Tools/ValidateVideoQuality.swift -o /private/tmp/splitcam-quality-validation
/private/tmp/splitcam-quality-validation
```

The harness uses the same production HEVC settings as CameraViewModel, encodes 90 frames of a moving high-complexity fixture, then checks output size, duration and decoding.

| Quality | Encoded dimensions | Actual 3-second file size |
| --- | --- | --- |
| Space Saver | 720 × 1280 | 2,604,116 bytes |
| Standard | 1080 × 1920 | 4,440,030 bytes |
| High | 1080 × 1920 | 8,838,988 bytes |

All three decode successfully. All four frame ratios produce the expected 720-based sizes for Low and unchanged sizes for Standard/High. Legacy stored values `standard` and `high` remain valid. Short, high-complexity test clips are not representative of the UI's nominal bitrate-based MB/min estimates.

## Native UI checks

- Quality: selected Space Saver through the actual Settings UI, restarted the app without preference overrides, and confirmed it remained selected.
- Pro gate: tapped the new Chrome icon without Pro; the new paywall opened with the icon benefit emphasized.
- Plans: verified Yearly defaults, Monthly changes the billing explanation to monthly renewal, and Lifetime changes it to one-time payment with no subscription. Prices and eligibility were returned by StoreKit; no real purchase was executed.
- Settings: official Custody Journal icon is visible; Restore Purchases is absent from Settings and available on the Pro page.
- Checked English and Simplified Chinese layouts, plus a large accessibility text size and iPhone SE layout. The accessible price cards stack vertically; the footer covers the bottom safe area.
- Hero motion is a native 12-second loop with a reduced-motion static branch and background pause. `pro-animation.mp4` shows one loop from the simulator.

Physical dual-camera capture, paid transactions and App Store sandbox restore still need the normal device/TestFlight release checks. The encoder check is a real local encode, not a physical dual-camera recording test.

## Reproducing the storyboard

Build the Debug app and install it on a dedicated simulator. Copy `Metadata/ASO/2026-09/source/demo-back.png` and `demo-front.png` into its Documents directory. Launch with `-preview-screen` set to `split`, `pip`, `duet`, `stack`, `portrait`, `quality`, `settings`, `icons`, or `paywall`; use `-AppleLanguages '(en)'` or `'(zh-Hans)'` for localization. The `-settings.defaultVideoQuality low` launch argument is only a screenshot preference override and is not needed for the persistence test.

Save raw screenshots to the corresponding `Metadata/ASO/2026-09/raw/<language>/` directory, then run:

```sh
swift Tools/RenderASO.swift
```

The renderer places native screenshots and local icon assets on new editorial layouts. Photo imagery is generated demonstration content; it is not a claim about real device output quality. Crops in boards 6–7 only enlarge existing native interface regions.

## Revised 6.5-inch upload set

The revised first five scenes use different outfits, expressions and settings. `Tools/CaptureASO.sh` copies each selected generated photo pair to the dedicated simulator and captures the actual app views in both languages; no camera UI is painted over. `source/scene-prompts.md` records the prompts. App source and release version are unchanged.

`Tools/RenderASO.swift` uniformly fits the design into 1284 × 2778. Page counters are removed; ordered filenames remain. Only the eight PNGs inside each language directory are for upload, not overviews or raw captures.

Run `swift Tools/ValidateASO.swift` to verify dimensions, opacity, color space and absence of page counters, including OCR near the former page-counter position.

Final revision checks passed on 2026-09-13: all 16 upload PNGs are 1284 × 2778 opaque sRGB, no page counters were detected, and all 10 camera captures contain the expected nonblank demo content. Both language overviews were visually inspected. A clipped pet portrait was reframed as a landscape source and recaptured; screenshots taken before the app finished launching were replaced. The capture script now checks demo-frame readiness and retries instead of trusting a fixed startup delay. OCR validation needs access to macOS Vision services. These checks do not claim an ASC upload was performed.

## Video quality follow-up (2026-09-13)

- Video quality is now shown only in Video mode, using one shared picker and one persisted preference. See the [state contract and save investigation](video-quality-and-save-audit.md).
- Verified through native simulator interaction: tapping the far-right blank area of Space Saver selects it and dismisses the camera picker; Settings immediately shows Space Saver. Tapping the far-left inset of High in Settings selects High. Returning to Video shows High without restart.
- Verified Photo mode hides the quality entry. Video mode restores it without changing the selected quality.
- Turned Remember Last Capture Layout & Settings off, chose High, terminated/relaunched without quality overrides, and confirmed High remained on the camera. The test app's persisted plist contained `settings.defaultVideoQuality = high` and `settings.remembersLastLayout = false`.
- Checked Simplified Chinese at the largest accessibility text size: rows expand, text wraps, and native list scrolling reaches the selected High option and complete footer.
- Debug Simulator and Release iPhone builds pass; Release Info.plist remains 1.8 (9). Existing VideoComposer Swift 6 migration warnings remain unchanged. Localizations and release metadata validate.
- Re-ran the real HEVC harness: all four size mappings pass; Low / Standard / High encode and decode successfully with the same file-size results recorded above. This does not test the real camera's concurrent stop/finalize path.
- Recaptured the four affected bilingual Settings / Quality raw screenshots; the quality board crop includes the new scope explanation and footer.

The reported first-save failure remains under investigation. No fix to the recording finalization / Photos save pipeline is claimed in this revision.
