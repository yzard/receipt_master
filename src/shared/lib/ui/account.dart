import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/auth_session.dart';
import '../data/store.dart';
import 'app_theme.dart';
import 'common.dart';
import 'home.dart';

class AccountGate extends StatefulWidget {
  final AppStore store;
  final String zone;
  final Appearance appearance;
  final AuthSession session;
  const AccountGate({
    super.key,
    required this.store,
    required this.zone,
    required this.appearance,
    required this.session,
  });
  @override
  State<AccountGate> createState() => _AccountGateState();
}

class _AccountGateState extends State<AccountGate> {
  String? account;
  AppStore? scoped;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final user = widget.session.user;
      if (user == null) return LoginPage(session: widget.session);
      if (user['must_change_password'] == true) {
        return PasswordPage(session: widget.session, requiredChange: true);
      }
      final identity = '${widget.session.endpoint}|${user['user_id']}';
      if (account != identity) {
        account = identity;
        final scopeAccount = account;
        final cacheKey = sha256.convert(utf8.encode(account!));
        final root = '${widget.store.cacheRoot}/accounts/$cacheKey';
        Directory(root).createSync(recursive: true);
        scoped = AppStore(
          root,
          client: widget.store.client,
          configuration: () async {
            if ('${widget.session.endpoint}|${widget.session.user?['user_id']}' !=
                scopeAccount) {
              throw StateError('账户已变更，上传已暂停');
            }
            final connection = await widget.session.connection();
            if ('${widget.session.endpoint}|${widget.session.user?['user_id']}' !=
                scopeAccount) {
              throw StateError('账户已变更，上传已暂停');
            }
            return connection;
          },
        );
      }
      return HomePage(
        key: ValueKey(account),
        store: scoped!,
        zone: widget.zone,
        appearance: widget.appearance,
      );
    },
  );
}

class LoginPage extends StatefulWidget {
  final AuthSession session;
  const LoginPage({super.key, required this.session});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final endpoint = TextEditingController(),
      username = TextEditingController(),
      password = TextEditingController();
  final form = GlobalKey<FormState>();
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    endpoint.text = widget.session.endpoint;
  }

  @override
  void dispose() {
    endpoint.dispose();
    username.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() => busy = true);
    try {
      await widget.session.login(endpoint.text, username.text, password.text);
      TextInput.finishAutofillContext(
        shouldSave: widget.session.user?['must_change_password'] != true,
      );
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Form(
            key: form,
            child: AutofillGroup(
              onDisposeAction: AutofillContextAction.cancel,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.receipt_long_outlined, size: 48),
                  const SizedBox(height: 20),
                  Text(
                    'Receipt Master',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text('登录，继续整理你的生活账目。'),
                  const SizedBox(height: 28),
                  if (error != null) Notice(error!),
                  TextFormField(
                    controller: endpoint,
                    decoration: const InputDecoration(labelText: '服务地址'),
                    keyboardType: TextInputType.url,
                    validator: (v) => v!.trim().isEmpty ? '请填写服务地址' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: username,
                    decoration: const InputDecoration(labelText: '用户名'),
                    autofillHints: const [AutofillHints.username],
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.next,
                    validator: (v) => v!.trim().isEmpty ? '请填写用户名' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: password,
                    decoration: const InputDecoration(labelText: '密码'),
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => submit(),
                    validator: (v) => v!.isEmpty ? '请填写密码' : null,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: busy ? null : submit,
                    child: Text(busy ? '正在登录…' : '登录'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class PasswordPage extends StatefulWidget {
  final AuthSession session;
  final bool requiredChange;
  const PasswordPage({
    super.key,
    required this.session,
    required this.requiredChange,
  });
  @override
  State<PasswordPage> createState() => _PasswordPageState();
}

class _PasswordPageState extends State<PasswordPage> {
  final username = TextEditingController(),
      old = TextEditingController(),
      password = TextEditingController(),
      repeat = TextEditingController();
  final form = GlobalKey<FormState>();
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    username.text = widget.session.user?['username'] as String? ?? '';
  }

  @override
  void dispose() {
    username.dispose();
    old.dispose();
    password.dispose();
    repeat.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() => busy = true);
    try {
      await widget.session.connection();
      await widget.session.changePassword(old.text, password.text);
      TextInput.finishAutofillContext(shouldSave: true);
      if (mounted && !widget.requiredChange) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !widget.requiredChange,
    child: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.requiredChange,
        title: const Text('修改密码'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              if (widget.requiredChange)
                const Notice('首次登录或管理员重置后，必须修改密码才能使用。'),
              if (error != null) Notice(error!),
              Form(
                key: form,
                child: AutofillGroup(
                  onDisposeAction: AutofillContextAction.cancel,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: username,
                        readOnly: true,
                        autofillHints: const [AutofillHints.username],
                        decoration: const InputDecoration(labelText: '用户名'),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: old,
                        obscureText: true,
                        autofillHints: const [AutofillHints.password],
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(labelText: '当前密码'),
                        validator: (v) => v!.isEmpty ? '请填写当前密码' : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: password,
                        obscureText: true,
                        autofillHints: const [AutofillHints.newPassword],
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '新密码（至少 12 个字符）',
                        ),
                        validator: (v) =>
                            (v?.runes.length ?? 0) < 12 ? '至少 12 个字符' : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: repeat,
                        obscureText: true,
                        autofillHints: const [AutofillHints.newPassword],
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => submit(),
                        decoration: const InputDecoration(labelText: '再次输入新密码'),
                        validator: (v) => v != password.text ? '两次密码不一致' : null,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: busy ? null : submit,
                child: Text(busy ? '正在保存…' : '修改密码'),
              ),
              if (widget.requiredChange)
                TextButton(
                  onPressed: busy ? null : widget.session.logout,
                  child: const Text('退出登录'),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class UsersPage extends StatefulWidget {
  final AuthSession session;
  const UsersPage({super.key, required this.session});
  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  List<Map<String, dynamic>>? users;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final rows = await widget.session.users();
      if (mounted) setState(() => users = rows);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> create() async {
    final name = TextEditingController(), password = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('创建用户'),
        content: AutofillGroup(
          onDisposeAction: AutofillContextAction.cancel,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofillHints: const [AutofillHints.newUsername],
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '用户名'),
              ),
              TextField(
                controller: password,
                obscureText: true,
                autofillHints: const [AutofillHints.newPassword],
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '临时密码（至少 12 个字符）'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await action(() => widget.session.createUser(name.text, password.text));
    }
    name.dispose();
    password.dispose();
  }

  Future<void> action(Future<void> Function() f) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await f();
      await load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('用户管理'),
      actions: [
        IconButton(
          tooltip: '创建用户',
          onPressed: busy ? null : create,
          icon: const Icon(Icons.person_add_outlined),
        ),
      ],
    ),
    body: ListView(
      children: [
        if (error != null) Notice(error!),
        if (users == null) const LinearProgressIndicator(),
        for (final u in users ?? [])
          ListTile(
            title: Text(u['username']),
            subtitle: Text(
              u['is_admin'] == true
                  ? '元用户 · 不可删除'
                  : u['must_change_password'] == true
                  ? '首次登录需要改密'
                  : '普通用户',
            ),
            trailing: u['is_admin'] == true
                ? const Icon(Icons.shield_outlined)
                : IconButton(
                    tooltip: '删除用户',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: busy
                        ? null
                        : () async {
                            if (await confirm(
                              context,
                              '删除用户？',
                              '该用户的会话会被撤销，收据和照片会删除。',
                            )) {
                              await action(
                                () => widget.session.deleteUser(u['user_id']),
                              );
                            }
                          },
                  ),
          ),
      ],
    ),
  );
}
