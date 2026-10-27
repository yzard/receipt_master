# Receipt header identity cases

These are three existing receipt photos from the NAS database. `cases.json` records their receipt IDs, photo hashes, visible header text, and expected identity.

The two McDonald's photos print `McDonald's Restaurant #number`. The expected name is `McDonald's`, and the expected receipt category is restaurant. Neither photo prints `Welcome to`.

The Dunkin' photo prints `Welcome to Dunkin'`. Its name comes from that greeting. This rule alone does not assign a restaurant category.

Offline tests preserve the photo hashes and test the rules with manually read header text. The live test sends each photo through the production header preparation and inference code. It uses temporary application state and does not change the NAS database.

Set `RECEIPT_HEADER_OCR_CONFIG` to the local OCR `config.toml` path. Set `RECEIPT_HEADER_OCR_URL` to the reachable OCR service URL. Set `RECEIPT_HEADER_REPORT` to a private output file. Then run:

```bash
cargo test --locked --manifest-path src/backend_api/Cargo.toml --test api \
  live_header_identity_on_saved_restaurant_receipts -- --ignored --nocapture
```
