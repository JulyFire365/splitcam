# September 2026 verification

## Build and assets

- Debug iOS Simulator build and Release iPhone build: checked with Xcode 26.2 SDK / iOS 26.3 simulator. Code signing disabled for local builds; no upload performed.
- Four new alternate icons are present in both build configurations and in the compiled app's CFBundleAlternateIcons dictionary. Final artwork is 1024 × 1024 with no alpha channel.
- All 16 ASO boards are 1320 × 2868 sRGB PNGs without alpha; English and Simplified Chinese overviews were visually reviewed.
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
