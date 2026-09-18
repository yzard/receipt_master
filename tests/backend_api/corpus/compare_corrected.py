"""Compare isolated engine outputs and fusion against the corrected confirmed database."""

import json
from pathlib import Path

import matplotlib

matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'tests/backend_api/corpus/baselines/2026-09-17-corrected-dual-ocr'
GOLD = ROOT / 'tests/backend_api/corpus/confirmed/2026-09-17-corrected/snapshot.json'
snapshot = json.loads(GOLD.read_text())
expected = {c['id']: c for c in snapshot['cases']}
count = len(expected)
reports = []
metrics = []
for engine, label in [('unlimited', 'Unlimited-OCR'), ('paddle', 'PP-OCRv6 medium'), ('both', '双 OCR 合并')]:
    report = json.loads((OUT / f'{engine}.json').read_text())
    rows = report['cases']
    assert len(rows) == count and {r['id'] for r in rows} == set(expected)
    for row in rows:
        assert row['images'] == expected[row['id']]['images']
    valid = [r for r in rows if r['valid']]
    metric = {
        'engine': engine,
        'label': label,
        'count': count,
        'valid': len(valid),
        'strict': sum(not r['errors'] for r in rows),
    }
    for key, prefix in [('total', 'total:'), ('line_count', 'line_count:'), ('time', 'time:')]:
        metric[key] = sum(not any(e.startswith(prefix) for e in r['errors']) for r in valid)
    metrics.append(metric)
    reports.append({r['id']: r for r in rows})
(OUT / 'summary.json').write_text(json.dumps(metrics, indent=2, ensure_ascii=False) + '\n')
font = FontProperties(fname='/usr/share/fonts/windows_fonts/msyh.ttc')
plt.rcParams['font.family'] = font.get_name()
plt.rcParams['svg.fonttype'] = 'path'
fig, axes = plt.subplots(1, 5, figsize=(19, 5.1), sharey=True)
for ax, (key, title) in zip(
    axes,
    [
        ('valid', '有效结果'),
        ('total', '总额一致'),
        ('line_count', '行数一致'),
        ('time', '时间一致'),
        ('strict', '全部评分字段一致'),
    ],
):
    values = [m[key] for m in metrics]
    ax.barh(range(3), values, color=['#758ea8', '#d1a05c', '#007f78'], height=0.48)
    ax.set_xlim(0, count * 1.32)
    ax.set_xticks([0, 6, 12, 18, 24])
    ax.set_title(title, fontsize=12, pad=16)
    ax.grid(axis='x', alpha=0.15)
    ax.set_axisbelow(True)
    ax.tick_params(axis='y', length=0)
    for spine in ax.spines.values():
        spine.set_visible(False)
    for i, n in enumerate(values):
        ax.text(n + 0.4, i, f'{n}/{count}\n{n/count:.1%}', va='center', fontsize=10)
axes[0].set_yticks(range(3), [m['label'] for m in metrics], fontsize=12)
axes[0].invert_yaxis()
fig.suptitle(f'{count} 张已确认收据 · 修正数据库后的重新实测', x=0.03, ha='left', fontsize=19)
fig.text(
    0.03, 0.13, '每张图片新跑两个 OCR，串行执行；单模型分数由各自原始输出单独经过同一套店铺解析规则计算。', fontsize=11
)
fig.text(
    0.03,
    0.065,
    '这里比较结构化提取结果，不是字符识别率。店名已知；别名、分类不计分。两项断笔 SKU 保留原确认值。',
    fontsize=10,
    color='#555555',
)
fig.subplots_adjust(left=0.15, right=0.99, top=0.76, bottom=0.28, wspace=0.13)
for ext in ['png', 'svg']:
    fig.savefig(ROOT / f'docs/assets/corrected_ocr_comparison.{ext}', dpi=160, facecolor='white')
plt.close(fig)
meta = json.loads((OUT / 'deployment.json').read_text())
lines = [
    '# 修正确认数据后的 OCR 评测',
    '',
    '日期：2026-09-17。数据库中的明确错误已经按用户核对结果保存；从修正后的数据库重新冻结全部已确认收据，共 24 张、24 张照片。',
    '',
    '![比较图](assets/corrected_ocr_comparison.png)',
    '',
    '## 结果',
    '',
    '| 方案 | 有效结果 | 总額一致 | 行数一致 | 时间一致 | 全部评分字段一致 |',
    '| --- | ---: | ---: | ---: | ---: | ---: |',
]
for m in metrics:
    lines.append(
        '| '
        + m['label']
        + ' | '
        + ' | '.join(f"{m[k]}/{count}（{m[k]/count:.1%}）" for k in ['valid', 'total', 'line_count', 'time', 'strict'])
        + ' |'
    )
lines += [
    '',
    f"整批新推理耗时 **{meta['batch_wall_seconds']:.2f} 秒**。每个任务依次运行 Unlimited-OCR 和 PP-OCR；客户端两个待处理请求进入服务端串行队列。耗时包含排队，不用于比较单个模型速度。",
    '',
    'Unlimited 与合并分支的五项汇总相同，但具体结果并非完全相同：Costco ca76c352 的 BLUEBERRIES 被 PP 纠正。该张仍有时间差异，所以整张严格通过数未增加。中文标准名称未作为本轮评分答案，不能用这张表否定 PP 的中文识别价值。',
    '',
    '## 标准答案与可比性',
    '',
    '- 3 张 SkyFoods 共 6 条称重商品修正数量、单价、单位和重量；Costco 的 BLUERRIES 改为 BLUEBERRIES。H Mart 晚上 21:32 的交易时间在操作前已修正，本次保留。金额没有改动。',
    '- [修正记录](confirmed_data_manual_review.md)；[新标准答案](../tests/backend_api/corpus/confirmed/2026-09-17-corrected/snapshot.json)；[写入前后实际数据](../tests/backend_api/corpus/baselines/2026-09-17-corrected-dual-ocr/corrections.json)。',
    '- 所有 24 张均重新读取原图调用两个模型，没有复用上轮推理。本轮未调整生产解析规则来适配标准答案。',
    '- 两个单模型分支只是离线隔离输入的评测：Unlimited 分支移除 PP 文字；PP 分支移除 Unlimited 文字；三者使用完全相同的解析器、单位换算和评分。线上仍要求每个任务运行两个模型。',
    '- 离线双模型解析结果逐张与本轮线上 JSON 完全相同，防止评测实现和部署不一致。',
    '- 逐项比较票面名称、商品种类、金额、重量、数量、单价、单位、SKU、税码、折扣关联，以及整张总额、币种和交易时间。未知可选值、用户别名和分类不计分；这不是文字字符准确率，也不能量化中文准确率。',
    '- 店名由确认记录提供，隔离店铺解析表现，不评估 Logo。每张只有一张照片，不代表长收据多图结果。解析器开发用过部分样本，这属于回归评测。',
    '- Costco 8572dcef 两项断笔 SKU 没有唯一正确替代值，仍保留数据库原值作为本轮评分标准；相关差异需结合这一不确定性解释。',
    '- 旧 Qwen/NuExtract 图表使用旧标准答案，保留为[历史结果](confirmed_ocr_comparison.md)，不能直接把旧分数和这里的新分数当作同标准模型排名。',
    '',
    '## 逐张差异',
    '',
    '数字为字段差异条数，不是错误商品数。下方原始记录含预测、规范化结果及每一条差异。',
    '',
    '| 收据 | 店铺 | Unlimited | PP-OCR | 双模型 |',
    '| --- | --- | ---: | ---: | ---: |',
]
for case in snapshot['cases']:
    lines.append(
        f"| `{case['id'][:8]}` | {case['expected']['store']} | "
        + ' | '.join(str(len(r[case['id']]['errors'])) if r[case['id']]['valid'] else '无效' for r in reports)
        + ' |'
    )
lines += ['', '## 差异明细（双模型）', '']
for case in snapshot['cases']:
    row = reports[2][case['id']]
    if row['errors']:
        lines += [f"### {case['expected']['store']} · {case['id']}", '', '```text', *row['errors'], '```', '']
lines += [
    '## 可追溯输出',
    '',
    '- [原始双 OCR 响应](../tests/backend_api/corpus/baselines/2026-09-17-corrected-dual-ocr/report.json)',
    '- [Unlimited 单独解析](../tests/backend_api/corpus/baselines/2026-09-17-corrected-dual-ocr/unlimited.json)',
    '- [PP-OCR 单独解析](../tests/backend_api/corpus/baselines/2026-09-17-corrected-dual-ocr/paddle.json)',
    '- [双模型解析](../tests/backend_api/corpus/baselines/2026-09-17-corrected-dual-ocr/both.json)',
    '- [部署、源码及标准答案哈希](../tests/backend_api/corpus/baselines/2026-09-17-corrected-dual-ocr/deployment.json)',
    '',
]
(ROOT / 'docs/corrected_ocr_comparison.md').write_text('\n'.join(lines))
print(json.dumps(metrics, indent=2, ensure_ascii=False))
