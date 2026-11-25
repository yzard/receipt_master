import '../l10n/strings.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../data/capture_session.dart';
import 'common.dart';
import 'app_theme.dart';

class CapturePage extends StatefulWidget {
  final String cacheRoot;
  final Future<void> Function(List<Uint8List>) onComplete;
  const CapturePage({
    super.key,
    required this.cacheRoot,
    required this.onComplete,
  });
  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> with WidgetsBindingObserver {
  late final CaptureSession session;
  CameraController? camera;
  Future<void> cameraWork = Future.value();
  bool busy = true, active = true, closing = false;
  int selected = -1;
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session = CaptureSession(widget.cacheRoot);
    initialize();
  }

  Future<void> initialize() async {
    try {
      await session.load();
      selected = session.pages.length - 1;
    } catch (e) {
      error = '无法恢复拍摄照片：$e';
    }
    if (!mounted) return;
    setState(() => busy = false);
    scheduleCamera();
  }

  void scheduleCamera() {
    cameraWork = cameraWork
        .then((_) async {
          final old = camera;
          camera = null;
          if (mounted) setState(() {});
          await old?.dispose();
          if (!mounted || !active || closing) return;
          try {
            final cameras = await availableCameras();
            if (cameras.isEmpty) throw CameraException('NoCamera', '没有可用相机');
            final device = cameras.firstWhere(
              (c) => c.lensDirection == CameraLensDirection.back,
              orElse: () => cameras.first,
            );
            final next = CameraController(
              device,
              ResolutionPreset.max,
              enableAudio: false,
            );
            try {
              await next.initialize();
            } catch (_) {
              await next.dispose();
              rethrow;
            }
            if (!mounted || !active || closing) {
              await next.dispose();
              return;
            }
            setState(() {
              camera = next;
              error = null;
            });
          } catch (e) {
            if (mounted) setState(() => error = '无法打开相机，请检查系统相机权限后重试。$e');
          }
        })
        .catchError((Object e) {
          if (mounted) setState(() => error = '相机暂不可用：$e');
        });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    scheduleCamera();
  }

  @override
  void dispose() {
    closing = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(cameraWork.then((_) => camera?.dispose()));
    super.dispose();
  }

  Future<void> shoot(bool replace) async {
    if (busy || camera == null || !camera!.value.isInitialized) return;
    setState(() => busy = true);
    try {
      final shot = await camera!.takePicture();
      await session.save(
        await shot.readAsBytes(),
        replaceIndex: replace ? selected : null,
      );
      if (!replace) selected = session.pages.length - 1;
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> removePhoto(int index) async {
    if (busy) return;
    final selectedName = selected >= 0 ? session.pages[selected] : null;
    setState(() => busy = true);
    try {
      await session.remove(index);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      final retained = session.pages.indexOf(selectedName ?? '');
      selected = retained >= 0
          ? retained
          : session.pages.isEmpty
          ? -1
          : index.clamp(0, session.pages.length - 1);
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> finish() async {
    setState(() => busy = true);
    try {
      await widget.onComplete(await session.bytes());
      await session.clear();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: camera?.value.isInitialized == true
                  ? CameraPreview(camera!)
                  : const CircularProgressIndicator(),
            ),
          ),
          if (error != null)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black87,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          context.translatedMessage(error!),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                        const SizedBox(height: Space.md),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white54),
                          ),
                          onPressed: scheduleCamera,
                          child: Text(context.tr("重试相机")),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xB8000000), Colors.transparent],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    BackButton(
                      onPressed: busy ? null : () => Navigator.pop(context),
                      color: Colors.white,
                    ),
                    Expanded(
                      child: Text(
                        context.tr("拍摄收据 · {0} 张", [session.pages.length]),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0xE6000000)],
                  stops: [0, .30],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: Space.md,
                  children: [
                    if (busy) const LinearProgressIndicator(),
                    Text(
                      context.tr("分段拍摄时，让相邻照片保留重叠区域"),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    if (session.pages.isNotEmpty)
                      SizedBox(
                        height: 90,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: session.pages.length,
                          itemBuilder: (context, i) => Stack(
                            children: [
                              InkWell(
                                key: ValueKey('capture-thumbnail-$i'),
                                onTap: busy
                                    ? null
                                    : () => setState(() => selected = i),
                                child: Container(
                                  width: 66,
                                  height: 80,
                                  margin: const EdgeInsets.all(5),
                                  padding: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: selected == i
                                          ? AppPalette.cameraAccent
                                          : const Color(0x66FFFFFF),
                                      width: selected == i ? 3 : 1,
                                    ),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: Image.file(
                                      session.file(i),
                                      key: ValueKey(session.pages[i]),
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => const Icon(
                                        Icons.image_not_supported_outlined,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                top: 0,
                                right: 0,
                                child: Tooltip(
                                  message: context.tr("删除第 {0} 张照片", [i + 1]),
                                  child: GestureDetector(
                                    onTap: busy ? null : () => removePhoto(i),
                                    behavior: HitTestBehavior.opaque,
                                    child: const SizedBox(
                                      width: 44,
                                      height: 44,
                                      child: Center(
                                        child: CircleAvatar(
                                          radius: 11,
                                          backgroundColor: Colors.white,
                                          child: Icon(
                                            Icons.close,
                                            size: 15,
                                            color: Color(0xFF111111),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 10,
                                bottom: 8,
                                child: IgnorePointer(
                                  child: Text(
                                    '${i + 1}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                      shadows: [Shadow(blurRadius: 5)],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (selected >= 0)
                      Text(
                        context.tr("重拍将替换第 {0} 张", [selected + 1]),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    Row(
                      children: [
                        Expanded(
                          flex: 10,
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white54),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                            ),
                            onPressed: busy || selected < 0 || camera == null
                                ? null
                                : () => shoot(true),
                            child: Text(context.tr("重拍")),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 13,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: AppPalette.cameraAccent,
                              foregroundColor: const Color(0xFF04201D),
                              disabledBackgroundColor: Colors.white12,
                              disabledForegroundColor: Colors.white38,
                              minimumSize: const Size(0, 56),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onPressed: busy || camera == null
                                ? null
                                : () => shoot(false),
                            child: Text(context.tr("拍摄")),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 10,
                          child: FilledButton.tonal(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0x26FFFFFF),
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: Colors.white12,
                              disabledForegroundColor: Colors.white38,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                            ),
                            onPressed: busy || session.pages.isEmpty
                                ? null
                                : finish,
                            child: Text(context.tr("完成")),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
