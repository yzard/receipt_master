# Receipt Master

## 第二版：后端统一存储

第二版将 SQLite、收据照片、识别结果与报表集中到 Rust `backend_api`。Android/iOS 共用 API 客户端，不再维护本地业务数据库；旧测试数据不迁移。

- 计划与验收：[docs/2nd_plan.md](docs/2nd_plan.md)
- 接口与持久化：[docs/backend_api_v2.md](docs/backend_api_v2.md)
- OCR/模型部署：[docs/backend_ocr.md](docs/backend_ocr.md)
- 镜像内置商店 Logo 样本和可配置提示词，空数据库首次启动即可使用；现有 Alias 不会因重启被覆盖。

### 构建和运行

```bash
./build_docker.sh
./run_playground.sh
```

`build_docker.sh` 执行后端检查、Docker 内 Android 构建，并构建 API/OCR 两个镜像。`run_playground.sh` 总是先构建，再以前台 Compose 启动服务并持续显示日志；Ctrl+C 停止服务，保留数据。iOS 使用独立的 `build_ios.sh /absolute/path/to/flutter`，需要 macOS/Xcode。
启动脚本向两个容器传入当前用户的 `PUID` 和 `GUID`，服务以该 UID/GID 运行。直接使用 Compose 时需先设置这两个环境变量。

### 数据和地址

- 宿主 `playground/backend_api/` → API 容器 `/data`，存放 `config.toml`、`prompt.toml`、SQLite、收据照片、识别结果和备份。
- 宿主 `playground/backend_ocr/` → OCR 容器 `/data`，仅存放该服务的 `config.toml`；模型权重随 OCR 镜像提供。
- `0.0.0.0:5000` → API 容器 `8000`；启动脚本打印实际宿主网络地址。手机使用同一网络可达的 host 和 port。
- OCR 只在 Docker 内部网络通信；Qwen3.8-27B NVFP4 模型权重（同时负责 Logo 图片匹配）打包在 OCR 镜像中，API 不运行模型。
- 下载 `/receipt_master.apk`。安装包预置后端地址和认证密钥；设置页“检查客户端更新”从同一服务检查版本和哈希，再交 Android 安装器确认。
- 试用密钥可从 APK 提取，持有者共享这个个人工作区。不要把它当多用户身份隔离。

### 使用

拍照/选图 → 上传并保留原图 → 发起后端识别 → 黄标核对并编辑 → 确认保存 → 按类别、商品、日/周/月/季度/年查看报告。识别任务在服务器运行，关闭客户端后可重新查看结果。

断网不会伪装保存成功。待上传照片保留在手机，可通过设置页重试；业务记录以服务器为准。整体恢复影响所有连接同一后端的设备，恢复前服务器自动留备份。

构建要求、第一版历史和之前验证记录保留在 `docs/implementation_status.md` 与 `docs/1st_plan.md`。

API 连接与认证配置在 [API config.toml](playground/backend_api/config.toml)；模型和推理参数配置在 [OCR config.toml](playground/backend_ocr/config.toml)。客户端只负责认证、采集、提交任务、编辑和显示服务器结果。

## OCR 回归评测

[真实票据测试与运行方式](tests/backend_api/corpus/README.md) · [修正确认数据后的 OCR 对比](docs/corrected_ocr_comparison.md) · [旧标准模型比较](docs/confirmed_ocr_comparison.md)

当前：[Qwen3.8 / NInfer 与可配置提示架构](docs/backend_ocr.md)。历史对照：[Unlimited-OCR / PP-OCRv6](docs/ocr_model_comparison.md)。

Logo 定位/比对及通用与商店提示配置：[playground/backend_api/prompt.toml](playground/backend_api/prompt.toml)，采用 `[[general]]` / `[[store]]`，修改后重启 API。模型开启 thinking，旧双 OCR 与 parser 已移除。
