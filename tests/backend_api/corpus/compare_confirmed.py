"""Render archived, same-photo receipt benchmark results; never rerun inference."""
import json
import statistics
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / 'tests/backend_api/corpus/baselines'
SNAPSHOT = json.loads((ROOT / 'tests/backend_api/corpus/confirmed/2026-09-17/snapshot.json').read_text())
INPUTS = [
    ('双 OCR · 串行 1（当前）', '2026-09-17-serial-dual-ocr/report.json'),
    ('双 OCR · 并发 2（旧版）', '2026-09-17-confirmed-dual-ocr/report.json'),
    ('Qwen3-VL 8B BF16 · 并发 2', '2026-09-17-confirmed-models/8b.json'),
    ('Qwen3-VL 32B AWQ · 并发 2', '2026-09-17-confirmed-models/32b.json'),
    ('NuExtract3 · 并发 2', '2026-09-17-candidates/nuextract3.json'),
    ('NuExtract 2.0-8B · 并发 2', '2026-09-17-candidates/nuextract2.json'),
]
EXPECTED = {c['id']: c for c in SNAPSHOT['cases']}
assert len(EXPECTED) == 24
metrics = []
reports = []
for name, path in INPUTS:
    report = json.loads((BASE / path).read_text())
    cases = report['cases']
    assert len(cases) == 24 and {c['id'] for c in cases} == set(EXPECTED), path
    for case in cases:
        assert [i['sha256'] for i in case['images']] == [i['sha256'] for i in EXPECTED[case['id']]['images']], path
    valid = [c for c in cases if 'prediction' in c and 'Prediction could not be normalized into a receipt' not in c['errors']]
    row = {'model': name, 'source': path, 'count': len(cases), 'validated': len(valid),
           'strict_match': sum(not c['errors'] for c in cases),
           'median_seconds': round(statistics.median(c['duration_ms'] for c in cases) / 1000, 2)}
    for key, prefix in [('total_match', 'total:'), ('line_count_match', 'line_count:'), ('time_match', 'time:')]:
        row[key] = sum(not any(e.startswith(prefix) for e in c['errors']) for c in valid)
    metrics.append(row)
    reports.append({c['id']: c for c in cases})

out = BASE / '2026-09-17-serial-dual-ocr'
(out / 'summary.json').write_text(json.dumps(metrics, indent=2, ensure_ascii=False) + '\n')
font = FontProperties(fname='/usr/share/fonts/windows_fonts/msyh.ttc')
plt.rcParams['font.family'] = font.get_name()
plt.rcParams['svg.fonttype'] = 'path'
fig, axes = plt.subplots(1, 4, figsize=(18, 6.2), sharey=True)
colors = ['#007f78', '#c58b67', '#6682ad', '#6682ad', '#6682ad', '#b4bcc5']
for ax, (key, title) in zip(axes, [('validated','返回有效结果'), ('total_match','总金额一致'), ('line_count_match','明细行数一致'), ('strict_match','全部评分字段一致')]):
    vals = [m[key] for m in metrics]
    ax.barh(range(len(metrics)), vals, color=colors, height=.55)
    ax.set_xlim(0, 28)
    ax.set_xticks([0,6,12,18,24])
    ax.set_title(title, fontsize=13, pad=15)
    ax.grid(axis='x', alpha=.14)
    ax.set_axisbelow(True)
    for i, v in enumerate(vals):
        ax.text(v+.4, i, f'{v}/24', va='center', fontsize=11)
    for s in ax.spines.values():
        s.set_visible(False)
    ax.tick_params(axis='y', length=0)
axes[0].set_yticks(range(len(metrics)), [m['model'] for m in metrics], fontsize=11)
axes[0].invert_yaxis()
fig.suptitle('24 张已确认收据 · 同图实测对比', fontsize=19, x=.06, ha='left', y=.97)
fig.text(.06,.11,'调度条件不同：当前双 OCR 串行执行；Qwen / NuExtract 仍是历史并发 2 结果，尚未串行重测。',fontsize=11,color='#8a462d')
fig.text(.06,.067,'同一批 24 张图片；失败计为未通过。店名已知，不评估 Logo；商品名称和分类不计分，不能据此量化中文准确率。',fontsize=10,color='#444444')
fig.text(.06,.025,'评分相对历史确认数据，部分历史值有疑点；不能把所有差异视为 OCR 错字。NuExtract 2.0 结果均被结构校验拒绝。',fontsize=10,color='#444444')
fig.subplots_adjust(left=.27, right=.99, top=.80, bottom=.24, wspace=.18)
for ext in ['png','svg']:
    fig.savefig(ROOT / f'docs/assets/confirmed_model_comparison.{ext}', dpi=160, facecolor='white')
plt.close(fig)

lines = ['# 24 张已确认收据：传统双 OCR 与端到端模型对比', '',
'日期：2026-09-17。传统方案本轮重新读取全部 24 张原图；Qwen3-VL 和 NuExtract 使用此前归档结果。串行版调整了调度和 PP-OCR 中文优先规则；未修改原收据或标准答案。', '',
'![实测图表](assets/confirmed_model_comparison.png)', '',
f"**当前串行版：有效结果 {metrics[0]['validated']}/24，总额一致 {metrics[0]['total_match']}/24，行数一致 {metrics[0]['line_count_match']}/24，全部字段一致 {metrics[0]['strict_match']}/24。** 旧并发版有 11 张请求失败，保留该轮原始结果作为对照。", '',
f"精度验收仍有 {24-metrics[0]['strict_match']}/24 张存在差异或请求失败，全部结果已保存。返回有效结构不等于商品字段全部正确。", '', '## 汇总', '',
'| 方案 | 有效结果 | 总额一致 | 行数一致 | 时间一致 | 全部字段一致 | 请求耗时中位数 |',
'| --- | ---: | ---: | ---: | ---: | ---: | ---: |']
for m in metrics:
    lines.append('| ' + m['model'] + ' | ' + ' | '.join(f"{m[k]}/24" for k in ['validated','total_match','line_count_match','time_match','strict_match']) + f" | {m['median_seconds']:.2f} 秒 |")
meta = json.loads((out/'deployment.json').read_text())
lines += ['', f"传统方案整批耗时：**{meta['batch_wall_seconds']:.2f} 秒**（客户端并发提交 2，服务端单任务串行，包括启动测试程序）。请求耗时包含服务排队，不能理解为纯模型计算速度。", '',
'## 方法与边界', '',
'**调度条件未统一：当前双 OCR 服务串行 1；旧双 OCR、Qwen 和 NuExtract 的请求并发均为 2，Qwen/NuExtract 的 vLLM max_sequences 也为 2。后者尚未做串行重测；不能把图表当成控制了并发变量的纯模型排名。**', '',
'具体错字、解析缺陷及确认数据疑点见 [双 OCR 细节分析](dual_ocr_error_analysis.md)。本次只更新图表说明与证据分析，不重新运行模型、不修改评分或确认数据。', '',
'- 当前链路为 Unlimited-OCR + PP-OCRv6 medium → Rust 店铺解析 → 结构校验及单位转换。没有语言模型负责结构化。',
'- 所有归档均核对 24 个收据 ID 与每张照片的 SHA-256；店铺为 Costco 10、SkyFoods 7、H Mart 3、99 Ranch 2、Feilong 1、Target 1。',
'- 使用相同确认数据与评分口径；模型只获得照片、已知店名、国家和币种，不获得商品答案。本轮不评估 Logo。',
'- 逐项比较票面名称、金额、种类、折扣关联、已知 SKU/税码/数量/单价/重量/单位、币种与交易时间；忽略用户别名、分类和未知可选字段。',
'- 严格一致率不是文字准确率。用户保存的数据可能带有历史默认值；没有为本次提高分数而更改答案。传统规则已根据部分历史样本调整，结果是回归表现，不能代表未知收据的泛化能力。',
'- NuExtract 2.0 的 24 次结果均未通过净额/折扣关联校验，不代表每个字符均未识别。InternVL 未完成实测，不计入图表。',
'- 每张收据一张照片；这组结果不能证明多图长收据表现。各方案的重试、图像处理和计算部署不同，耗时仅供部署参考。', '',
'## 逐张差异数', '',
'“失败”表示未返回可评分结果；数字是字段差异条数，不是错误商品数。', '',
'| 收据 | 店铺 | 双 OCR 串行 | 双 OCR 旧并发 | Qwen 8B | Qwen 32B | NuExtract3 | NuExtract2 |',
'| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |']
for c in SNAPSHOT['cases']:
    cells = [str(len(r[c['id']]['errors'])) if 'prediction' in r[c['id']] else '失败' for r in reports]
    lines.append(f"| `{c['id'][:8]}` | {c['expected']['store']} | " + ' | '.join(cells) + ' |')
lines += ['', '## 当前传统方案按店铺拆分', '',
          '| 店铺 | 样本 | 有效结果 | 总额一致 | 行数一致 | 全部字段一致 |',
          '| --- | ---: | ---: | ---: | ---: | ---: |']
for store in sorted({c['expected']['store'] for c in SNAPSHOT['cases']}):
    cases = [reports[0][c['id']] for c in SNAPSHOT['cases'] if c['expected']['store'] == store]
    valid = [c for c in cases if 'prediction' in c and 'Prediction could not be normalized into a receipt' not in c['errors']]
    totals = sum(not any(e.startswith('total:') for e in c['errors']) for c in valid)
    counts = sum(not any(e.startswith('line_count:') for e in c['errors']) for c in valid)
    strict = sum(not c['errors'] for c in cases)
    lines.append(f'| {store} | {len(cases)} | {len(valid)} | {totals} | {counts} | {strict} |')
lines += ['', '## 当前失败与差异', '']
failed = [c['id'][:8] for c in reports[0].values() if 'prediction' not in c]
if failed:
    lines.append(f'本轮有 {len(failed)} 张未返回可评分结果：' + '、'.join(f'`{c}`' for c in failed) + '。完整错误见原始结果。')
else:
    lines.append('本轮 24 张全部返回有效结构，其中包含上一轮失败的全部 11 张；每张原始响应均保留两种 OCR 输出，没有降级成单模型成功。')
lines += ['', '旧并发版的底层传输异常当时未记录，不能精确归因。独立诊断中 11 张的两个模型全部正常结束；本轮改为单任务、双模型依次执行，并补充安全的失败日志。详见 [诊断与串行处理说明](ocr_serial_processing.md)。']
lines += ['', '`e6c62f11` 的差异集中在折扣行的数量、单价及单位；`2f97fc50` 存在日期、优惠拆分及数量等差异。严格指标保留这些差异，没有为了分数调整评分口径。', '']
lines += ['', '## 原始证据与重现', '',
'- [完整本轮结果](../tests/backend_api/corpus/baselines/2026-09-17-serial-dual-ocr/report.json)、[汇总数据](../tests/backend_api/corpus/baselines/2026-09-17-serial-dual-ocr/summary.json)、[镜像与源文件哈希](../tests/backend_api/corpus/baselines/2026-09-17-serial-dual-ocr/deployment.json)。同目录保留测试日志、解析器和评分器源码。',
'- [Qwen 原始评测](confirmed_model_evaluation.md)、[NuExtract 原始评测](candidate_model_evaluation.md)、[测试运行说明](../tests/backend_api/corpus/README.md)。',
'- 使用 `python3 tests/backend_api/corpus/compare_confirmed.py` 从归档重建本报告及 PNG/SVG 图表；需要 Matplotlib 和本机微软雅黑字体。', '']
(ROOT/'docs/confirmed_ocr_comparison.md').write_text('\n'.join(lines))
print(json.dumps(metrics, indent=2, ensure_ascii=False))
