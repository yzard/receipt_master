# 构建清理约束

2026-10-27：检查所有四个维护中的构建入口。历史评测目录中的运行快照不是当前构建入口。

| 入口 | 原有不足 | 当前行为 |
| --- | --- | --- |
| `build_docker.sh` | 使用共享默认 builder，成功后保留中间层和缓存 | 本次独立 builder，检查、导出及可选推送成功后移除 builder 和项目临时输出 |
| `build_android.sh` | 准备发生在锁外，保留 debug APK、staging、Flutter 工作目录 | 项目锁覆盖全过程，只构建 release APK，发布后清理临时输出 |
| `build_web.sh` | 保留构建缓存，直接覆盖 Web 导出目录可能留下旧资源 | 独立导出后替换正式目录，成功后清理 builder 和工作目录 |
| `build_ios.sh` | 未导出独立产物，工作目录和依赖缓存保留 | 导出最终应用压缩包，成功后清理工作目录及本次依赖缓存 |

`docker/build_lifecycle.sh` 统一管理项目锁、工作目录、builder 和退出状态。组合构建的子入口复用父入口的 builder。独立调用也使用同一套规则。工作目录位于 `build/work.*`，成功后移除；失败时保留，控制台给出路径。清理失败返回非零状态。

`docker/build_state.py` 将内容指纹保存在 `build/state/`。输入包括源码、测试、构建脚本、锁文件、Dockerfile、工具链及上游产物。复用前重新计算最终文件的 SHA256，并检查记录的最终镜像是否存在。缺失、改变或损坏的产物触发重建。目标通过检查并导出后才发布成功记录，失败目标不覆盖原记录。

未变化的 Web、Android、iOS 和后端镜像直接复用最终产物。Docker 组合入口仍执行容器 HTTP smoke。模型运行依赖由共享 Strata 服务维护，不属于本项目构建输入。

需要更新可变的上游基础镜像或系统软件包时，使用 `RECEIPT_REFRESH_BUILD=1 ./build_docker.sh` 明确刷新。该设置绕过最终产物复用。普通源码构建不自动刷新这些依赖。

`docker/build_cleanup.py` 只删除列出的项目生成路径。它拒绝越界路径、路径中的符号链接和仍在使用的 Rust 编译目录。清理不执行全局 Docker prune，不删除其他项目的 builder。旧默认 builder 中无法明确归属的历史缓存不在清理范围内。

保留 `build/mobile/` 中的当前 release APK、更新清单、安装 APK、iOS 最终压缩包及校验报告。`build/web/` 保留本次 Web 产物。签名密钥、版本状态、目标指纹、后端默认地址配置、运行数据、备份和评测报告继续保留。这些是产物或受保护状态，不是缓存例外。

Android 不再生成 debug APK。真机 iOS 构建使用 release 和 `--no-codesign`，产物为 `receipt-master-ios-unsigned.zip`。模拟器仍使用 Flutter 支持的 debug 构建，产物为 `receipt-master-ios-simulator.zip`。导出后不保留编译工作目录。

## 外部模型

本项目不再下载、提取或打包模型层。已有跨项目模型缓存不由此项目删除；Strata 及模型由共享 local_llm 项目维护。

## 验证范围

回归覆盖成功清理、构建失败保留、清理失败退出、正式产物保护、清理路径范围、活动 Rust 锁、嵌套入口复用 builder、旧 Web 资源替换。指纹回归包含输入未变、源码改变、工具链改变、产物损坏、产物缺失和镜像缺失。iOS 入口测试覆盖连续两次构建复用、压缩包导出与后续清理，原生编译仍需要 macOS/Xcode。

旧的 root 测试产物可能无法由当前用户删除。清理器在 Linux 上遇到权限错误时，使用临时 Python 容器对同一组已校验路径重试，不扩大挂载或删除范围。

## 2026-10-27 实测结果（合并后端前）

完整 `build_docker.sh` 通过。构建包含 36 项构建脚本测试、55 项 Web 测试、90 项移动端测试、137 项 Rust 常规测试，以及 OCR 检查。容器 HTTP smoke 覆盖认证、角色、用户隔离、照片、多图上传、旋转、报表和镜像内 APK 下载。已有真实模型评测仍按各测试的配置跳过。

Android 当前 build 为 10103。API 镜像为 `c104417ffbc9`，OCR 镜像为 `66ece90a2ef2`，两者都有 `20261027` 与 `latest` 标签。组合入口连续执行以及删除 builder 后的新调用均复用相同产物，APK 版本、SHA256 和最终镜像 ID 不变。

真实模型探针使用 Long Live Health 更新后的完整目录复制指令。它与 Receipt Master 镜像的模型层均为：

```text
sha256:e35eee7aab2f21634d928afca6a63292bcc1a48a0da1d1daaa585464c8e85bde
```

模型复制探针使用 `--network none`，没有下载权重。独立 builder、不同父镜像的小型探针也得到相同复制层。实际 OCR 运行层提取和后续构建通过，没有重新编译 NInfer 或安装 OCR 运行依赖。运行层探针保留正常测试网络，独立检查阶段仍可安装测试依赖。

最终核对确认，本次两个 builder 及其状态卷、`build/work.*`、staging、debug APK、Flutter/Rust 工作目录和 Python 缓存均已删除。一次性清理也移除旧 `receipt-mobile-toolchain:local`、本项目无引用的试验镜像、Web 开发依赖目录，以及旧评测的临时虚拟环境。评测报告、模型缓存、最终产物、签名和版本记录继续保留。

本机 OCR 容器的 ID 和启动时间保持不变，没有部署或重启服务。没有完整重建另一项目的应用镜像，其真实模型探针用于核对共享层。原生 iOS 仍未在 Linux 编译，仅其入口流程通过测试。

机器可读记录位于 `build/evaluations/build-cleanup-20261027.json`。
