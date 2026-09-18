# 双 OCR 与按商店解析

2026-09-17：停止端到端模型候选测试，生产路径恢复 Unlimited-OCR + PP-OCRv6 medium。历史模型比较保留归档，不代表当前实现。

## 当前架构

| 容器 | 职责 |
| --- | --- |
| backend_api（Rust） | 鉴权、异步任务、Logo 图像 Alias 匹配、通用/店铺文字解析、JSON 校验、金额/重量/UTC 运算、SQLite/照片、报表与 APK 下载 |
| backend_ocr（Python） | Unlimited-OCR 的文字/版面识别、PP-OCRv6 medium 的文字/坐标/置信度、DINOv2 Logo embedding；不解释商品、折扣或退款 |

仍为两个独立容器。OCR 内部用 GPU vLLM 跑 Unlimited-OCR，独立 Python 环境在 CPU 跑 Paddle，进程由同一个容器管理。固定 revision 的两个 OCR 模型和 Logo 权重全部包含在镜像中，运行时离线加载。

API 对外监听 `0.0.0.0:5000 → 8000`。OCR 不发布宿主机端口；API 通过 Compose 内部网络调用 OCR。SQLite、原照片、Logo 裁剪、识别原始输出继续保存在 `playground/data:/data`。不清空数据，不需要数据库迁移。

## 识别流程

1. 手机上传按顺序排列的照片并提交异步任务，可以继续做其他操作。
2. 任务在 backend_api 的 SQLite 队列持久保存，单个 worker 依次处理；backend_ocr 的任务门禁和 vLLM 序列数固定为 1。每张照片先交给 Unlimited-OCR，完成后再交给 PP-OCRv6 medium；整张收据完成后才处理下一项。先统一 EXIF 方向，保留 Unlimited 布局以及 Paddle 字框和分数。任一引擎失败或输出截断，任务明确失败，不伪装成双模型成功。
3. 首张照片的 Unlimited 布局复用于 Logo 合并裁剪；原有 DINOv2 embedding、图像 Alias 库、0.60 相似度和 0.08 候选差距保留。店名不从文字 OCR 猜测。
4. API 用已保存店名或匹配到的 Logo Alias 选择 parser。文字消息中提到店名不会切换规则。
5. 统一布局层组装名称/金额分列，两种结果交叉核验，匹配行包含中文时采用 PP-OCR 的结果（包括中文与金额同一行的情况），文字或金额冲突保留核对提示。HTML 表格行与非表格行共用后续解析。
6. 按照片顺序合并连续重叠行：至少两行一致才折叠照片边界；同张照片内的重复商品保留。可忽略下一张重复页头。仅单行重叠或两次 OCR 文字不同仍可能需要人工核对。
7. 解析结果经过原有 JSON Schema、引用与数值校验，再做精确重量/金额/UTC 转换。合计不一致显示差额，不编造小费或平衡费用。异步结果仍受删除、确认和编辑版本保护。

## 规则位置和扩展方式

规则目录：`src/backend_api/src/parsing/`。

| 文件 | 处理内容 |
| --- | --- |
| `mod.rs` | 店铺注册、解析流程、照片边界重叠、字段关联 |
| `generic.rs` | 通用金额、时间、地址、汇总/付款排除、重量和数值核验 |
| `layout.rs` | 双 OCR 行布局、列组合、中文补充与冲突提示 |
| `costco.rs` | 可选单字符税码、SKU、优惠按 SKU 关联最近商品、会员退款、瓶押金、预扫描小计核验；无目标 SKU 的描述优惠按相邻商品关联并黄标，价格末列的斜线小数点明确黄标 |
| `skyfoods.rs` | 数量、中文标准名、Qty Spl/Pkg Disc 关联上一商品及已含优惠的净价 |
| `hmart.rs` | WT 不进入名称，前置重量行归属 WT 商品，保留完整商品名 |

已注册别名：Costco / Costco Wholesale、SkyFood / SkyFoods / Sky Foods、H Mart / H-Mart。匹配忽略大小写、空白和标点，不使用子串匹配。未知商店及未注册的自定义名称使用通用规则，并提示核对。

新增商店：

1. 在 `parsing/` 新建店铺模块，仅放该店不同于通用行为的规则。
2. 在 `profile()` 注册明确的店铺名称，并接入相应的商品、折扣或版面处理。
3. 将原照片、两种 OCR 原始输出、人工确认结果加入语料；在 `tests/backend_api/parsing.rs` 添加该店回归断言。
4. 检查未知店铺仍走通用路径，已有店铺、重复商品和多照片重叠测试仍通过。

结构协议仍为 `src/backend_api/src/receipt_schema.json`；客户端不需要 OCR 设置。每个识别结果保存 `receipt_parsing`（版本、profile、照片数、金额差异）和 `ocr`（两种原始输出及用量），便于定位规则问题。旧 `receipt_vision` 提示词元数据退出新识别路径，历史文件原样保留。

## REST 和部署

- 对外兼容入口仍是 backend_api `/v1/chat/completions`，服务名通过 `/v1/models` 获取；当前为 `receipt-dual-ocr`。
- API → OCR 使用内部 `/v1/ocr/recognize`。请求包含 `model`、`messages` 中的 inline JPEG/PNG/WebP 和 `max_tokens`；返回 `pages:[{unlimited,paddle:{words:[{text,confidence,box}]}}]` 与 `usage`。`box` 基于 EXIF 方向修正后图像，归一化至 0..1。
- `/v1/logo/embedding` 内部协议不变。
- API 配置为 `playground/backend_api/config.yaml`；OCR 进程配置为 `playground/backend_ocr.toml`。费用预算只提醒，不限制识别。`max_images` 和输出 token 参数属于技术容量校验，不是消费额度。
- Unlimited-OCR：`baidu/Unlimited-OCR@07dea832e22aefee32ad281d4b80551282e1c168`。
- PP detection：`PaddlePaddle/PP-OCRv6_medium_det@8e0f56fb2ef86b461d99cfc7ac5c137738985f61`。
- PP recognition：`PaddlePaddle/PP-OCRv6_medium_rec@e5a92bcbc5cc1b494628e458d267778f0704fd7c`。
- Logo：`facebook/dinov2-small@ed25f3a31f01632728cabb09d1542f84ab7b0056`。
- `./build_docker.sh` 执行服务检查、Docker Android 构建、两个运行镜像构建；`./run_playground.sh` 先构建再通过 Compose 前台启动，跟随日志，Ctrl+C 停止。
- `/receipt_master.apk` 和 Android 更新元数据仍由同一个 API host/port 提供。

## 验证范围

构建运行 API、存储、Logo、金额/重量、异步任务和 parser 回归测试。17 张历史双 OCR 输出检查结构、明细数和票面总额；另有针对 SKU、优惠关系、退款、完整 FAGE 名称、重量、中文、TIPS 和多图重叠的断言。这些是确定性解析回归，不是重新运行模型准确率比较，也不证明所有名称字符正确。新样本可能仍需补充规则或人工确认。

## 镜像内置商店样本（空库开箱即用）

`src/backend_api/resources/merchants/manifest.json` 保存版本、店名、parser ID、Logo 图片文件名与 SHA256、DINOv2 模型标识和预计算 embedding。对应 PNG 是用户已确认的 Logo 裁剪，不包含整张收据或个人数据库。当前包含 7 家店的 10 个样本：Costco、skyFOODS、H MART、Target、99 Ranch、Hualian、Feilong。

Logo 图片与 manifest 通过 `include_bytes!` / `include_str!` 编译进 backend_api 可执行文件；Rust parser 同样编译进该文件。因此最终 Docker 镜像自带完整样本和解析规则，不依赖开发机、旧数据库或外部文件挂载。构建检查验证资源摘要、模型、embedding 维数和 parser 对应关系。

新建空库时，初始化事务把内置样本写入已有 merchant、logo_sample、media_blob 表及 `/data/media/derived`。这一阶段不需要 OCR 服务或 GPU，后续第一张收据即可和内置样本比较。首次识别仍需 OCR/embedding 服务就绪，匹配仍遵守阈值和候选差距，未知 Logo 不强制套用店名。

内置样本初始化后与普通样本一样，可在 App 内修改/取消 Alias。只在新建数据库时导入；重启、升级镜像或恢复现有数据库不会重灌样本，不覆盖用户修改，也不会复活已删除关联。用户以后添加的样本继续只写入 `/data`，不会自动进入镜像。未增加 schema migration，已有 playground 数据保持原样。

增加内置商店时：提交已确认的裁剪 PNG、对应同版本 embedding 和 manifest 条目，在 `src/backend_api/src/merchant_images.rs` 登记编译资源；登记/新增对应 parser（尚无专用规则时明确使用 `generic`），补充回归测试，再通过 `build_docker.sh` 构建。不要在普通构建中自动读取 playground 数据库或打包整张收据。新镜像的新增内置样本会用于之后创建的空库；既有数据库沿用自己的样本库。

串行调度约定与故障证据：[OCR 失败诊断](ocr_serial_processing.md)。


## 99 Ranch 专用解析

Logo / 店名 Alias 匹配为 `99 Ranch` 或 `99 Ranch Market` 时，选用 `ranch99`（随 API 镜像编译，预置商家资源也声明此解析器）。
商品下方 `2.65 lb @ $2.99/lb` 作为上一商品的数量、计价单位与单价；复用通用重量换算及金额差异提示，不生成额外商品。没有前项或已经到达总额区的称重行不关联到后面的商品。多图分段可将下一张顶部称重行关联到上一张末尾商品。
交易时间只取商品区之前、电话下方或带门店收银台编号的交易行；`Item count` 后面的付款时间不参与冲突判断。顶部时间缺失时留待确认，不用底部时间替代。不同照片的顶部交易时间确实冲突时仍需人工确认。
真实双 OCR 样本 `2f97fc50` 应取 `2026-07-29T18:37:41`，`1b072114` 应取 `2026-08-17T16:08:07`（票面本地时间，后续统一转换为 UTC）。本次不改历史确认数据或旧评测结果；折扣与税行解析尚待分别完善。


## Hualian 专用解析

Hualian / Hualian Supermarket / 华联 / 華聯 使用 `hualian` 解析器，预置 Hualian Logo 资源随 API 镜像指向此规则。
右侧金额标记商品首行，金额左侧作为票面名称。随后没有金额的名称行，无论中文或其他文字，都按顺序合并为同一商品的标准名称。
称重信息位于商品首行之前：先暂存数量、单位与单价，再关联到下一商品首行，复用单位换算和金额核验。此规则优先于缩进，称重行不属于上一商品，不进入标准名称，也不生成新商品。
其他行首至少两个额外空格（或制表符），以及 OCR 坐标显示右缩进的行，作为上一商品续行。税、总额、付款汇总优先处理，不并入名称。跨照片暂存称重与名称关联继续有效。
真实样本 `fe3a7e41` 回归：CHINESE LEEK = 0.50 lb × $3.99/lb → $2.00；CHIVES = 0.76 lb × $4.49/lb → $3.41；CHINESE CABBAGE = 2.69 lb × $0.69/lb → $1.86。醋和蓝莓不继承下一商品的重量。英文、中文标准名称均保持，6 件商品加独立税行。


## 全店铺中文双 OCR 合并提示

中文采用 PP-OCR。判断为繁体中文时，不添加两模型文字不一致提示；简体中文或无法判定时保留提示。简繁混用按特有字形数量判断占优字形，数量相同时保留提示；例如「恒順香醋六年陳」按繁体处理。用内置 OpenCC 1.3.2 字典识别特有字形，不转换原始名称；繁简共用字参考本张照片 PP-OCR 的字形上下文。
规则位于共同布局合并层，所有专用及通用解析器共享。商品首行和标准名称续行均适用。低置信度、两模型金额不一致、重量金额核验等独立问题仍保留提示。重新识别后应用新规则，不直接清除数据库既有历史提示。
字典来源及许可证见 `src/backend_api/resources/chinese/README.md`。
