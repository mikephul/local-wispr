# Connect your local models

**No endpoint?** Select **LLM → On this Mac**, download Whisper Base or Small, and leave server Polish off. On-device Dictation requires Apple silicon. The rest of this guide covers the optional server setup.

local-wispr records on your Mac and sends requests to model servers you run. You need a speech-to-text server for Dictation. Polish is optional and uses a separate chat-model service.

This guide applies to version 1.1.0. It covers the app's current endpoint settings; it does not install models or change your server configuration automatically.

## 1. Choose where the servers run

| Deployment | Enter in the app's LLM → Server field |
| --- | --- |
| Both services run on this Mac | `127.0.0.1` |
| Both services run on another machine | That machine's reachable hostname or IP, for example `inference.local` |
| Services run behind a VPN | The server's reachable VPN hostname or IP |

Enter **only the hostname or IP**. Do not paste a full URL such as `http://localhost:8090/v1`.

The app constructs these URLs:

| Service | Request | URL |
| --- | --- | --- |
| Dictation | Discover model IDs | `http://HOST:8090/v1/models` |
| Dictation | Transcribe audio | `http://HOST:8090/v1/audio/transcriptions` |
| Polish | Discover model IDs | `http://HOST:8080/v1/models` |
| Polish | Correct text | `http://HOST:8080/v1/chat/completions` |

**Both services must be reachable on the same host, using these ports.** Version 1.1.0 does not offer separate endpoint URLs, custom ports, HTTPS, or API-key fields. If your services use different hosts or ports, change their listening ports or place a reverse proxy in front of them. The proxy must forward the paths above without adding another `/v1` prefix.

For another machine to connect, the server must listen on a reachable network interface, not only its own loopback address. Keep access restricted to your Mac or trusted VPN. HTTP itself does not encrypt the audio or transcript, and local-wispr cannot authenticate to a server that requires a token. See [SECURITY.md](../SECURITY.md).

## 2. Prepare Dictation

Your speech server must accept multipart AAC/M4A uploads, a `language` code, and a `model` ID at `/v1/audio/transcriptions`. It must return JSON with a `text` field. A text-only chat server does not provide this capability just because it offers OpenAI-compatible chat endpoints.

Choose a model that supports the languages you intend to dictate. Multilingual models can be assigned to more than one language profile. Language-specific models should only be assigned to compatible profiles.

### Example server: Speaches

[Speaches publishes installation instructions for CPU and CUDA deployments](https://speaches.ai/installation/). Follow the variant for your server. Its documented container port is 8000; when running on the same Mac, map it to the port local-wispr expects:

```text
127.0.0.1:8090:8000
```

Use that as the Docker `--publish` value in place of `8000:8000`. For a separate workstation, bind the published port to the appropriate trusted interface instead of loopback.

Install an ASR model using the server's own model-management commands. Speaches distinguishes models available in its registry from installed models returned by `/v1/models`; see its [model discovery guide](https://speaches.ai/usage/model-discovery/). Copy the installed model's exact ID into local-wispr. Confirm M4A decoding with the test below before relying on any server/model combination.

These are configuration examples based on the server documentation, not a bundled or automatically tested deployment.

## 3. Prepare Polish, or skip it

Polish needs a model that handles text instructions and supports `/v1/chat/completions`. Use a model that understands your dictation languages. The app sends the raw transcript, your Light or Polished instruction, and relevant dictionary entries.

### Example server: LM Studio

Download and load a suitable chat model in LM Studio, then start its local server from the Developer tab. With the `lms` CLI installed, you can set the port explicitly:

```sh
lms server start --port 8080 --bind 127.0.0.1
```

If the server is already running on another port, stop it before restarting with the new port. This loopback example is for services on the same Mac. See LM Studio's [server guide](https://lmstudio.ai/docs/developer/core/server) and [server-start options](https://lmstudio.ai/docs/cli/serve/server-start) for network binding and port configuration.

Use the model ID reported by `/v1/models`, which may differ from the model's display name or filename. Run the request test below to confirm that your server accepts the exact request fields local-wispr sends.

### Dictation without a chat model

In local-wispr, set **Settings → your language → Polish → Raw** for each language that should skip Polish. Dictation still works with only port 8090 available. The Polish connection check may report unavailable; that is expected when no chat server is running.

## 4. Check the endpoints from your Mac

Run these commands on the Mac where local-wispr runs. Replace the host if necessary:

```sh
WISPR_HOST=127.0.0.1
curl --fail-with-body --max-time 3 "http://${WISPR_HOST}:8090/v1/models"
curl --fail-with-body --max-time 3 "http://${WISPR_HOST}:8080/v1/models"
```

A model list should contain `data` entries with `id` values:

```json
{"data": [{"id": "your-model-id"}]}
```

Use each service's own IDs; a Dictation model ID is not necessarily a valid Polish model ID.

### Test Dictation

Record a short, non-sensitive M4A sample. Replace the file path, model ID, and language code:

```sh
curl --fail-with-body --max-time 25 \
  "http://${WISPR_HOST}:8090/v1/audio/transcriptions" \
  --form 'file=@/path/to/sample.m4a;type=audio/mp4' \
  --form-string 'model=your-dictation-model-id' \
  --form-string 'language=en'
```

The expected shape is `{"text":"Your recognized words."}`. If the server only accepts WAV, it needs an adapter that converts M4A before invoking that model. Changing the filename extension does not convert audio.

### Test Polish

Replace `your-polish-model-id` in this request:

```sh
curl --fail-with-body --max-time 8 \
  "http://${WISPR_HOST}:8080/v1/chat/completions" \
  --header 'Content-Type: application/json' \
  --data '{
    "model": "your-polish-model-id",
    "temperature": 0,
    "chat_template_kwargs": {"enable_thinking": false},
    "messages": [
      {"role": "system", "content": "Fix punctuation. Preserve meaning. Output only the corrected text."},
      {"role": "user", "content": "hello this is a test"}
    ]
  }'
```

The result must contain text in `choices[0].message.content`. The server must accept or ignore `chat_template_kwargs`. If it rejects that field, adapt the request at your proxy or use a compatible server. The app does not currently offer provider-specific request formats.

## 5. Select models in local-wispr

1. Open **LLM**, enter your host, and click **Check connection**.
2. Under **Dictation**, choose a reported model for English, or enter its exact ID and click **Save**.
3. Use **Add language** for more languages. Select a language or enter its code, then choose a compatible Dictation model. Assign its shortcuts in Settings.
4. Under **Polish**, select the chat model shared by all profiles. Choose Raw, Light, or Polished independently for each language in Settings.
5. Open **Setup & test**, check permissions and shortcuts, then try dictation in the test box.

The initial model names are examples. Replace them with your server's IDs even when the connection check succeeds. Selecting a model in local-wispr does not download or load it on the server.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Connection refused | Server process, listening port, container port mapping, and configured host. |
| Works on the server but not the Mac | Bind address, firewall rules, VPN routing, and whether you accidentally used the server's loopback address on the Mac. |
| HTTP 401 or 403 | The server requires authentication. The app has no API-key setting. |
| HTTP 404 | Wrong service, unsupported path, or proxy path rewriting. A chat endpoint alone cannot transcribe audio. |
| Model missing or unknown model | Download/load the model on the server, check `/v1/models`, and copy the exact ID. Manual entry does not install a model. |
| Audio rejected | Confirm M4A/AAC decoding, multipart support, and the `language` and `model` fields. |
| Raw text appears with “Polish unavailable” | Test the chat endpoint, selected model, extra request fields, and response shape. The app keeps the raw transcript when Polish fails. |
| Requests time out | Warm the model before testing. The app allows 25 seconds for Dictation and 8 seconds for Polish; model discovery allows 3 seconds. |

For response schemas, prompt construction, retry behavior, and transport limits, see the [backend contract](backend.md).
