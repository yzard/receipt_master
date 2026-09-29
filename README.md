# Receipt Master

## 第三版：Web 与多用户账户

Web、Android 和 iOS 通过统一 API 管理收据。Rust `backend_api` 保存 SQLite、照片、目录和报表；每个账户有独立的数据空间。Web 静态资源随 API 镜像部署，不新增容器。

- 当前计划与验收：[docs/3rd_plan_web_auth.md](docs/3rd_plan_web_auth.md)
- 第二版历史：[docs/2nd_plan.md](docs/2nd_plan.md)
- 接口与持久化：[docs/backend_api_v2.md](docs/backend_api_v2.md)
- OCR/模型部署：[docs/backend_ocr.md](docs/backend_ocr.md)
- 镜像内置商店 Logo 样本和可配置提示词，空数据库首次启动即可使用；现有 Alias 不会因重启被覆盖。

### 构建和运行

```bash
./build_docker.sh
./run_playground.sh
```

`build_docker.sh` 执行后端检查、Docker 内 Android 和 Web 构建，并构建 API/OCR 两个镜像。`run_playground.sh` 总是先构建，再以前台 Compose 启动服务并持续显示日志；Ctrl+C 停止服务，保留数据。iOS 使用独立的 `build_ios.sh /absolute/path/to/flutter`，需要 macOS/Xcode。
启动脚本向两个容器传入当前用户的 `PUID` 和 `GUID`，服务以该 UID/GID 运行。直接使用 Compose 时需先设置这两个环境变量。

### 数据和地址

- 宿主 `playground/backend_api/` → API 容器 `/data`，存放 `config.toml`、`prompt.toml`、SQLite、收据照片、识别结果和备份。
- 宿主 `playground/backend_ocr/` → OCR 容器 `/data`，仅存放该服务的 `config.toml`；模型权重随 OCR 镜像提供。
- `0.0.0.0:5000` → API 容器 `8000`；启动脚本打印实际宿主网络地址。手机使用同一网络可达的 host 和 port。
- OCR 只在 Docker 内部网络通信；Qwen3.8-27B NVFP4 模型权重（同时负责 Logo 图片匹配）打包在 OCR 镜像中，API 不运行模型。
- 登录 Web 后，从侧边栏“下载 Android APK”下载 `/receipt_master.apk`；APK、更新清单和更新包都需要登录认证。安装包只预置后端地址，安装后仍需输入用户名密码；“检查客户端更新”使用手机的登录会话从同一服务检查版本和哈希。
- Web 打开 `http://localhost:5000/`；其他设备使用启动脚本打印的网络地址。
- 中央身份库为 `playground/backend_api/auth.sqlite`；admin 保留原业务数据，普通用户的数据在 `users/<UUID>/`。

### 账户和公网部署

首次启动创建 `admin`，默认密码 `admin`。首次登录必须修改为至少 12 个字符的新密码，之后才能访问业务页面。admin 是不可删除、不可改名的元用户；只有 admin 可以创建或删除其他用户。新用户首次登录也必须修改临时密码，没有公开注册入口。

忘记管理员密码时：

```bash
RESET_ADMIN_PASSWORD=true ./run_playground.sh
```

这是 **backend_api 运行时环境变量**，Compose 会传入容器。它把 admin 密码重置为 `admin`、强制改密并撤销旧会话。完成恢复后取消这个变量，否则每次启动都会再次重置。普通用户密码不受影响。

密码以 Argon2id 哈希保存。浏览器刷新会话使用 HttpOnly/SameSite cookie；手机刷新令牌保存在安全凭据存储中。JWT 签名密钥仅在 API 的 `[general].jwt_secret` 中，既不发给客户端，也不复用以前嵌入 APK 的共享密钥。OCR 服务间认证继续使用其独立 API key。

公网部署需在 API 前配置 HTTPS 反向代理，保留 `Host` 并设置 `X-Forwarded-Proto: https`；这样浏览器相机和 Secure cookie 才能正常使用。API 端口应仅由可信代理访问。先完成 admin 改密，再开放公网；OCR 端口保持内部可见。

Web 支持收据四列排序、多图拍摄/上传、异步识别、编辑确认、商品目录、商店 Logo 名称、互动趋势与明细、主题、重量和报表币种、备份恢复、CSV 以及管理员用户管理。断网的待上传照片保存在浏览器 IndexedDB，绑定原账户，恢复登录后可以重试。

部署公网域名时，在构建/启动时指定手机可访问的站点地址，例如：

```bash
RECEIPT_BACKEND_ENDPOINT=https://receipts.example.com/ ./run_playground.sh
```

将示例域名换成实际 Web 站点地址。该地址写入已签名 APK；域名或端口变更后需重新构建。Web 的登录会话、用户名和密码不会写入安装包。默认 playground 写入本机的可达网络地址，手机不能使用宿主的 `localhost`。

### 使用

拍照/选图 → 上传并保留原图 → 发起后端识别 → 黄标核对并编辑 → 确认保存 → 按类别、商品、日/周/月/季度/年查看报告。识别任务在服务器运行，关闭客户端后可重新查看结果。

断网不会伪装保存成功。待上传照片保留在手机，可通过设置页重试；业务记录以服务器为准。整体恢复只影响登录同一账户的设备，恢复前服务器自动留备份。

构建要求、第一版历史和之前验证记录保留在 `docs/implementation_status.md` 与 `docs/1st_plan.md`。

API 连接与认证配置在 [API config.toml](playground/backend_api/config.toml)；模型和推理参数配置在 [OCR config.toml](playground/backend_ocr/config.toml)。客户端只负责认证、采集、提交任务、编辑和显示服务器结果。

## OCR 回归评测

[真实票据测试与运行方式](tests/backend_api/corpus/README.md) · [修正确认数据后的 OCR 对比](docs/corrected_ocr_comparison.md) · [旧标准模型比较](docs/confirmed_ocr_comparison.md)

当前：[Qwen3.8 / NInfer 与可配置提示架构](docs/backend_ocr.md)。历史对照：[Unlimited-OCR / PP-OCRv6](docs/ocr_model_comparison.md)。

Logo 定位/比对及通用与商店提示配置：[playground/backend_api/prompt.toml](playground/backend_api/prompt.toml)，采用 `[[general]]` / `[[store]]`，修改后重启 API。模型开启 thinking，旧双 OCR 与 parser 已移除。
