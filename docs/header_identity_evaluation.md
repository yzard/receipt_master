# 收据头部店铺识别验证

2026-10-25：使用现有数据库的两张 McDonald's 和一张 Dunkin' 原图测试当前 Qwen3.8-27B / NInfer。三张均通过。测试只识别头部店铺身份，不评估本次商品明细准确率。

| 收据 | 头部证据 | 识别店名 | 采用规则 | 餐馆类别 | 耗时 |
| --- | --- | --- | --- | --- | --- |
| b123c3f3-5b55 | McDonald's Restaurant #7458 | McDonald's | Restaurant | 是 | 17.55 秒 |
| 7a1bc1d8-998f | McDonald's Restaurant #32967 | McDonald's | Restaurant | 是 | 8.95 秒 |
| 90c796c4-c192 | Welcome to Dunkin' | Dunkin' | Welcome to | 此规则不单独指定 | 8.52 秒 |

店名顺序为明确欢迎语、明确 Restaurant 头部、原有 Logo 图片 Alias。Restaurant 规则去掉标记及门店编号，并设置店铺、收据和新识别明细的默认类别。欢迎语对应同一 Restaurant 名称时也设置餐馆类别。Dunkin' 样本没有 Restaurant 字样，因此欢迎语本身不强制餐馆类别，仍可使用已有店铺配置。

测试调用生产代码的头部裁剪和模型请求，按顺序处理三张完整原图。模型只看到应用 EXIF 方向后的顶部 30%，没有标准答案或已保存的商品目录。请求复用原有头部定位步骤。耗时为该次调用的墙钟时间，不代表固定延迟。

原图、SHA256 和人工读取的头部标准答案位于 [测试样本](../tests/backend_api/corpus/header_identity/README.md)。完整模型响应保存于私有开发输出 `build/evaluations/2026-10-25-header-identity/report.json`。测试使用临时应用状态，没有新建或修改 NAS 的收据、任务及商品目录。

离线回归同时覆盖大小写、换行、空店名、缺少欢迎语、Restaurant Depot、页内多行杂文及两条规则冲突。API 回归覆盖头部身份优先于冲突的 Logo Alias、Logo 匹配回退、多张照片共同送入商品识别、店铺提示词选择，以及餐馆类别保存。
