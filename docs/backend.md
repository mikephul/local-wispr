# Backend contract

For step-by-step configuration, start with [Connect your local models](local-model-setup.md).

local-wispr is a client for two HTTP services on the same configured host. Ports and paths are fixed; the host field accepts a hostname or IP address, without a scheme, port, or path. There is currently no authentication header, HTTPS setting, or independent host per service.

The endpoints resemble the OpenAI API, but compatibility depends on the details below. No server implementation or deployment configuration is included in this repository.

## Dictation

`POST http://HOST:8090/v1/audio/transcriptions`

The request uses `multipart/form-data` with these fields:

| Field | Value |
| --- | --- |
| `file` | AAC audio in an M4A container, filename `dictation.m4a`, content type `audio/mp4` |
| `language` | The profile's language code, such as `en` or `th` |
| `model` | The model ID selected for that profile |

Return a successful HTTP status and JSON:

```json
{"text": "Your recognized words."}
```

The total request deadline is 25 seconds. An error retains the recording for Retry or Discard. Successful completion, cancellation, discard, and normal quit remove temporary audio. A forced exit can leave it behind.

## Polish

`POST http://HOST:8080/v1/chat/completions`

Example request shape:

```json
{
  "model": "your-polish-model",
  "temperature": 0,
  "chat_template_kwargs": {"enable_thinking": false},
  "messages": [
    {"role": "system", "content": "The configured Polish instruction and dictionary guidance."},
    {"role": "user", "content": "The raw transcript."}
  ]
}
```

The server must accept or ignore `chat_template_kwargs`. Return:

```json
{"choices": [{"message": {"content": "The corrected transcript."}}]}
```

The deadline is 8 seconds. An error, malformed response, or empty result falls back to the transcript after local dictionary corrections. Raw mode skips this service entirely; exact dictionary corrections still run locally.

Light and Polished instructions are editable in LLM, with a 500-character limit on each instruction. The app appends relevant dictionary entries as JSON after that instruction, so the complete system message can exceed 500 characters. The transcript is a separate user message. Prompt instructions ask the model to preserve meaning and treat dictated content as data, but model output is not guaranteed to follow them.

## Model discovery

Both services expose `GET /v1/models`, with a 3-second deadline:

```json
{
  "data": [
    {"id": "your-speech-model", "language": "en"},
    {"id": "another-model"}
  ]
}
```

`language` is optional. Users can also enter an ID manually. IDs must be nonempty, at most 200 characters, and contain no control characters.

The English starter profile uses the example ID `parakeet-tdt-0.6b-v2`; the initial Polish ID is `pennyroyal`. These are configurable names, not bundled models or promises of availability. Replace them with IDs your servers report. All additional languages use the model ID the user selects, with no language-specific model preset. Assign shortcuts in Settings after adding a profile. Existing saved profiles retain their models, keys, and colors, including profiles from earlier English/Thai versions.

Host, language, model, Polish style, prompt, and dictionary settings are captured when recording starts, including for retries. Changes during processing do not change that request.

## Transport limits

Use a trusted local network or an encrypted VPN. HTTP does not encrypt audio or text itself. URLSession currently follows HTTP redirects, so a server can redirect requests to another host. Servers and any redirect destinations must be trusted. Direct use of an authenticated public endpoint is not supported.

Request deadlines also apply to cold model startup. Increasing server capacity or warming models may be necessary; timeout settings are not currently exposed in the app.
