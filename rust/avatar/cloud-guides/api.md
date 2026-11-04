# Cloud API v1 — Private Host Control Plane

Implementation: `rust/avatar/scripts/cloud/`. Served by the existing `server.mjs` loopback host, bundled through `package-app.py`. No new packages or public listening address. The native AppKit panel uses `native-host.mjs` over private stdin/stdout, reusing this service without exposing another listener. That bridge supports catalog and consent-gated FASHN create/poll/stop; it rejects realtime room creation with `MEDIA_NOT_CONNECTED`. This API manages cloud control operations only; it does not yet stream media into CallBridge.

## Authentication and limits

Exact Host: `127.0.0.1:<assigned port>`. Cross-site Origin/Fetch-Metadata is rejected. `GET /cloud/v1/info` returns the in-memory local token; all other cloud routes require `X-CB-Token`. POST requires the exact local Origin. No CORS. GET is read-only and offline. All JSON responses use `Cache-Control: no-store`.

The host boundary is browser-origin protection, not isolation from other local processes. Do not expose the listener with a tunnel. A trusted local caller must still explicitly authorize cloud processing/billing. Input body ≤512 KiB, read deadline 800ms; upstream JSON ≤1 MiB with a 15s deadline covering body consumption. Redirects are rejected. Provider endpoints cannot be supplied by a caller. One unresolved session/job per host, up to 32 retained terminal snapshots. Max duration 10–600 seconds (default 120); provider-plan limits may be stricter.

## Routes

| Method | Path | Meaning |
| --- | --- | --- |
| GET | `/cloud/v1/info` | Local token, schema=1, mediaConnected=false |
| GET | `/cloud/v1/providers` | Eight providers, configured state, control-plane/planned capability; no network |
| POST | `/cloud/v1/sessions` | Explicitly create a provider token/session/job |
| GET | `/cloud/v1/sessions/{id}` | Local snapshot without transport secrets; no network |
| POST | `/cloud/v1/sessions/{id}/poll` | FASHN status request; no automatic polling |
| POST | `/cloud/v1/sessions/{id}/stop` | Provider-specific stop; inspect resulting state |

POST create uses `Content-Type: application/json` and rejects unknown top-level/parameter fields. Credentials are never accepted in JSON. Example payload (not an executed call):

```json
{
  "provider": "liveavatar",
  "params": {"avatarId": "YOUR_EXISTING_AVATAR_UUID"},
  "maxSeconds": 120,
  "consent": {"cloudProcessing": true, "billing": true}
}
```

| Provider | Params | Host credential | Create result |
| --- | --- | --- | --- |
| decart | `model`: `lucy-vton-3.6` or `lucy-vton-3.5` | `CB_DECART_API_KEY` | `connection.type=decart-token`, signed `token`, ephemeral `apiKey`, `expiresAt`, model |
| liveavatar | `avatarId` | `CB_LIVEAVATAR_API_KEY` | `connection.type=livekit`, URL/clientToken, optional controlUrl |
| tavus | `faceId`, `palId`, optional `context` ≤2,000 characters | `CB_TAVUS_API_KEY` | `connection.type=daily`, private URL/meetingToken |
| fashn | `personImage`, `garmentImage`: PNG/JPEG/WebP data URI, each ≤250,000 characters | `CB_FASHN_API_KEY` | `connection.type=image-job`; poll returns HTTPS output URL |

Every create response includes a local `id`, provider, state, maxSeconds, createdAt, error, remoteMayBeActive, mediaConnected=false and outputActive=false. No response claims physical capture, final composition or remote call receipt. The frontend must treat connection descriptors as untrusted transport data, load a pinned compatible SDK, and apply a reviewed endpoint/CSP policy; do not embed arbitrary returned URLs as web content. Current CSP remains local-only, intentionally preventing an unreviewed browser cloud connection.

Create after explicit permission, not page load. Do not attach raw microphone/camera tracks on initialization. Permanent keys are never sent to browser UI. Local snapshots never return keys, session tokens or user images. Create responses contain ephemeral transport credentials and must not be logged/persisted. Decart SDK token use should follow the pinned SDK's current signed-token contract; no automatic reconnect permission is implied.

## Failures and stop semantics

Errors return `{ "error": "CODE", "sessionId": "optional-local-id" }`; raw provider bodies are discarded. `CREDENTIAL_MISSING`=409, `CONSENT_REQUIRED`=403, `ADAPTER_NOT_IMPLEMENTED`=501, invalid fields=400, upstream errors=502. Credential rejection, credits exhaustion, rate limit, network timeout, unexpected schema, unknown creation and failed cleanup are distinct. Never automatically retry creation after a network failure; it may have created a billable remote resource.

- LiveAvatar: create token → start; cleanup by API key + remote session ID. A partial start failure triggers cleanup when an ID is known. HTTP success with a non-success application code is not considered stopped.
- Tavus: private conversation, recording disabled, provider duration/absence limits; end via `/end`, never delete. No meeting URL accepted.
- Decart: only token issuance is implemented. Stop returns `client_disconnect_required` until the token issuance/session-duration window expires. This is not proof that a remote SDK disconnected; frontend must close its own connection. Minted tokens cannot be revoked.
- FASHN: no documented cancel is implemented. Stop returns `remote_job_pending`; continue explicit poll or check the dashboard. Do not automatically download/import the result.
- Ambiguous creation without a provider ID: `creation_unknown` blocks new sessions. Check the provider account before restarting the host. The unknown remote resource may outlive the host.

Sources and provider-specific instructions: [user guide index](README.md). Decart REST mapping additionally checked against [official Python SDK](https://github.com/DecartAI/decart-python/blob/main/decart/tokens/client.py); do not treat SDK marketing examples as CallBridge test results.
