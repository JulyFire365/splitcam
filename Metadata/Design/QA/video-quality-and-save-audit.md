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

### Confirmed code risks in the existing recording path

1. The camera screen's `error.videoSaveFailed` ("Failed to save video") is raised in `CameraViewModel.stopRecording()` when writer completion is not `.completed`. It is not raised by the photo-library completion handler. Permission denial therefore does not directly explain that exact alert in this path.
2. Camera callbacks append video/audio on CameraEngine's serial `dataOutputQueue`, but stop marks inputs finished and calls `finishWriting` from the main actor. `composeAndWriteFrame` can still run while writer status is `.writing`; it is not gated by the UI's `isRecording` flag. The separately declared `recordingQueue` is unused. Apple requires finalization to occur after all append calls have returned: [finishWriting documentation](https://developer.apple.com/documentation/avfoundation/avassetwriter/finishwriting(completionhandler:)).
3. The asynchronous completion reads and clears `self.composedWriter` instead of the specific writer being finished. `isRecording` becomes false before completion and no processing state prevents another start. Starting a new recording during this window can make the old completion inspect/clear the new recording's writer.
4. `startWriting`, video append and audio append results are ignored; the failure message discards the writer's underlying error. `isWritingStarted` records session start, not successful frame append, so the current empty-recording guard cannot establish that a video frame was accepted.
5. Photo-library authorization denial and `performChanges` errors are currently swallowed. These are separate save-feedback defects, not evidence that the reported alert was caused by authorization.

These are credible causes of intermittent failure, but do not prove why this particular first attempt failed. They are not fixed by the quality UI/state change.

### Proposed follow-up repair (awaiting scope confirmation)

- Serialize writer creation, append, stop and finalization on one owned queue; stop accepting samples before marking inputs finished.
- Bind each completion to its own recording context and hold a finishing/saving state until it is safe to start again.
- Check writer setup/append results, track accepted video frames and keep diagnostic stage + NSError domain/code/underlying error (no user media).
- Separate encoding failures, photo-library authorization denial and photo-library write failures. Preserve an encoded file if album saving fails so retry is possible.
- Reproduce on a supported physical device: fresh install / first Photos authorization, short and normal clips, all quality presets, rapid stop/start, background transitions, denial and re-enable. Verify playable output and audio/video sync.

Do not mark the reported first-save problem resolved or the release fully verified until this investigation / repair has been completed on device.
