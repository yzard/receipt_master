import json,statistics,sys,shutil,hashlib
from pathlib import Path
from collections import Counter
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
sys.path.insert(0,'tests/backend_api')
from printed_name_evaluation import compare,normalized_name
load=lambda p:json.loads(Path(p).read_text())
work=Path('build/ninfer');old=Path('tests/backend_api/corpus/baselines/2026-09-18-qwen38-q4');dest=Path('tests/backend_api/corpus/baselines/2026-09-18-ninfer')
ann=load(old/'printed-names.json');snapshot=load(old/'snapshot.json');raw=load(work/'nonthinking/report.json');current=load(work/'scored.json')
assert len(raw['cases'])==32
inputs={'dual':load(old/'dual-scored.json'),'llama':load(old/'qwen-scored.json'),'ninfer':current}
names={key:compare(ann,value) for key,value in inputs.items()}
golds={c['id']:c['expected'] for c in snapshot['cases']};annotations={c['id']:c for c in ann['cases']}
def fields(source):
 totals=valid=weight_count=weights=bound_weights=0;differences=[]
 for case in source['cases']:
  gold=golds[case['id']];actual=case.get('normalized',{});valid+=bool(case.get('valid'));totals+=actual.get('totalMinor')==gold['totalMinor']
  pairs=lambda receipt:Counter((line['amountMinor'],line['weightMg']) for line in receipt.get('lines',[]) if line['isWeighed'] and line['weightMg'] is not None)
  g,a=pairs(gold),pairs(actual);weight_count+=sum(g.values());weights+=sum((g&a).values())
  bound=lambda receipt:Counter((normalized_name(line['rawName']),line['amountMinor'],line['weightMg']) for line in receipt.get('lines',[]) if line['isWeighed'] and line['weightMg'] is not None)
  bg,ba=bound(gold),bound(actual);bound_weights+=sum((bg&ba).values())
  if gold['totalMinor']!=actual.get('totalMinor') or bg-ba:
   differences.append({'id':case['id'],'expected_total':gold['totalMinor'],'actual_total':actual.get('totalMinor'),'missing_name_amount_weight':list((bg-ba).elements())})
 return {'valid':valid,'total_correct':totals,'weight_pair_hits':weights,'weight_name_pair_hits':bound_weights,'weight_count':weight_count,'differences':differences}
metrics={key:fields(value) for key,value in inputs.items()}
oldraw=load(old/'raw-report.json');latency={key:{'batch_seconds':r['elapsed_seconds'],'median_seconds':statistics.median(c['duration_ms']/1000 for c in r['cases']),'min_seconds':min(c['duration_ms']/1000 for c in r['cases']),'max_seconds':max(c['duration_ms']/1000 for c in r['cases']),'median_prompt_tokens':statistics.median(c['usage']['prompt_tokens'] for c in r['cases'])} for key,r in [('llama',oldraw),('ninfer',raw)]}
summary={'names':{k:v['summary'] for k,v in names.items()},'fields':metrics,'latency':latency,'raw_json_objects':sum('prediction' in c for c in raw['cases']),'raw_requests':len(raw['cases']),'formatting_only_decoded':sum('prediction' in c for c in load(work/'adapted.json')['cases'])}
dest.mkdir(parents=True,exist_ok=True)
for src,target in [(work/'nonthinking/report.json','raw-report.json'),(work/'adapted.json','adapted-report.json'),(work/'scored.json','scored.json'),(work/'deployment.json','deployment.json'),(work/'inference.log','inference.log'),(work/'models/manifest.json','model-manifest.json'),(old/'printed-names.json','printed-names.json')]:shutil.copyfile(src,dest/target)
for p in (work/'nonthinking').glob('*'):
 if p.name!='report.json':shutil.copyfile(p,dest/p.name)
(dest/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
(dest/'names.json').write_text(json.dumps(names['ninfer'],ensure_ascii=False,indent=2)+'\n')
labels=['Dual OCR + parser','Qwen Q4_K_M / llama.cpp','Qwen NVFP4 / NInfer'];colors=['#55788f','#147d64','#9b6c29']
fig,axs=plt.subplots(1,2,figsize=(12,4.6),layout='constrained')
values=[names[k]['summary']['name_recall']*100 for k in ('dual','llama','ninfer')]
axs[0].barh(labels,values,color=colors);axs[0].invert_yaxis();axs[0].set_xlim(0,110);axs[0].set_title('Printed-name recall (136 readable names)');axs[0].set_xlabel('Percent')
for i,v in enumerate(values):axs[0].text(v+1,i,f'{v:.1f}%',va='center')
values=[latency[k]['median_seconds'] for k in ('llama','ninfer')]
axs[1].barh(labels[1:],values,color=colors[1:]);axs[1].invert_yaxis();axs[1].set_xlim(0,max(values)*1.2);axs[1].set_title('Median request latency (32 same receipts)');axs[1].set_xlabel('Seconds')
for i,v in enumerate(values):axs[1].text(v+.3,i,f'{v:.1f}s',va='center')
for ax in axs:ax.spines[['top','right','left']].set_visible(False)
fig.suptitle('Deployment comparison: quantization, image budget and JSON enforcement differ',fontsize=12)
fig.savefig('docs/assets/ninfer_comparison.png',dpi=170);fig.savefig('docs/assets/ninfer_comparison.svg');plt.close(fig)
rows=[]
for key,label in zip(('dual','llama','ninfer'),labels):
 n=names[key]['summary'];f=metrics[key]
 rows.append(f"| {label} | {n['matched_names']}/136（{n['name_recall']:.1%}） | {n['fully_correct_receipts']}/28 | {n['correct_row_counts']}/32 | {f['total_correct']}/32 | {f['weight_name_pair_hits']}/20 |")
percase=[]
for c in ann['cases']:
 cs=[next(r for r in names[k]['cases'] if r['id']==c['id']) for k in ('dual','llama','ninfer')];i=c['id'];photo='../tests/backend_api/corpus/baselines/2026-09-18-qwen38-q4/'+c['images'][0]['path']
 percase.append(f"| [{i[:8]}]({photo}) | {c['store']} | "+' | '.join(f"{r['matched_names']}/{r['verified_names']}" for r in cs)+f" | {cs[-1]['predicted_rows']}/{cs[-1]['expected_rows']} |")
l,n=latency['llama'],latency['ninfer'];r=names['ninfer']['summary']
text=f'''# NInfer / Qwen3.8 收据实测

日期：2026-09-18。使用上一轮完全相同的 **32 张收据原图**、票面名称标注和通用/商店提示规则。原确认数据库、照片与生产识别配置未修改。

## 结果

下表 NInfer 为**仅去掉外层 Markdown 代码框后**的结果，没有改字、补金额、修复 JSON 或重试推理。整张名称完全正确率只计所有名称可辨认的 28 张；8 个无法确定的名称不计入 136 个名称的分母。

| 方案 | 票面名称命中 | 名称整张完全正确 | 商品行数正确 | 总额与确认记录一致 | 名称+金额+重量组合命中 |
| --- | ---: | ---: | ---: | ---: | ---: |
{chr(10).join(rows)}

金额和重量仍以冻结的确认字段作辅助核验；名称以原图核验标注为准。重量只覆盖确认记录中已有明确重量的 20 行，不代表全部称重行。此处增加商品名称绑定条件，避免把正确重量放到错误商品仍计为命中。

![比较图](assets/ninfer_comparison.png)

## 速度

| 指标 | 上一轮 llama.cpp / Q4_K_M | NInfer / NVFP4 |
| --- | ---: | ---: |
| 32 张批次耗时 | {l['batch_seconds']:.1f} 秒 | {n['batch_seconds']:.1f} 秒 |
| 单张请求中位数 | {l['median_seconds']:.1f} 秒 | {n['median_seconds']:.1f} 秒 |
| 单张请求范围 | {l['min_seconds']:.1f}–{l['max_seconds']:.1f} 秒 | {n['min_seconds']:.1f}–{n['max_seconds']:.1f} 秒 |
| 输入 token 中位数 | {l['median_prompt_tokens']:.0f} | {n['median_prompt_tokens']:.0f} |

NInfer 的单张请求中位数约为上一轮的 **{n['median_seconds']/l['median_seconds']:.1%}**，即快 **{l['median_seconds']/n['median_seconds']:.2f} 倍**。请求计时包括本地传输、图像处理和推理；批次还包括客户端图片编码。两轮均串行、不重试、无独立预热，模型加载与本轮编译/下载不计入。双 OCR 本轮使用缓存重新解析，不参与速度比较。

## 接口问题：没有强制 JSON 输出

NInfer 本轮原始回复中，能直接解析成 JSON 对象的有 **{summary['raw_json_objects']}/32**；格式适配后能解析 **{summary['formatting_only_decoded']}/32**，其中 **{metrics['ninfer']['valid']}/32** 通过相同的后端结构校验与规范化。

[NInfer 的 API 文档](https://github.com/Neroued/ninfer/blob/9e163eee4b8acec21ab0ac765107b6a3f287b217/docs/serving.md)明确不支持 JSON Schema 约束解码，仅接受 `response_format=text`。因此把同一 schema 加入提示文字，请求“只输出 JSON”。模型仍可能加代码框。离线适配只允许完整回复是单个 JSON 代码框；不从解释文字中猜测截取 JSON，不接受截断结果，也不改任何字段。原始失败和原始回复都已保留。

这意味着不能把 NInfer 原样替换现有结构化接口。接入时至少需要格式适配、schema 校验和金额/重量校验，不能把“能解析 JSON”当成“数据正确”。

## 配置与可比性

- [NInfer](https://github.com/Neroued/ninfer) 固定 commit `9e163eee4b8acec21ab0ac765107b6a3f287b217`；CUDA 13.1.2；在本机 RTX 5090 32 GB 上容器化运行。
- 模型：[neroued/Qwen3.8-27B-nvfp4-NInfer](https://huggingface.co/neroued/Qwen3.8-27B-nvfp4-NInfer)，revision `f0b43ad436b9fa8142c6ed6647c470a6fe409484`；文件 SHA256 `74d2c57145e6ff11d1d2faa79594477f9bc903a611af1fb20218189fbbb77d82` 已校验。模型是混合 NVFP4/FP8 权重，不是上一轮 GGUF Q4_K_M。
- thinking 关闭、temperature 0、seed 42、上下文与 KV 容量 32768、FP8 KV、并发 1、MTP 3-token 推测解码、优化 proposal head、最大输出 8192 token。
- 同样先 EXIF 调正原图再传 PNG。NInfer 使用模型自带 16,777,216 像素上限；原图约 12.5 MP，而上一轮 llama.cpp 限制 4096 图像 token。因此分辨率、量化、模板与结构化输出机制都不同，**这是实际部署配置对比，不能把精度或速度差异全部归因于引擎**。
- 一次设备显存采样为 26,819 MiB（约 26.2 GiB），不是峰值。模型运行时只发布本机回环测试端口；原 backend_api 保持运行，双 OCR 暂停让出 GPU，测试后恢复。
- 沿用[原图票面名称标注](../tests/backend_api/corpus/annotations/2026-09-18-printed-names.json)，不使用商品名称作为文字答案。标注由 Codex 逐图核验，未经过用户独立复核；未评测中文续行逐字准确率、Logo、多图长收据或新商店泛化。

## 逐张票面名称

| 收据 | 商店 | 双 OCR | llama.cpp Q4_K_M | NInfer NVFP4 | NInfer 商品行数/原图 |
| --- | --- | ---: | ---: | ---: | ---: |
{chr(10).join(percase)}

[完整指标及差异](../tests/backend_api/corpus/baselines/2026-09-18-ninfer/summary.json) · [原始输出记录](../tests/backend_api/corpus/baselines/2026-09-18-ninfer/raw-report.json) · [格式适配后记录](../tests/backend_api/corpus/baselines/2026-09-18-ninfer/adapted-report.json) · [部署记录](../tests/backend_api/corpus/baselines/2026-09-18-ninfer/deployment.json)
'''
Path('docs/ninfer_evaluation.md').write_text(text)
print(json.dumps(summary,ensure_ascii=False,indent=2))
