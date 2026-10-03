# Optional Codex CLI connection · 0928v1

The UI's copied `OPENAI_BASE_URL` and `OPENAI_API_KEY` describe a generic Responses client connection. They do not select a custom Codex CLI provider or guarantee that an already signed-in CLI stops using its existing ChatGPT authentication. They do not change Codex Desktop.

For an explicit isolated CLI session, use a separate CODEX_HOME and a custom provider whose `env_key` names the local proxy key. Replace the port, key and model with the running queue's values. Use a model shown by authenticated GET /v1/models. Run in an intended disposable working directory; no central config/auth file needs editing.

```sh
proxy_home="$(mktemp -d)"
CODEX_HOME="$proxy_home" AIGOODBRO_PROXY_KEY='REPLACE_WITH_LOCAL_PROXY_KEY' \
  codex exec --ignore-user-config --ignore-rules --ephemeral \
  --skip-git-repo-check --sandbox read-only \
  --model 'REPLACE_WITH_QUEUE_MODEL' \
  -c 'model_provider="aigoodbro_local"' \
  -c 'model_providers.aigoodbro_local={name="AiGoodBro Local",base_url="http://127.0.0.1:REPLACE_PORT/v1",env_key="AIGOODBRO_PROXY_KEY",wire_api="responses",requires_openai_auth=false,supports_websockets=false,request_max_retries=0,stream_max_retries=0}' \
  -c 'check_for_update_on_startup=false' \
  'Reply with a short greeting. Do not call tools.'
```

The custom-provider fields and isolated invocation pattern were exercised in the existing standalone CLI fixture using bundled codex-cli 0.155.0-alpha.16.4. This document adds no new live-model verification. Other CLI versions may differ in their support for the isolation flags.

The current proxy exposes Responses HTTP/SSE, responses/compact and models; WebSockets are unavailable. AiGoodBro's separate Connect Desktop entry uses the packaged app-server adapter after Codex exits. Do not describe protocol fixtures as full Desktop UI acceptance. The directory created by mktemp contains only this isolated CLI session's state and can be removed after the session if no output is needed.
