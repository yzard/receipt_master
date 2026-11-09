# NAS deployment

Receipt Master now deploys one backend API image. Shared Strata inference runs independently on desk; see [configuration and migration](shared_inference.md).

The existing NAS service is `receipts` in `/data/docker/2_home_service.yaml`, with `/data/docker/data/receipts:/data`. Preserve this mount, existing account/database/photo data, JWT signing secret, and `prompt.toml`. APKs and update files remain in the API image.

Keep the existing `download_network` and Caddy routing from `receipts.zhuoyin.info` to container port 8000, and the existing `PUID`/`PGID` from `lsio.env`. No new public inference port is needed on the NAS.

Before deploying a tested image, replace `[ocr]` in the mounted `config.toml` with the complete `[inference]` template. Set `base_url` to the reachable desk address including `/v1`, the shared service API key, and its model ID. Keep the file private (0600). Remove `BACKEND_OCR_URL` and `BACKEND_OCR_API_KEY` from deployment environment settings; configuration now comes only from TOML. Do not reuse the retired OCR service key.

Shared model loading, unloading and GPU allocation belong to `local_llm`. The NAS configuration uses `http://192.168.1.20:8080/v1` and model `qwen3.8-flash-next-iq3_s`. The inference timeout is 1800 seconds. The [validation results](unified_backend_validation.md) record the initial migration.

Publish the API image from the Receipt Master checkout after you push its source to GitHub.
GitHub Actions runs `./build_docker.sh --security-scan`. The same scans run on every publication attempt.
OSV-Scanner checks the Rust, Web, and Flutter lockfiles. Trivy checks the final image for vulnerabilities and secrets.
If a scan reports a finding or fails to complete, the script stops before it updates `latest` or pushes a tag.

```sh
RECEIPT_BACKEND_ENDPOINT=https://receipts.example.com/ \
  ./build_docker.sh --publish dockerhub --username zhuoyin
```

Set the NAS service `image` to `zhuoyin/receipt-master-backend-api:latest` and `pull_policy` to `always`. After the script publishes both tags, pull the image and recreate `receipts` on the NAS.

```sh
cd /data/docker
docker compose -f 2_home_service.yaml pull receipts
docker compose -f 2_home_service.yaml up -d --no-deps receipts
```

Make sure that the running image matches the published digest. Check `https://receipts.zhuoyin.info/health` after the service starts.
