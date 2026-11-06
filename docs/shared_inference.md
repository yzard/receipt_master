# 单 API 镜像与共享 Strata 推理

Receipt Master 只构建和运行 `backend_api`。API 保留认证、数据库、任务队列、提示词、Logo 定位/匹配、收据解析和校验，并负责图片 EXIF 方向、RGB PNG 转换、多图像素预算和串行推理。不再打包模型、CUDA、NInfer 或独立 OCR HTTP 服务。

共享服务由 `desk:/home/zyin/dev/local_llm` 管理，与其他项目共用。该代理负责 Strata 模型加载、空闲卸载和跨项目资源管理。Receipt Master 不启动、停止或下载模型。

## 配置和迁移

先备份 `/data/config.toml`。保留 `[general]`（特别是 `jwt_secret`）、数据库、账号、原始照片和 `/data/prompt.toml`。删除旧 `[ocr]`，从 `docker/defaults/backend_api.toml` 复制完整 `[inference]`：

- `base_url`：OpenAI-compatible API base，包含 `/v1`，例如 `http://host.docker.internal:8080/v1`。Compose 为同机 Docker 配置 host-gateway；NAS 或其他主机必须填写可达的 desk IP/DNS。SSH 的 `desk` 别名不等于容器可用 DNS。
- `api_key`：共享服务的真实 API key，仅写入权限为 `0600` 的配置；不能使用旧 OCR 服务密钥，不写入镜像、客户端或环境变量。
- `model`：共享服务模型 ID，当前 local_llm 配置为 `qwen3.8-flash-next-iq3_s`。
- `max_images`、`image_pixel_budget`：模型允许的图片数量与单请求总像素预算，所有照片一起发送，超限报错，不丢弃页面。
- `receipt_output_tokens`、`logo_output_tokens`、`temperature`、`seed`：推理参数。默认收据/Logo 输出为 32768/4096 token，包含思考与最终答案。共享服务上下文必须容纳文字输入、视觉 token 和输出；当前 Desk 图片请求上下文为 98304、视觉上限为 65536，实际图片 token 与文字输入仍须留出输出空间。
- 可选 `thinking`：发出 `chat_template_kwargs.enable_thinking` 扩展；不支持此扩展的兼容服务应删除该字段。
- `[general].timeout_seconds`：覆盖一次模型请求的冷加载和生成，默认 1800 秒（30 分钟），底层 TCP 上传超时与此一致。

配置准备工具遇到旧 `[ocr]` 会拒绝静默迁移，不会覆盖原配置或旧 OCR 数据目录。它只为新安装生成 JWT 密钥，保留空的共享 API key 待管理员填写。此次代码更改不会修改任何现有部署配置。

API 请求 `POST {base_url}/chat/completions`，使用 Bearer 认证；本项目内部的 `profile` 不发送给模型。图片容量从配置读取，不再依赖私有 `/capabilities`。API `/health` 只检查本地业务存储；识别 readiness 使用共享服务 `/models`，不触发推理。任务直接尝试推理，失败记录为可重试任务，不因旧 `/health` 接口不存在而无限排队。全用户共用一个推理许可。

收据明细与总额可计算但不一致时，API 保留全部原图和上一轮结构化结果，额外请求一次金额复核。此复核独立于 `repair_attempts` 的格式修复预算；模型调用次数最多为 `2 + repair_attempts`。复核后仍不一致则保留原始金额和核对提醒，不生成补差额项目。调用失败或输出无效仍按正常错误处理，所有调用均记录在诊断和 token 用量中。

## 构建与测试边界

正常 `./build_docker.sh` 仍构建 Web/Android、运行检查、构建 API、执行容器 smoke，然后才更新日期及 latest 标签。发布必须显式指定 `--publish`。构建不再准备模型层或 OCR 镜像。

仅构建候选后端（需要已准备的 `build/web` 和 `build/mobile` 资源）：

```sh
docker build --target runtime -f docker/backend_api.Dockerfile \
  -t receipt-master-backend-api:20261105-unified-candidate .
```

`runtime` 只编译程序并组装镜像，不执行测试；`checks` 是独立测试阶段。候选构建不更新 latest，不推送、不启动服务、不访问共享模型。仅构建候选镜像时不自动启动测试或模型。2026-11-05 已按用户授权完成测试和 NAS 部署，见 [验证记录](unified_backend_validation.md)。历史评测目录保留为记录，不代表当前服务部署方式。
