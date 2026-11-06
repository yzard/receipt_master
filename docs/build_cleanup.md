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

回归覆盖成功清理、构建失败保留、清理失败退出、正式产物保护、清理路径范围、活动 Rust 锁、嵌套入口复用 builder、旧 Web 资源替换，。指纹回归包含输入未变、源码改变、工具链改变、产物损坏、产物缺失和镜像缺失。iOS 入口测试覆盖连续两次构建复用、压缩包导出与后续清理，原生编译仍需要 macOS/Xcode。



旧的 root 测试产物可能无法由当前用户删除。清理器在 Linux 上遇到权限错误时，使用临时 Python 容器对同一组已校验路径重试，不扩大挂载或删除范围。
