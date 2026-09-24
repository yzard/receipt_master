# Qwen3.8 / NInfer 生产识别

2026-09-18：生产使用 **Qwen3.8-27B NVFP4 + NInfer + thinking + 通用/商店提示配置**。Unlimited-OCR、PP-OCR、Paddle worker、Rust 通用及商店 parser 已删除；历史对比结果和原图仍保留，不是备用运行路径。

## 两个容器

- `backend_api`：Rust API、认证、SQLite `/data`、照片、持久任务队列、Logo Alias 选择、提示组合、结构校验、单位换算、金额检查、报表和 APK。
- `backend_ocr`：一个 NInfer 视觉模型；Logo 图片匹配也使用同一个 Qwen 模型。推理引擎只监听容器回环地址，内部 REST 代理只允许一个请求运行，其余排队。没有第三个服务，也没有第二个文字 OCR。

模型文件固定 revision/SHA256，NInfer 固定 commit。模型权重都包含在 OCR 镜像里，运行时不下载。`build_docker.sh` 构建 Android APK 和两个镜像；`run_playground.sh` 保持前台 Compose、持续日志与 Ctrl+C 停止的原有契约。API 发布 `0.0.0.0:5000 -> 8000`，OCR 不发布宿主端口。

## 按需加载与空闲卸载

`playground/backend_ocr/config.toml` 的 `[general]` 配置 `idle_timeout_seconds = 300`（秒，必须大于零）。修改后重启 OCR 容器生效。

- 容器启动只运行轻量 HTTP 服务，不启动 NInfer、不加载权重。
- 有效任务进入串行队列后自动启动 NInfer，等待模型就绪，再进行推理；首个任务包含模型冷启动时间。加载与推理共用 `timeout_seconds` 上限。
- 最后一个任务完成后开始空闲计时；排队、图像准备、模型加载及推理期间都不会卸载。到期终止并回收整个 NInfer 进程组，释放其显存和进程内存，保留镜像中的模型文件。
- `/health` 在未加载时也返回 200，`engine_state` 表示 `unloaded` / `loading` / `ready` / `busy` / `stopping`。健康检查不会唤醒模型或延长保留时间。
- 推理超时、取消或连接中断时终止原生进程，防止后台生成与下一个任务重叠；下一项任务可以重新启动模型。
- HTTP 服务持续可接收任务；操作系统可回收的文件页缓存不等同于 NInfer 进程仍驻留。

### 按需加载验证（2026-09-18）

- OCR 13 项测试通过，覆盖串行排队、首次启动等待、空闲卸载重载、启动失败/崩溃恢复、超时和取消的进程清理。重建时 API 101 项测试通过，另有 3 项既有忽略用例。
- Playground 启动后 `engine_state=unloaded`，无 NInfer 进程；真实图片首个请求 8.27 秒返回正确的 `$12.34`（包含冷启动）。
- 使用实际 `300` 秒配置并持续轮询健康检查，在约 302 秒的采样点确认进程退出、GPU 中无 NInfer 占用；卸载前约 23086 MiB 显存，卸载后 OCR 容器约 41 MiB 内存。
- 随后第二次请求自动启动新的 NInfer PID，8.26 秒返回相同正确结果。以上耗时仅代表这张小型测试图片及本机配置，不是完整收据的速度基准。
- 本轮在线验证没有更改现有收据。原始验证记录：`build/ocr-demand-live.log`、`build/ocr-demand-memory.log`。

## 提示配置

推理设置由 [OCR config.toml](../playground/backend_ocr/config.toml) 管理：`[engine]` 包括模型、图片上限、收据与 Logo 各自的输出 token 上限、thinking、温度和随机种子。`[general]` 包括监听地址和内嵌的 OCR 专用 `api_key`。Backend API 的 `[ocr]` 只有 URL 和同一 `api_key`。Logo 定位、Logo 图片比对、收据通用和商店专用提示词都在 [prompt.toml](../playground/backend_api/prompt.toml)；首次运行从 `docker/defaults/` 安装模板，以后保留 `/data` 内的修改。修改提示词重启 API，修改推理参数重启 OCR。

```toml
[[general]]
prompt = '''
通用的票面名称、金额、优惠、退款和多图重叠规则……
'''

[[store]]
name = "Hualian"
aliases = ["華聯", "华联"]
prompt = '''
称重行属于下一条有独立价格的商品；后续无价格的文本属于同一商品……
'''
```

`general` 至少一个，按配置顺序拼接。`store` 可为空；匹配到店名时仅附加该商店的一个提示。`aliases` 可省略。匹配忽略大小写、空白与标点，不能用子串猜商店；未知商店仅用通用提示。跨商店重复名称/别名、空提示、未知配置字段会阻止启动。

当前提供 Costco、skyFOODS、H MART、Hualian、99 Ranch 提示。其他店使用通用提示。添加商店只需添加 TOML 条目，不再编写 Rust parser。

通用提示明确独立 `TOTAL` 后的交易金额优先，排除付款、找零、奖励抵扣、SUBTOTAL/TOTAL SAVINGS 等。Hualian 提示明确称重行先暂存，关联下一条有价格商品，然后清空；中英文续行不拆成商品。

## 识别顺序

1. 手机上传图片并提交持久任务；立即返回，后台处理，客户端不等待推理。
2. Qwen 在首张照片应用 EXIF 方向后的顶部 30% 区域定位完整 Logo/文字商标。定位图片最长边为 1600 像素，使用 0–1000 整数坐标，再换算回原图归一化坐标；返回坐标，不返回店名。API 裁剪后提交查询图与参考图片，让 Qwen 返回参考编号，再从图片 Alias 库确定商店。原图库和用户 Alias 保留；每次重新识别都会重新匹配 Logo，即使草稿已有店名。匹配成功更新任务提交时的旧店名，匹配未知则保留原值；识别过程中用户新改的店名仍由任务快照合并保护。商品识别只使用本次匹配店名选择专用提示词；本次匹配未知或该店没有专用配置时使用通用提示词，不沿用旧店名的规则。
3. API 根据店名选择提示，附加固定的机器 JSON schema，并一次提交该收据全部有序照片。用户图片中的文字仅是证据，不决定商店提示路由。
4. NInfer 开启 thinking。全部照片先应用 EXIF 方向；使用无损 PNG。为适配模型上下文，多图共享 `engine.image_pixel_budget`，按照片数量分配分辨率；不丢照片。原始照片仍完整保存在 `/data`。当前支持最多 16 张、32768 上下文、8192 总输出 token（思考与答案共用）；超限明确失败，不静默截断。
5. API 只解码完整结束的输出，分离模型思考和最终 JSON；清理单个外层 Markdown 代码框，按 schema 投影删除额外字段，并在结果 `receipt_parsing.removed_fields` 记录路径。不会修正名称拼写、修改金额、猜测缺失字段或截取解释中的 JSON。
6. 必填字段、类型、金额精度、优惠引用和证据框仍严格校验。结构错误按 API 的 `general.repair_attempts` 最多补充一次协议反馈、重新请求原图；失败即失败。`model_runs` 保留每次原始响应与 token 用量。金额不平不触发猜测性重试，只添加核对提示。
7. 后端做单位换算和原有存储校验，识别结果自动进入可编辑草稿；确认后才维护商品目录。照片、商品名称、分类与数据库约束不改变。

## 保留的 Logo 资源

`src/backend_api/resources/merchants/` 与 `merchant_images.rs` 继续内置已审核 Logo 裁剪和店名。空库初始化可识别已有商店；已有库不会被内置样本覆盖。匹配使用已验证的简短提示词，只比较商标图形和文字，忽略纸张背景与拍摄变形。模型只返回本批次参考编号或 null，店名由对应图片 Alias 决定。无法定位时保存顶部候选区域供核对。

## 接口与验证

对外仍是认证的 API、异步任务和 Chat Completions。API 对外使用固定的 `receipt-master` 标识；客户端从服务器查询服务信息，不配置实际 OCR 模型或提示。内部只使用受服务密钥保护的 `/v1/chat/completions` 和 `/capabilities`；旧 `/v1/logo/match` 已删除。

运行代码和测试不依赖旧 parser。保留历史模型评测归档；离线候选评分只接收已经生成的结构化预测。新回归覆盖 32 张 thinking 输出的字段投影、严格校验、错误/截断拒绝、商店提示隔离、Logo 先于商品识别、多图同请求、串行队列和 API 响应性。

[模型实验结果](ninfer_prompt_thinking_evaluation.md) 是切换前基线；其中两张额外字段失败已由本次生产适配解决。它不代表所有字段都识别正确，仍应通过核对页确认。

## 2026-09-18 部署验收

- Docker 构建内 Rust 检查通过：API 22、语料回归 22、存储 56；另外 3 个显式在线评测保持忽略。格式、Clippy 和 release 构建通过。
- OCR 服务 13 个测试及离线 SuperPoint/LightGlue Logo 回归通过；Android APK build 10036 下载内容与更新清单 SHA256 一致。
- 真实 Hualian `fe3a7e41`：6 个商品，3 条称重关联正确，总额 $27.25；真实 Costco `8572dcef`：9 个商品，总额 $138.03。独立识别请求分别约 53.3 / 44.3 秒，仅为这两次现场观测，不是全库延迟统计。
- Costco `3a8e3c19` 临时草稿完整通过 Logo 图片匹配及商品识别。发现并修复整图浮点定位偏移，新增 EXIF/顶部图片处理回归；匹配阈值未降低。
- 两张重叠照片产生同一张收据：4 个商品加税行，总额 $14.00，无重复商品。多任务观测为 running/queued，识别时收据查询保持响应；提交约 10–17 ms。
- 现场测试全部使用临时草稿并在结束后清理；原有 32 张 receipt 行按主键排序的完整内容 SHA256 与部署前一致，没有遗留 running/queued 任务。未重新识别或改写已确认的用户收据。
- Dual OCR 的运行实现、旧 parser、测试归档中的 parser 源码副本及专属执行器均已删除。保留历史原图、输出和比较报告；需要旧实现时从 Git 恢复。

候选 Logo 匹配评测：[Qwen 图片匹配报告](qwen_logo_evaluation.md)。简短提示词在当前开发回归组中 40/40；仅为评测，生产 Logo 匹配现已切换为 Qwen。

## Logo 匹配切换（2026-09-18）

`playground/backend_api/prompt.toml` 的 `logo.match_reference` 使用评测通过的简短提示词，thinking 继承 OCR 设置。图片最长边 768，4096 输出 token，temperature=0、seed=42。每次最多 15 个参考（受配置的最大图片数量进一步限制），较大的库分批遍历；若不同批次/查询图选择了不同店名，返回未知。返回编号必须属于当前批次，拒绝额外字段、伪造编号、截断和错误类型。

匹配过程保留图片/目录版本检查，过程中发生删除、旋转或 Alias 修改时拒绝过期结果。异步识别记录包含匹配响应和合计 token 用量。

删除 SuperPoint/LightGlue 实现、依赖、下载脚本、旧阈值、旧匹配测试和历史源码副本。SQLite 当前 schema 没有向量/特征专属表；`logo_sample` 和 `receipt_logo` 保存通用图片关系，继续使用，不重建用户数据库。

切换验收：Docker 构建内 API 22、语料 22、存储 57、OCR 8 项检查通过（另有 3 项显式在线评测未运行）；已验证多批参考、未知/伪造编号、不同店名冲突及 Alias 变更的过期保护。最新 Target 原图创建临时草稿后完整识别出 Target，提交 19 ms，APK build 10036 校验通过。测试清理后原有 33 张 receipt 行的完整内容哈希与切换前一致，无待处理任务。

旧运行镜像及过时的 Receipt Master 实验镜像已移除；运行容器 `/models` 仅有 Qwen NInfer 文件，不再安装 torch、LightGlue、OpenCV、Kornia。旧 Logo/双 OCR 实验目录、特征缓存和测试数据库副本已清理，历史比较结果保留为报告证据。
