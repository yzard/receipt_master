# NAS deployment

Receipt Master now deploys one backend API image. Shared Strata inference runs independently on desk; see [configuration and migration](shared_inference.md).

The existing NAS service is `receipts` in `/data/docker/2_home_service.yaml`, with `/data/docker/data/receipts:/data`. Preserve this mount, existing account/database/photo data, JWT signing secret, and `prompt.toml`. APKs and update files remain in the API image.

Keep the existing `download_network` and Caddy routing from `receipts.zhuoyin.info` to container port 8000, and the existing `PUID`/`PGID` from `lsio.env`. No new public inference port is needed on the NAS.

Before deploying a tested image, replace `[ocr]` in the mounted `config.toml` with the complete `[inference]` template. Set `base_url` to the reachable desk address including `/v1`, the shared service API key, and its model ID. Keep the file private (0600). Remove `BACKEND_OCR_URL` and `BACKEND_OCR_API_KEY` from deployment environment settings; configuration now comes only from TOML. Do not reuse the retired OCR service key.

Do not start a Receipt Master OCR container. Shared model loading, unloading and GPU allocation belong to local_llm. The tested image `receipt-master-backend-api:20261105-unified-strata` was deployed on 2026-11-05. The NAS configuration uses `http://192.168.1.20:8080/v1`, model `qwen3.8-flash-next-iq3_s`, and a 1800-second inference timeout. Existing transfer and registry policies are unchanged; no registry push was performed. See [validation results](unified_backend_validation.md).
