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

未变化的 Web、Android、iOS 和后端镜像直接复用最终产物。Docker 组合入口仍执行容器 HTTP smoke。OCR 业务源码变化而运行依赖不变时，从已有最终镜像临时提取运行层，避免重新编译 NInfer 或安装其依赖。这份输入只存在于本次工作目录，成功后删除。运行依赖、模型版本或工具链改变会使对应指纹失效。

需要更新可变的上游基础镜像或系统软件包时，使用 `RECEIPT_REFRESH_BUILD=1 ./build_docker.sh` 明确刷新。该设置绕过最终产物和 OCR 运行依赖的复用，但仍保留校验通过的固定版本模型。普通源码构建不自动刷新这些依赖。

`docker/build_cleanup.py` 只删除列出的项目生成路径。它拒绝越界路径、路径中的符号链接和仍在使用的 Rust 编译目录。清理不执行全局 Docker prune，不删除其他项目的 builder。旧默认 builder 中无法明确归属的历史缓存不在清理范围内。

保留 `build/mobile/` 中的当前 release APK、更新清单、安装 APK、iOS 最终压缩包及校验报告。`build/web/` 保留本次 Web 产物。签名密钥、版本状态、目标指纹、后端默认地址配置、运行数据、备份和评测报告继续保留。这些是产物或受保护状态，不是缓存例外。

Android 不再生成 debug APK。真机 iOS 构建使用 release 和 `--no-codesign`，产物为 `receipt-master-ios-unsigned.zip`。模拟器仍使用 Flutter 支持的 debug 构建，产物为 `receipt-master-ios-simulator.zip`。导出后不保留编译工作目录。

## 唯一的持久缓存

Qwen3.8 模型及许可证使用同一个跨项目目录：

```text
~/.cache/shared-model-layers/qwen3.8-27b-nvfp4-ninfer-f0b43ad4/model/
```

目录采用 OCI 镜像格式，只保留模型和许可证及其元数据，允许两个独立资源层或一个合并层。它不包含 CUDA、NInfer 编译产物、应用代码或依赖缓存。缓存与另一个 OCR 项目的格式和锁文件一致。

`docker/shared_qwen.py` 优先复用有效缓存。如果缓存不存在，它查找本机已有镜像，提取匹配的模型层并核对文件 SHA256。它支持原有 ADD 层，以及重建后 COPY 层的 Docker history 格式。本机没有可用模型时，才构建并下载模型阶段。缓存损坏会报错，不会静默删除后重新下载。

构建使用 `--build-context qwen-model=oci-layout://...` 覆盖模型阶段。最终 OCR 镜像使用 `COPY --link --from=qwen-model / /` 复制整个模型树，保留共享输入中的目录元数据。逐个复制文件会重新创建父目录，其时间不同会产生不同层 ID。运行时不依赖宿主缓存挂载。构建后另行核对镜像内两个文件的 SHA256。

Docker 对命名阶段和本地 OCI 输入的说明见 [Buildx 文档](https://docs.docker.com/reference/cli/docker/buildx/build/#additional-build-contexts---build-context)。iOS 的 CocoaPods 缓存通过 `CP_HOME_DIR` 和 `CP_CACHE_DIR` 放入本次工作目录，依据 [CocoaPods 配置实现](https://github.com/CocoaPods/CocoaPods/blob/master/lib/cocoapods/config.rb)。

## 验证范围

回归覆盖成功清理、构建失败保留、清理失败退出、正式产物保护、清理路径范围、活动 Rust 锁、嵌套入口复用 builder、旧 Web 资源替换，以及本地模型复用和首次下载分支。指纹回归包含输入未变、源码改变、工具链或模型改变、产物损坏、产物缺失和镜像缺失。iOS 入口测试覆盖连续两次构建复用、压缩包导出与后续清理，原生编译仍需要 macOS/Xcode。

为统一模型层，同步调整了 Long Live Health 的模型复制步骤、合并层缓存兼容性及对应回归。没有更改其业务逻辑或服务配置。独立 builder 和不同父镜像的复制探针用于验证目录元数据稳定；完整模型探针另行比较真实权重层。

旧的 root 测试产物可能无法由当前用户删除。清理器在 Linux 上遇到权限错误时，使用临时 Python 容器对同一组已校验路径重试，不扩大挂载或删除范围。
