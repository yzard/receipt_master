# 统一界面语言

## 资源和接口

Web、Android、iOS 使用同一份后台资源：`src/backend_api/resources/localizations.json`，编译进 backend_api 镜像。客户端不再维护独立的英文翻译表。

`POST /api/v1/localizations/get`，请求体 `{}`，返回：

```json
{
  "data": {
    "schema_version": 1,
    "default_language": "zh",
    "available_languages": [
      {"code": "zh", "name": "中文", "locale": "zh-CN"},
      {"code": "en", "name": "English", "locale": "en-US"}
    ],
    "translations": {
      "zh": {"设置": "设置"},
      "en": {"设置": "Settings"}
    }
  }
}
```

示例仅展示一个文案；实际返回完整翻译表。这个接口允许登录前读取，不含账户或业务数据；收据、照片及 APK 的认证要求保持不变。

## 客户端行为

- Settings → Language 的全部选项来自 `available_languages`，不在客户端硬编码中文/英文选项。
- Web 每次页面启动、移动端每次应用启动对同一服务器成功请求一次，合并同时发生的请求。一次取得所有语言，切换语言直接使用对应表，不重复请求。
- 选择分别保存在浏览器和移动设备，切换保持当前页面、未保存输入及密码自动填充属性。已选语言不再可用时采用服务端默认语言。
- Web 缓存完整资源；移动端按服务器地址分别缓存。加载失败保留有效缓存，设置页提供重试。无有效缓存时保留可读的中文源文案，语言选项等待 API 返回。
- 只翻译界面固定文案及已收录的错误/警告，保留模板参数。票面名称、商品名称、店铺名称、用户创建的种类和未收录的模型备注不翻译。

## 增加语言

在后台 JSON 的 `available_languages` 添加代码、语言原名和格式化 locale，同时在 `translations` 添加同一组完整文案。保留所有 `{0}`、`{1}` 等占位符。重新构建并部署 backend_api 后，客户端下次启动取得新列表，无需修改客户端语言菜单或发布新 APK。

移动端语言代码采用 BCP 47，例如 `zh`、`en`、`zh-Hant`；Flutter 的系统日期/时间控件还需该 locale 受其本地化委托支持。iOS 原生系统权限提示使用平台资源，不属于此界面 API。

## 验证

后端测试核对语言列表、完整文案键集合和占位符一致性，并验证匿名可读取资源、匿名不可读取收据。Web/移动端测试从同一后台 JSON 读取样本，覆盖新增语言菜单、切换保持输入、不重复请求、缓存与失败重试，以及换服务器时忽略旧响应。容器 HTTP smoke 核对实际镜像返回的资源与源文件一致。
