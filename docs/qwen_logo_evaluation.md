# Qwen Logo 图片匹配测试

日期：2026-09-18。下文记录切换前的匹配实验。后续生产已按此结果切换到 Qwen；旧匹配源码与权重已删除，历史结果保留。

## 结论

使用简短提示词的 **Qwen3.8-27B NVFP4 + NInfer + thinking** 在本组测试中 40/40 正确；现有 SuperPoint + LightGlue 为 36/40。最新 Target `be4a2b4d-87d4…` 和它的旋转、透视、模拟折痕版本均被正确识别，原方法这四项均返回未知。结果支持继续接入 Qwen 匹配，但不能解释为未知数据的 100% 准确率。

## 方法

- 冻结 10 个内置参考 Logo，覆盖 7 个商店；每次把查询图与所有候选图一并提交。参考标签只用 `r01` 等编号，**不把商店名称传给模型**；返回编号后在测试端映射店名。
- 真实组：27 个数据库 Logo 裁剪，排除与参考图 SHA256 相同的样本。覆盖 Costco 12、skyFOODS 8、H MART 3、99 Ranch 2、Target 1、Hualian 1。最新 Target 由用户指明并目视确认；其余使用历史保存的店名。不是 27 个独立商标。
- 变形组：Target、skyFOODS、Hualian 各做旋转、透视、模拟折痕。源自真实组，必须与真实独立照片区分；不代表所有实际折痕都已验证。
- 拒绝组：删除 Target 参考后查询 Target、删除 Hualian 参考后查询 Hualian、空白图、未登记的 `FRESH GOODS` 文字图，预期均为未知。
- 两种方法使用相同查询与参考库。现有方法保留阈值 0.55、几何证据 0.75、不同店名差值 0.05，取同名参考的最高有效分数。
- Qwen 每张图最长边 768，随机打乱参考顺序（固定种子），temperature=0、seed=42、thinking=true、输出上限 4096。只接受合法 JSON、有效参考编号或 null；截断按失败计，不把“没有答案”算成正确拒绝。
- 串行通过当前内部 OCR 队列运行。原照片/裁剪和参考图均不修改；测试只另生成变形图。

## 正确数

| 分组 | 数量 | 现有方法 | Qwen 初版提示词 | Qwen 简短提示词 |
|---|---:|---:|---:|---:|
| 真实收据 Logo | 27 | 26/27 | 26/27 | 27/27 |
| 旋转/透视/模拟折痕 | 9 | 6/9 | 9/9 | 9/9 |
| 缺失参考/空白/陌生名称 | 4 | 4/4 | 4/4 | 4/4 |
| 总计 | 40 | 36/40 | 39/40 | 40/40 |

简短提示词结果分两步获得：先验证 4 个关键案例，再用完全相同的提示词、参数与参考顺序补完其余 36 项；每项都实际运行，没有用初版结果替代。提示词调整使用了本组 Hualian 的失败，因此这组结果是开发回归，尚不是独立的泛化测试集。skyFOODS/Hualian 在本次测试中没有互相误认；这种方法返回分类结果，不提供可与传统匹配分数直接比较的校准相似度。

## Hualian 失败及复测

初版提示词在 `fe3a7e41-45ad…` 上用完 4096 token，全用于 thinking，未输出 JSON，耗时 38.48 s。保持图片、顺序和提示词不变，只提高到 8192，仍全部用于 thinking，51.64 s 后截断。**增加预算没有修复问题。**

改为简短提示词、强调直接比较可见图形、不必推断品牌名称、限制思考篇幅，恢复 4096 上限：该图 2.63 s 返回 Hualian，实际输出 206 token（含 thinking）。Target 2.18 s、skyFOODS 1.93 s、移除 Hualian 参考后正确拒绝 3.40 s。随后完成其余案例验证。

最终提示词：[short-prompt.txt](../tests/backend_ocr/baselines/2026-09-18-qwen-logo/output/short-prompt.txt)。限制思考篇幅是提示要求，并非引擎硬保证；生产仍需处理超时、截断与未知结果。

## 现场耗时

| 方法 | 中位数 | P95 | 最慢 |
|---|---:|---:|---:|
| 现有 SuperPoint + LightGlue | 2.25 s | 2.96 s | 3.04 s |
| Qwen 初版提示词 | 4.39 s | 16.42 s | 38.48 s |
| Qwen 简短提示词 | 2.18 s | 2.84 s | 3.40 s |

这是模型已加载、当前 10 个参考样本、单次串行调用的现场耗时，包含代理和队列等待，不含 Logo 定位/裁剪，不是完整收据识别耗时。当前数据上简短提示词与 CPU 方法耗时接近；不能外推到更大的 Logo 库。当前每次最多 16 张图，包含查询图，所以实际接入还需要明确超过 15 个参考样本时的分批策略。

## 产物与复现

- [原始结果与输入](../tests/backend_ocr/baselines/2026-09-18-qwen-logo/README.md)：照片哈希、候选顺序、两轮模型原始响应、耗时及预算复测。
- [评测脚本](../tests/backend_ocr/qwen_logo_evaluation.py) 现仅运行 Qwen，历史传统方法比较结果冻结保存；与 `logo_variants.py` 放在同一目录，在独立评测环境运行（需要 Pillow、NumPy、OpenCV），通过内部网络访问 OCR 服务。生产镜像已移除这些旧匹配依赖，不再兼任完整评测环境。服务和数据保持不变。

```bash
python qwen_logo_evaluation.py \
  --input /tmp/qwen-logo-evaluation/input \
  --output /tmp/qwen-logo-retest \
  --url http://backend_ocr:8000 \
  --model qwen3.8-27b-ninfer-nvfp4 \
  --prompt-file /tmp/qwen-logo-evaluation/output/short-prompt.txt \
  --max-output-tokens 4096
```

## 逐项结果

| 案例 | 预期 | 现有方法 | 初版提示词 | 简短提示词 | 简短提示词耗时 |
|---|---|---|---|---|---:|
| `be4a2b4d-87d4-41f8-8ad2-b8b419229096` | Target | 失败 | 正确 | 正确 | 2.18 s |
| `57bb2995-1993-4ff0-863e-43764ee31526` | Costco | 正确 | 正确 | 正确 | 2.28 s |
| `834a4c6e-9307-40bb-acf6-c143c5f41e73` | skyFOODS | 正确 | 正确 | 正确 | 1.93 s |
| `560ccf19-b7af-4ad6-a512-1dd51853f4d8` | Costco | 正确 | 正确 | 正确 | 2.48 s |
| `74356ee7-d2e7-42e4-aea1-8fa567dec8ea` | skyFOODS | 正确 | 正确 | 正确 | 2.06 s |
| `78f63611-ad9f-4982-86aa-7b16450f46a7` | 99 Ranch | 正确 | 正确 | 正确 | 2.35 s |
| `2f97fc50-4cf3-47e1-bd44-ea6de95c774c` | 99 Ranch | 正确 | 正确 | 正确 | 2.11 s |
| `fe3a7e41-45ad-4865-8a83-427a696481db` | Hualian | 正确 | 失败 | 正确 | 2.63 s |
| `e3843baa-904a-4bbf-bc21-278a1693d5c7` | H MART | 正确 | 正确 | 正确 | 2.14 s |
| `199fc34a-4857-4aac-873c-8c55f8b223a9` | H MART | 正确 | 正确 | 正确 | 2.06 s |
| `4e491343-7593-42b4-b5b5-01e5648557ee` | Costco | 正确 | 正确 | 正确 | 2.13 s |
| `c00860de-60e8-4892-8bc3-1e0b2c8314ab` | Costco | 正确 | 正确 | 正确 | 2.85 s |
| `6d9da1ec-c0fc-4905-82b4-4ebd11716b1c` | skyFOODS | 正确 | 正确 | 正确 | 2.01 s |
| `e6c62f11-3b8d-4ac0-a860-1756df0efa55` | Costco | 正确 | 正确 | 正确 | 2.41 s |
| `73953603-31f5-496a-9dd4-76fc845c8398` | skyFOODS | 正确 | 正确 | 正确 | 2.84 s |
| `d7f8ff6d-6502-4eeb-8850-2f15b131988f` | skyFOODS | 正确 | 正确 | 正确 | 2.17 s |
| `a31f7e6b-8bb1-49c8-a292-504d76d1a59c` | skyFOODS | 正确 | 正确 | 正确 | 2.08 s |
| `8572dcef-7f7f-4d77-80c6-0ede75d45fa3` | Costco | 正确 | 正确 | 正确 | 2.74 s |
| `3a8e3c19-e8d0-4ea8-8fa3-06e3cd5fcfd4` | Costco | 正确 | 正确 | 正确 | 2.37 s |
| `e9ee06e0-f4aa-4c3c-812a-4e8abc21e3f0` | skyFOODS | 正确 | 正确 | 正确 | 2.16 s |
| `924e246e-c811-497a-a61b-6b5724f7bacd` | Costco | 正确 | 正确 | 正确 | 2.09 s |
| `e297a3d3-f9f1-4ba7-8e5e-a18e56fdecdd` | H MART | 正确 | 正确 | 正确 | 2.05 s |
| `5331c892-9fb6-42b5-bdb3-5a205b1a0767` | skyFOODS | 正确 | 正确 | 正确 | 2.08 s |
| `20267232-d4d0-4540-9c14-b0e051b06445` | Costco | 正确 | 正确 | 正确 | 2.29 s |
| `c5fdc978-8f74-43bf-a5c5-e22d28f5aea9` | Costco | 正确 | 正确 | 正确 | 2.52 s |
| `ca76c352-9601-498c-8324-0ef9bcf5ea3b` | Costco | 正确 | 正确 | 正确 | 2.13 s |
| `4fc6a91b-faba-4d3e-82a3-be4c78270e99` | Costco | 正确 | 正确 | 正确 | 2.28 s |
| `be4a2b4d-87d4-41f8-8ad2-b8b419229096-rotate` | Target | 失败 | 正确 | 正确 | 2.09 s |
| `be4a2b4d-87d4-41f8-8ad2-b8b419229096-perspective` | Target | 失败 | 正确 | 正确 | 2.63 s |
| `be4a2b4d-87d4-41f8-8ad2-b8b419229096-simulated_fold` | Target | 失败 | 正确 | 正确 | 2.13 s |
| `834a4c6e-9307-40bb-acf6-c143c5f41e73-rotate` | skyFOODS | 正确 | 正确 | 正确 | 1.98 s |
| `834a4c6e-9307-40bb-acf6-c143c5f41e73-perspective` | skyFOODS | 正确 | 正确 | 正确 | 2.06 s |
| `834a4c6e-9307-40bb-acf6-c143c5f41e73-simulated_fold` | skyFOODS | 正确 | 正确 | 正确 | 2.16 s |
| `fe3a7e41-45ad-4865-8a83-427a696481db-rotate` | Hualian | 正确 | 正确 | 正确 | 2.29 s |
| `fe3a7e41-45ad-4865-8a83-427a696481db-perspective` | Hualian | 正确 | 正确 | 正确 | 2.24 s |
| `fe3a7e41-45ad-4865-8a83-427a696481db-simulated_fold` | Hualian | 正确 | 正确 | 正确 | 2.38 s |
| `be4a2b4d-87d4-41f8-8ad2-b8b419229096-absent` | 未知 | 正确 | 正确 | 正确 | 2.70 s |
| `fe3a7e41-45ad-4865-8a83-427a696481db-absent` | 未知 | 正确 | 正确 | 正确 | 3.40 s |
| `blank` | 未知 | 正确 | 正确 | 正确 | 1.93 s |
| `unregistered_text` | 未知 | 正确 | 正确 | 正确 | 2.43 s |
