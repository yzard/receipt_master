# 合并后端验证与 NAS 部署（2026-11-05）

已部署 `receipt-master-backend-api:20261105-unified-strata`，镜像 ID 为 `sha256:4daff3e50feabb63dd86d6dba317cbd91fd4239f1d80cf15ae753474c544d5d3`，平台 linux/amd64。镜像经本地传输到 NAS，没有推送镜像仓库。Web/APK 沿用之前已生成的产物。

## 检查结果

- 140 项 Rust 测试通过；4 项需要专门环境的测试按原设计忽略。另以真实 HTTP 请求运行下述 OCR 验证。
- 37 项 Python 测试通过（构建/清理 27、配置 2、维护工具 8）。Rust 格式检查和 Clippy 通过。
- 最终镜像 HTTP smoke 通过：登录、强制改密、权限隔离、照片上传/旋转、任务、报表、APK/更新文件哈希、运行 UID/权限及用户清理。
- 新增大请求回归：服务端等待 35 秒后才读取 16 MiB 请求体，请求成功。

第一轮真实冷加载暴露了 Linux reqwest 默认 30 秒 TCP 上传超时：共享代理在模型加载完成前暂不接收大图片，连接先被关闭。修复后 TCP 超时与 API 请求超时使用同一配置；默认及 NAS 的 `[general].timeout_seconds` 均为 1800 秒。没有修改共享 Strata 服务的生命周期配置。

## 真实图片

使用版本库已有确认收据，在独立数据目录测试最终镜像，经共享 Strata `qwen3.8-flash-next-iq3_s` 推理：

| 收据 | 返回状态 | 总额 | 耗时 |
|---|---:|---:|---:|
| H MART | 200 | 33.96 | 39.40 秒 |
| Costco 退款 | 200 | -16.99 | 26.42 秒 |
| skyFOODS | 200 | 6.41 | 31.79 秒 |

三张总额均与已确认记录一致。H MART 输出显式拆分了四行优惠，商品金额标记为包含优惠的净额，所以原始行数与旧快照不同；不能将 HTTP 成功等同于全字段精度验收。本次是三张样例验证，不是完整语料准确率评测。

另测试 skyFOODS 的照片上传 → 持久任务 → 店铺识别 → OCR → 自动保存草稿，最终为 `applied`，店铺 skyFOODS、总额 641 分、3 行。测试容器已停止，临时的含密钥配置已移除，未改写线上收据。

## NAS

- 只重建 `receipts` 服务；其他服务未重启。
- `/data/docker/2_home_service.yaml` 使用上述固定版本镜像，删除旧 `BACKEND_OCR_*` 环境配置。
- `/data/docker/data/receipts/config.toml` 使用 `[inference]`，地址 `http://192.168.1.20:8080/v1`，共享服务真实密钥仅保存在私有 TOML 中。
- JWT 签名密钥保留；配置权限 `1002:1003 / 0600`。
- HTTPS 网页与 `/health` 返回 200；新容器使用配置中的凭据访问共享 `/v1/models` 成功，模型 ID 相符。
- 部署前一致性备份：`nas:/data/docker/receipt-unified-backup-20261105-154807/`。包含完整数据归档、旧/新配置、Compose、旧镜像 ID 和验证记录。
- 部署前后 `auth.sqlite`、`receipts.sqlite` 各表行数一致，数据库完整性检查通过；389 个媒体及提示文件哈希一致。
- desk 的旧 `receipt-master-ocr-backend_ocr-1` 已停止，容器和镜像保留供回退；共享 Strata 服务未停止。

详细测试输出保存在本地 `build/backend_api/` 和 desk 的独立构建目录 `/home/zyin/dev/receipt-master-unified-build/`，包含私有票据输出，不随文档公开。

## 64K 视觉、32K 输出与押金复核

同一组 NAS 快照 30 张收据在视觉预算 65536、输出预算 32768 下全部返回成功，总额 30/30、时间 29/30 与确认记录一致。仍有明细差异，不能视为全字段准确率 100%。测试仅写入独立副本。

华联 $51.23 样例原始模型返回漏了 $2.00 瓶押金。加强通用及华联提示词，并增加独立的一次金额复核后，该原图实测首轮即返回 `40*0.05 RV`、`kind=deposit`、`amount=2.00`；15 行合计 $51.23，未触发复核，总流程 291.97 秒。金额复核的成功恢复、仍不一致及无需重试路径由回归测试覆盖。完整 backend tests、fmt、clippy 通过。
