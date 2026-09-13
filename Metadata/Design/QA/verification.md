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

That initial quality-only revision did not change the recording finalization / Photos save pipeline. The authorized follow-up below addresses the confirmed code risks; the exact original incident still requires device evidence.

## Recording/save repair and final UI follow-up (2026-09-13)

### Recording/save regression

Run the production writer and storage harness on macOS:

```sh
swiftc -module-cache-path /private/tmp/splitcam-swift-cache -parse-as-library Core/CameraEngine/VideoRecordingSession.swift Core/CameraEngine/VideoQuality.swift Core/MediaStore/VideoAlbumSaver.swift Shared/Extensions/String+L10n.swift Tools/ValidateRecordingSave.swift -o /private/tmp/splitcam-recording-save-validation
/private/tmp/splitcam-recording-save-validation
```

- Passed all three HEVC quality outputs (720 × 960 for Low, 1080 × 1440 for Standard/High), positive duration and decoding, including AAC audio.
- Passed empty capture handling, 12 consecutive single-frame recordings, stop with an append in flight, rejection of late samples, stale completion isolation, and protection of existing files.
- The fake Photos adapter exercised first grant/denial, restrictions, write errors, retained/recovered files and successful retry. No real Photos data was written by this harness.
- The Debug simulator route `-preview-screen recording-check` exercised actual CameraEngine callbacks, `CameraRecordingComposer`, `VideoRecordingSession` and `CameraViewModel` with synthetic frames. All checks passed: processing locks, first denial, retained file after model recreation, write failure, retry, thumbnail, cleanup and subsequent recordings. Native tapping of Retry Save removed the alert and pending-save badge after the test adapter succeeded.
- This does not replace fresh-install, multi-camera, background-transition and audio/video-sync checks on a supported physical device. See the [updated investigation](video-quality-and-save-audit.md).

### Clipped quality explanation

- Moved the scope text out of the transparent zero-inset rounded list row and into the option section's native header, with native horizontal insets and unrestricted vertical wrapping.
- Verified the actual camera → Video Quality sheet on iPhone SE (3rd generation), English, at standard and the largest accessibility text size. The entire sentence is visible and wraps without clipping the initial letters. [Standard-size capture](quality-scope-se-en.png).
- Recaptured the bilingual native quality screenshots and re-rendered the affected quality boards and overview sheets. All 16 upload boards pass the 1284 × 2778 / opaque sRGB / no-page-counter validator. Both updated quality boards were visually reviewed.

### Pro button and dock

- Annual CTA: **按年订阅 / Subscribe Yearly**. An eligible free trial uses **免费试用 X 天 / Start X-Day Free Trial** instead. Monthly and Lifetime use their own subscription/purchase actions, not the generic unlock text.
- The selected full price, billing period, trial-to-paid transition where applicable, and auto-renewal disclosure remain directly beneath the CTA. StoreKit prices, eligibility checks, product IDs and offer configuration are unchanged. The annual card continues to show the full billed annual price, not a monthly equivalent.
- A 24-point top-only gradient shadow fades into the scrolling region, is excluded from hit testing/accessibility, and does not darken the button. The dock remains fixed at ordinary Dynamic Type sizes.
- Accessibility sizes place the purchase area in the same ScrollView as the plans to avoid a fixed footer occupying nearly the whole small screen. Legal links and CTA allow vertical wrapping. The revised top layout and complete accessibility labels were checked on iPhone SE at maximum size; the current native automation could not drive that SwiftUI ScrollView to the bottom. Manually verify touch scrolling to the CTA and all legal links on device.
- Verified native Chinese trial, monthly and lifetime selections; English no-trial annual state and its complete renewal disclosure. [English annual/no-trial capture](pro-yearly-no-trial-en.png), [Chinese annual/no-trial on iPhone SE](pro-yearly-se-zh-Hans.png). The no-trial snapshots use the simulator-only `-preview-no-trial` override, not a purchase or a change to the account's eligibility. No transaction or restore was performed.
- Reference: Apple's [auto-renewable subscription presentation guidance](https://developer.apple.com/app-store/subscriptions/) and [App Review guideline 3.1.2(c)](https://developer.apple.com/app-store/review/guidelines/#subscriptions). These checks are not a guarantee of review approval.

Final Debug simulator and Release iPhone builds passed; the compiled Release Info.plist remains 1.8 (9). A Release binary string check found none of `preview-screen`, `preview-no-trial`, `RecordingSaveChecks`, `recording-check` or `demo-front.png`. Localizations, metadata limits and `git diff --check` pass. Existing VideoComposer Swift 6 migration warnings remain; no new warnings from the repaired recording or paywall code were reported. No signing, upload or App Store submission was performed.
