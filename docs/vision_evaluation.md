> 历史模型实验记录；当前方案为[双 OCR 与店铺解析](backend_ocr.md)。

# Qwen3-VL 端到端识别验收

> 本文保留 vision-v5 基线。当前按店铺选择模板的 vision-v7 结果见 [商店提示词实测](store_prompt_evaluation.md)。

评测时间：2026-09-16 晚（纽约），2026-09-17 UTC。版本：`vision-v5`。

## 结论

架构改造、构建和异步任务链路已完成并部署到 playground。Qwen3-VL-8B-Instruct 直接读取同一收据的全部图片并输出 JSON；API 保留 Logo 图像别名、结构校验、金额/重量/时间运算，旧商品文字解析器已退出生产路径。

**识别准确性尚未全部验收通过。** 17 张历史问题收据中，8 张通过全部人工标注字段检查，8 张返回的结构化结果存在字段错误，1 张返回 HTTP 502。另 3 张近期问题照片中，1 张通过关键项检查，2 张仍有错误。这不是随机样本或字符准确率，也不足以证明优于旧模型。离线测试通过不代表照片识别正确。

原始报告、提示词、schema、配置和镜像摘要保存在 [本次评测目录](../tests/backend_api/corpus/baselines/2026-09-17-qwen3-vl/)。本次未改写已有收据；异步测试只创建并清理自己的副本。

## 实际部署与程序验证

- 两个健康容器：Rust `backend_api` 和运行 vLLM 的 `backend_ocr`。仅 API 发布 `0.0.0.0:5000`；模型通信使用 Docker 内部网络。
- 固定版本 Qwen3-VL-8B-Instruct，BF16；保留原 DINOv2 Logo embedding 与已确认 Alias。模型权重位于 OCR 镜像中，运行时离线加载。
- 32K 上下文、单图最多 6,291,456 像素、全部图片共享 16,777,216 像素预算、最多 16 图、两个推理序列。超出容量显式报错，不丢弃照片。
- `build_docker.sh` 完成两个镜像和 Docker 内 Android APK 构建：76 项 Rust 测试、26 项 Flutter 测试、4 项 OCR Python 测试、2 项 Android 打包测试通过；Rust 格式/Clippy、Flutter 静态检查通过。两个 GPU 评测用例为显式执行，普通构建跳过。
- 实际任务提交约 9–10 ms；两个任务同时进入 running，识别期间收据查询正常，完成后由服务器自动保存待确认草稿。
- 两张有重叠的合成照片通过：只保留 MILK、BREAD、EGGS、RICE 四个商品及零税额，总额 14.00，保存两张原图和一份整张收据识别结果。此项证明已测重叠场景，不代表所有长收据都已验证。
- 真实 Costco 照片副本从空店名开始，经 Logo 裁剪、已有图片 Alias 得到 Costco，随后自动保存识别草稿。
- APK build **10025** 可下载，实际文件 SHA256 与更新清单一致；未认证业务 API 返回 401。
- 当前环境为 Linux，未进行原生 iOS 编译或此次手机界面操作验证；客户端接口保持现有协议。

## 17 张历史照片

逐张原始输出及差异见 [real-receipts.json](../tests/backend_api/corpus/baselines/2026-09-17-qwen3-vl/real-receipts.json)。指标包括完整商品名、中文标准名称、金额与符号、折扣关联、重量、重复商品、总额及交易时间。模型店名强制 null，Logo Alias 单独验证。

| 追溯编号前缀 | 本次结果 |
| --- | --- |
| b92bd0ff、f7cc0090、2f083787、3270f3c9、2718947f、f3bca374、00c86447、6fe7d01a | 全部标注字段通过 |
| 391b3273 | 把支付金额 123.80 当成消费总额 138.03；时间秒数和一处名称有误 |
| efe47023 | OPTIMUM W 漏掉末尾 W |
| bbbfe093、e8698610 | 退款金额/总额被识别为正数 |
| 5e4547ea | 2.81 lb 称重信息错误关联到 FAGE，苹果缺少数量与单价 |
| a730a1be | 中文错字、两条豆腐优惠归属及净价标记错误 |
| 00710190 | 优惠已经包含在票面价中却未标记，优惠行未使用商品名 |
| b38d62dd | HTTP 502；日志显示首次返回的图片证据坐标无效并触发重试，评测未保存第二次失败的响应正文 |
| e1be8ec6 | 秒数、中文名称、豆腐优惠关联及净价标记错误 |

其中 16 张返回了可验证的结构化数据，13 张的票面总额与标注一致。仍有金额合计不符的结果会保留差额供用户核对；**金额相等也不能证明正确**，例如整张退款被识别为正数时，内部金额仍可相等。这类语义错误不能依靠 JSON 或加法校验发现。

## 3 张近期照片

这三张使用人工核对的关键项（商品数、SKU、优惠金额/关联、税、合计），不是完整字段标注，因此不与上述 17 张合并计算全字段通过率。

| 追溯编号前缀 | 结果 |
| --- | --- |
| 3a8e3c19 | 通过：5 商品、两条 -5.00 优惠、正确 SKU 与关联、税、总额 256.70 |
| e6c62f11 | 失败：优惠漏项，/BRSH HD 和瓶押金被当成商品，SKU/商品数/合计错误 |
| 6d9da1ec | 失败：商品数和优惠金额正确，但优惠关联到错误商品、未标记已含优惠净价，合计错误 |

## 协议与后续评测约束

模型只返回票面金额及其 `amount_basis`（原价或已含关联优惠的净价）；API 根据明确的关联执行净价与优惠的加减。包装重量返回原数值和单位，由 API 换算成克。此设计减少模型计算，但不会修复模型判断错的关系。不得为通过评测恢复按店名/文字猜商品的 API 规则，也不得修改人工答案迎合模型输出。

本次提示词已覆盖历史的 Costco SKU/税码、预扫描区、优惠、SkyFoods 净价、中英文、WT、退款、TIPS、时间和多图重叠等反馈。下一次改提示词或换模型应重复运行同一组照片；当前结果保留为基线。暂不能把本版称为“全部历史边界问题已解决”。

## 重复执行

服务启动后，在项目根目录执行：

```bash
RECEIPT_BENCH_URL=http://127.0.0.1:5000 \
RECEIPT_BENCH_CONFIG="$PWD/playground/data/backend_api.toml" \
RECEIPT_BENCH_OUTPUT="$PWD/build/vision/real-receipts.json" \
cargo test --manifest-path src/backend_api/Cargo.toml --test corpus live_image_benchmark -- --ignored --nocapture

python tests/backend_api/vision_reported.py \
  --url http://127.0.0.1:5000 --config playground/data/backend_api.toml \
  --output-directory build/vision/reported

python tests/backend_api/smoke_async.py --scenario multi \
  --url http://127.0.0.1:5000 --config playground/data/backend_api.toml \
  --data-directory playground/data
```

`smoke_async.py` 的另外两个场景为 `parallel`、`logo`。Logo 场景依赖本地已确认的 Costco 图像 Alias。准确性评测发现任一差异会非零退出并保留报告；不得忽略失败后宣称识别全部通过。
