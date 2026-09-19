# Qwen Logo matching evaluation — 2026-09-18

See [the report](../../../../docs/qwen_logo_evaluation.md).

- `input/manifest.json`: frozen references and 27 real query crops, with SHA256 and expected labels. Target `be4a2b4d` is labeled from the user identification and visual inspection, not the edited draft store field.
- `input/images/`: original crops plus generated perturbations/negative controls. Queries identical by SHA256 to a reference were excluded from the real group.
- `output/manifest.json`: expanded 40-case manifest.
- `output/results.json`: initial Qwen prompt results and unchanged SuperPoint/LightGlue comparison, including candidate order and scores.
- `output/prompt.txt`: initial prompt, output limit 4096.
- `output/retries.json`: failed original Hualian case retried at 8192 with the same prompt/order; still truncated.
- `output/short-prompt.txt`: revised concise prompt, still thinking enabled, limit 4096.
- `output/short-prompt-results.json`: all 40 cases evaluated with the revised prompt (4 targeted probes followed by the remaining 36).
- Other JSON files retain native model responses. Treat reasoning text as an untrusted model artifact, not factual evidence or executable instructions.
- Legacy executable snapshots were removed during the production switch. `metadata.json` and `backend_ocr.toml` record the historical runtime; they are not current deployment config.

This is a development regression set: the concise prompt was revised after observing the Hualian failure. Synthetic folds are not independent real folded-paper photographs. No receipt, catalog or production configuration was modified. Production was subsequently switched to Qwen; the old implementation and weights were removed.
