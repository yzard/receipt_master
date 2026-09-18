> 当前采用 Unlimited-OCR + PP-OCRv6 medium，backend_api 负责通用和按店铺解析；下文保留历史计划。现行设计见 [backend_ocr.md](backend_ocr.md)。

# 第二版统一数据 API

所有业务数据由 Rust `backend_api` 管理，Android/iOS 通过同一套接口访问。SQLite 当前完整表结构由 `src/backend_api/schema.sql` 定义；空库直接初始化，不提供旧版本迁移。不导入第一版测试数据。

## 持久化

Compose 将宿主 `playground/data/` 绑定到 `/data`。其下包括 `database/receipts.sqlite`（以及 WAL/SHM）、`media/originals/`、`media/derived/`、`recognition/`、`staging/` 和 `backups/`。重建镜像、重建容器和退出 playground 不删除这些数据。配置 `data_dir` 必须指向可写持久目录。

只有 API 容器访问业务目录。OCR 容器无数据目录挂载，只通过内部 REST 接收识别图像。APK 与更新清单继续只读挂载在 `/artifacts`。

## 协议

普通业务操作使用 `POST /api/v1/{component}/{operation}`。请求格式：

```json
{"request_key":"客户端生成的唯一请求标识","input":{"id":"资源标识"}}
```

写操作需要稳定的 `request_key`。重试同一内容返回第一次成功结果；同键不同内容返回 409。读取操作可省略该字段。成功返回 `{"data": ..., "catalog_version": ...}`（导出等独立操作没有 catalog_version）。失败返回 `{"error":{"code":...,"message":...}}`，401 表示未认证，404 表示资源不存在，409 表示版本或请求冲突，422 表示数据关系约束失败。

全部业务请求、媒体和备份都需要 `Authorization: Bearer <API key>`。个人试用版本使用一个共享工作区；共享密钥意味着共享数据访问权，不提供不同用户隔离。APK 下载及更新清单维持公开。

| Component | Operations | 关键字段 |
| --- | --- | --- |
| receipts | create/save/confirm | receipt：完整编辑 DTO；revision 为已读取的版本，初次为 0 |
| receipts | get/list/check_duplicates | id；或 trash、cursor、limit；或 receipt |
| receipts | trash/restore/purge | id、expected_version；purge 必须先入回收站 |
| images | list/reorder/rotate/remove/restore | receipt_id；写操作带 expected_version；排序带 ids，其他修改带 id |
| categories | list/save/delete | save：id/name/parent；delete：id，解除关联并归入未分类；写操作带目录版本 |
| printed_names | list/set_product_name | id（printed_name_id）、name；空字符串解除名称关联 |
| product_names | list/delete/classify | id（product_name_id）；分类使用 category_id 或 category_name（可新建） |
| products | list/suggest | suggest：name（票面名称），查询历史规格 |
| config | get/save_weight_unit | 只提供重量显示偏好；OCR 配置不可由客户端修改 |
| reports | summary/details | UTC 毫秒 start/end，currency、可空 category、offset/limit |
| recognition | start/get/list/runs/cancel/apply | start：receipt_id/expected_version/zone；get/cancel/apply：id；list：receipt_id |
| exports | csv/create_backup | csv 带 zone；备份响应包含 id、bytes_base64 |
| maintenance | prepare_restore/commit_restore | prepare 带 bytes_base64，返回 token；commit 带 token、confirm:true |

目录、商品名称、显示偏好写入使用 `expected_version = catalog_version`。收据与图片写入使用该收据的 revision。数据规则在服务器重新验证，不信任客户端自行校验。

## 照片

`POST /api/v1/images/upload` 使用 multipart：`metadata` 是上述请求信封，input 包含 receipt_id、expected_version、captured_at_utc_ms；`photo` 是原始文件。网络层流式写入 staging，工作线程解码及计算哈希。提交后返回 image_id 和最新 receipt。

客户端在收到成功响应前保留原始待上传文件及请求标识。重试先使用同一个请求标识，避免响应丢失引起重复上传。用户发起重试时，可在明确版本冲突后重新读取收据版本再追加照片。移除图片为软删除；原图与旋转后的文件分别保存，永久删除收据才清理无引用文件。

`GET/HEAD /api/v1/media/{blob_id}` 是鉴权下载，支持 Range；不暴露 `/data` 路径。照片列表给出 original_blob_id、current_blob_id、media_id、宽高和哈希。

## 识别与报表

识别任务持久化于 SQLite，并固定图片版本快照。每次模型响应另存为 JSON，客户端退出不终止后台处理。重启保留 queued，并将 running 重新排队；当前两个 OCR 都在本地容器内运行。中断的调用记录保留 unknown，重试产生新调用记录。任务结果可从编辑器的“识别任务与结果”重新打开。

应用识别结果时检查启动时的收据版本。识别成功后由后端自动将草稿结果保存为可编辑草稿，不需要手机轮询或调用 apply 才能落库；正式收据仅载入编辑表单，由用户再次确认保存。分段重叠至少两个连续一致行才合并；单行疑似重复保留并黄标。时间解析使用设备提供的 IANA 时区，保存 UTC；金额使用整数缩放。

报表在后端过滤和计算净额、差额、优惠、退款、支出、类别与商品汇总；明细通过分页返回。服务器根据客户端提供的设备时区和周期条件计算日/周/月/季度/年的 UTC 半开区间，避免 DST 日按固定 24 小时切分。币种分别统计，不自动换汇，不计算平均每收据支出。

## 备份与恢复

备份在存储串行执行区内创建 SQLite 快照，并从快照枚举媒体与 OCR 文件，生成带大小及 SHA256 的 ZIP。当前个人版通过一次 API 请求返回完整备份，执行期间其他数据写入等待，防止数据库与照片不一致。

恢复先验证路径、清单、文件哈希、schema、数据库完整性和关系，再生成恢复前备份。替换 `/data` 内部目录，不替换挂载点。持久恢复日志保证进程中断后先完成恢复，再接受业务请求。只支持第二版后端备份，不兼容旧手机备份。

## 健康与限制

`GET /health` 检查存储可用性；鉴权的 `GET /api/v1/recognition/readiness` 检查模型。模型加载或失败不关闭数据 API，历史记录、照片和 APK 仍可访问。

单 API 实例、单机 SQLite。手机没有离线业务数据库；网络断开时显示失败，未上传照片仍保留。大量数据优化、独立多用户认证和多实例存储不属于这一版。

### iOS 构建配置

在 macOS 上可设置 `RECEIPT_BOOTSTRAP_FILE=/absolute/path/backend_defaults.json` 后执行 `build_ios.sh`，将同样的后端默认配置写入组装工程。脚本不会更改共享源码中的默认配置；HTTP 例外仅写入配置的主机。系统本地网络权限说明已添加。IP 地址例外规则依据 [Apple NSExceptionDomains 文档](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSAppTransportSecurity/NSExceptionDomains)。原生编译与设备验收需要 macOS/Xcode。

## Playground 录入与重量改进

- 首页三个入口：拍照、上传照片、手动。前两个直接启动系统采集界面，取消不会创建空收据；选完图片后立即保存待上传文件并后台提交，首页保持可操作；上传完成后自动提交服务器识别任务，用户从收据列表打开结果确认。
- 收据列表每条一行，左滑露出 Trash。点击会执行 `receipts/purge`，直接永久删除草稿或正式收据，以及关联明细、照片、任务和 OCR 文件；不必先放进回收站。保留 revision 冲突检查。正在执行的推理不能把已删除收据写回来。
- 时间支持票面秒数、AM/PM、ISO 时间分隔符和美国日期格式；解析成功后按指定 IANA 时区转 UTC。DST 歧义、日期缺失仍保留估计标记。
- 识别、重量换算、显示值生成、手动输入换算全部由 Rust `backend_api` 完成。客户端不实现 lb/kg/oz 换算，只提交图片或输入文本，显示 API 返回值。
- `config/get` 返回 `weight_unit`；`config/save_weight_unit` 接受 `weight_unit` 和 `expected_version`。全局选择 g/kg/lb/oz，默认 kg，同一后端的设备共享。
- 当前 schema 标记为版本 15，直接执行 `schema.sql` 创建完整表结构。商品与未匹配明细的 `weight_g` 统一保存克，精确到 0.001 g；不处理旧库单位转换。传输 DTO 的 `weightMg` 保留既有千分之一克整数约定，避免破坏已发布客户端。
- 1 lb = 453.59237 g，1 oz = 28.349523125 g。称重商品的 quantity/quantity_unit 可补出缺失重量；保留原始计价数量和单位，不把 fluid ounce 当重量。
- 收据明细返回 `display`：weightText/weightUnit/weightLabel、quantityText/quantityUnit、priceText、amountText；商品规格返回 weight_label/weight_text。报表重量和数量由服务器按全局单位展示。
- `receipts/display_line` 接受 line/currency，生成编辑表单显示值；`receipts/prepare_line` 再接受 fields（上述文本字段）并返回换算后的明细，随后随整张收据保存。显示单位在编辑期间变化时返回冲突，防止错用单位；未修改字段保留原始精度。


## 客户端职责与服务器配置

`playground/backend_api/config.yaml` 是 OCR、结构化模型、价格估算和预算提醒的唯一运行配置，Compose 只读挂载到 `/config/config.yaml`。修改后重启 backend_api 生效。YAML 的 pricing 两项为带引号的 USD/百万 token 十进制字符串；同时设 null 表示费用未知。budget.monthly_usd 为带引号的 USD 金额或 null，alert_percent 为提醒比例，timezone 为预算月份时区。预算只产生提示，不拦截任务。

客户端不再显示或保存 OCR 模型、provider 地址、token 价格、预算和模型费用记录。安装包只预置后端 origin 与认证密钥；设置中的“连接并验证”验证后端认证。识别任务入口保留状态和可编辑结果。重量显示单位属于共享展示偏好，仍可在设置修改。

- `receipts/edit`：receipt/action，支持 preview、currency、split、merge、total_from_lines；可提供 total_text。后端返回转换后的 receipt 和 summary（knownTotal/difference）。客户端不再计算合计、差额、拆分合并金额或币种数值转换。
- `receipts/time_candidates`：text/zone，服务器返回 UTC 候选毫秒；客户端仅展示 DST 歧义候选供用户选择。
- `reports/range`：anchor/zone/period/period_offset，服务器返回 start/end/previous_start、label、unfinished；统计与时间边界都在后端。
- `recognition/start` 的价格快照由服务器从 YAML 注入，客户端提交的价格无效；`recognition/get` 可返回服务器算出的 notice。
- 旧的 config/save、budgets/get/save 不再提供。历史 SQLite 预算/价格表仅作为旧备份 schema 保留，不参与运行配置。

### 识别置信度提示

当前文本 OCR 链路不提供校准过的商品置信度，`confidence=null` 表示不可用，不等于识别质量低。后端不再为所有商品添加统一的“识别置信度低或未知”提示；缺少金额、缺少数量单位、时间含估计值和重叠待确认等具体问题仍保留。历史收据读取和列表问题计数排除这条旧提示；再次保存时清除，旧任务结果也不会重新写入该提示。客户端无需升级，重新打开收据即可获取修正后的结果。

### 重量显示与收据总览

kg 和 lb 的重量、购买数量及报表数量统一由后端四舍五入为两位小数（例如 0.84 kg、1.00 lb）；g/oz 保留原有显示精度。数据库不舍入。编辑页未改动的显示值仍保留原始精度，仅改价格也不会重写舍入后的数量。报表新增 `quantity_labels` 显示数组，原始 `quantities` 保留整数精度。总览使用共享列宽对齐店名、时间和右对齐金额，保留左滑 Trash。

### 店名别名

- `merchant_aliases/list`、`save`、`delete` 通过统一认证 API 访问。保存参数为 `raw`、`name`、`expected_version`；删除参数为 `raw`、`expected_version`。
- `merchant_alias` 使用规范化店名作为主键，指向 `merchant`；统一店名只存于商家表。匹配合并连续空白、忽略大小写，采用精确匹配，不进行可能误认商家的模糊匹配。
- OCR 结构化之后、商品名称匹配之前解析店名别名。`recognizedStore` 保留原始识别店名，存于 `receipt_ocr_store`，与收据一起保存、备份和删除；`store` 是显示及后续业务使用的店名。
- 收据编辑页的“记住店名别名”可保存对应关系并填写当前店名；商品页的“店名别名”可新增、修改和删除。新别名用于后续识别，不追溯覆盖已确认收据。

### 总览排序与称重说明行

收据列表按 `created_at_utc_ms DESC, receipt_id DESC` 排序，分页游标封装两列值。录入时间由后端首次建立草稿时保存，修改或重新识别交易时间不会改变排序。总览时间列显示“录入时间”，详情继续显示交易时间。

OCR 不把纯称重价格行（例如 `2.81 lb @ 2.99 /lb`）作为独立商品。后端核对相邻商品的票面金额，只在归属唯一时转移数量和单价，保留该商品原金额，并重映射折扣目标；无法唯一匹配时保留待核对提示。BALANCE、CHANGE 等结算行不作为押金或商品。分段重复商品仍按原有重叠规则处理。

### 完整票面名称与称重金额核验

结构化结果中的商品名称与 OCR 原文金额交叉匹配：只有名称前缀和金额唯一对应时，恢复金额左侧的完整名称，保留品牌、TOTAL、百分比等字符；金额后的税类标记不属于名称。已有用户设置的商品名称不因此被覆盖。

`WT` 是称重标记，不显示在票面名称中。后端将其转换成明细 `isWeighed`，通过 `line_weighed` 与明细的一对一关系保存；明细删除时一起删除。旧数据的 WT 前缀在读取时同样转换，保存后持久化标记。

后端使用原始定点数量和单价计算金额，按币种最小单位四舍五入后与票面金额精确比较，避免使用仅供显示的两位重量。存在差额时返回黄色核对提示，包含计算金额、票面金额和“票面减计算”的有符号差额。缺少重量、重量单位、单价或金额时提示无法核验。编辑后重新计算，已解决的问题提示自动清除；票面金额不被自动改写。WT 明确指向相邻称重商品时，即使金额不符仍关联其重量/单价，并由核验提示差额。对于模型漏掉的重量/单价，在商品名和金额唯一匹配 OCR 原文时，读取该 WT 商品紧邻的纯重量单价行补齐；相邻多个不同价格或重名同价造成歧义时不猜测。


### 双语收据、数量列和已含优惠价格

USD 收据中出现明确 `Item Count`、数量列、独立价格行及小计时，后端用票面数量和金额共同校验商品行。只有数量一致且金额能精确解释小计，才重建明细；不按店名或固定金额匹配。没有独立价格的中文翻译不重复记商品，数量列不放入名称，同名但分别计价的购买保留为两行。商品行之后的重量/单价即使隔着翻译行也归属于该商品，优先于名称中的包装重量字样。`1 @ 2/$5.99` 等促销说明不是商品。

`Qty Spl Disc.` 记为关联商品的负数优惠。若票面商品金额之和已等于小计，表示商品价格已含优惠：后台将商品金额还原为折前值、另列负数优惠，同时通过 `printedAmountMinor` 保留原票面净额，存入一对一 `line_printed_amount` 表。客户端显示后端的 `display.pricingNote`，例如“原票面净额 USD 3.00；优惠已拆分”。统计只使用商品折前金额和负优惠，避免重复扣减；原票面金额只供追溯。旧客户端未发送该字段时保留原值，明确发送 null 则清除；拆分/合并行清除不再一一对应的原票面金额。原图保留。

明确 `Total` 优先于刷卡页脚 `AMOUNT`。数量、小计无法交叉验证时，保持识别结果供用户核对，不强行凑出总额。此规则和原有 FAGE 完整名称恢复、WT 隐藏、重量乘单价差额提醒共存。


### 中文商品名称、退款和 OCR 异常容错

双语商品保留英文 `rawName`，使用同一价格行下方唯一的中文描述作为候选商品名称 `product_name`，已有票面名称对应的商品名称优先；没有中文时不自行翻译。用户维护的商品名称用于显示与报表汇总，不覆盖票面名称。

后端把 OCR HTML 表格恢复成逐行文本，再交给结构化模型与票面规则。金额末尾负号和会计括号按明确的负数记法读取（例如 `16.99-` → `-16.99`）。退款商品仍是 product，会员/服务退款是 other_adjustment，退款税额为负数；SUBTOTAL/TOTAL/TOTAL TAX 不重复计入消费。只有退款明细、小计、税额、总额相互吻合时才重建退款段。

PRE-SCANNED 段逐行提取。`26/18` 等疑似小数点误读，仅在按 `26.18` 解释后全部商品精确吻合打印小计时采用，并返回核对提示。无法解析的金额、数量、重量或单价保留为空并黄标，其他明细继续保存，不再使整张任务失败。打印在结尾 Items Sold 段后的唯一有效时间可纠正正文月份误读；无法解决的日期冲突使用估计时间并提示核对。

当前 Executive Reward 按付款抵付处理：消费总额取商品加税，后面的余额总额是银行卡实付，税不重复列两次。底层消费金额未扣除奖励抵付。后端产生的 `review_notes` 进入明细审核提示；不使用模型自行生成的置信度说明。

## 后台提交与双模型（2026-09-16）

- Android/iOS 共用后台提交队列；待上传照片和批次意图先落盘。创建草稿、上传、提交识别均保留幂等身份，网络失败可重试，重开 App 会恢复提交。上传期间可继续拍摄、浏览和编辑。
- 这里的后台提交是在 App 进程内异步运行。手机系统终止/挂起 App 后，尚未上传完的照片要等 App 恢复；服务器已经接收的识别任务不依赖手机继续运行。
- `recognition/start` 按当前统一接口约定立即返回 HTTP 200 + `job_id/status`，不等待推理；同一收据版本的 queued/running 任务自动去重。
- `config.yaml` 的 `job_workers: 2` 控制并发任务数（1–8）。数据库领取任务为短事务，推理不占用数据库锁；后台每秒检查队列。模型尚未就绪时保留 queued。
- 列表返回最新 `recognition_status`；手机有待处理工作时定时刷新。applied 表示已保存为待确认草稿；succeeded 表示保留候选结果；failed 可从编辑器重新发起。
- 用户编辑导致版本变化时保留候选，标记 stale_input，绝不覆盖新编辑。正式收据需要用户确认候选。取消和永久删除之后，运行中的旧结果不能写回。
- 每张图片同时交给 Unlimited-OCR 与 PP-OCRv6 medium。融合、金额/重量核验和结构化仍在 Rust backend_api；backend_ocr 只提供两份读图证据。融合规则见 `docs/backend_ocr.md`。
- 这是单实例、多并发任务的基础；当前仍是个人版共享认证，尚未增加独立用户身份、按用户隔离数据或多实例任务调度。


### 完整流程验证

Docker 构建执行 Rust 单元/接口/语料回归、Flutter 分析与共享测试、OCR 双引擎接口与进程关闭测试。真实 playground 可运行以下检查；只创建并清理它自己的两张临时收据，不修改已有收据：

```bash
python3 tests/backend_api/smoke_async.py --scenario parallel \
  --url http://127.0.0.1:5000 \
  --key-file playground/secrets/ocr-api-key \
  --data-directory playground/data
```

该检查验证任务立即受理、两个任务同时运行、推理期间查询可用、不调用 apply 就自动保存草稿、每次结果保留两个模型证据，以及实际下载 APK 与更新清单 SHA256 一致。

## 小费整行判定

识别结构化后由 Rust 按票面整行名称判断。忽略大小写、首尾空白和名称末尾冒号，独立的 TIP/TIPS/GRATUITY/GRATUITIES/小费/小費 作为 tip；名字包含这些词的商品（如 BOK CHOY TIPS、BEEF TIPS）仍为 product，不能拆出额外小费。金额可位于同一行或紧邻下一行；无可读金额时保留 null，不从总额差值推算。建议小费百分比、提示文案不是实际收费。规则从 OCR 证据恢复真正小费，防止商品数量重建丢失该收费，同时消除模型臆造的独立小费。删除错误候选时重新映射优惠关联，保留折扣对应商品。

## 收据总览与多张采集（2026-09-16）

- 总览四列：店名、录入时间、收据时间、总金额。两个时间均按当前设备时区显示。默认录入时间降序；点列标题切换该列，再点切换升/降序。服务端接受 sort_by=store/created_at/receipt_time/total 与 direction=asc/desc，按白名单构造查询并用稳定游标分页；未知金额始终放末尾。不作汇率换算。既有客户端的默认排序及旧游标继续兼容。
- 未确认草稿黄色背景，识别失败红色背景优先；不再把“待确认”加在店名前面。
- 相机页直接实时预览；拍摄追加照片，点缩略图选择当前页，重拍替换该页，完成后才把整批照片提交为一张收据。未提交照片与顺序在手机落盘，重新打开相机可继续。相机按照 Flutter 官方 camera 插件的生命周期释放/重建资源，拍照禁用音频；不申请录音。参见 https://pub.dev/packages/camera 。
- 相册继续支持一次多选，全部上传成功后只提交一个识别任务。后端按图片顺序运行双 OCR 并合并重叠段；不以手机等待结果作为保存条件。
- 编辑页移除拍摄、导入、识别和任务按钮、长收据提示，只展示照片、结果及编辑确认操作。
- 相邻图片至少连续两行的名称、类型、金额、数量和重量匹配才自动合并。名称前整数等于已解析数量时，仅在匹配中忽略该前缀（如 `1 BREAD`/`BREAD`），票面名称原样保留；数量不符不忽略，单行边界重复只黄标提示。
- 多张 GPU 完整流程验证：用带 Pillow 的 Python 执行同一 smoke_async.py，传 --scenario multi；它产生两张含两行重叠的合成票，验证最终仅一张收据、4 件商品+税、总额 $14、双模型证据与 APK 校验，并清理自己的测试记录。

## SkyFood 数量优惠

`Qty Spl Disc.`（忽略大小写、空格和句点）归入商品优惠，使用关联商品的票面名称与商品名称，金额为负数，未知金额保持未知。优先保留按 OCR 原图定位的商品关联；结构化输出未关联时使用前一个商品。优惠不产生第二份数量或重量。已有收据读取时共用同一规则，新识别结果保存前也应用；无需客户端更新。现有票面净额核验继续保留，已包含优惠的商品金额先还原再单列优惠，避免重复扣减。

## Logo / 文字招牌图像别名（2026-09-16）

店名不再从 OCR 文本提取或按文字别名匹配。结构化结果的 store 强制为空；自动店名仅来自确认过的图像样本。人工录入店名仍可用于手工收据，旧收据已保存的店名不重写。旧文字别名入口和 API 已移除；历史数据库表保留，不参与新识别。文字内容回归语料不再用 OCR 店名评分，Logo 单独验证。

- 新收据第一张图：先应用原照片 EXIF 方向，再依据 Unlimited 的顶部 title/header/figure/image 或较大文字布局框裁剪，忽略框内 OCR 字符；无可靠顶部框时保存顶部候选区域，用户必须查看后才可指定别名。定位框并不保证一定是 Logo。
- Logo 身份匹配使用 SuperPoint + LightGlue（固定代码提交 `eb42fee2d71449efb0aa5c10549752b5d75384d8`），CPU 运行。先估计纸张背景、归一化墨迹对比度，最长边保留至 1024 像素，前景附近提取最多 768 个局部特征；背景颜色、明暗和黑白排版不直接贡献匹配分数。
- backend_api 负责裁剪、图像与人工店名映射、参考样本选择和最终阈值判定；backend_ocr 负责局部特征匹配及几何证据。`logo_sample` 只保存图像 blob、merchant 外键和创建时间，已移除旧 DINO model/embedding 字段；`receipt_logo` 保留原图片版本与裁剪框。只使用人工命名或预置审核过的样本；所有店铺样本都会参与比较，不做全局 embedding 提前筛除。
- 最多拟合两个局部透视区域，每区至少 12 个内点并覆盖足够空间；第二个区域与主变换的偏移受限，避免任意扭曲不同 Logo。计分为双向前景覆盖的较小值乘以证据系数 `min(1, 内点数/80)`；只统计通过几何约束、投影后距对方墨迹小于 3 像素的前景，不把空白背景算成相似。分数不是概率，低分不区分严重损坏与不同身份，需同时查看 evidence/coverage。
- `config.yaml` 的 `logos.identity_threshold=0.55`、`minimum_evidence=0.75` 和 `margin=0.05` 共同决定自动认店；同店多样本取最佳，比较不同店名的分差。新分数与旧余弦分数不具可比性。不足或模棱两可时不认店，不回退 OCR 猜店名。
- API：保留 `logos/list/extract/save/delete`。新增受认证的 `logos/match`（receipt_id），只读返回 selected、各参考样本 score/evidence/coverage/inliers/regions，以及版本化模型标识。模型内部接口为 `/v1/logo/match`，每批最多 8 个参考图，API 自动分批；不得将任意远程图片 URL 传给模型。匹配前后校验样本列表、目录版本与原图片关联，改名、删除或旋转导致变化时拒绝旧结果。
- 模型权重固定 SHA256 并打入 OCR 镜像；启动时核验本地权重，不联网下载。内容寻址 LRU 缓存最多 128 份局部特征，缓存不属于业务数据库；模型变更或容器重启后从持久裁剪图重新计算。Logo 匹配与两种 OCR 共用串行队列，保持两个容器。
- “商店名称”仍是图像到店名的人工映射；删除原收据保留已确认样本，删除别名后该图不再作为参考。全新数据库直接安装镜像内审核过的裁剪图及标签；重启不覆盖用户改名或删除。

模型依据：[SuperPoint](https://arxiv.org/abs/1712.07629)、[LightGlue](https://github.com/cvg/LightGlue)。分区域折痕验证和前景覆盖计分由本项目实现，不把通用模型能力宣称为纸张折痕保证。

真实流程冒烟：

```bash
python3 tests/backend_api/smoke_logo_alias.py \
  --url http://127.0.0.1:5000 \
  --key-file playground/secrets/ocr-api-key \
  --photo tests/backend_api/corpus/images/b38d62dd-0.jpg
```

该测试只创建/清理自己的样本别名与收据，证明新收据使用图像别名而非 OCR 文本店名；不作为不同照片的匹配准确率。现有 17 张调试语料的留一比较在 0.90/0.08 下为 9 次正确自动匹配、8 次拒绝匹配、0 次错误自动匹配，初始阈值依据这一小样本，尚非独立验证。


### 商品税码与商店 SKU

Costco（店名含 Costco、开市客或好市多）商品以 `^\s*(?:([A-Za-z])\s+)?([0-9]+)\s+(\S(?:.*\S)?)\s*$` 拆分票面前缀，例如 `E 2338 WHITE PEACH` → `taxCode=E`、`sku=2338`、`rawName=WHITE PEACH`。税码只保留一个字符，不推断税率/税种。其他商店不自动套用这一规则。识别、拆分和校验全部在 backend_api；客户端仅显示和提交编辑。

DTO 的 `taxCode`、`sku` 均为可空字符串；SKU 保留前导零。`sku(sku_id, merchant_id, code)` 对 `(merchant_id, code)` 唯一，店名经 merchant 关联，不重复存储；`line_sku(line_id, sku_id)` 关联票面明细，`line_tax_code(line_id, tax_code)` 保留该次交易的税码。未确认店名的手工 SKU 暂存 `line_unmatched_sku(line_id, code)`，设置店名后保存会绑定到相应商店 SKU。SKU 不直接决定品牌、规格或跨店商品身份，按票面名称与重量关联商品，按商品名称跨店汇总。四张表符合 3NF；不要求每件商品有 SKU。

确认页可分别修改/清空税码和 SKU；已发布旧客户端不提交新字段时，后端保留现有值，显式 null 才清空。多图去重同时比较 SKU 和税码；合并不同明细时清空标识，避免误继承第一件商品的 SKU。当前 schema 仍只支持初始化和当前版本检查，没有自动迁移入口。


### 先确定店名，再选择商店解析规则

后台任务的固定顺序为：读取首张照片的原始 OCR/版面 → 提取并匹配 Logo 图像别名（已有确认店名可直接使用）→ 选择 `merchant_rules::Profile` → 按该店铺规则进行商品结构化 → 拆分 SKU/税码并核验、保存。原始 OCR 为 Logo 裁剪提供坐标，不决定店名，也不先解释商品字段。同一张收据的后续照片复用首次确定的店名和解析方案；原始 OCR 结果直接复用，不因识别 Logo 再跑一遍 OCR。

当前内置 Costco 与 Generic 两种解析方案。Costco 的结构化提示明确税码/SKU 不是数量、重量或价格，保留中间原始前缀，随后由确定性正则拆分；未知店名或没有专用规则的商店使用 Generic，不套用 Costco 前缀规则。后续商店规则在 `merchant_rules` 中扩展。每次识别结果保留 `receipt_parser.profile` 便于追踪所用规则。无收据店名上下文的 Chat Completions 调用采用 Generic；不使用 OCR 输出中的店名来选规则。


Costco 税码允许缺失：`2338 WHITE PEACH` 提取 `sku=2338`、`rawName=WHITE PEACH`，`taxCode=null`，不按历史商品补猜税码。名称内的数字完整保留，多次保存不会再次把名称开头数字当成 SKU；其他店铺仍走自身/通用规则。


### 多区域 Logo 裁剪

按顶部布局框坐标排序，以首个有效框为锚，合并纵向相邻、横向重叠的 header/title/logo/image/figure 区域。合并限制间隔、单块高度和整体高度，普通 text 区域不用于扩展，避免把地址、电话或后面的 REFUND/SELF-CHECKOUT 标题拼入 Logo。先求合并框，再统一加边距；不读取店名文字来决定合并。扩展后的裁剪若来自同一未变照片且包含原已确认区域，沿用原 Logo 样本的 merchant 关联；不同照片或不相交区域不继承别名。

Logo 图像别名匹配成功后，在商品结构化之前独立保存草稿店名并递增收据版本。后续模型截断或其他商品识别失败，任务仍显示失败，但已保存店名保留。仅对仍在运行的任务、未删除且未确认的草稿、空店名及与任务快照一致的照片/商品/币种执行；保留并发修改的时间、分店等头部字段，不覆盖已填写的店名。完成商品识别时仍使用原任务快照做三方合并，正常成功任务不会因提前保存店名产生版本冲突。

### 收据页面重新识别

Android/iOS 共享编辑页在 Trash 左侧提供刷新图标“重新识别”。有照片的草稿可重试：先检查是否已有排队/运行任务，再保存当前编辑并用保存后的版本提交异步识别，提交成功返回总览。已有任务时提示并留在当前页，不重复提交；保存或提交失败时保留编辑页并允许重试。无照片或已确认的收据禁用按钮，避免空任务及覆盖正式记录。

### 防止商品结构化重复生成

已确定 Costco 身份且整段含商品计数、小计、税和总额时，后端尝试逐行提取 SKU 商品与 `优惠编号 / 商品SKU 金额-` 优惠。必须商品数吻合、每条优惠关联前一商品 SKU、逐行净额等于小计、小计加税等于总额才采用；未知行、缺数、金额不符或退款等未覆盖版式仍走模型。真实同名重复购买保留为独立行，优惠分别关联对应购买；尾部税码转入独立 taxCode 字段。完整校验成功后，结构模型只提取头部（lines 数组约束为空），后端附加已核验的明细与总额，避免重复生成商品。

通用结构化遇到截断、无效 JSON 或重复金额行超过票面金额出现次数时，从编号后的原 OCR 行自动重试一次；不将截断结果直接写库，不按商品名去重。重试改变提示和采样参数，失败则维持失败状态，不无限重试。成功结果的 token 用量包含第一次失败生成及重试；Logo 店名独立保存逻辑保持不变。

Costco 的 item_discount 通过 discountTarget 继承对应商品的 SKU 和 taxCode，包含前导零；商品缺税码时优惠也为空。识别结果、编辑预览和保存后的读取使用同一规则，修改商品标识或优惠对象后同步生效。遵循 3NF，优惠关系仍由 line_discount 表维护，SKU/税码只存商品行；优惠 DTO 中的两个字段由关联商品派生，不重复持久化，也不采用客户端提交的独立优惠标识。既有优惠记录读取时立即生效，无需迁移或重新 OCR。

Costco 预扫描表格同样按完整边界、商品计数和净明细加税等于票面总额核验；已识别的小计也必须相符。瓶押金单列 deposit，不计入商品数。优惠打印数字 SKU 时必须与前一商品对应；预扫描区域内只打印优惠描述、未打印目标 SKU 时可按前一商品关联，并黄标说明。SKU 和票面星号名称从原始行保留；模型删掉前缀时，只在名称（容许边缘装饰星号不同）和金额唯一匹配的原始行中恢复，不猜测有歧义的 SKU。行首单字母优先作为标记，无行首标记时保留金额后的单字母。

旧版 DINOv2 曾使用 0.60/0.05 的余弦阈值；现已由上述局部身份匹配取代，新的分数不能沿用旧分数含义。


## 商品名称、分类与重新识别

- 名称仅有“票面名称”和“商品名称”两层。`printed_name(printed_name_id, raw_name)` 保存票面名称；`product_name(product_name_id, name, category_id, last_used_at_utc_ms)` 保存共用商品名称、分类和最近使用时间；`printed_name_product_name(printed_name_id, product_name_id)` 是多对一映射。规格表 `product(product_id, printed_name_id, weight_g)` 只保存规格，满足 3NF。
- 商品名称不存在时，显示与报表回退到票面名称。同一个商品名称跨店、跨票面名称、跨重量分组。商品优惠沿目标商品汇总。
- 客户端“商品管理”有四个 tab：**票据名称**（票面名称 → 输入或选择商品名称）、**商品名称**（名称标签，X 删除）、**商品分类**（商品名称 → 输入或选择商品种类）、**商品种类**（种类标签，支持添加、删除、编辑与父类管理）。商店 Logo 名称另有入口。
- 删除商品名称只删除名称字典项和映射，保留所有收据、明细、照片。修改或清空某一票面名称的商品名称后，服务器在同一事务中清理没有任何票面名称关联的商品名称；仍有其他票面名称引用的名称保留。收据编辑需先处理全部行的映射，再清理，以免行间交换名称丢失分类和名称标识。删除分类后，关联商品名称和明细分类归到未分类，子分类移到顶层；系统保留类别不可删除。
- 分类属于商品名称，分类调整同时更新其已保存明细；新识别自动读取已有名称和分类。点击分类标签仍可改名和管理父类。
- 新库预置 22 个普通商品种类：杂货、电器、电子产品、水果、蔬菜、畜禽肉、水产品、调料、日用品、家具、保健品、奶制品、饮料、坚果、豆类及其制品、鸡蛋、大米及其制品、小麦及其制品、粗粮、冰激凌、酱料、零食。普通预置分类可删除，重启不会重新添加。
- 收据编辑 DTO 使用 `productNameEdit`；识别候选使用 `product_name`；展示使用 `display.productName`。未传待编辑字段不修改名称映射，空值清除，非空写入。预览不写库，保存失败整体回滚。票面对应的已保存商品名称优先于 OCR 的候选名称。
- 已确认收据可重新识别，提交时原子转为草稿并入队；无照片或版本冲突时不改变原记录。金额、时间、原图和录入时间不因名称管理改变。
- 当前 schema 15，空库直接初始化；没有运行时迁移代码。playground 更新先完整备份，再离线转换名称与分类关联，并验证收据、明细、照片和金额未改变。

Costco 保留缺空格 SKU 规则：`1062201ORG EDAMAME` → SKU `1062201`，票面名称 `ORG EDAMAME`。其他店不套用 Costco 规则。

### 报表下拉刷新

Android/iOS 报表页支持下拉刷新，包括内容不足一屏和空报表。刷新沿用周期、偏移、币种与分类筛选，重新请求后端周期范围、本期与上期统计以及分类列表；统计仍由后端读取当前数据库计算。刷新失败保留已显示数据并提示错误，再次下拉可重试；过期请求结果不会覆盖较新的筛选结果。

### 分类读取的一致性

`line_effective_category` 对已关联商品名称的商品行直接使用 `product_name.category_id`，不受旧明细分类快照影响；商品优惠继承目标商品的有效分类。没有商品名称映射的商品、税费及独立调整仍使用明细分类。报表分组、分类过滤、收据读取和 CSV 导出共享这条规则。历史金额和原始明细不因分类读取修复而重写。

### 商品管理中的待完善项目

票据名称页将未关联商品名称的票面名称置顶；商品分类页将系统“未分类”对应的商品名称置顶，判断依赖系统类别标识而非显示文字。两组之间显示 0.5 逻辑像素细分隔线；只存在一组时不显示分隔线。每组保持接口返回顺序，保存后重新加载并按最新状态分组。


### 确认后建立名称库及名称追溯

草稿保存和 OCR 自动落库仅保存收据明细；通过现有票面名称查询已知商品名称，但不创建全局票面名称、商品规格或商品名称映射。草稿中输入的商品名称保存在 `line_product_name_candidate`，空字符串表示明确清空；重量保存在明细本地表。整张收据确认时才建立全局关联，无单项确认入口。

同一事务中维护约束：全局票面名称集合等于未删除的已确认收据中非空商品票面名称集合；商品名称必须存在票面名称引用。修改票面名称、移除明细、删除/放入回收站及重新识别转草稿都会回收无引用名称，仍被其他已确认商品使用的名称保留。放入回收站/转草稿前保留局部名称、分类与重量；恢复已确认收据时重建关联，已有的当前名称映射优先。没有运行时迁移代码。

商品名称标签可点击查看包含该名称的收据，按录入时间倒序排列。`receipts/list` 接受可空 `product_name_id` 筛选，使用当前名称关联（草稿显式候选优先），按收据去重并保留分页；排除回收站。点击任一收据进入原编辑页，返回后重新查询，名称改变或删除后列表随之更新；空列表与加载失败均可刷新。
