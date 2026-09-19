当前运行路径为 Qwen3.8/NInfer；旧双 OCR/parser 代码已删除。下文相关运行命令仅为历史记录；候选评分 `candidate_comparison_benchmark` 只支持 `candidate`。生产字段适配回归见 `tests/backend_api/api.rs`。

最新复测：[Hualian/TOTAL 提示与 thinking](../../../docs/ninfer_prompt_thinking_evaluation.md)。注意 JSON 可解析与后端 schema 接受率分别计分。

最新结果与图表：[NInfer / Qwen3.8 NVFP4，32 张同图比较](../../../docs/ninfer_evaluation.md)。原始 JSON 合规率与格式适配后的提取指标分开报告。

最新结果与图表：[32 张收据的 Qwen3.8 Q4_K_M 评测](../../../docs/qwen38_q4_evaluation.md)。采用对照原图核验的票面名称标注；旧模型在共同 24 张照片上重新按该标准计分。

> 当前生产采用双文字 OCR + 店铺 parser。离线真实 OCR 回归位于 `../parsing.rs`；本轮 Qwen3.8 为独立离线评测，未切换生产模型。下文较早的 8B/32B 和 NuExtract 记录仍保留其原始口径。

# 真实票据回归语料

最新实测：[全部 24 张已确认收据的 8B / 32B 对比](../../../docs/confirmed_model_evaluation.md)。本次 32B AWQ 没有改善整体结果，默认保留 8B。

## 数据库全部已确认收据

按用户要求，当前模型对比使用 `confirmed/2026-09-17/snapshot.json` 中的 **24 张已确认收据**，而非只使用下方历史问题集。快照通过只读 API 获取每张已确认收据的数据、当前有效照片及其顺序/旋转；所有照片都有 SHA256。原收据不被重识别结果覆盖。离线测试检查 24 张快照和图片完整性。

采集新的快照（目录不可复用已有快照）：

```bash
python tests/backend_api/confirmed_snapshot.py --url http://127.0.0.1:5000 \
  --key-file playground/secrets/ocr-api-key --output build/vision/confirmed-snapshot \
  --fallback-zone America/New_York
```

运行当前已冻结的快照：

```bash
RECEIPT_BENCH_URL=http://127.0.0.1:5000 \
RECEIPT_BENCH_KEY_FILE="$PWD/playground/secrets/ocr-api-key" \
RECEIPT_BENCH_SNAPSHOT="$PWD/tests/backend_api/corpus/confirmed/2026-09-17/snapshot.json" \
RECEIPT_BENCH_OUTPUT="$PWD/build/vision/confirmed-model.json" \
cargo test --manifest-path src/backend_api/Cargo.toml --test corpus live_image_benchmark -- --ignored --nocapture
```

评分对照保存的票面名称、类型、金额、优惠关联、已知重量/数量/单价、SKU/税码、币种和时间。空的可选字段不作为标准答案，分类、用户标准名称/Alias 和店名识别不参与分数；店名作为已知上下文提供给模板路由。金额与单位使用生产解码逻辑，在临时数据库中转换，不往 playground 写入。

时间使用已有识别任务的时区；没有历史时区时显式使用采集命令的 fallback。本次 23 张采用纽约 fallback，1 张有历史纽约时区；已确认 UTC 时间始终保留原值。时间差异应单独审阅，不能据此自动改写已确认数据。

同一个输出可设置以上 `RECEIPT_BENCH_SNAPSHOT`、`RECEIPT_BENCH_OUTPUT` 后运行 `saved_predictions_benchmark -- --ignored --nocapture`，只重新计分、不调用模型。实时评测从 `/v1/models` 获取当前模型标识。

## 专项提取模型对比

2026-09-17 候选使用 `confirmed/2026-09-17-candidates/snapshot.json`，重新从数据库采集全部 24 张确认收据，与前轮的确认内容及照片完全相同。
候选配置和原始结果归档在 `baselines/2026-09-17-candidates/`；[结果报告](../../../docs/candidate_model_evaluation.md)分别统计返回可校验结果、金额、日期、明细行数、全部字段匹配和失败原因。

模型接入由服务器配置指定，客户端不设置：

- API `ocr.protocol: chat`：普通多模态对话协议，例如 Qwen3-VL、InternVL。
- API `ocr.protocol: nuextract3`：把同一 JSON Schema 转为 NuExtract 类型模板，规则放入 `instructions`，失败结果放入 `previous_output`，关闭 thinking。
- API `ocr.protocol: nuextract2`：使用 v2 原生类型模板；规则和重试信息放 system，每张照片独立 user message，避免官方模板丢弃与文字混排的照片或同一 message 的后续照片。
- OCR `engine.family: qwen_vl` 使用图片像素预算；`internvl` 换算成 448×448 动态切片预算，所有照片共享总预算，额外 thumbnail 为模型原生行为。
- 所有候选仍使用同一生产 JSON/关联/金额校验，不修补模型语义，不把无效输出计成成功。评测保留最终 HTTP 错误体，便于区分格式、关联、证据框和服务错误。

复现某个候选时使用归档的 Dockerfile、OCR TOML 和 API YAML，通过 `build_docker.sh` 完成 Android 与两个镜像构建，再由规范 Compose 启动。已冻结的数据和结果不可覆盖。NuExtract 模板转换仅支持当前明确的结构类型；不支持的 Schema 返回错误，不静默猜测。

## 历史问题集

这里有 17 张完整标注票据（原 12 张加新 5 张），逐张核对原图后建立答案。`index.json` 记录追溯编号、原图 SHA-256、人工答案和历史模型输出。另新增 3 张近期问题照片的关键项标注，见 `vision/reported-cases.json`。原图包含真实票据资料，未发送给新的云端服务。

## 三种测试，分别解释结果

1. **离线领域回归**：17 个具名用例将人工核对的结构化输入交给生产 `jobs::decode_receipt`，在独立 SQLite 数据库内验证商品名称、中文标准名称、退款符号、税、优惠、重复商品、重量克数、总额和纽约时间到 UTC 的转换。这证明正确的识别输入不会被后端处理坏，**不证明模型读图正确**。
2. **评测器单元测试**：主动注入 FAGE 截断、中文错字、退款变正数、重量错误、AM/PM 错误、漏掉重复商品、凭空增加 TIPS 等问题；要求评分器能够报错。另保留真实错误输出，防止把模型错误改成标准答案。旧文字解析器已移除；对应规则放在 vision_prompt.txt，正确模型输出的契约回归继续覆盖这些照片。
3. **真实图片识别评测**：显式调用本机完整 多图 Qwen3-VL → JSON 校验/单位转换链路，对照相同人工答案。绕过店名/商品 Alias，不写入 playground 票据。逐张保存输出、差异、耗时、模型标识及图片校验值；有任何不符就退出失败。普通构建不自动启动 GPU 推理。

离线测试已经注册到 Cargo，因此 `build_docker.sh` 的现有 `cargo test --locked` 会包含它们。快速执行：

```bash
cargo test --manifest-path src/backend_api/Cargo.toml
```

本机服务就绪后执行真实图片评测：

```bash
RECEIPT_BENCH_URL=http://127.0.0.1:5000 \
RECEIPT_BENCH_KEY_FILE="$PWD/playground/secrets/ocr-api-key" \
RECEIPT_BENCH_OUTPUT="$PWD/build/vision/real-receipts.json" \
cargo test --manifest-path src/backend_api/Cargo.toml --test corpus live_image_benchmark -- --ignored --nocapture
```

评测失败表示识别结果没有达到人工答案；不能据此将整个离线测试套件标为失败，也不能拿离线套件通过宣称 OCR 全对。`captured/` 是历史输出，部分产生于早期版本，不能作为当前部署版本的准确率。

近期三张的只读评测：

```bash
python tests/backend_api/vision_reported.py --url http://127.0.0.1:5000 \
  --key-file playground/secrets/ocr-api-key --output-directory build/vision/reported
```

`baselines/2026-09-17-qwen3-vl/` 保存 vision-v5 最终实测：17 张全字段通过 8 张，另外三张关键项通过 1 张。保存模型输出和失败结果，不以正确 JSON 的离线回归代替模型准确率。部署配置、提示词和 smoke 日志同目录存档；详细解释见 [评测报告](../../../docs/vision_evaluation.md)。

`baselines/2026-09-17-store-prompts/` 保存按商店选择模板的 vision-v7：17 张全字段通过 8 张，近期三张关键项通过 0 张。当前评测提供人工确认的店名模拟 Logo Alias，商品答案不传给模型；未知商店回退由 API 测试和多图 smoke 覆盖。效果有改善也有回退，详见 [商店模板评测](../../../docs/store_prompt_evaluation.md)。

## 标注与计分约定

- 金额用最小货币单位整数，重量用毫克整数（对应数据库固定精度克数），不比较二进制浮点近似值。
- 忽略名称空格、大小写、Unicode 全半角排版差异和独立 SKU 数字列；不做拼写纠正，不允许只保留名称开头。人工无法读清的 Costco 笔迹遮挡三行使用显式 `visible_name_fragments`，要求可见的首尾片段保留，其金额仍精确比较。
- 中文按票面逐字比较，暂不把简繁转换视为同一字符；这是严格文字保真指标，不等同于用户可接受率。
- Costco 与其票面完整商标 Costco Wholesale 均接受；不通过已有用户 Alias 改写结果。
- 称重商品比较数量和单价；没有明确标注单价的普通商品允许推导单价，不把可选的 null 与推导值差异记成 OCR 错误。
- 商品可换顺序，逐行匹配且每行只能使用一次；相同名称的两盒豆腐仍必须保留两行。
- 英文名称中的 `TIPS` 不等于小费；退货政策中的 refund 不等于退款交易。税为零也保留独立税行。
- 391b3273 的 Executive Reward 暂按付款方式处理：消费 138.03，卡支付 123.80。沿用此前明示的默认解释，尚未获得用户进一步选择；策略变化应同时更新说明与测试。
- 原 d3c9895c 已被用户删除，无法保留其原图。使用现存 5e4547ea 的相同 FAGE/ENVY APPLE 版式覆盖该反馈，已有文字回归仍保留原问题。
- 这 17 张是个人问题回归集，不是随机抽样基准。全字段通过率不能当成通用 OCR 字符准确率。

## 当前覆盖

17 张人工标注涵盖 FAGE 全名、WT/重量详情、中英文同一商品、真实重复购买、Qty Spl Disc.、优惠净额、负数退款、会员退款、税、TIPS 商品名、页尾时间、UTC 和重量转换。正确 JSON 不应被 API 再解释。schema 拒绝错误引用；API 测试确保多照片进入同一次视觉请求并保留重试上限；storage 测试覆盖显式 SKU/税码、照片证据、金额差额黄标和后台编辑保护。

旧 captured/baselines/regressions 保留原样。expected 输入已更新为端到端协议（显式字段及证据数组），不以新模型输出替换人工答案。模型误差必须报告而非改动答案来使评测通过。


## 修正后的确认数据（2026-09-17）

当前标准答案为 `confirmed/2026-09-17-corrected/snapshot.json`。保留旧快照；不要覆盖归档的旧标准答案。
用户核对的称重字段和票面名称通过保存接口写回数据库后，重新冻结全部 24 张已确认收据。
详见 [修正审计](../../../../docs/confirmed_data_manual_review.md) 和 [本轮结果](../../../../docs/corrected_ocr_comparison.md)。

每张图片仍在线上依次运行两个 OCR。对新原始响应做离线隔离比较：

```bash
RECEIPT_BENCH_SOURCE="$PWD/tests/backend_api/corpus/baselines/2026-09-17-corrected-dual-ocr/report.json" \
RECEIPT_BENCH_SNAPSHOT="$PWD/tests/backend_api/corpus/confirmed/2026-09-17-corrected/snapshot.json" \
RECEIPT_BENCH_OUTPUT="$PWD/tests/backend_api/corpus/baselines/2026-09-17-corrected-dual-ocr/unlimited.json" \
RECEIPT_BENCH_ENGINE=unlimited \
cargo test --locked --manifest-path src/backend_api/Cargo.toml --test corpus isolated_ocr_benchmark -- --ignored --nocapture
```

将 engine/output 改为 `paddle` 或 `both`，分别得到 PP 和合并分支；`both` 额外断言离线解析与部署返回逐张完全相同。
此测试完整报告精度差异，但只对运行、证据完整性和线上/离线一致性断言失败；不能将测试通过误解为全部字段正确。
最后运行 `python3 tests/backend_api/corpus/compare_corrected.py` 生成独立新标准图表。旧模型结果未在新标准下重新推理，不与新分数混排。
# 2026-09-18：以原图票面名称为准的 Qwen3.8 Q4_K_M 评测

本轮标准答案是 `annotations/2026-09-18-printed-names.json` 中逐张对照原图核验的商品票面名称（允许明确标注的同一商品英文续行）。
它与用户维护的商品名称、以及历史确认记录中的 `rawName` 分开保存；不修改线上数据库。
保留真实票面缩写、拼写和重复购买行，数量前缀、独立 SKU、税码与 WT 标记不是名称的一部分。
无法确定的字符以 `printed_name: null` 标明原因，不猜测、不计入名称命中率分母。
此标注由 Codex 视觉核验，尚未经用户独立复核。中文续行不在此名称指标内。

名称计分忽略大小写、空白和标点，只对字母/数字进行精确的一对一多重集合匹配。
失败的完整推理记录必须保留；不能只提交成功样本。只有所有名称均可辨认的收据参与名称精确率和整张完全正确率。
原图哈希和样本集合必须一致。与确认数据库一致率是另外的辅助指标，不应当称为票面文字正确率。

```bash
python3 tests/backend_api/printed_name_evaluation.py \
  --annotations tests/backend_api/corpus/annotations/2026-09-18-printed-names.json \
  --predictions build/qwen38/nonthinking/report.json \
  --output build/qwen38/qwen-names.json
python3 -m unittest discover -s tests/backend_api -p 'test_*evaluation.py'
```

模型输入由 `tests/backend_api/qwen38_evaluation.py` 构造，仅包含原图与已知商店、国家、币种；
不提供商品名称、票面标准答案、金额标准答案或历史 OCR 输出。临时推理容器配置见
`docker/qwen38_evaluation.compose.yaml`，只绑定本机回环地址。正常 playground 仍维持原来的两个容器。

2026-09-18 清理：Dual OCR parser 的归档源码、副本执行器和专属 compare_corrected 脚本已删除，历史输出/图表保留。历史文档中的旧命令不再可执行；旧实现请从 Git 恢复。

2026-09-18 Logo 切换清理：旧视觉模型/DINO 镜像构建配方、下载器和 llama.cpp 评测容器配置已删除；下文旧启动命令为历史记录，源码从 Git 恢复。当前 Logo 匹配通过生产 NInfer 的 Chat Completions 接口。
