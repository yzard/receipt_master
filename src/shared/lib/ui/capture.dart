import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../data/capture_session.dart';
import 'common.dart';

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
      appBar: AppBar(title: Text('拍摄收据 · ${session.pages.length} 张')),
      body: SafeArea(
        child: Column(
          children: [
            if (busy) const LinearProgressIndicator(),
            Expanded(
              child: Center(
                child: error != null
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(error!),
                          TextButton(
                            onPressed: scheduleCamera,
                            child: const Text('重试相机'),
                          ),
                        ],
                      )
                    : camera?.value.isInitialized == true
                    ? CameraPreview(camera!)
                    : const CircularProgressIndicator(),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                '同一张收据可拍多张，相邻照片保留重叠区域。',
                style: TextStyle(fontSize: 12),
              ),
            ),
            if (session.pages.isNotEmpty)
              SizedBox(
                height: 88,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: session.pages.length,
                  itemBuilder: (context, i) => Stack(
                    children: [
                      InkWell(
                        onTap: busy ? null : () => setState(() => selected = i),
                        child: Container(
                          width: 72,
                          margin: const EdgeInsets.all(4),
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: selected == i
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.grey,
                              width: selected == i ? 3 : 1,
                            ),
                          ),
                          child: Column(
                            children: [
                              Expanded(
                                child: Image.file(
                                  session.file(i),
                                  key: ValueKey(session.pages[i]),
                                  fit: BoxFit.contain,
                                  errorBuilder: (context, error, stack) =>
                                      const Icon(
                                        Icons.image_not_supported_outlined,
                                      ),
                                ),
                              ),
                              Text(
                                '${i + 1}',
                                style: const TextStyle(fontSize: 10),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        right: 0,
                        child: IconButton(
                          tooltip: '删除第 ${i + 1} 张照片',
                          onPressed: busy ? null : () => removePhoto(i),
                          icon: const DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              shape: BoxShape.circle,
                            ),
                            child: Padding(
                              padding: EdgeInsets.all(3),
                              child: Icon(
                                Icons.close,
                                size: 18,
                                color: Colors.white,
                              ),
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
                '重拍将替换第 ${selected + 1} 张',
                style: const TextStyle(fontSize: 12),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  OutlinedButton(
                    onPressed: busy || selected < 0 || camera == null
                        ? null
                        : () => shoot(true),
                    child: const Text('重拍'),
                  ),
                  FilledButton(
                    onPressed: busy || camera == null
                        ? null
                        : () => shoot(false),
                    child: const Text('拍摄'),
                  ),
                  FilledButton.tonal(
                    onPressed: busy || session.pages.isEmpty ? null : finish,
                    child: const Text('完成'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
