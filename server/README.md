# Keepsake server integrations

This directory contains the current standalone FastAPI service used by the iPhone
app's live speech/webhook and Create features. It is separate from the versioned,
self-hosted raw-chunk API in [`../backend/`](../backend/README.md).

## Run locally

Use Python 3.11 or newer and create an isolated environment:

```sh
cd server
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
export WEBHOOK_AUTH_TOKEN="$(openssl rand -hex 32)"
.venv/bin/uvicorn omi_server:app --host 127.0.0.1 --port 8000
```

For public deployment, place the service behind an HTTPS reverse proxy and bind
to a private interface. Set secrets in the deployment environment, never in source
control. Optional integrations read `SARVAM_API_KEY`, `POSTS_API_TOKEN`, and the X
OAuth credentials `X_API_KEY`, `X_API_SECRET`, `X_ACCESS_TOKEN`, and
`X_ACCESS_TOKEN_SECRET`. Configure only the services you use. The decision service
also has separate model/runtime requirements and is not started by the webhook API.

The app's live/checkpoint webhook uses the configured HTTPS URL and bearer token.
The Create feature uses its own bearer token. Set these values in the iPhone app's
server settings; they are stored in Keychain. Keep tokens private and rotate them
if they are exposed.

## Files

- `omi_server.py`: webhook, speech streaming, transcript/decision and Create routes.
- `server_audio_gate.py`: server-side audio gate and optional speech preprocessing.
- `social_posts.py`: X post draft/publishing integration.
- `decision_service.py`: optional classifier service entry point.
- `models/`: model file and its license/usage notes.

## Data

The service may process audio, transcripts and generated posts. Configure its
storage, retention, backups and network access for your deployment. Do not place
production `.env` files, databases, recordings or credentials in this directory.

This integration service has evolved alongside a private deployment. Treat its
routes and deployment assumptions as distinct from the documented raw-chunk
contract in `backend/`; verify the matching endpoint before configuring an app.
