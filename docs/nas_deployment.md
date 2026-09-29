# NAS deployment

The API runs on `nas` (`192.168.1.10`) and OCR remains on the GPU host
(`192.168.1.20`). This deployment is separate from the all-local playground.

## NAS API

`nas:/data/docker/2_home_service.yaml` defines the service and container as
`receipts`, using `zhuoyin/receipt-master-backend-api:latest`. Its only data mount
is `/data/docker/data/receipts:/data`. APKs and updates remain inside the image.
The image includes only the latest APK version and its supported ABI updates;
the build also deletes all superseded APKs from development output directories.

Images currently reach the NAS through a verified local transfer. Set
`pull_policy: never` for `receipts` so `/data/docker/update.sh` skips replacing
this image with an older registry `latest` that uses an obsolete runtime contract.
Install a new tested image before recreating this service. Registry pulls require
an explicit `--policy always` after the corresponding release has been published.

The service joins the existing `download_network`, where Caddy routes
`receipts.zhuoyin.info` to container port `8000`. It does not publish an API host
port and has no Compose `ports` or `expose` entries. The API image declares
`EXPOSE 8000` for Caddy's Docker discovery; this metadata does not publish a host
port. Read runtime identity from `env_file: ./lsio.env` and set
`BACKEND_OCR_URL` and `BACKEND_OCR_API_KEY` in the `receipts` service's
`environment` block. Keep the key in `/data/docker/.env` (mode `0600`) for
Compose interpolation; do not put it in the image or the APK. `lsio.env` sets
`PUID=1002` and `PGID=1003`. All Receipt Master entrypoints, scripts and examples
use this standard pair. The entrypoint owns data as `1002:1003` and
drops privileges before starting the Rust API. The NAS service does not set
`RESET_ADMIN_PASSWORD`, preserving the admin password already changed by the user.

The NAS API uses neither `init: true` nor a Compose `healthcheck`. Its entrypoint
executes the Rust server directly, and the API does not spawn child processes.
Use direct HTTPS `/health` requests when verifying the deployment; disabling
periodic Docker probes does not remove this endpoint.

The data root contains `config.toml`, `prompt.toml`, `database/auth.sqlite`,
`database/receipts.sqlite`, photos, recognition results and backups. Preserve
all user subdirectories, authentication state and secrets when transferring data.
The NAS Compose service sets `BACKEND_OCR_URL=http://192.168.1.20:8000`.
Its `BACKEND_OCR_API_KEY` must match the GPU host's
`playground/backend_ocr/config.toml` `[general].api_key`. These two environment
values override the API's `[ocr]` TOML fields at startup; the TOML fields remain
the local playground defaults. Empty or invalid overrides fail startup.

After a verified data transfer and image installation, start only this service:

```bash
ssh nas 'cd /data/docker && docker compose -f 0_all.yaml up -d --no-deps --pull never receipts'
```

## Local OCR

Use `docker/nas-ocr.compose.yaml`, which inherits the maintained OCR definition
from `docker/docker-compose.yaml`. It starts only OCR and binds its authenticated
HTTP service to the specified LAN address; the native NInfer port remains private.
The standard playground still keeps OCR unpublished on its internal network.

```bash
PUID="$(id -u)" PGID="$(id -g)" \
  RECEIPT_OCR_LISTEN_IP=192.168.1.20 RECEIPT_OCR_PORT=8000 \
  docker compose -f docker/nas-ocr.compose.yaml up -d --no-build backend_ocr
```

Keep the OCR port on the private LAN; do not add an Internet proxy or router
forwarding for it. Health requests do not load the model. Inference requires
the API key embedded in each service's TOML.

## Images and Android origin

Set the APK's initial server address explicitly at build time. The current
requested default is `https://receipts.example.com/`, while the Web download
site remains `https://receipts.zhuoyin.info/`. The former is an IANA example
domain and does not currently resolve publicly; users must edit the login
address to reach the NAS until a usable service address is chosen. Existing
installations keep their saved server and credentials, and check updates from
that authenticated server. A previously saved local HTTP origin remains usable
after an upgrade; newly entered HTTP origins remain restricted.

```bash
RECEIPT_BACKEND_ENDPOINT=https://receipts.example.com/ ./build_docker.sh
```

Before transferring the API image, verify the signed APK contains the requested
address. A local playground build embeds its LAN address and must not be deployed
to the NAS as this website download:

```bash
python3 - <<'PY'
import json
from zipfile import ZipFile

with ZipFile('build/mobile/receipt_master.apk') as apk:
    defaults = json.loads(apk.read('assets/flutter_assets/resources/backend_defaults.json'))
assert defaults == {'endpoint': 'https://receipts.example.com/'}, defaults
print('APK origin verified:', defaults['endpoint'])
PY
```

The combined build checks both backends, Web and Android, then creates the
`YYYYMMDD` tags and matching `latest` aliases. Install the exact tested API
image on the NAS by registry pull or `docker image save` over SSH. A local image
transfer does not publish to a registry. When publishing explicitly, use the
existing `--publish dockerhub|github --username NAME` options to push both tags.

Validate the HTTPS route and `/health`, NAS-to-OCR readiness, SQLite integrity,
photo hashes, data ownership and rejection of unauthenticated APK downloads.
Retain the stopped source data as a rollback copy until the transfer is verified.
The initial transfer's rollback copy is
`build/nas-deployment/backend-api-source-20260929/`; the local API container was
removed after verification. The live data owner is the NAS service.

The two OCR Compose entrypoints share a project and container. While the NAS is
active, start/recreate OCR using `docker/nas-ocr.compose.yaml`. Running
`run_playground.sh` switches the OCR container back to the all-local networking
configuration, removing its NAS-facing port; it does not run the NAS deployment.
Do not run it while the NAS needs this OCR service.
