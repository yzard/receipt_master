import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/models.dart';

/// Unsubmitted camera pages survive interruption; no business records live here.
class CaptureSession {
  final Directory directory;
  final List<String> pages = [];
  CaptureSession(String cacheRoot)
    : directory = Directory('$cacheRoot/camera_session');
  File get manifest => File('${directory.path}/pages.json');
  Future<void> load() async {
    await directory.create(recursive: true);
    pages.clear();
    if (await manifest.exists()) {
      pages.addAll(
        List<String>.from(jsonDecode(await manifest.readAsString())),
      );
    }
  }

  Future<void> save(Uint8List bytes, {required int? replaceIndex}) async {
    final name = '${newId()}.jpg';
    await File('${directory.path}/$name').writeAsBytes(bytes, flush: true);
    final next = [...pages];
    String? old;
    if (replaceIndex == null) {
      next.add(name);
    } else {
      old = next[replaceIndex];
      next[replaceIndex] = name;
    }
    await _persistPages(next);
    if (old != null) await File('${directory.path}/$old').delete();
  }

  Future<void> _persistPages(List<String> next) async {
    final temp = File('${manifest.path}.tmp');
    await temp.writeAsString(jsonEncode(next), flush: true);
    await temp.rename(manifest.path);
    pages
      ..clear()
      ..addAll(next);
  }

  Future<void> remove(int index) async {
    final old = file(index);
    final next = [...pages]..removeAt(index);
    await _persistPages(next);
    await old.delete();
  }

  File file(int index) => File('${directory.path}/${pages[index]}');
  Future<List<Uint8List>> bytes() async {
    final result = <Uint8List>[];
    for (var i = 0; i < pages.length; i++) {
      result.add(await file(i).readAsBytes());
    }
    return result;
  }

  Future<void> clear() async {
    if (await directory.exists()) await directory.delete(recursive: true);
    pages.clear();
  }
}
