# Video quality consistency and first-save investigation

Date: 2026-09-13. Baseline: `fe681a0`, SplitCam 1.8 (9).

## Quality UX and state contract

- Quality changes video encoding only: Low uses a 720-based canvas at 3 Mbps; Standard and High keep a 1080-based canvas at 12 / 25 Mbps. `currentExportSize` and the photo renderer do not use this preference.
- The camera quality button now appears only in Video mode. Both Camera and Settings open `VideoQualityPickerView`, with the same scope explanation, file-size estimates, selection and full-width hit targets. Custom separators are visual only and do not intercept taps.
- The user-facing setting is **Video Quality**, not **Default Video Quality**. There is no separate temporary camera choice.
- `AppSettings.defaultVideoQuality` remains the single source of truth. The legacy `settings.defaultVideoQuality` storage key and enum raw values are preserved. `CameraViewModel.resolutionQuality` is a computed read, not another published copy synchronized by a view lifecycle callback.
- The most recent explicit selection wins, regardless of which picker was used. It persists independently of Remember Last Capture Layout & Settings. Layout restoration and lifecycle persistence never write video quality.
- An existing writer keeps the size/bitrate established at recording start. The camera quality entry remains disabled while recording. Preference changes no longer push a new output size into an already-finishing writer via `onChange`.

The baseline simulator build already synchronized the setting and accepted a right-side blank tap in the Settings picker. The reported failure was **not reproduced** on that build / iOS 26.3. This revision makes the interaction explicit, removes the duplicate state and replaces the separate camera menu with the shared picker; it does not claim to identify an OS-specific hit-testing defect.

## First-save failure: findings, not a confirmed root cause

The user reported the first video failing to save and a second attempt succeeding. No device log, exact alert screenshot, duration, quality or permission-prompt sequence has been supplied yet. Simulator UI checks and standalone HEVC encoding are not a physical dual-camera reproduction.

### Confirmed code risks in the pre-repair recording path

1. The camera screen's `error.videoSaveFailed` ("Failed to save video") is raised in `CameraViewModel.stopRecording()` when writer completion is not `.completed`. It is not raised by the photo-library completion handler. Permission denial therefore does not directly explain that exact alert in this path.
2. Camera callbacks append video/audio on CameraEngine's serial `dataOutputQueue`, but stop marks inputs finished and calls `finishWriting` from the main actor. `composeAndWriteFrame` can still run while writer status is `.writing`; it is not gated by the UI's `isRecording` flag. The separately declared `recordingQueue` is unused. Apple requires finalization to occur after all append calls have returned: [finishWriting documentation](https://developer.apple.com/documentation/avfoundation/avassetwriter/finishwriting(completionhandler:)).
3. The asynchronous completion reads and clears `self.composedWriter` instead of the specific writer being finished. `isRecording` becomes false before completion and no processing state prevents another start. Starting a new recording during this window can make the old completion inspect/clear the new recording's writer.
4. `startWriting`, video append and audio append results are ignored; the failure message discards the writer's underlying error. `isWritingStarted` records session start, not successful frame append, so the current empty-recording guard cannot establish that a video frame was accepted.
5. Photo-library authorization denial and `performChanges` errors are currently swallowed. These are separate save-feedback defects, not evidence that the reported alert was caused by authorization.

These are credible causes of intermittent failure, but do not prove why this particular first attempt failed. The initial quality-only change did not address them; the authorized follow-up below does.

### Authorized follow-up repair implemented

- `VideoRecordingSession` owns creation, appends and finalization on one serial queue. Stop waits for in-flight appends, closes the sample gate, then finishes the captured writer. Recording IDs keep stale completions from affecting another recording. Output dimensions are immutable for each recording.
- `CameraRecordingComposer` snapshots layout and camera frames behind a lock; composition runs on the writer queue instead of reading main-actor view-model state from capture callbacks. Its layout/fit/mask geometry is preserved.
- The camera stays in a finishing/saving state until the asynchronous operation settles; new capture is blocked in that state. Empty recordings have a distinct error, and single-frame clips have a positive duration.
- Writer setup and append results are checked. `VideoSave` diagnostics record stage, accepted-frame count and NSError domain/code/underlying codes, never media, filenames, URLs or error userInfo.
- `VideoAlbumSaver` distinguishes denied/restricted Photos access from album write failures. Finalized files are retained under Application Support until Photos confirms success. The alert and a counted camera action support retry without re-recording; pending files are rediscovered after relaunch.
- A background task covers finalization/saving. A playable staging file left between encoding and its ready rename is recovered on next setup. This is bounded background time, not a guarantee against the OS terminating an in-progress encode.

### Regression evidence and remaining limits

- `Tools/ValidateRecordingSave.swift` passed real HEVC/AAC encode/decode at all three qualities, 12 consecutive single-frame recordings, empty recording rejection, an append held in flight while stop is requested, late-frame rejection, stale finish isolation and existing-file protection.
- Its injected Photos adapter passed first authorization granted/denied, restricted access, write failure, durable retention, completed staging recovery and successful retry/cleanup. It does not write to the real photo library.
- The simulator-only `-preview-screen recording-check` harness passed the production CameraEngine callback → composer → writer → view-model save flow with synthetic frames. It verified processing locks, denial, model recreation, album failure, retry, thumbnail creation and subsequent recordings. The real camera alert's Retry Save action was tapped and its pending badge disappeared on success.
- Still required on a supported physical device: fresh-install first Photos authorization, short/normal clips, all quality presets, rapid stop/start, background transitions, denial/re-enable, playable outputs and audio/video sync, including PiP/duet.

The identified code risks are repaired and the automated/simulator regressions pass. The original incident's exact cause is not proven; do not describe a physical-device first-save regression as passed until it is actually run.
