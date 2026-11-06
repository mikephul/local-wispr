# Release and publication checks

Reviewed on 2026-11-06 for version 1.3.0, build 6.

## Source publication

This repository starts with a clean source snapshot and fresh Git history. The initial commit uses a GitHub noreply author address. Personal workstation addresses, home-directory paths, work email addresses, old UI screenshots, local signing configuration, recordings, diagnostics, and build outputs are excluded. The project copyright uses the project contributor name. Required third-party copyright and license notices remain intact.

Run `python3 scripts/check-public.py --history` before publishing changes. This checks selected credential patterns, private/shared IPv4 addresses, home paths, and sensitive filenames. It does not prove that every possible secret format is absent. Inspect binary assets and commit metadata separately. The app artwork retains image provenance metadata with the certificate issuer's contact details, not a project contributor's contact address.

The repository is initially private. Public source publication is separate from a signed, notarized binary release.

## Verification

- Swift suite: 86 tests executed, 82 passed, four optional integration/benchmark checks skipped by default.
- Five Python publication-check tests passed.
- Signed Release build passed. Model catalog and license resources are bundled, and SwiftPM and Xcode lockfiles agree.
- Explicit Whisper Base testing downloaded and verified the model, recognized synthetic speech, and recognized it again in a new engine with HTTP blocked. No inference HTTP requests were observed.
- Explicit model lifecycle tests passed: shared preparation and transcription, reuse, mid-operation cancellation and recovery, idle unloading, and reloading.
- The development app retained its signing identity, microphone, Input Monitoring, and Accessibility permissions.

## Local Dictation performance

The app prepares the selected model in the background and reuses it between dictations. It releases the model after five idle minutes. File hashes are checked on each fresh load. Local inference never falls back to server Dictation; server Polish requires explicit opt-in.

On a 5.7-second synthetic English clip, repeated warm calls measured 0.138 seconds for Whisper Base and 0.356 seconds for Whisper Small. Before reuse, the first measured model loads took 6.873 and 19.156 seconds respectively. These measurements depend on the device, speech, and Core ML cache. Initial preparation after a download or cache eviction can still be slow.

## Remaining release checks

- Physical microphone disconnect/reconnect, Bluetooth format changes, and whispered speech with silence skipping on and off.
- Download cancellation and retry with interrupted networks.
- Physical shortcuts and text insertion across native and browser apps.
- Recognition accuracy across languages and real microphone recordings.
- Supported macOS versions, Intel server mode, multiple displays, and accessibility behavior.
- Developer ID signing, notarization, and installer verification before distributing public app downloads.

## Known limitations

Server transport uses HTTP on fixed ports without API-key authentication and follows redirects. Use trusted servers and networks or an encrypted VPN. History and dictionary are plaintext; crashes can leave temporary audio. Clipboard readers can observe dictated text. See [SECURITY.md](../SECURITY.md) for storage and transport details.

Silence skipping is a level gate, not a speech classifier. Large-history persistence and meter-driven view updates remain performance follow-ups. This review is not a penetration test or a formal security certification.
