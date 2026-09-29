# 一次性税码长度更新

税码可留空；非空税码允许 1–3 个字符。新库使用当前 `schema.sql`，服务启动不执行税码迁移。

已有库使用 `src/backend_api/tools/expand_tax_codes.py`，先停止 backend_api，再执行：

```bash
python3 src/backend_api/tools/expand_tax_codes.py \
  --data-dir /path/to/backend_api/data \
  --backup-dir /path/to/new/backup-directory
```

脚本更新 `database/receipts.sqlite` 及 `users/*/database/receipts.sqlite`。先检查所有数据库并备份，再逐库事务重建 `line_tax_code` 的 CHECK 约束；保留外键、索引和触发器。提交前检查所有业务表内容指纹、SQLite 完整性和外键，数据库版本号保持不变。已更新的库会跳过，备份不会被覆盖。

使用数据库所属的服务 UID/PGID 执行，确保能够访问 SQLite WAL 和锁文件。更新后启动新 API 镜像；Android/iOS 和 Web 输入页以及 OCR JSON 校验均允许最多 3 个字符。

NAS 已于 2026-09-29 完成更新：100 张收据、334 条税码记录保留，所有业务表内容指纹与更新前一致。备份位于 `/data/docker/data/receipts/backups/receipts-tax-code-backup-20260929-165952/`，包括原数据库和原提示词。随后通过 `./update.sh 2_home_service.yaml` 部署新 API 镜像，其内嵌 Android APK 构建号为 10073。
