import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/audiobook.dart';
import 'api.dart';
import 'book_cache.dart';
import 'core.dart';
import 'downloads.dart' show downloadsRootProvider;

final bookDownloadsProvider = ChangeNotifierProvider<BookDownloads>((ref) {
  final server = ref.watch(sessionProvider.select((s) => s?.host));
  final root = ref.watch(downloadsRootProvider);
  return BookDownloads(
      BookCache(root, server == null ? '' : bookServer(server)));
});

class BookDownloads extends ChangeNotifier {
  BookDownloads(this.cache) : copies = cache.read();
  final BookCache cache;
  final Map<String, BookCopy> copies;
  final progress = <String, double>{};
  final errors = <String, String>{};
  final _jobs = <String, CancelToken>{};
  final _removing = <String>{};
  final _settled = <String, Completer<void>>{};
  bool _disposed = false;
  Iterable<BookCopy> get ready => copies.values.where((c) => c.complete);
  BookCopy? readyFor(String id) {
    final c = copies[id];
    return c != null && c.complete ? c : null;
  }

  Future<void> start(Api api, AudioBook book) async {
    final id = book.id;
    if (_jobs.containsKey(id) || _removing.contains(id)) return;
    final cancel = CancelToken();
    final settled = _settled[id] = Completer<void>();
    _jobs[id] = cancel;
    errors.remove(id);
    progress[id] = 0;
    copies.putIfAbsent(
        id,
        () => BookCopy(
            book, Directory('${cache.root.path}/${bookKey(id)}'), false));
    notifyListeners();
    try {
      copies[id] = await cache.download(api, book, cancel, (v) {
        if (_disposed || ((progress[id] ?? 0) - v).abs() < 0.005) return;
        progress[id] = v;
        notifyListeners();
      });
    } catch (e) {
      if (!cancel.isCancelled)
        errors[id] = 'No se completó la descarga. Puedes reintentarla.';
    } finally {
      progress.remove(id);
      _jobs.remove(id);
      _settled.remove(id);
      settled.complete();
      if (!_disposed) notifyListeners();
    }
  }

  void pause(String id) => _jobs[id]?.cancel();
  Future<void> remove(String id) async {
    if (!_removing.add(id)) return;
    try {
      final settled = _settled[id];
      if (settled != null) {
        pause(id);
        await settled.future;
      }
      final c = copies[id];
      if (c == null) return;
      if (await c.folder.exists()) await c.folder.delete(recursive: true);
      copies.remove(id);
      errors.remove(id);
    } finally {
      _removing.remove(id);
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final c in _jobs.values) c.cancel();
    super.dispose();
  }
}
