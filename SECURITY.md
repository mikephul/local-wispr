# Security and privacy

## Where data goes

In server mode, local-wispr sends audio to the configured Dictation service and, unless Raw is selected, sends the transcript and relevant dictionary entries to the Polish service. In On this Mac mode, audio stays local; text leaves the Mac only when the user enables server Polish and chooses Light or Polished. There is no automatic fallback from local to server Dictation. It has no bundled analytics SDK or account service. Explicit model downloads contact Hugging Face and its HTTPS CDN. Model URLs pin a repository revision; each file is checked for its expected byte count and SHA-256 hash before use. Local inference loads its tokenizer from disk without a network fallback. Your server controls its own logging, retention, and onward processing.

Transport currently uses HTTP on fixed ports without API-key authentication. Use a trusted local network or an encrypted VPN. URLSession follows redirects, which can send requests to another destination chosen by the server. The app's transport policy permits HTTP and the app is not sandboxed.

Polish output may change meaning or fail to follow instructions. Review dictated text before submitting it. The app never sends Return to submit text automatically.

## Local storage

| Data | Location and retention |
| --- | --- |
| Transcripts and dictionary | Plaintext `~/Library/Application Support/LocalSTT/library.json`. Each entry can also keep up to five previous text versions. History defaults to 30 days; Settings offers 7, 30, 90 days or Forever. Dictionary entries remain until removed. |
| Downloaded models | `~/Library/Application Support/LocalSTT/Models/`. Retained until removed in LLM. Cancelled downloads keep complete files for retry. Core ML also manages its own device-specific cache. |
| Preferences | macOS UserDefaults under `com.localstt.mac`, including host, models, shortcuts, and Polish prompts. |
| Recordings | `localstt-*.m4a` in the system temporary directory. Failed transcription or an interrupted microphone can retain captured audio for retry. Success, cancellation, discard, and normal quit remove it; a crash or forced exit may leave files. |
| Diagnostics | `localstt-diagnostics.json` in the system temporary directory. Contains status, permission, shortcut, and device information. Error messages may reveal local paths. Review and redact before sharing. |
| Clipboard | Dictated text is placed on the system clipboard for insertion. After automatic insertion, the app attempts to restore previous contents after 1.5 seconds if the clipboard has not changed. Manual-paste fallback leaves the transcript on the clipboard. Other software can observe clipboard contents. |

If saved settings need recovery, the app keeps the original data in the `dictationPreferencesRecoveryBackup` UserDefaults key and displays a notice. Dismissing the notice does not delete that backup.

Retention is application-level deletion, not secure erasure. Backups may retain earlier copies. No application-level encryption protects local history or preferences.

## macOS permissions

Microphone access records speech. Input Monitoring receives global shortcuts. Accessibility enables text insertion and interaction with the original application. The app checks focus before automatic insertion, but macOS cannot confirm that every receiving app consumed a paste. Copy from Dictation if insertion fails.

Keep one installed copy and reuse its signing identity across builds. The local certificate helper changes the login Keychain only when explicitly invoked. Never share private signing keys or Keychain exports.

## Reporting a vulnerability

Do not include recordings, transcripts, tokens, or personal server addresses in public issues. If the GitHub repository has private vulnerability reporting enabled, use **Security → Report a vulnerability**. Otherwise, ask the maintainer for a private reporting channel without posting exploit details or sensitive data.

There is no published security support schedule yet. Include the commit or build version, macOS version, impact, and minimal reproduction steps. The [release audit](docs/release-audit.md) lists known limitations; this document does not claim a formal security certification.
