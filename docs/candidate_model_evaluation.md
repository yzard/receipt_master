> 最新同图实测及图表：[24 张确认收据对比](confirmed_ocr_comparison.md)。

# 收据端到端模型候选实测

状态：按用户要求停止。NuExtract3、NuExtract-2.0 的已完成结果保留在归档中；InternVL 未完成实测，不报告准确率。生产方案回到 Unlimited-OCR + PP-OCRv6 medium，backend_api 按店铺解析。

本轮用数据库全部 24 张已确认收据比较 NuExtract3、NuExtract-2.0-8B、InternVL3.5-8B。所有识别本地执行，原确认内容和照片不被覆盖。快照通过只读 API 重新取得，与上一轮数据完全相同。店名作为已确认上下文输入，Logo 匹配不参与本次提取评分。

模型权重固定 revision 并放入 Docker 镜像，BF16 权重，KV cache auto，32K 上下文，输出上限 8192 token，temperature 0，并发 2，最多两次尝试。提示词与 JSON Schema 均为 vision-v7。NuExtract 使用官方原生模板参数，InternVL 使用通用对话协议。具体说明见 [语料 README](../tests/backend_api/corpus/README.md)。

本轮未给模型提供商品标准答案，也未按模型输出改写已确认数据。商品用户别名/分类与未知可选字段不计分。23 张缺少历史时区，明确使用纽约 fallback；全部保留原 UTC 预期值。严格通过率代表与用户确认字段一致，不是字符准确率或重新人工核验的绝对正确率。

图片预处理遵循各模型接口：Qwen 系列使用最多 6,291,456 像素/图、16,777,216 总预算；InternVL 采用 448×448 动态切片，单图最多 31 个切片，另有模型 thumbnail。图片来源与顺序相同，但模型视觉编码不同，不能称为完全相同的分辨率。耗时包含重试、排队、可能出现的首遇形状内核编译；比较时作为部署观测而非纯模型速度排名。每个候选先用同一张短退款票预热，预热结果不代替正式全量结果。

完整快照、配置、模型输出和失败原因见 [归档](../tests/backend_api/corpus/baselines/2026-09-17-candidates/deployment.json)。
