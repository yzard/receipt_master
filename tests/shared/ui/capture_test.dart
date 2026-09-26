import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:receipt_master/ui/capture.dart';
import 'package:receipt_master/data/capture_session.dart';

class FakeCamera extends CameraPlatform {
  int shots = 0, disposed = 0;
  final errors = StreamController<CameraErrorEvent>.broadcast();
  @override
  Future<List<CameraDescription>> availableCameras() async => [
    const CameraDescription(
      name: 'test',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
    ),
  ];
  @override
  Future<int> createCamera(
    CameraDescription description,
    ResolutionPreset? preset, {
    bool enableAudio = false,
  }) async {
    expect(enableAudio, isFalse);
    return 1;
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {}
  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(
        const CameraInitializedEvent(
          1,
          640,
          480,
          ExposureMode.auto,
          true,
          FocusMode.auto,
          true,
        ),
      );
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => errors.stream;
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();
  @override
  Widget buildPreview(int cameraId) => const ColoredBox(color: Colors.black);
  @override
  Future<XFile> takePicture(int cameraId) async {
    shots++;
    final picture = img.Image(width: 8, height: 8)
      ..setPixelRgb(0, 0, shots, 0, 0);
    return XFile.fromData(
      Uint8List.fromList(img.encodePng(picture)),
      mimeType: 'image/png',
    );
  }

  @override
  Future<void> dispose(int cameraId) async {
    disposed++;
    errors.add(const CameraErrorEvent(1, 'disposed'));
  }
}

void main() {
  testWidgets(
    'camera appends pages, retakes selected page and completes one ordered batch',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('multi-camera-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final previous = CameraPlatform.instance, fake = FakeCamera();
      CameraPlatform.instance = fake;
      addTearDown(() {
        CameraPlatform.instance = previous;
      });
      List<Uint8List>? submitted;
      await tester.pumpWidget(
        MaterialApp(
          home: CapturePage(
            cacheRoot: dir.path,
            onComplete: (photos) async {
              submitted = photos;
            },
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
      }
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '完成'))
            .onPressed,
        isNull,
      );
      for (var i = 0; i < 2; i++) {
        await tester.runAsync(() async {
          await tester.tap(find.text('拍摄'));
          await Future<void>.delayed(const Duration(milliseconds: 80));
        });
        await tester.pumpAndSettle();
      }
      expect(submitted, isNull);
      expect(find.text('拍摄收据 · 2 张'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('capture-thumbnail-0')));
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.text('重拍'));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pumpAndSettle();
      final recovered = CaptureSession(dir.path);
      await tester.runAsync(() => recovered.load());
      expect(recovered.pages.length, 2);
      Future<void> tapAndSave(Finder target) async {
        await tester.runAsync(() async {
          await tester.tap(target);
          await Future<void>.delayed(const Duration(milliseconds: 80));
        });
        await tester.pumpAndSettle();
      }

      // Deleting before the selection keeps the same photo selected.
      await tapAndSave(find.text('拍摄'));
      final removedFile = recovered.file(0);
      await tapAndSave(find.byTooltip('删除第 1 张照片'));
      expect(find.text('重拍将替换第 2 张'), findsOneWidget);
      expect(removedFile.existsSync(), isFalse);
      await tester.runAsync(() => recovered.load());
      expect(recovered.pages.length, 2);
      final retained = await tester.runAsync(() => recovered.bytes());
      expect(img.decodeImage(retained![0])!.getPixel(0, 0).r, 2);
      expect(img.decodeImage(retained[1])!.getPixel(0, 0).r, 4);
      // Deleting the selected last photo selects its predecessor.
      await tapAndSave(find.byTooltip('删除第 2 张照片'));
      expect(find.text('重拍将替换第 1 张'), findsOneWidget);
      await tapAndSave(find.byTooltip('删除第 1 张照片'));
      expect(find.text('拍摄收据 · 0 张'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '重拍'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '完成'))
            .onPressed,
        isNull,
      );
      await tester.runAsync(() => recovered.load());
      expect(recovered.pages, isEmpty);
      // The same session remains usable and submits only newly captured photos.
      await tapAndSave(find.text('拍摄'));
      await tapAndSave(find.text('拍摄'));
      await tester.runAsync(() async {
        await tester.tap(find.text('完成'));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pumpAndSettle();
      expect(submitted!.length, 2);
      expect(img.decodeImage(submitted![0])!.getPixel(0, 0).r, 5);
      expect(img.decodeImage(submitted![1])!.getPixel(0, 0).r, 6);
      expect(recovered.manifest.existsSync(), isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      expect(fake.disposed, greaterThan(0));
    },
  );
}
