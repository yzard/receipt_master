# 识别失败诊断

后台为每个收据识别任务记录 `receipt_id`、`job_id` 和 `run_id`。容器日志说明每次提取失败的原因，并记录店铺提示词名称、图片数量、尝试次数、耗时、`finish_reason` 和模型返回的 token 用量。字段校验错误包含 JSON 字段路径，JSON 语法错误包含行号和列号。未知用量保持为空，不估算思考 token。

`finish_reason=length` 和 `output_truncated=true` 表示模型输出达到额度上限。JSON 格式错误、字段类型错误、商品折扣关联错误、连接失败和超时分别保留对应原因。OCR 请求失败的日志包含可用的 HTTP 状态和连接、超时标记。日志不输出请求图片、模型正文、提示词或认证头。

收据提取失败后，后台把每次模型返回和校验诊断存到当前用户数据根目录的 `recognition/<run_id>.json`。文件包含模型的最终文本、思考文本和用量，不包含提交的图片或凭证。文件权限为 `0600`。`recognition_run.result_relative_path` 指向该文件，备份和媒体清理沿用现有关系。成功识别的文件同样包含每次尝试的诊断。后台不会为没有收到响应的请求生成模型原文。

`recognition_run.error_code` 保留真实错误，例如 `invalid_structured_output`，不再统一替换为 `inference_failed`。Logo 阶段等发生在商品提取之前的失败，会在任务日志中记录编号和原因。直接调用 Chat Completions 的请求同样输出诊断日志，但不创建收据识别记录。

在 NAS 上运行以下命令，查看最近的失败记录。

```bash
ssh nas 'docker logs --since 30m receipts 2>&1' | rg 'receipt inference attempt failed|receipt extraction failed|receipt recognition job failed|OCR transport failed'
```

用日志中的收据编号定位任务，再根据 `run_id` 和数据库中的文件路径读取私有诊断文件。不要把完整诊断发布到公开日志，因为模型原文包含收据内容。

历史失败没有保留的模型原文无法恢复。更新服务后，新任务和重新识别会记录诊断，不需要修改数据库结构。
