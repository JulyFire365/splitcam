# SplitCam — Dual-Camera Recorder for iOS

Native SwiftUI app that records the **front and back iPhone cameras simultaneously** into a single split-screen video (left/right, top/bottom, or picture-in-picture). Also supports **duet mode** — record yourself alongside a video/photo imported from your library.

Built on `AVCaptureMultiCamSession` with two parallel `AVAssetWriter`s and a custom `AVVideoCompositing` pipeline for post-capture composition.

---

## Demo

https://github.com/JulyFire365/splitcam/raw/master/demo/demo.mov

> If the player doesn't load inline on your browser, open [`demo/demo.mov`](demo/demo.mov) directly.

---

## Features

- **Dual-camera simultaneous capture** — front + back at the same time
- **Three split layouts** — left/right, top/bottom, picture-in-picture (circle or rounded rect)
- **Duet mode** — import a video or photo and record alongside it
- **Photo + video** — both shooting modes supported
- **Aspect ratios** — 9:16, 1:1, 4:3, 16:9
- **Resolution** — up to 1080p (device-dependent)
- **Pinch-to-zoom** on each camera feed independently
- **Bilingual UI** — English and Simplified Chinese

Free tier covers left/right and top/bottom split + all photo capture. PiP layout and duet-mode video recording are Pro features (if you build from source yourself, StoreKit is bypassed in your local build — everything is unlocked).

---

## Install

### Option 1 — App Store (easiest, recommended)

[![Download on the App Store](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg)](https://apps.apple.com/us/app/splitcam-dual-recorder/id6761194664)

**https://apps.apple.com/us/app/splitcam-dual-recorder/id6761194664**

One-tap install, auto-updates, works on any iPhone.

### Option 2 — Build and sideload it to your own iPhone (free, forever)

Apple lets any Apple ID sideload apps onto personal devices for free. The signature lasts 7 days for a free account (you re-run Xcode once a week), or 1 year if you have a paid Developer account.

**Requirements**
- A Mac with **Xcode 15+**
- An iPhone running **iOS 16+** (real device — `AVCaptureMultiCamSession` does not work in the Simulator)
- A free **Apple ID** signed into Xcode (`Xcode → Settings → Accounts`)
- A USB-C / Lightning cable

**Steps**

1. Clone the repo
   ```sh
   git clone https://github.com/JulyFire365/splitcam.git
   cd splitcam
   ```

2. Open the project
   ```sh
   open SplitCam.xcodeproj
   ```

3. Change the bundle identifier and team
   - Select the `SplitCam` target → **Signing & Capabilities**
   - Change **Bundle Identifier** from `com.flinter.splitcam` to something unique to you, e.g. `com.<yourname>.splitcam`
   - Under **Team**, pick your personal Apple ID team

4. Plug in your iPhone, unlock it, and trust the Mac.
   - On the iPhone: **Settings → Privacy & Security → Developer Mode → On** (iOS 16+ requires this for sideloaded apps).

5. In Xcode's top device picker, select your iPhone. Press **⌘R** to build and run.

6. First launch on the phone will fail with "Untrusted Developer". Fix it:
   - iPhone: **Settings → General → VPN & Device Management → your Apple ID → Trust**

7. Launch the app. Enjoy dual-camera recording.

> **Note on the 7-day limit:** with a free Apple ID, the signed build expires after 7 days. Just re-run it from Xcode (⌘R) and you get another 7 days. No payment, no account upgrade.

---

## Architecture (for the curious)

- `Core/CameraEngine/` — wraps `AVCaptureMultiCamSession`, owns two `AVCaptureVideoDataOutput`s, two `AVCaptureMovieFileOutput`-equivalent `AVAssetWriter`s, and the photo outputs. Recording writes each camera to its own `.mov` file in real time.
- `Core/SplitLayout/` — pure layout math + SwiftUI live preview. The preview uses `SampleBufferDisplayView` fed by the capture callbacks directly.
- `Core/VideoComposer/` — custom `AVVideoCompositing` implementation that merges the two per-camera recordings into a single split-screen output. PiP masking (circle / rounded rect) happens here with Core Image.
- `Core/MediaImporter/` + `Core/MediaStore/` — PHPicker import for duet mode, local persistence of finished captures.
- `Features/Camera/`, `Features/Editor/`, `Features/Export/`, `Features/Gallery/` — SwiftUI screens, MVVM.

The key thing to know: **the live preview and the exported video are produced by two different code paths**. Preview is live SwiftUI composition of two `CMSampleBuffer` streams. Export is AVFoundation composition of the two recorded files. If one looks right and the other looks wrong, that tells you which layer to debug.

## Tech stack

- SwiftUI, iOS 16+
- `AVCaptureMultiCamSession` (iPhone XS / XR and newer)
- StoreKit 2
- No third-party dependencies

## License

MIT. See [LICENSE](LICENSE).

## Support

- Issues: [GitHub Issues](https://github.com/JulyFire365/splitcam/issues)
- Email: captainlongevity@gmail.com
