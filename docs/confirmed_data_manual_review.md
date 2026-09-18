# 历史确认数据：人工核对清单

来源是 2026-09-17 从数据库冻结的 24 张已确认收据快照（`posted=true`），不是推测的旧值。已确认状态不代表每个字段都经过人工逐项核验。下列明确的修正已获用户确认并写回数据库。原始冻结快照保留用于追溯；最新评分使用修正后的新快照。

[冻结快照](../tests/backend_api/corpus/confirmed/2026-09-17/snapshot.json) · [本次双 OCR 原始响应与预测](../tests/backend_api/corpus/baselines/2026-09-17-serial-dual-ocr/report.json)

时间对比明确使用纽约时区；应用显示若使用其他设备时区，小时数会不同。以下“历史保存”指冻结时的数据库记录，若后来在 App 修改过，以修订记录另行核对。

## H Mart：交易时间上午/晚上

完整追溯编号：`e3843baa-904a-4bbf-bc21-278a1693d5c7`

[打开原始照片](../tests/backend_api/corpus/confirmed/2026-09-17/images/e3843baa-904a-4bbf-bc21-278a1693d5c7-0.jpg)

历史保存：纽约时间 **2026-08-23 09:32（上午）**；UTC 为 `2026-08-23T13:32:00Z`。

原图付款区及最底部打印 `08/23/26 09:32pm`，本次两个模型都读成晚上 **21:32**，对应 UTC `2026-08-24T01:32:00Z`。请核对票面 `pm`。

数据出处：快照 `cases[2].expected`。交易时间字段为 `occurredAt` / `rawTime`；商品字段位于 `lines`，包括 `rawName`、`sku`、`quantityMicros`、`quantityUnit`、`unitPriceScaled`、`weightMg`。

## SkyFoods：第一项白菜重量

完整追溯编号：`d7f8ff6d-6502-4eeb-8850-2f15b131988f`

[打开原始照片](../tests/backend_api/corpus/confirmed/2026-09-17/images/d7f8ff6d-6502-4eeb-8850-2f15b131988f-0.jpg)

商品：`TAIWAN CABBAGE (1POUNDS)`，第 1 个商品。

历史保存：**1 件 × $1.75/件**，没有重量。

本次识别：**3.02 lb × $0.58/lb = $1.75（四舍五入）**。原图英文商品名、中文名下面紧接着是称重明细；不要把名称中的 `(1POUNDS)` 当成实际购买重量。

数据出处：快照 `cases[7].expected`。交易时间字段为 `occurredAt` / `rawTime`；商品字段位于 `lines`，包括 `rawName`、`sku`、`quantityMicros`、`quantityUnit`、`unitPriceScaled`、`weightMg`。

## Costco：第一项蓝莓的票面名称

完整追溯编号：`ca76c352-9601-498c-8324-0ef9bcf5ea3b`

[打开原始照片](../tests/backend_api/corpus/confirmed/2026-09-17/images/ca76c352-9601-498c-8324-0ef9bcf5ea3b-0.jpg)

历史保存：**`BLUERRIES`**。

Unlimited 本次也读成 `BLUERRIES`；PP-OCR 读成 **`BLUEBERRIES`**，最后采用 PP 结果。请看原图 SKU `57554` 后的第一项名称，那里有笔迹重叠。

数据出处：快照 `cases[19].expected`。交易时间字段为 `occurredAt` / `rawTime`；商品字段位于 `lines`，包括 `rawName`、`sku`、`quantityMicros`、`quantityUnit`、`unitPriceScaled`、`weightMg`。

## SkyFoods：前三项称重商品（已修正）

完整追溯编号：`e9ee06e0-f4aa-4c3c-812a-4e8abc21e3f0`

[打开原始照片](../tests/backend_api/corpus/confirmed/2026-09-17/images/e9ee06e0-f4aa-4c3c-812a-4e8abc21e3f0-0.jpg)

| 商品 | 历史保存 | 本次识别 | 金额 |
| --- | --- | --- | ---: |
| BOK CHOY TIPS | 1 件 × $4.63/件 | 1.86 lb × $2.49/lb | $4.63 |
| CHIVES | 1 件 × $1.51/件 | 0.76 lb × $1.99/lb | $1.51 |
| LONG HOT PEPPER | 1 件 × $1.61/件 | 0.81 lb × $1.99/lb | $1.61 |

历史三项都没有保存重量。本次金额未变，区别在数量、计价单位和单价；请核对各商品中文名下面的称重行。

数据出处：快照 `cases[11].expected`。交易时间字段为 `occurredAt` / `rawTime`；商品字段位于 `lines`，包括 `rawName`、`sku`、`quantityMicros`、`quantityUnit`、`unitPriceScaled`、`weightMg`。

## SkyFoods：两项称重商品（已修正）

完整追溯编号：`5331c892-9fb6-42b5-bdb3-5a205b1a0767`

[打开原始照片](../tests/backend_api/corpus/confirmed/2026-09-17/images/5331c892-9fb6-42b5-bdb3-5a205b1a0767-0.jpg)

| 商品 | 历史保存 | 本次识别 | 金额 |
| --- | --- | --- | ---: |
| BOK CHOY TIPS | 1 件 × $4.98/件 | 2.00 lb × $2.49/lb | $4.98 |
| LONG HOT PEPPER | 1 件 × $1.43/件 | 0.72 lb × $1.99/lb | $1.43 |

历史两项都没有保存重量；请核对商品下面的称重明细。

数据出处：快照 `cases[16].expected`。交易时间字段为 `occurredAt` / `rawTime`；商品字段位于 `lines`，包括 `rawName`、`sku`、`quantityMicros`、`quantityUnit`、`unitPriceScaled`、`weightMg`。

## Costco：断笔 SKU，尚不能认定历史值错误

完整追溯编号：`8572dcef-7f7f-4d77-80c6-0ede75d45fa3`

[打开原始照片](../tests/backend_api/corpus/confirmed/2026-09-17/images/8572dcef-7f7f-4d77-80c6-0ede75d45fa3-0.jpg)

| 商品 | 历史保存 SKU | Unlimited | PP-OCR |
| --- | --- | --- | --- |
| KS UNSL PIST | `1752518` | `1752618` | `1792519` |
| ORGNIC BS THG | `22967` | `22957` | `225167` |
| KS ICE CREAM | `948400` | `948403` | `948400` |

前两项三方不一致，原图数字断笔明显，**只是待核验，不能认定历史值错误**。冰淇淋是 PP 与历史一致，主要怀疑 Unlimited。请看商品名称左侧的数字列；必要时结合 Costco 商品信息核验。

数据出处：快照 `cases[9].expected`。交易时间字段为 `occurredAt` / `rawTime`；商品字段位于 `lines`，包括 `rawName`、`sku`、`quantityMicros`、`quantityUnit`、`unitPriceScaled`、`weightMg`。

断笔 SKU 没有确定的替代值，因此保留历史保存值；此项仍是标准答案的不确定性。


## 已执行修正（2026-09-17）

- 通过正常确认接口修正 4 张收据：3 张 SkyFoods 共 6 条商品的数量、计价单位、单价与重量，以及 Costco 蓝莓票面名称。总额、每项金额、收据编号和录入时间未改变。
- H Mart 的交易时间在本次操作前已由用户改为纽约 2026-08-23 21:32，保留该值。旧识别原文 rawTime 留作来源记录；评分以 occurredAt 的 UTC 时间为准。
- 重量及商品标识由保存接口重新计算；所有记录仍为已确认状态。
- 写入前已生成完整备份 `build/vision/confirmed-corrections/before-corrections.receiptbackup`。
- [实际写入前后记录](../tests/backend_api/corpus/baselines/2026-09-17-corrected-dual-ocr/corrections.json)
- [修正后的全部 24 张确认值](../tests/backend_api/corpus/confirmed/2026-09-17-corrected/snapshot.json)
- [修正前即时快照](../tests/backend_api/corpus/confirmed/2026-09-17-before-user-corrections/snapshot.json)
