# iOS 与 Android 一致性验证

两端使用 `src/shared/lib` 的同一份业务实现：收据列表及排序、连续拍摄与相册多选、待上传持久化与重试、后台识别状态轮询、草稿编辑和确认、税码/SKU、商品/类别/店名/Logo 别名、报表、回收站、CSV、备份与整体恢复。iOS 通过 Swift Package Manager 注册原生插件。

平台差异：Android APK 校验、下载和安装更新仅适用于 Android。iOS 更新需要单独的 Apple 分发渠道，当前项目没有 App Store/TestFlight 更新配置。Android 的 `retrieveLostData` 用于恢复被系统回收的图片选择 Activity；iOS 不调用该 Android API，共用拍摄缓存和上传重试仍然生效。

## 可重复执行

要求 macOS、Xcode、可用 iOS Simulator runtime 和 Flutter 3.47.4 / Dart 3.13.3。

```bash
./build_ios.sh /absolute/path/to/flutter --simulator
./build_ios.sh /absolute/path/to/flutter
```

第一条生成 `build/flutter/build/ios/iphonesimulator/Runner.app`；第二条执行无签名真机编译，不是可分发的签名 IPA。两者都会运行静态检查和 iOS 控件模式的共享测试。

使用 `RECEIPT_BOOTSTRAP_FILE=/absolute/path/to/config.json` 注入与 Android 相同的配置，只允许 `endpoint` 字段，不打包凭据。默认读取 `build/mobile-config/backend_defaults.json`，缺失或无效时构建立即失败；启动后使用账户登录，HTTP 仅允许构建时预置的地址。注入只修改构建目录，并为 HTTP 主机生成限定的 ATS 例外。重复准备工程会重新复制资源，不污染源码。

```bash
xcrun simctl boot <simulator-id>
xcrun simctl install <simulator-id> build/flutter/build/ios/iphonesimulator/Runner.app
xcrun simctl launch <simulator-id> com.receiptmaster.receiptMaster
cd build/flutter
/absolute/path/to/flutter run -d <simulator-id> --target=../../tests/ios/smoke.dart --no-resident
```

原生冒烟入口输出 `IOS_SMOKE_PASS` 才表示 Keychain 写/读/删、持久文件读写、临时目录、设备时区和配置加载全部通过。它使用独立临时键和文件，不改动业务凭据，完成后启动真实主界面。运行后重新使用正常 `lib/main.dart` 构建/安装即可恢复正式入口。

共享测试默认运行 Android 控件模式；`--dart-define=TEST_PLATFORM=ios` 运行 iOS 控件模式。测试通过 Flutter 的 `TargetPlatformVariant` 设置并恢复平台，业务请求使用测试服务器响应。它们不代替真实服务的端到端验收。

## 2026-10-03 合并验证

保留远端账户登录与严格后端地址校验，合入模拟器构建入口、资源隔离和平台测试。新增的语言、外观、店铺类型、搜索及设置测试也运行 iOS 控件模式；滚动控件等待稳定并确保点击位置在屏幕内，登录表单等待 iOS 无障碍错误提示计时结束。

合并后 Android/iOS 模式各 76 项共享测试通过，15 项 Python 构建测试及静态检查通过；更新后的源码已通过 iOS Simulator Debug 编译。本次原生编译使用未配置后端的开发工程，仅验证编译，不是已配置的发布构建，未进行实际服务器验收。正式 `build_ios.sh` 仍要求有效的 endpoint 配置，不会回退到空配置。冒烟入口与新的账户登录模型保持兼容，不再在未登录时主动请求认证连接。

## 2026-09-22 历史验证范围

- 两端各 32 项共享测试通过，包括列表、拍摄、重试、编辑、目录和报表回归。
- Python 构建配置回归 3 项通过，覆盖资源隔离和 HTTP → HTTPS → 空配置时清除旧 ATS 例外。
- 真实摄像头、相册权限、系统分享/文件选择以及连接实际服务器的 OCR、备份恢复仍需设备/服务验收。当前仓库未提供后端配置，不能据此宣称所有功能已完成端到端验证。

2026-09-22：使用 Xcode 27.0（27A266a）完成 iOS Simulator Debug 构建和无签名 iPhoneOS Debug 构建；在 iPhone 17 Pro / iOS 26.4 模拟器安装并启动，原生冒烟输出全部五组 `IOS_SMOKE_PASS`。截图与执行日志保存在 `build/ios-launch.png`、`build/ios-build.log`、`build/ios-smoke.log` 和 `build/android-widget-tests.log`。启动截图中的数据加载失败源于空后端配置，不代表已连通服务器。
