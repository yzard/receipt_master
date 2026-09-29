# 第三版：Web UI 与多用户认证

## 代码检查结论

- Android/iOS 共用 `src/shared` 的 Flutter UI，已支持收据、拍摄/多图上传、异步识别、商品目录、商店 Logo 名称、报表、设置、备份和恢复。
- Flutter 客户端大量使用 `dart:io` 和移动平台插件，不能直接作为完整浏览器客户端部署。Web 使用 `src/web`，与移动端共享后端协议和业务运算。
- API 当前使用共享 Bearer API key；SQLite、照片、目录和偏好属于单一数据空间，没有用户授权边界。共享密钥不能继续作为公共客户端认证方式。
- 保留两个独立容器。Web 静态资源由 `backend_api` 同源提供，OCR 服务仍只在内部网络可见。

## 已确定的行为

1. 初次创建身份库时建立不可删除的元用户 `admin`，临时密码 `admin`。登录后只能修改密码或退出；改密前不能访问任何业务 API。
2. `RESET_ADMIN_PASSWORD=true` 作为 backend_api 的运行时环境变量传入容器：启动时将 admin 密码重设为 `admin`、强制改密，并撤销旧会话。完成恢复后应取消该变量，否则再次启动会再次重置。Docker image 不固化该开关或密码。
3. 只有 admin 可创建普通用户、删除其他用户。没有公开注册、不能创建第二个 admin、不能删除/改名/降级 admin。普通用户不能调用用户管理 API。
4. 密码使用 Argon2id 加盐哈希；正式密码至少 12 个字符。管理员创建的临时密码也需首次登录修改。
5. 使用短期 Bearer JWT 和持久化、可撤销、轮换的刷新会话。Web 刷新令牌放 HttpOnly/SameSite cookie；移动端放安全凭据存储。退出、改密、删除用户、管理员重置会撤销会话。登录错误不泄露用户是否存在，并限制重复失败尝试。
6. 用户数据完整隔离：中央身份库 `/data/database/auth.sqlite`，与 admin 的 `/data/database/receipts.sqlite` 同目录；admin 继续使用现有业务库和照片；普通用户各用 `/data/users/<不可变 UUID>/` 下独立 SQLite 和照片。用户 ID/数据根由认证层决定，客户端不能指定。目录、Logo 别名、偏好、作业、报表、备份都遵守同一边界。新用户安装预置分类与已审核商店样本。
7. 删除用户立即撤销认证、停止领取其任务；后台等待运行中的任务结束后安全清理其数据。其他用户、admin 和中央身份库不受影响。
8. 移动安装包只预置服务地址，不再包含共享 API 密钥；Android/iOS 都改为用户名密码登录、强制改密、账户退出和管理员管理。
9. Web 功能与移动端对齐：表格收据、四字段排序、草稿/失败背景、多图拍摄/上传、手动录入、照片查看/删除/旋转/排序、编辑/确认/删除/重新识别、商品目录四个 tabs、商店图像名称、互动趋势及分类商品明细、主题/重量/报表币种、备份恢复和 CSV。客户端不执行 OCR、重量换算或统计计算。
10. 保持浅色/深色/系统主题、半透明导航和响应式布局。Web 支持键盘操作、清楚的加载/空白/错误状态、可见的重试和破坏性操作确认。浏览器拍照需要浏览器提供的相机能力；部署到公网使用 HTTPS 才能正常使用安全 cookie 与相机。

## 逐步执行与验收

- [x] 1. 实现身份库、Argon2id、JWT/刷新轮换、强制改密、登录限流、不可删除 admin、管理员用户 API 和 RESET_ADMIN_PASSWORD。
- [x] 2. 接入所有 API/media/job/export 的用户数据边界；复用现有异步作业，覆盖跨用户访问、用户删除及重启恢复测试。
- [x] 3. Android/iOS 改用账户认证，删除客户端共享密钥设置/嵌入，提供账户与管理页面；共用 Flutter 代码通过分析与业务回归。
- [x] 4. 实现完整 Web UI，各页面直接使用统一业务 API；响应式布局、键盘操作和对话框标签已实现，关键交互通过组件测试。
- [x] 5. 新增 `build_web.sh`，在 Docker 内检查/构建 Web；`build_docker.sh` 构建 Android、Web 和两个 backend image；API image 包含 Web，Compose 传入重置变量。
- [x] 6. 完成后端认证/授权/业务测试、移动端分析与测试、Android Docker APK 编译、Web 构建、组件回归和真实容器 HTTP 验证；更新 README 和运行说明。浏览器视觉和 iOS/Xcode 验收的环境限制单列如下。

## 主要测试要求

- 默认 admin 的密码修改门禁；重置后的旧令牌失效；admin 不可删除（API 与数据库约束双重保障）。
- 普通用户不能创建/删除用户；两用户的收据 ID、照片 ID、目录、作业、报表、备份不可互访。
- 错误/过期 JWT、刷新令牌重放、退出、改密与用户删除后访问被拒绝。
- Web/mobile 登录和 session expiry 的恢复流程；相机/多图上传不阻塞浏览与异步识别。
- 无密码明文落库、无令牌日志、无共享认证 secret 出现在 Web/APK 资源中。

## 实施结果（2026-09-28）

### 构建与自动验收

`./build_docker.sh` 完整执行成功，包含以下检查：

| 范围 | 结果 |
| --- | --- |
| Rust API、认证、真实票据及存储回归 | 113 项通过，3 项原有测试忽略；格式、Clippy 和 release 编译通过 |
| Web | 20 项会话、组件与持久化上传测试通过；TypeScript 检查与生产构建通过；依赖审计 0 个已知漏洞 |
| 共用 Flutter 客户端 | 48 项测试通过；源代码和测试静态分析通过 |
| Android | Docker 内 APK 编译、签名及版本/哈希检查通过 |
| 配置与安装包默认值 | 6 项配置测试、3 项默认值测试通过 |
| API/OCR 镜像 | 两个镜像构建成功，Web 静态文件包含在 API 镜像中 |
| 真实容器 HTTP 回归 | Web 资源及响应头、Cookie 登录、强制改密、权限、跨账户隔离、多图上传和旋转、异步任务、报表、APK 哈希、文件 UID/权限、运行时重置、用户数据清理通过 |

HTTP 回归由 `tests/web/http_smoke.py` 创建临时容器和临时数据目录，结束后清理，已纳入总构建。它不会修改 playground 的业务库，也不启动 GPU 模型。此轮没有重新评测 OCR 模型准确率。

### 关键完成细节

- 身份库与收据库同在 `database/`，业务备份只包含收据库。恢复及中断恢复仅替换 `receipts.sqlite` 和它的 WAL/SHM，不替换整个目录，不覆盖身份库、用户或登录会话。回归覆盖替换前、旧收据库移走后、新收据库就位后三个中断点，以及已有身份库连接保持打开时的 WAL/SHM 保留。
- 删除用户先撤销会话，再等待正在运行的请求与识别任务结束后清理目录；重启可继续清理。
- 管理员重置同时清除该账户的登录失败锁定，避免恢复密码后仍无法登录。
- Web 待上传照片保存在 IndexedDB，手机待上传文件按服务地址和账户分开。切换账户不会将旧账户的照片提交给新账户。
- 会话刷新轮换支持浏览器多标签协调；切换账户后，旧请求的失败不能登出新账户。
- 收据编辑的预览金额由后端计算；所有客户端继续通过后端完成 OCR、转换和统计。

### 启用方式

新镜像和 APK 已生成；登录问题修复后已更新正在运行的 playground API 容器。后续运行 `./run_playground.sh` 重建并启动，访问 `http://localhost:5000/`。首次用 `admin` / `admin` 登录，界面强制修改密码；旧移动客户端需升级后用账户登录。

恢复管理员账户时运行 `RESET_ADMIN_PASSWORD=true ./run_playground.sh`。恢复后取消该环境变量，防止下次启动再次重置。公网使用 HTTPS 反向代理，并在开放公网前完成 admin 改密，具体设置见 README。

### 尚需有相应环境的手工验收

- 初次全量构建时没有可用的受控浏览器；后续已验证真实浏览器的登录、强制改密页，以及独立实例的收据查询、手动创建和商品编辑入口，并检查改密表单的自动填充标记。完整视觉检查、相机权限、设备尺寸下的手势及真实密码管理器操作仍需验收。
- Linux 无法执行 Xcode/iOS 编译和真机测试；Android/iOS 共用代码已完成分析和测试，Android APK 已构建。

## Web 登录调用修复

浏览器报 `'fetch' called on an object that does not implement interface Window.`：默认请求函数直接保存为 Client 的成员，作为成员调用时把 Client 当成了原生 `fetch` 的调用对象。之前的注入模拟请求不要求浏览器调用对象，未暴露该错误。

- 默认请求入口改为通过 `globalThis.fetch` 调用，JSON 和照片上传共用这一入口。
- 新回归测试使用默认 Client，按浏览器语义检查调用对象，覆盖登录、会话刷新、收据查询和 multipart 照片上传。修复前复现相同错误，修复后全部通过。
- Web 生产构建、API 镜像构建和真实容器 HTTP 回归通过；仅更新 playground 的 API 容器。
- 在真实浏览器中刷新新页面，使用 `admin` / `admin` 登录，成功进入“设置你的新密码”。新密码由用户自己设置，测试未修改密码。

## UUID 兼容与密码自动填充

- 删除所有业务代码对 `crypto.randomUUID()` 的直接调用。`src/web/src/id.ts` 统一使用安全随机接口 `getRandomValues` 生成 UUID v4，供请求、收据、商品行及上传任务使用；不回退到弱随机数。
- 回归环境保留 `getRandomValues`、移除 `randomUUID`，覆盖查询、录入和断点多图上传；修复前复现 3 处失败，修复后通过。缺少安全随机数接口时给出清楚的错误。
- Web 登录、改密和创建用户表单提供稳定的 form/input 名称与 ID。登录密码标记 `current-password`，新密码及再次输入标记 `new-password`，改密表单保留只读用户名作为账户上下文。
- Web 提交时读取原生 FormData，并同步表单状态；密码管理器未触发 React change 事件时，仍提交实际填入的用户名和密码。单元测试覆盖此路径及两次新密码一致性检查。
- Android/iOS 使用 AutofillGroup 和 username/password/newPassword 提示。两个新密码字段在同一组中；成功改密后请求保存，失败及取消不保存。管理员创建其他用户的凭据使用独立组，关闭后取消该组。
- 完整 Docker 构建、Android APK、容器 HTTP 回归通过。playground API 已更新；独立浏览器验证实例结束后已清理，未修改真实账户密码。

自动填充依据：[浏览器表单实践](https://web.dev/articles/sign-in-form-best-practices)、[Flutter newPassword](https://api.flutter.dev/flutter/services/AutofillHints/newPassword-constant.html)、[Flutter 完成自动填充上下文](https://api.flutter.dev/flutter/services/TextInput/finishAutofillContext.html)。

## 登录后下载 Android

用户流程：登录 Web 并完成必要的改密 → 侧边栏“下载 Android APK” → 安装 → 服务地址已预填 → 输入用户名密码登录手机。

- `/receipt_master.apk`、`/android-update.json` 和 `/updates/<sha256>.apk` 统一要求有效 JWT 或 Web 会话 Cookie；未登录返回 401，尚未完成强制改密返回 403。普通用户和 admin 都可以下载。
- 侧边栏和设置页共用下载组件，先刷新即将过期的登录会话，再触发浏览器同源下载；URL 不携带令牌。保留已认证的 GET、HEAD 和 Range 支持，响应设置 `private, no-store`。
- Android 更新清单和 APK 请求使用当前登录 JWT，禁用自动重定向；更新服务必须与登录服务、安装包预置的源一致，防止向其他域名发送凭据。已撤销会话停止下载，并清除该手机会话。
- APK 只包含构建配置的服务地址，签名、哈希和版本逻辑不变；不会转移 Web 的账号、密码或会话。公网域名通过 `RECEIPT_BACKEND_ENDPOINT=https://实际域名/` 配置；playground 默认预填手机可达的宿主网络地址。
- `build_docker.sh` 完成 Android 构建后，将初始 APK、更新清单和不可变更新包复制进 API 镜像的 `/artifacts/`。Compose 不挂载 APK 目录。容器 HTTP 回归仅挂载临时 `/data`，验证镜像内 APK 与构建产物一致、清单及所有架构更新包的大小和 SHA256 正确；未登录及未改密仍拒绝下载。新 APK 必须随 API 镜像一起发布。
- 后端鉴权测试、Web 下载组件测试、移动端下载身份与来源测试、完整 Docker 构建和真实容器 APK 哈希校验通过。真实浏览器中，普通测试用户登录后已验证侧边栏链接及原生 APK 下载事件；独立测试账户和数据随后清理。
