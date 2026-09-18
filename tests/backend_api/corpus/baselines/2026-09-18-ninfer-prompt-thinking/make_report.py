import json, statistics, sys, shutil, hashlib
from pathlib import Path
from collections import Counter
from decimal import Decimal
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
sys.path.insert(0,'tests/backend_api')
from printed_name_evaluation import compare, normalized_name
load=lambda p:json.loads(Path(p).read_text())
work=Path('build/ninfer-prompt-thinking');dest=Path('tests/backend_api/corpus/baselines/2026-09-18-ninfer-prompt-thinking')
previous=Path('tests/backend_api/corpus/baselines/2026-09-18-ninfer');frozen=Path('tests/backend_api/corpus/baselines/2026-09-18-qwen38-q4')
gold=load(frozen/'snapshot.json');ann=load(frozen/'printed-names.json');raw=load(work/'thinking/report.json')
assert len(raw['cases'])==32
reports={'before':load(previous/'scored.json'),'after':load(work/'scored.json')}
names={k:compare(ann,r) for k,r in reports.items()}
expected={c['id']:c['expected'] for c in gold['cases']}
def weighted(r):
 return Counter((normalized_name(l['rawName']),l['amountMinor'],l['weightMg']) for l in r.get('lines',[]) if l['isWeighed'] and l['weightMg'] is not None)
def metric(r):
 valid=totals=weights=weight_count=weight_pairs=0;cases=[]
 for c in r['cases']:
  g=expected[c['id']];a=c.get('normalized',{});wg,wa=weighted(g),weighted(a)
  totals+=a.get('totalMinor')==g['totalMinor'];valid+=bool(c.get('valid'));weights+=sum((wg&wa).values());weight_count+=sum(wg.values())
  pairs=lambda r:Counter((l['amountMinor'],l['weightMg']) for l in r.get('lines',[]) if l['isWeighed'] and l['weightMg'] is not None)
  weight_pairs+=sum((pairs(g)&pairs(a)).values())
  cases.append({'id':c['id'],'expected_total':g['totalMinor'],'actual_total':a.get('totalMinor'),'known_weight_hits':sum((wg&wa).values()),'known_weight_count':sum(wg.values()),'missing_name_amount_weight':list((wg-wa).elements()),'sum_lines':sum(l['amountMinor'] for l in a.get('lines',[]))})
 return {'valid':valid,'total_correct':totals,'weight_hits':weights,'weight_count':weight_count,'weight_pair_hits':weight_pairs,'cases':cases}
fields={k:metric(r) for k,r in reports.items()}
raws={'before':load(previous/'raw-report.json'),'after':raw}
latency={k:{'batch_seconds':r['elapsed_seconds'],'median_seconds':statistics.median(c['duration_ms']/1000 for c in r['cases'])} for k,r in raws.items()}
reasoning=[]
for p in (work/'thinking').glob('*.response.json'):
 r=load(p);m=r['choices'][0]['message'];reasoning.append({'id':p.name.removesuffix('.response.json'),'reasoning_chars':len(m.get('reasoning_content') or ''),'reasoning_tokens':r.get('usage',{}).get('completion_tokens_details',{}).get('reasoning_tokens'),'finish_reason':r['choices'][0]['finish_reason']})
summary={'names':{k:v['summary'] for k,v in names.items()},'fields':fields,'latency':latency,'reasoning':reasoning,'raw_total_hits':sum(Decimal(c['prediction']['total'])*100==expected[c['id']]['totalMinor'] for c in raw['cases']), 'raw_json_objects':sum('prediction' in c for c in raw['cases']),'adapted_json_objects':sum('prediction' in c for c in load(work/'adapted.json')['cases'])}
dest.mkdir(parents=True,exist_ok=True)
for src,target in [(work/'thinking/report.json','raw-report.json'),(work/'adapted.json','adapted-report.json'),(work/'scored.json','scored.json'),(work/'deployment.json','deployment.json'),(work/'inference.log','inference.log'),(frozen/'printed-names.json','printed-names.json')]:shutil.copyfile(src,dest/target)
for p in (work/'thinking').glob('*'):
 if p.name!='report.json':shutil.copyfile(p,dest/p.name)
for src in ['tests/backend_api/prompts/qwen38_receipt.txt','tests/backend_api/prompts/qwen38_hualian.txt','tests/backend_api/qwen38_evaluation.py','tests/backend_api/candidate_json_format.py','tests/backend_api/printed_name_evaluation.py','docker/ninfer_evaluation.compose.yaml',str(work/'run.sh'),str(work/'make_report.py')]:shutil.copyfile(src,dest/Path(src).name)
(dest/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n');(dest/'names.json').write_text(json.dumps(names['after'],ensure_ascii=False,indent=2)+'\n')
fig,axs=plt.subplots(1,2,figsize=(11,4.3),layout='constrained');labels=['Old / thinking off','New / thinking on'];colors=['#55788f','#147d64']
for ax,vals,title,unit in [(axs[0],[names[k]['summary']['name_recall']*100 for k in reports],'Printed-name recall (136 readable names)','%'),(axs[1],[latency[k]['median_seconds'] for k in reports],'Median latency (32 receipts)','s')]:
 ax.barh(labels,vals,color=colors);ax.invert_yaxis();ax.set_title(title);ax.set_xlim(0,max(vals)*1.18);ax.spines[['top','right','left']].set_visible(False)
 for i,v in enumerate(vals):ax.text(v+max(vals)*.015,i,f'{v:.1f}{unit}',va='center')
fig.suptitle('Qwen3.8-27B NVFP4 / NInfer: combined prompt + thinking change')
fig.savefig('docs/assets/ninfer_prompt_thinking.png',dpi=170);fig.savefig('docs/assets/ninfer_prompt_thinking.svg');plt.close(fig)
rows=[]
for k,label in zip(reports,labels):
 n=names[k]['summary'];f=fields[k];t=latency[k]
 rows.append(f"| {label} | {n['matched_names']}/136 ({n['name_recall']:.1%}) | {n['fully_correct_receipts']}/28 | {n['correct_row_counts']}/32 | {f['total_correct']}/32 | {f['weight_hits']}/20 | {t['median_seconds']:.1f} 秒 |")
case_rows=[]
for a in ann['cases']:
 i=a['id'];b=next(c for c in names['before']['cases'] if c['id']==i);n=next(c for c in names['after']['cases'] if c['id']==i);f=next(c for c in fields['after']['cases'] if c['id']==i)
 photo='../tests/backend_api/corpus/baselines/2026-09-18-qwen38-q4/'+a['images'][0]['path']
 case_rows.append(f"| [{i[:8]}]({photo}) | {a['store']} | {b['matched_names']}/{b['verified_names']} | {n['matched_names']}/{n['verified_names']} | {n['predicted_rows']}/{n['expected_rows']} | {f['actual_total']} / {f['expected_total']} |")
text=f'''# NInfer：Hualian 专用提示、TOTAL 规则与 thinking 复测

2026-09-18。沿用同一 32 张原图、原图票面名称标注、NInfer commit、Qwen3.8-27B NVFP4 模型、图像处理和串行运行配置。没有修改 playground 收据。

## 结果

| 配置 | 票面名称命中 | 整张名称完全正确 | 商品行数正确 | 后端接受且总额一致 | 名称+金额+重量组合命中 | 请求中位耗时 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
{chr(10).join(rows)}

票面名称和商品行数直接检查模型输出，包含后端拒绝的两张；这不是完整可用率。模型原始总额与确认值一致为 {summary['raw_total_hits']}/32，而后端接受且总额一致为 {fields['after']['total_correct']}/32。

名称基准为照片上的票面文字，不是商品名称或历史数据库文字。136 个可辨认名称计入命中率；8 个不确定名称排除；整张名称仅评估 28 张全部可辨认收据。重量和总额以冻结确认字段为辅助基准；20 个已知称重行并不覆盖所有实际称重行，不能当全量重量准确率。没有评测中文续行逐字准确率。

![对比图](assets/ninfer_prompt_thinking.png)

## 本轮改动

1. 通用提示明确读取独立 `TOTAL` 标签后或正下方对应金额，排除 SUBTOTAL、TOTAL TAX、TOTAL SAVINGS、付款额、找零及奖励抵扣。缺少可靠证据时返回未知；不编造金额来凑平。
2. Hualian 独立提示：称重行先暂存，绑定下一条有独立右侧金额的商品，然后清空。该商品下面无价格的中英文续行属于同一商品；下一条称重行属于下一商品。乘法仅用于复核关联，不能修改打印金额。
3. 用户要求开启 thinking。本轮请求显式 `enable_thinking=true`，覆盖服务端非 thinking 默认值。总输出预算仍为 8192 token（包含思考与答案），上下文 32768，温度 0，seed 42，无重试。

这是**提示修改与 thinking 同时变化**的实验，不能把提升或回退单独归因于其中一项；未进行仅改提示或仅开 thinking 的消融对照。本轮新增提示没有写入样本中的具体商品名或金额答案；原有通用提示示例沿用，模型不接收历史 OCR 输出或确认字段答案。Hualian 和 Costco 是已经知道错误的调试样本，因此这是回归检查，不是独立盲测。已知商店仍由评测上下文提供；本轮不评测 Logo。

## 输出与性能

原始直接 JSON 对象 {summary['raw_json_objects']}/32；去掉单个完整外层代码框后 {summary['adapted_json_objects']}/32；通过同一后端结构校验和规范化 {fields['after']['valid']}/32。保留所有原始输出、失败及思考字段，不修改字段值、不修复截断答案。

本轮 {sum(bool(r['reasoning_chars']) for r in reasoning)}/32 个响应包含非空独立 reasoning 字段，确认实际进行了思考。32 张批次耗时 {latency['after']['batch_seconds']:.1f} 秒，上一轮 {latency['before']['batch_seconds']:.1f} 秒。批次含图片编码和传输，不含模型加载；未独立预热。单次串行测量不能代表稳定生产延迟。

## 逐张结果

总额列以美分记录“本轮输出 / 确认值”。名称、总额和商品行数分别计分，不代表所有字段同时正确。

| 原图 | 商店 | 上轮名称 | 本轮名称 | 本轮商品行数/应有 | 总额（美分） |
| --- | --- | ---: | ---: | ---: | ---: |
{chr(10).join(case_rows)}

[上一轮报告](ninfer_evaluation.md) · [完整指标和逐例差异](../tests/backend_api/corpus/baselines/2026-09-18-ninfer-prompt-thinking/summary.json) · [本轮原始结果](../tests/backend_api/corpus/baselines/2026-09-18-ninfer-prompt-thinking/raw-report.json) · [部署记录](../tests/backend_api/corpus/baselines/2026-09-18-ninfer-prompt-thinking/deployment.json)
'''
Path('docs/ninfer_prompt_thinking_evaluation.md').write_text(text)
print(json.dumps({k:v for k,v in summary.items() if k not in ['fields','reasoning']},ensure_ascii=False,indent=2));print('FIELDS',json.dumps({k:{a:b for a,b in v.items() if a!='cases'} for k,v in fields.items()}))
