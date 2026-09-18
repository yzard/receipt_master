> 最新同图实测及图表：[24 张确认收据对比](confirmed_ocr_comparison.md)。

# OCR 回归与替代模型评估

日期：2026-09-16。

## 已实现

- [12 张真实票据及人工答案](../tests/backend_api/corpus/README.md)，照片采用 SHA-256 固定。
- [15 个新增离线测试](../tests/backend_api/corpus.rs)：12 个票据领域用例、语料完整性/结构检查、主动造错验证评分器、历史错误输出验证。连同原有 49 个后端测试，共 64 个。
- 两个显式运行的评测入口：真实图片调用本机服务、对已保存的预测重新评分。它们不在普通构建中自动调用模型；不把识别失败掩盖为通过。
- 既有前端测试负责入口、表格和滑动删除；票据识别准确率不能由前端组件测试推断。

这次只增加测试、语料和说明，没有替换模型，也没有修改正在使用的票据。正常构建会自动运行新增离线测试，无需新增根目录检查脚本。

## 为什么要分层检查

目前链路是 Unlimited-OCR 读取文字，再由 Qwen3-4B-Instruct-2507 结构化，最后由 backend_api 做金额、重量、税/优惠、时间等运算。

- 中文错字、`PISTACHIO` 读错、负号或 PM 丢失：首先要定位文字识别层。
- 把 `BOK CHOY TIPS` 当小费、把付款余额当消费总额：也可能是结构化或规则层的问题。
- 总额正确不代表商品名、称重、退款符号都正确。

新图片评测测量完整链路。它不能将所有差异归因于 Unlimited-OCR，也不是纯 OCR 字符准确率；后续比较 OCR 候选时应保持结构化模型、提示词、图片和后处理不变，并额外保留原始文字/坐标用于定位。

## 候选模型与服务

| 候选 | 适合本项目的理由 | 需要验证的限制 |
| --- | --- | --- |
| **PP-OCRv6 medium，优先试验** | 专门的文字检测/识别；单模型支持简体、繁体、英文；适合先解决密集票面文字和字符保真，可本地部署 | 不是票据会计解析器；仍需要 backend_api 处理税、退款、折扣和重量关联。是否优于现模型必须用本语料验证 |
| **PaddleOCR-VL-1.6** | 面向文档解析，可处理版面和表格；0.9B，提供部署方案 | 应测试包括版面分析的完整流水线，只替换一个视觉模型不等同于官方完整效果；不能用通用文档榜单分数当收据准确率 |
| **Azure Document Intelligence `prebuilt-receipt`** | 专门提取商户、时间、商品、单价、税、总额的云端票据服务，可作英文收据对照 | 官方 Receipt 语言清单未列出中文，不能把 Invoice 支持中文混同于 Receipt；中文超市票不是首选。云端计费，也不符合模型随本地 Docker 镜像封装的部署方式 |

依据：[PP-OCRv6 官方说明](https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/algorithm/PP-OCRv6/PP-OCRv6.en.md)、[PaddleOCR-VL 官方部署文档](https://www.paddleocr.ai/main/en/version3.x/pipeline_usage/PaddleOCR-VL.html)、[Azure Receipt 模型](https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/prebuilt/receipt?view=doc-intel-4.0.0)、[Azure 各模型语言支持](https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/language-support/prebuilt?view=doc-intel-4.0.0#receipt-model)。这些资料说明候选能力，不保证这 12 张票据的识别结果。

## 推荐下一步

先在 backend_ocr 中试验 PP-OCRv6 medium，保持 backend_api 与客户端接口不变，沿用两容器结构。对当前模型和候选模型运行同一批图片，分别比较中文名称、完整票面名称、金额符号、日期、重量和整张成功率；再决定是否切换。若重点是复杂版面，则再加入 PaddleOCR-VL-1.6 完整流水线比较。

这次尚未下载或部署候选模型，也没有将真实图片发送给新的云服务。

## 重评保存结果

在项目根目录执行，预测保持原样，只更新逐项差异及评分时间：

```bash
RECEIPT_BENCH_OUTPUT="$PWD/build/v2/ocr-corpus-baseline.json" \
cargo test --manifest-path src/backend_api/Cargo.toml --test corpus saved_predictions_benchmark -- --ignored --nocapture
```

有任何差异就返回失败；报告仍完整保存。人工答案变更必须有原图依据，不能为了让候选模型通过而放宽条件。

## 2026-09-16 本机基线

[逐张原始预测与差异](../tests/backend_api/corpus/baselines/2026-09-16-unlimited.json) 已保存，包含图片及标注哈希、模型名、部署镜像摘要和耗时。这是一次运行结果，没有重试挑选较好结果。

**12 张中 4 张全部匹配，7 张有字段差异，1 张调用失败（HTTP 502）。** 因此严格通过数为 4/12，质量门禁返回失败。正常离线测试 64 项通过，Clippy 通过。

| 票据 | 结果 |
| --- | --- |
| 391b3273 | 时间未确定；QUINOA 出现错字 |
| b92bd0ff | 匹配 |
| f7cc0090 | PISTACHIO 被读成 PUSTACHIO |
| efe47023 | OPTIMUM 右侧仍可见的 W 被漏掉；笔迹遮住的字符未要求猜测 |
| bbbfe093 | 会员退款名称 DOWN 漏 D；金额符号正确 |
| e8698610 | 匹配 |
| a730a1be | HTTP 502，本次未得到结果 |
| 2f083787 | 白菜苗被读成白菜菇 |
| 5e4547ea | 匹配；FAGE 全名和重量行正确 |
| 3270f3c9 | H MART 丢失 H；本次 PM 正确 |
| 2718947f | 匹配 |
| f3bca374 | 白菜苗错字，另有简繁字形差异；本次没有多出小费 |

实测结果支持继续比较模型，但不能据此承诺替代模型一定更好。历史错误仍保留在固定回归中，即使本次随机推理没有重现，也不能删除相应用例。

最新：[17 张真实票据的 Unlimited-OCR / PP-OCRv6 medium 对照结果](ocr_model_comparison.md)。
