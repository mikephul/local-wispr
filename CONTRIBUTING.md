# Contributing

local-wispr uses SwiftUI, AppKit, AVFoundation, Core Audio, and native keyboard/accessibility APIs. It uses pinned WhisperKit and swift-transformers packages for on-device Dictation. Commit both SwiftPM and Xcode package lockfiles when updating dependencies. The minimum macOS version is 14.

## Local checks

From the repository root:

```sh
swift test
python3 -m unittest discover -s scripts/tests
python3 scripts/check-public.py
python3 scripts/create-project.py
git diff --exit-code -- LocalSTT.xcodeproj/project.pbxproj
```

The Xcode project is generated from `Sources/LocalSTT/*.swift`. Regenerate and commit it when adding or removing source files. The build script also regenerates it before building.

For a compile check without a signing certificate:

```sh
xcodebuild -project LocalSTT.xcodeproj -scheme LocalSTT \
  -configuration Release -derivedDataPath .build/xcode-check \
  CODE_SIGNING_ALLOWED=NO REGISTER_APP_WITH_LAUNCH_SERVICES=NO build
```

An unsigned build verifies compilation; use a consistently signed app for real permission and dictation testing. CI runs the local tests, publication hygiene check, project freshness check, and unsigned Release build. Live services and microphone interaction are not tested in CI.

## Versioning

`Info.plist` is the version source of truth. Update `CFBundleShortVersionString` for the user-facing release version and increase `CFBundleVersion` for each distributed build. The sidebar, Settings, native About panel, and diagnostics read bundle metadata; do not duplicate the release number in Swift code. Swift package runs without app metadata display “Development.”

## Signing

Select an existing identity with `python3 scripts/signing.py use '<identity>'`, or explicitly run `python3 scripts/signing.py create-local` for development on your Mac.

`create-local` creates a ten-year self-signed certificate and non-exportable private key in the login Keychain, grants codesign access, and adds user-level trust for code signing only. Temporary key material is removed after import. It reuses an existing valid identity and refuses to silently replace a broken one.

The chosen fingerprint goes in ignored `Config/LocalSigning.xcconfig`. Never commit that file, certificates with private keys, or Keychain exports. Keep the identity and bundle ID stable across rebuilds. Replacing the identity or launching another app copy can require renewed permission grants.

```sh
./scripts/build.sh
python3 scripts/verify-signing.py build/Build/Products/Release/local-wispr.app
```

The verification script signs a temporary copy with changed contents, checks that the designated requirement stays the same, and leaves the built app unchanged. Locally signed builds are not a public distribution pipeline. Public downloads need a separate Developer ID signing and notarization workflow; see [Apple's distribution documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Live backend tests

Live tests are skipped unless both `STT_HOST` and `STT_FIXTURES` are set. They transmit fixture audio and transcripts to that host. Use non-sensitive fixtures you have permission to share.

```sh
STT_HOST=localhost STT_FIXTURES=/path/to/fixtures swift test --filter IntegrationTests
```

Create `fixtures.json` in that directory, alongside the referenced M4A recordings. Each entry chooses its own language, model, and expected phrase:

```json
[
  {
    "file": "sample.m4a",
    "language": "en",
    "dictationModel": "your-speech-model",
    "polishModel": "your-chat-model",
    "expectedText": "tomorrow"
  }
]
```

Add entries for any languages your server supports. Omit `polishModel` to test Dictation alone; when supplied, the test requires Polish to succeed. `expectedText` must be a nonempty phrase in the result. Recordings are not included in the repository. See the [backend contract](docs/backend.md).

## Manual verification

Use a signed app launched through Finder or `open`, so macOS attributes permissions to the app. Check:

- Permission denial and recovery, disconnected microphones, device reconnection, and microphone levels.
- Push-to-talk, double-tap hands-free, a single press to stop, Escape, and the two-minute limit.
- The English starter profile and additional languages with chosen models, including conflicting shortcut rejection, removing English, and preserving existing profiles after upgrading.
- Native and browser text insertion, changing focus while processing, and clipboard changes during paste.
- Unavailable servers, slow responses, raw fallback, retry/discard, and saved history after restart.
- Light/dark appearance, multiple displays, Dock placement, full-screen apps, and Reduce Motion.

For a two-second capture/encoding check, quit other copies of the app, then run:

```sh
open -n -W --stdout /tmp/localstt-microphone.log \
  -a "$PWD/build/Build/Products/Release/local-wispr.app" --args --verify-microphone
cat /tmp/localstt-microphone.log
```

This records temporary audio, checks decoded frames, and deletes it without sending it to a server.

## Before sharing changes

Run `python3 scripts/check-public.py`. It checks tracked and non-ignored untracked text for selected credential patterns, private IPv4 addresses, and personal home paths. It is a small hygiene check, not a comprehensive secret scanner. Inspect images and other binaries manually.

Use `python3 scripts/check-public.py --history` before publishing an existing Git history. This also checks historical blobs and reports how many distinct author/committer addresses need review, without printing those addresses. Removing a sensitive file in the latest commit does not remove previous versions.

Keep transcripts, recordings, diagnostics, signing configuration, and local review notes out of commits. Include reproduction steps and verification results in a pull request. See [SECURITY.md](SECURITY.md) for sensitive reports.

## Audio fixtures and recovery checks

`swift test --filter BatchFeaturesTests` generates temporary WAV fixtures and drives the real audio writer, silence gate, recording lifecycle, level meter, and mocked backend requests. It covers silent clips, quiet audio, cancellation, network failure/retry, interrupted capture, re-Polish, and version restoration. It opens no microphone and sends no network requests. Generated audio is test data, not speech, and does not establish recognition accuracy.

To check a prerecorded WAV through the writer and silence gate locally:

```sh
/Applications/local-wispr.app/Contents/MacOS/LocalSTT --verify-audio-fixture /path/to/test.wav
```

This command prints the frame count and keep/skip result, deletes its temporary M4A, and does not transcribe, paste, or change history. Use a short clip, up to two minutes.

Before release, also check a real microphone disconnect/reconnect, Bluetooth format changes, short and whispered speech with silence skipping on/off, paste-last in another app, and both language shortcuts. Synthetic input does not prove physical device or system-wide key behavior.

## On-device model verification

Normal tests verify provider routing, optional Polish, catalog integrity, and rejection of corrupted downloads without downloading weights. To explicitly download Whisper Base into an isolated test directory and recognize a non-sensitive speech fixture:

```sh
WISPR_LOCAL_MODEL_TEST_ROOT="$PWD/.build/local-model-test" \
WISPR_LOCAL_AUDIO_FIXTURE=/path/to/non-sensitive-speech.wav \
swift test --filter LocalDictationTests/testRealLocalModelWithNonSensitiveFixtureWhenExplicitlyEnabled
```

The fixture should include the word “local.” The test downloads about 150 MB, verifies two transcriptions with separate engine instances, and removes the test model. It does not record a microphone or contact a Dictation/Polish endpoint. Also check download cancellation/retry, model removal, restarting without internet, and local versus server routing in the app.

`Sources/LocalSTT/LocalModels.json` pins model and tokenizer files by HTTPS URL, byte count, and SHA-256. Update it deliberately when changing models; do not accept a remote manifest at runtime. Keep model licensing notices in `Resources/Licenses`.

For a read-only latency and warm-model lifecycle check using already-downloaded models:

```sh
WISPR_BENCHMARK_MODELS=/path/to/model-directory \
WISPR_LOCAL_AUDIO_FIXTURE=/path/to/non-sensitive-speech.wav \
swift test --filter 'LocalDictationTests/test(WarmModelLifecycle|LocalModelLatency)WhenExplicitlyEnabled'
```

This measures verification, loading, and decoding separately, and checks shared preparation, reuse, cancellation recovery, idle unloading, and reloading. It neither installs nor removes model files. The fixture should include “local.” Timings depend on the device, Core ML cache, and speech content.
