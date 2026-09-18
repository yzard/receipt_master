> 当前识别架构已改为 Qwen3-VL 多图直接生成 JSON；下文旧 OCR/结构化模型及文本规则记录属于历史方案。现行设计见 [backend_ocr.md](backend_ocr.md)。

# 第二版：后端集中存储与统一数据 API

状态：第二版代码已实现，后端与 Android 已完成本机验收；iOS 原生验收等待 macOS/Xcode。日期：2026-09-15。
本计划在与第一版冲突时优先：业务数据从手机迁到 backend_api，第一版的金额、分类、商品身份、人工确认和时区规则保留。

## 1. 目标与边界

- Android 和 iOS 共用 Flutter 客户端，通过 backend_api 的统一 API 访问全部业务数据；不再创建、查询或更新客户端业务 SQLite。
- backend_api 使用 SQLite 保存收据、明细、商品、别名、分类、图片关系、识别记录、预算提醒等数据。
- 相机/相册取得的照片与对应 receipt 长期留存于后端；原始上传字节保留，预览及 OCR 衍生图另存。Android/iOS 仍在测试阶段，旧本地数据库、照片和识别记录不导入第二版。
- backend_api 的唯一业务持久化根目录为 `/data`；playground 用 `playground/data/` 绑定到容器 `/data`。
- 维持两个容器：backend_api 和 backend_ocr；OCR 通过内部 REST 通信，不直接打开数据库或挂载业务照片目录。
- 继续由 backend_api 提供 APK 和更新清单，客户端更新继续使用 APK 服务的 host、published port。
- 第二版使用全新后端数据库，不做旧数据迁移、旧版兼容导出或跨版本数据对账；不自动删除设备现有测试文件。
- 本版按个人单工作区、多设备共享实现；暂不引入多用户账户、权限角色或离线数据库同步。今后供不同用户独立使用时另做用户隔离迁移，不能直接把共享密钥当用户身份。
- 手机允许保留连接凭据、设备偏好、可丢弃缓存、临时下载，以及待上传照片文件和最小上传状态文件；这些不构成业务数据库。未获服务器确认的照片不得自动删除。
- 离线时明确显示无法读取/保存服务器数据，不伪装保存成功，不创建第二套离线业务真相。

## 2. Source code review

以下记录实施前对第一版的静态代码与调用链 review；位置和行号对应当时源码。后续实现与实际验证结果见文末。

| 位置 | 当前实现/发现 | 对迁移的影响与处理 |
| --- | --- | --- |
| `src/shared/lib/main.dart:19`、`data/store.dart:270` | 两个平台启动同一个 LocalStore，手机 SQLite 开启 WAL；并非 Android/iOS 各有不同数据库实现 | 共用客户端改一次，两个平台都切到 API；移除本地数据库启动和恢复逻辑 |
| `data/store.dart:12` | AppStore 用本机队列和 isolate 串行执行约三十项操作 | 保留业务方法边界但换成类型化 HTTP repository；本机队列不能代替后端多客户端事务 |
| `data/store.dart:515` | 保存包含商品匹配、别名、分类、折扣、证据关系和校验；整体删建明细 | 把完整事务移到后端，禁止只做表级 CRUD；保留审阅状态的业务语义，并避免无条件重建导致身份/审阅信息丢失 |
| `ui/editor.dart:138` | refreshImages 只取新 revision 填回现有表单，不重新合并字段 | 多设备下可让旧表单持新 revision 覆盖另一设备修改；改为冲突检测和明确重新加载/合并 |
| `data/files.dart` 的 importImage | 导入时缩到宽 2400 并重编码 JPEG，未保存收到的原始文件 | 第二版先持久化原始上传字节，再生成衍生图，不能把预览图称为原图 |
| `data/files.dart` 的 rotateImage | 改路径、尺寸和证据坐标，但未更新 content_sha256 | 确认存在的哈希一致性缺陷；后端每个不可变文件有独立哈希，旋转生成新版本 |
| `ui/editor.dart:184` | 手机逐图调用 Chat Completions、写 OCR JSON、记录费用，并合并结果 | 整段编排、任务状态及结果应用迁到后端，手机只发起/查询/确认 |
| `ui/editor.dart:438`、`:813`、`ui/home.dart:62` | UI 直接打开本地照片，启动恢复 pending_capture | 改为鉴权媒体访问和待上传恢复；不能只替换 AppStore 而遗留 File 调用 |
| `data/files.dart` 的 createBackup/restoreBackup | 备份包含 SQLite 和媒体，恢复直接交换本地目录 | 服务端备份需要一致性快照；不能在挂载点 `/data` 上照搬 rename 交换 |
| `data/store.dart:852`、`ui/reports.dart` | 本地查询明细并在 UI 聚合，当前时间区间由客户端处理 | 服务端完成过滤/汇总；保留时区与金额口径，使用分页明细 |
| `src/backend_api/src/lib.rs`、`config.rs` | 只有 OCR、health、APK 路由，无数据库/data配置；一个共享 Bearer key | 增加持久层和业务路由；照片、备份、全部业务接口需鉴权 |
| `src/backend_api/src/main.rs:43` | 模型 supervisor 结束会使整个 API 退出；health 也依赖模型 | 第二版必须拆分 API/存储健康与识别可用性，模型失败不阻断查看、编辑和下载 |
| `docker/docker-compose.yaml` | backend_api 只有配置和 `/artifacts` 挂载，无持久化数据卷 | 添加 `/data` 可写 bind mount；APK 继续走独立只读 `/artifacts` |

### 优先风险

1. **数据覆盖**：任何客户端改数据都必须使用服务端版本检查，不能直接沿用本地队列及 refreshImages 逻辑。
2. **照片丢失或引用损坏**：文件系统和 SQLite 不是同一个事务；上传、旋转、清理、备份必须定义提交顺序和恢复过程。
3. **服务不可用**：将数据迁到后端后，模型失败导致 API 退出的当前行为会让全部历史数据不可访问，须先改。
4. **业务规则遗漏**：重写后端时需覆盖回收站、分类、别名、证据、未知重量和 OCR 记录；不导入旧测试数据，但保留这些功能。

## 3. 目标架构与目录

```text
Android / iOS
  └── backend_api（统一 API、鉴权、SQLite、照片、报告、识别任务）
        ├── /data（宿主持久化）
        ├── /artifacts（只读 APK 与更新清单）
        └── 内部 REST → backend_ocr
```

```text
src/backend_api/
  schema.sql              唯一权威的当前完整业务表结构
  src/db/                 连接、迁移、repository、事务
  src/domain/             金额/商品/分类/确认规则
  src/storage/            上传、媒体、备份、恢复
  src/services/           收据、报表、识别任务
  src/routes/             业务 API 与受保护文件访问
src/shared/lib/data/      API client、repository、DTO、上传恢复
src/shared/lib/domain/    客户端展示模型和即时输入提示
src/android/、src/ios/    平台拍照、凭据、安装更新等桥接
```

`src/shared/resources/database/schema.sql` 的业务模型作为后端新 schema 的设计依据，实施时移除手机端 schema 资产和 SQLite 依赖。后端保留唯一权威 schema，不保留旧库读取或导入兼容层。

### `/data` 布局

```text
/data/
  database/receipts.sqlite    同目录包含 WAL/SHM
  media/originals/            不可变原始上传文件
  media/derived/              缩略图、旋转图、OCR 输入图
  recognition/               原始 OCR 响应与合并候选结果
  staging/                   未完成上传和恢复的临时数据
  backups/                   完整快照包与校验清单
```

- 路径由服务端生成；数据库保存相对路径，不接受客户端指定宿主路径，不向客户端暴露磁盘路径。
- `/data` 不放在镜像层、`build/`、`/tmp` 或 OCR 权重目录。
- Docker 配置新增 `data_dir = "/data"`，启动前验证可写性，失败则明确退出，不回退到临时数据库。
- Compose 的 backend_api volumes 增加 `../playground/data:/data`（相对 docker/docker-compose.yaml）。宿主的 `/data` 根目录不是本次默认挂载源。
- run_playground.sh 创建宿主目录并检查容器运行身份的写权限，不清空、不递归修改无关目录；Ctrl+C、重建镜像、重新创建容器均保留数据。
- runtime 数据、备份和密钥不进入 Git 或 Docker build context。两容器网络和 0.0.0.0:5000 → 8000 映射维持现状。

## 4. 数据库与事务设计

### 保留第一版业务模型

参考现有 17 张业务表、索引、视图及触发器设计全新的后端数据库，保持 3NF。后端 schema 版本管理用于新库初始化及未来升级，不代表需要迁移第一版手机测试数据。

- merchant/store_location、product_name/product、store_alias 和 category 保持拆分。
- 商品身份仍为含品牌/口味的标准名称 + 可空重量；重量存整数 mg，UI 输入 g；未知重量不自动并入已知重量商品。
- 金额整数、币种小数位、数量及单价缩放规则不变，禁止浮点累计金额。
- 商品折扣为负数行；税、小费、押金等独立行；未解释差额不自动归为小费。
- UTC 毫秒保存所有时间；服务器生成创建/修改/接收时间，消费时间由识别和用户确认提供，保留估计来源。
- 树形分类、特殊未分类节点、历史重分类策略、黄标审阅及正式确认规则继续保留。

### 新增或调整的结构

| 表/概念 | 设计 |
| --- | --- |
| schema 校验 | 空库直接初始化当前表结构，不提供旧库迁移；拒绝结构不匹配的库 |
| receipt.version | 每次业务修改的单调版本；与识别输入的 input_revision 分离；所有写入在事务内检查 expected_version |
| 分类/商品/别名版本 | 对独立编辑对象采用同样的条件更新；批量历史重分类在同一事务提交 |
| media_blob | blob_id、唯一 relative_path、SHA256、字节数、MIME、宽高、创建 UTC；文件不可变 |
| receipt_image | receipt_id、顺序、original_blob_id、current_blob_id、采集/导入 UTC、来源和软删除时间；图片字节属性归 blob 表，避免重复依赖 |
| image_revision | 图片版本、blob_id、旋转/坐标变换及创建 UTC；识别证据引用明确版本，旧 OCR 不指向新旋转图 |
| recognition_job / job_image | 持久化任务状态、收据输入版本、模型、候选结果；关系表保存有序输入图片版本快照 |
| recognition_run | 单图/单次 provider 调用记录、原始结果、费用、错误；关联 job；审阅后应用与识别成功是两个状态 |
| idempotency_record | 操作作用域、请求键、请求摘要、资源ID及完成结果；同键同内容返回同结果，同键不同内容返回冲突 |

具体 DDL 在实施步骤 1 固化并逐项检查函数依赖；媒体拆分时同步调整 evidence 外键和图片版本，不同时维护两套路径/哈希字段。

### SQLite 并发

- 一个 backend_api 实例管理该 SQLite；启用 foreign_keys、WAL、busy_timeout，SQLite 文件放本机文件系统，暂不做多实例共享网络文件库。
- 使用后端 SQLite 驱动的受控连接/阻塞执行边界，不能阻塞 Tokio 网络线程。
- 多表写入以短事务完成；OCR、文件上传、图像编码不占用数据库写事务。
- 保存、删除、恢复、图片排序/旋转、识别结果应用均检查版本；冲突返回 409，客户端展示冲突并重新加载，不能静默覆盖。
- 创建/上传/任务发起等可重试操作带幂等键；读请求的重试不能产生写入。

## 5. 统一 API 契约

遵循项目 action-style 约定：普通业务路由使用 POST `/api/v1/<component>/<operation>`，读取无副作用；媒体和下载使用 GET/HEAD。保持现有 OpenAI 兼容 `/v1/models`、`/v1/chat/completions` 不变。

| Component | Operation | 范围 |
| --- | --- | --- |
| receipts | create/list/get/save/confirm/trash/restore/purge/check_duplicates | 收据与明细、回收站、重复提示；save/confirm 为完整业务事务 |
| images | upload/list/reorder/rotate/remove/restore | multipart 原始照片、图片版本与排序；返回媒体ID，不返回本地路径 |
| categories | list/save/delete | 分类树、保留类别保护、删除后迁移目标 |
| products | list/rename/merge/classify | 商品名称+重量身份、历史分类更新策略 |
| aliases | list/save/delete/suggest | 商家内别名及跨商家商品归一 |
| reports | summary/details | 日期范围、币种、类别树、商品种类、日/周/月/季/年汇总与分页明细 |
| recognition | start/get/list/cancel/apply | 后台持久任务、结果预览和人工确认应用 |
| budgets | get/save | 服务端预算与费用提醒，不限制识别额度 |
| exports | csv/create_backup/get | 服务端一致数据导出和异步备份状态 |
| maintenance | prepare_restore/commit_restore/get | 后端自身备份的整库恢复，需要维护模式和明确确认 |

- 所有业务和媒体/备份接口要求 Bearer 凭据。GET `/api/v1/media/{id}` 等通过身份验证后解析文件；不能把 `/data` 当公开静态目录。
- 仅 health、APK、更新清单与固定更新 APK 路径延续公开访问。APK 内预置共享 key 在个人试用范围继续使用；拿到 key 的设备共享同一份数据，未来多用户发布前必须替换身份体系。
- 定义 OpenAPI/JSON DTO 契约及错误格式：request_id、code、message、必要的当前版本；使用 400/401/404/409/422/503 区分失败。
- 列表使用稳定排序+游标分页，禁止列表接口一次返回全部图片字节；媒体使用独立鉴权下载和可丢弃缓存。
- 服务端重新验证所有业务规则，客户端校验仅用于即时提示。普通客户端不再直接调用 OCR provider 或提交任意本机 schema/SQL。
- UI 将“后端地址和访问凭据”与“识别模型配置”分开；模型及 provider 密钥由后端管理。Android 更新来源仍固定为安装包预置的 APK 服务地址，不随 OCR 模型配置改变。

## 6. 照片留存、识别与故障恢复

### 上传与留存

1. 先通过 API 创建 receipt 草稿，取得ID和版本，再拍照/选图。相机返回文件暂存在手机，记录 receipt_id、upload_id 和采集 UTC。
2. 上传原始字节至 staging，流式计算 hash，检查可解码性与格式；同一 upload_id 重试不生成重复照片。
3. 生成需要的衍生图，flush 后原子移动到最终文件位置，再在短事务中写 blob、receipt_image 及版本。
4. 只有数据库提交并返回明确资源ID后，手机才删除待上传副本。网络响应丢失时查询/重试原幂等键确认结果。
5. 崩溃在文件落盘与 DB 提交之间可能产生无引用文件；启动修复/延迟清理仅删除已确认无引用且不属于活跃上传、识别、备份的文件。
6. 相同照片上传到不同收据不能自动合并收据；重复识别只是提示。

原始照片不可被旋转、缩放覆盖。移除照片先软删除，仍保留归属和历史版本；收据进入回收站时照片继续存在。只有用户明确永久删除后才允许清理关联文件，共享引用存在时不得删除 blob。备份中的历史副本按备份生命周期管理，不声称永久删除能自动擦除既有导出包。

### 识别流程

- 客户端提交 receipt_id、expected_version、幂等键，服务器建立任务并固定有序图片版本快照，返回 200 + job_id（沿用统一接口约定）。
- 后端从自己存储读取照片，逐段调用现有 OCR/结构化链路并合并重叠区域，保留单图响应及合并候选结果。
- App 退出不取消任务；重新打开可查询状态。当前本地双模型部署在重启后自动重新排队未完成任务，保留 interrupted/unknown 调用记录；若以后接入付费提供商，需要单独制定重试计费策略。
- 完成识别不自动覆盖已确认记录；人工确认 apply 时检查输入和收据版本，过期结果保留但返回冲突。
- 预算仅提醒，不因为金额、月预算或次数阻止识别；传输失败/格式错误与预算限制是不同概念。
- API 存储健康检查与 OCR readiness 分开。Qwen/OCR 故障只影响识别，模型管理可退避重启；CRUD、报告、照片、备份和 APK 下载仍可用。

## 7. 报表与时间

- 服务器汇总，客户端展示；仅正式且未删除记录计入报表，不计算平均每 receipt 消费。
- 按币种分别统计，不隐式换汇；类别树汇总包含后代，商品种类按既有名称+重量规则归一。
- 请求携带当前设备 IANA 时区、粒度和本地日期范围，服务器转换为 UTC 半开区间并按当地日历分桶；也支持明确 UTC 区间。
- 验证 DST 的 23/25 小时日、跨年周及季度边界；响应包含实际 UTC 区间和时区，便于复现。
- 消费时间仍统一存 UTC，UI 转为当前设备时区；设备恢复前台或时区改变后刷新展示时区，不能只在启动时读取一次。

## 8. 全新初始化与后端备份恢复

### 测试阶段直接切换

- backend_api 首次启动创建新库、初始化币种和系统分类，不读取手机数据库或旧 `.receiptbackup`。
- Android/iOS 切换到 API 后，移除 LocalStore、旧库恢复、旧备份导入及本地业务 schema 依赖。
- 不提供旧测试数据迁移工具、兼容窗口、ID 映射或迁移对账；测试验收用新 fixtures 和通过 API 创建的数据。
- 新版不再访问设备上的旧测试库，但本次计划不授权自动删除这些文件。

### 后端备份/恢复

- 备份使用 SQLite 一致性快照，从该快照枚举引用文件；备份期间 pin 文件防止 GC，输出 manifest+哈希。不能分别随意复制主DB、WAL和正在变更的媒体。
- 备份必须覆盖原图、衍生图、OCR结果及必要 schema 信息；`/data/backups` 方便保留，但同盘备份不能代替下载到其他介质。
- 仅支持第二版后端自身备份的恢复，不兼容第一版手机备份。恢复先验证到 staging，再进入维护模式、停止写入/任务、关闭数据库连接并保存恢复前快照。
- 不 rename 挂载根 `/data`。在其内部替换受控数据库/媒体目录，使用持久恢复日志标识每一步；启动时先完成/回滚未完恢复再开放服务，避免多目录交换一半即接受请求。
- 恢复后校验全部引用及数据库完整性，成功后恢复服务；失败保留原库与日志。

## 9. 实施顺序与验收

以下状态依据实际实现与验证更新；不把未运行的 iOS 原生验证标为完成。

- [x] **1. 固化契约与新库 schema**：后端初始化 schema、DTO/API 清单、错误与版本约定；建立全新测试 fixtures，确认金额/分类/时间等既有业务规则。
- [x] **2. 持久化与可用性基础**：`/data` 配置、Compose bind mount、SQLite 连接/迁移、启动失败行为；拆分 API 与模型存活状态。重启/重建后数据不变，模型断开时数据 API 可用。
- [x] **3. 收据与目录 API**：迁移完整保存/确认事务、类别树、商品/别名、回收站、版本冲突和幂等；用两客户端测试无覆盖、无重复提交。
- [x] **4. 照片 API 与留存**：原图/衍生图、受保护下载、旋转/排序/软删除、崩溃修复；哈希一致，原图不变，关系无悬空引用。
- [x] **5. 后端识别任务**：逐图调用和合并、任务重启恢复、结果审阅/应用、费用提醒；客户端退出仍完成，过期结果不能覆盖新编辑。
- [x] **6. 报表和导出**：服务端汇总/分页、CSV、备份及维护恢复；基于已知样例的汇总结果正确，DST/币种/分类边界正确。
- [x] **7. Android/iOS 客户端切换**：AppStore 替换为 API repository；更新首页、编辑器、图片、报表、设置和备份界面；移除本地数据库及旧备份导入依赖；相机中断/上传重试可恢复。
- [ ] **8. 构建和端到端验收**：Docker 内 Android 构建、两个后端镜像、升级下载回归；Android 真机/模拟器及 macOS/iOS 验证；填写验收结果并更新 README/skill。

### 必测场景

- 新建 → 多段照片上传 → OCR → 黄标编辑 → 确认 → Android/iOS 相互读取 → 日/月/季度/年报表。
- 网络断开、响应丢失、两台设备并发编辑、上传/写事务/备份时服务重启、磁盘不可写或空间不足。
- 无鉴权不能读收据/照片/备份；APK 下载仍可公开访问；路径穿越及跨收据证据引用被拒绝。
- 停止/删除并重建 backend_api 容器后，SQLite、照片和 OCR 结果仍在；重建镜像不清理 playground/data。
- 全新后端首次启动可用，重复启动不重复初始化；后端备份恢复失败不破坏现有库。
- OCR 故障时仍能读取、编辑和备份；费用提醒从不阻断识别。
- 最终正常业务路径不依赖本地 SQLite、schema 资产或本地永久照片目录；不保留旧库兼容层。

## 10. 本版采用的默认决策

1. 单个人共享工作区，Android/iOS 连接同一个 backend_api 就看到同一数据。
2. 在线优先，不实现离线业务库同步；未上传照片保留并可重试。
3. 原始上传文件及收据长期保留，只有明确永久删除才清理；不按 OCR 完成自动清理照片。
4. 宿主挂载源为仓库的 `playground/data/`，容器目标严格为 `/data`。
5. Android/iOS 还在测试阶段，直接使用新后端空库，不迁移旧数据库和照片。
6. 实施已建立全新的后端库并切换本机测试服务；没有导入或删除旧手机测试数据。


## 11. 实施记录与剩余验收

已实现后端 SQLite、受保护媒体、原始照片与旋转衍生图、持久 OCR 任务、后台分段合并、版本冲突与幂等、商品/别名/分类、预算价格、服务端报告、CSV、备份和维护恢复。移动端移除业务 SQLite、schema 资产及直接 OCR 调用，使用同一 API repository。待上传文件整批先落盘，再逐个提交；重复重试共用任务，网络失败保留文件。

采用的具体实现决定：

- 私人单工作区使用现有服务 Bearer key；不引入账户体系。
- 目录使用一个全局 catalog_version，收据各有独立 version；目录改动保守地使已打开的收据版本过期，防止历史分类被旧编辑覆盖。
- 图片版本通过 image_revision 和 job_image 固定识别输入；当前审阅证据随旋转转换坐标，原始 OCR JSON 和输入图片版本仍留存。
- 报表客户端提供按当前设备日历计算的 UTC 半开区间，后端负责筛选和汇总；这是本计划第 7 节允许的明确 UTC 区间形式。
- 个人版备份采用串行快照、同步返回完整包，备份时其他数据写入等待；恢复使用持久日志在挂载目录内部完成。尚未做大型备份的异步任务与流式下载优化。

已实际验证：Rust API/存储测试、Flutter 静态分析与测试、Docker 内 APK 编译及签名、模拟器读取后端收据、相册上传、真实 GPU OCR（MILK/BREAD/税费，总额 6.48）、人工确认和后端报表。强制重新创建 API 容器后，收据内容和原图 SHA256 完全一致，模型加载期间数据 API 仍可访问。

iOS 共享代码和独立构建入口已更新；私有后端默认配置注入与源文件隔离检查通过。当前主机是 Linux，`build_ios.sh` 明确拒绝原生编译。**步骤 8 尚不能标记全部完成：仍需 macOS/Xcode 编译及 iOS 设备验收**。已询问可用 Mac/CI；未擅自推送代码或触发远端发布。

当前 API 契约和运行说明见 [backend_api_v2.md](backend_api_v2.md)。实际验收产物保存在 `build/v2/`。

最终本机验收：23 项 Rust 测试、16 项 Flutter 测试、2 项 Android 发布状态测试通过；Docker 总构建成功。APK 版本 2.0.0，build 10005；模拟器经应用内更新安装到 versionCode 14005。下载清单和两个架构 APK 的 SHA256 校验通过，运行库 integrity_check 与 foreign_key_check 通过。

最终 APK 冷启动成功，重新读取后端已确认收据 USD 6.48；升级后检查显示“已是最新版本”。
