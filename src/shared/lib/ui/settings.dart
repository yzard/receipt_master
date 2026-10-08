import '../l10n/catalog.dart';
import '../l10n/strings.dart';

import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../data/auth_session.dart';
import 'account.dart';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../data/store.dart';
import '../data/android_update.dart';
import '../domain/models.dart';

import 'common.dart';
import 'app_theme.dart';

class SettingsPage extends StatefulWidget {
  final AppStore store;
  final String zone;
  final Future<void> Function() onChanged;
  final Appearance appearance;
  const SettingsPage({
    super.key,
    required this.store,
    required this.zone,
    required this.onChanged,
    required this.appearance,
  });
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool busy = false, loaded = false;

  String? message;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (!mounted) return;
    setState(() => loaded = true);
    try {
      await widget.store.loadPreferences();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => message = '无法读取服务器偏好；请稍后重试。');
    }
  }

  Future<void> action(Future<void> Function() f) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await f();
      await widget.onChanged();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> checkAndroidUpdate() async {
    await action(() async {
      setState(() => message = '正在检查客户端更新…');
      final update = await AndroidUpdate.check(AuthSession.instance);
      if (!mounted) return;
      if (update == null) {
        setState(() => message = '已是最新版本');
        return;
      }
      if (!await confirm(
        context,
        context.tr("发现客户端更新"),
        context.tr("版本 {0}（{1}），约 {2} MB。现在下载并安装？", [
          update.release.versionName,
          update.release.versionCode,
          (update.release.bytes / 1048576).toStringAsFixed(1),
        ]),
      )) {
        return;
      }
      final result = await update.downloadAndInstall((progress) {
        if (mounted) {
          setState(() => message = '正在下载更新 ${(progress * 100).toInt()}%');
        }
      });
      if (mounted) {
        setState(
          () => message = result == 'permission_required'
              ? '请允许此应用安装更新，返回后再次点击“检查客户端更新”继续安装。'
              : '已打开系统安装器，请确认安装。',
        );
      }
    });
  }

  Future<void> exportFile(String name, Uint8List bytes, String mime) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final temp = await getTemporaryDirectory();
      final file = File(p.join(temp.path, name));
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: mime)],
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } else {
      final location = await getSaveLocation(suggestedName: name);
      if (location == null) return;
      await File(location.path).writeAsBytes(bytes, flush: true);
    }
  }

  Future<void> backupData() async {
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final bytes = await widget.store.createBackup(stamp);
    await exportFile('receipts-$stamp.receiptbackup', bytes, 'application/zip');
    if (mounted) setState(() => message = '备份已生成。请在系统面板中保存到你选择的位置。');
  }

  Future<void> restoreData() async {
    final file = await openFile();
    if (file == null || !mounted) return;
    if (!await confirm(
      context,
      context.tr("整体恢复备份"),
      context.tr("当前收据、商品和照片会被备份替换，不合并。替换前会在后端保留一份恢复点。此操作影响登录同一账户的所有设备。"),
    )) {
      return;
    }
    final bytes = await file.readAsBytes();
    final result = await widget.store.restoreBackup(bytes);
    await load();
    if (mounted) setState(() => message = result);
  }

  Future<void> exportRecovery() async {
    final bytes = await widget.store.latestBackup();
    await exportFile('server-recovery.receiptbackup', bytes, 'application/zip');
  }

  Future<void> csv() async {
    final zone = widget.zone;
    final text = await widget.store.csvExport(zone);
    await exportFile(
      'receipt-items.csv',
      Uint8List.fromList(utf8.encode(text)),
      'text/csv',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!loaded) return const Center(child: CircularProgressIndicator());
    return AbsorbPointer(
      absorbing: busy,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 116),
        children: [
          PageHeading(
            title: context.tr("设置"),
            subtitle: context.tr("让记录方式适合你"),
          ),
          if (busy) const LinearProgressIndicator(),
          if (message != null) Notice(message!),
          Text(context.tr("账户"), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  AuthSession.instance.user?['username'] ?? '',
                  key: const ValueKey('settings-username'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: context.tr("修改密码"),
                onPressed: () => openPageOverlay<void>(
                  context,
                  PasswordPage(
                    session: AuthSession.instance,
                    requiredChange: false,
                  ),
                ),
                icon: const Icon(Icons.password_outlined),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: context.tr("退出登录"),
                onPressed: () => action(AuthSession.instance.logout),
                icon: const Icon(Icons.logout),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            AuthSession.instance.endpoint,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: AppPalette.muted(context)),
          ),
          if (AuthSession.instance.user?['is_admin'] == true) ...[
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.manage_accounts_outlined),
              title: Text(context.tr("用户管理")),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openPageOverlay<void>(
                context,
                UsersPage(session: AuthSession.instance),
              ),
            ),
          ],
          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 20),
          Text(
            context.tr("外观"),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 6),
          Text(
            context.tr("选择适合当前环境的显示方式。"),
            style: TextStyle(color: AppPalette.muted(context)),
          ),
          const SizedBox(height: 14),
          AppearancePicker(
            appearance: widget.appearance,
            onError: (e) {
              if (context.mounted) showError(context, e);
            },
          ),
          const SizedBox(height: 28),
          if (TranslationCatalog.instance.languages.isNotEmpty)
            DropdownButtonFormField<Locale>(
              key: ValueKey(
                'language-${widget.appearance.locale.toLanguageTag()}',
              ),
              initialValue: TranslationCatalog.instance.resolveLocale(
                widget.appearance.locale,
              ),
              decoration: const InputDecoration(labelText: 'Language'),
              items: TranslationCatalog.instance.languages
                  .map(
                    (entry) => DropdownMenuItem(
                      value: entry.locale,
                      child: Text(entry.name),
                    ),
                  )
                  .toList(),
              onChanged: (locale) async {
                if (locale == null) return;
                try {
                  await widget.appearance.setLocale(locale);
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
            ),
          if (TranslationCatalog.instance.languages.isEmpty)
            Text(context.tr('正在加载界面语言…')),
          if (TranslationCatalog.instance.error != null)
            ListTile(
              title: Text(context.tr('无法加载界面语言，请重试。')),
              trailing: TextButton(
                onPressed: () => action(TranslationCatalog.instance.retry),
                child: Text(context.tr('重试')),
              ),
            ),
          _PreferenceHint(context.tr('界面语言仅保存在此设备，不改变收据内容。')),
          const SizedBox(height: 28),
          Text(
            context.tr("偏好设置"),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          if (Platform.isAndroid) ...[
            OutlinedButton.icon(
              onPressed: busy ? null : checkAndroidUpdate,
              icon: const Icon(Icons.system_update),
              label: Text(context.tr("检查客户端更新")),
            ),
            const SizedBox(height: 16),
          ],
          OutlinedButton.icon(
            onPressed: () => action(widget.store.retryUploads),
            icon: const Icon(Icons.cloud_upload_outlined),
            label: Text(context.tr("重试未完成的照片上传")),
          ),
          const SizedBox(height: 24),
          DropdownButtonFormField<String>(
            initialValue: widget.store.weightUnit,
            decoration: InputDecoration(labelText: context.tr("全局重量显示单位")),
            items: const ['g', 'kg', 'lb', 'oz']
                .map((unit) => DropdownMenuItem(value: unit, child: Text(unit)))
                .toList(),
            onChanged: busy
                ? null
                : (unit) {
                    if (unit != null) {
                      action(() async {
                        await widget.store.saveWeightUnit(unit);
                      });
                    }
                  },
          ),
          _PreferenceHint(context.tr("收据与商品统一显示此单位；数据库统一保存克数。")),
          const SizedBox(height: 24),
          DropdownButtonFormField<String>(
            key: ValueKey('report-currency-${widget.store.reportCurrency}'),
            initialValue: widget.store.reportCurrency,
            decoration: InputDecoration(labelText: context.tr("报表显示币种")),
            items: currencies.keys
                .map((code) => DropdownMenuItem(value: code, child: Text(code)))
                .toList(),
            onChanged: busy
                ? null
                : (code) {
                    if (code != null) {
                      action(() => widget.store.saveReportCurrency(code));
                    }
                  },
          ),
          _PreferenceHint(context.tr("所有已确认收据按交易日汇率换算后统一统计。")),
          const SizedBox(height: 24),
          Text(
            context.tr("后端数据"),
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          ListTile(
            leading: const Icon(Icons.backup_outlined),
            title: Text(context.tr("导出完整备份")),
            subtitle: Text(context.tr("包含照片和草稿；不含密钥")),
            onTap: () => action(backupData),
          ),
          ListTile(
            leading: const Icon(Icons.restore),
            title: Text(context.tr("从备份整体恢复")),
            onTap: () => action(restoreData),
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: Text(context.tr("导出最近一次后端备份")),
            onTap: () => action(exportRecovery),
          ),
          ListTile(
            leading: const Icon(Icons.table_view_outlined),
            title: Text(context.tr("导出明细 CSV")),
            onTap: () => action(csv),
          ),
          const SizedBox(height: 24),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

/// Separate help text grows with translations and the device's text size.
class _PreferenceHint extends StatelessWidget {
  const _PreferenceHint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: AppPalette.muted(context)),
    ),
  );
}
