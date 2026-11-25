import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import 'core.dart';
import 'downloads.dart';
import 'native.dart';
import 'peticiones.dart' show requestsProvider;
import 'profiles.dart' show profilesProvider;
import 'remote.dart';
import 'sounds.dart';

// ===========================================================================
//  Avisos de la app:
//   · progreso de las descargas en la notificación de Android (y aviso al terminar);
//   · aviso cuando una película/serie que pediste ya está en la biblioteca, que además
//     queda guardado en la bandeja de la campanita (Novedades).
// ===========================================================================

/// Una entrada de la bandeja interna (campanita).
class InboxItem {
  const InboxItem(
      {required this.key,
      required this.title,
      required this.type,
      this.year,
      this.posterUrl,
      required this.ms,
      this.read = false});
  final String key, title, type;
  final int? year;
  final String? posterUrl;
  final int ms;
  final bool read;

  String get label => year == null ? title : '$title ($year)';

  InboxItem asRead() => InboxItem(
      key: key,
      title: title,
      type: type,
      year: year,
      posterUrl: posterUrl,
      ms: ms,
      read: true);

  Map<String, dynamic> toJson() => {
        'key': key,
        'title': title,
        'type': type,
        'year': year,
        'posterUrl': posterUrl,
        'ms': ms,
        'read': read,
      };

  factory InboxItem.fromJson(Map<String, dynamic> j) => InboxItem(
      key: '${j['key']}',
      title: '${j['title'] ?? ''}',
      type: j['type'] == 'tv' ? 'tv' : 'movie',
      year: j['year'] as int?,
      posterUrl: j['posterUrl'] as String?,
      ms: (j['ms'] as int?) ?? 0,
      read: j['read'] == true);
}

/// Bandeja de avisos internos, guardada en el dispositivo por servidor y perfil.
class InboxNotifier extends Notifier<List<InboxItem>> {
  String get _key {
    final host = ref.read(sessionProvider)?.host ?? '';
    final me = requesterName(ref.read(prefsProvider));
    return 'inbox:$host:$me';
  }

  @override
  List<InboxItem> build() {
    ref.watch(sessionProvider);
    ref.watch(profilesProvider.select((p) => p.valueOrNull?.currentProfile?.key));
    try {
      final raw = ref.read(prefsProvider).getString(_key);
      if (raw == null) return const [];
      return [
        for (final e in jsonDecode(raw) as List)
          InboxItem.fromJson((e as Map).cast<String, dynamic>())
      ];
    } catch (_) {
      return const [];
    }
  }

  void _save() {
    try {
      ref
          .read(prefsProvider)
          .setString(_key, jsonEncode([for (final i in state) i.toJson()]));
    } catch (_) {}
  }

  void add(InboxItem i) {
    state = [i, ...state.where((x) => x.key != i.key)].take(50).toList();
    _save();
  }

  void markRead(String key) {
    if (state.any((i) => i.key == key && !i.read)) {
      Sfx.play(Snd.marcarVisto, force: true);
    }
    state = [for (final i in state) i.key == key ? i.asRead() : i];
    _save();
  }

  void markAllRead() {
    state = [for (final i in state) i.asRead()];
    _save();
  }

  void remove(String key) {
    state = [
      for (final i in state)
        if (i.key != key) i
    ];
    _save();
  }
}

final inboxProvider =
    NotifierProvider<InboxNotifier, List<InboxItem>>(InboxNotifier.new);

/// Cuántos avisos internos hay sin abrir.
final inboxUnreadProvider =
    Provider<int>((ref) => ref.watch(inboxProvider).where((i) => !i.read).length);

/// Escucha descargas y peticiones y lanza los avisos. Se activa con `ref.read`.
final appNotificationsProvider = Provider<void>((ref) {
  final n = _AppNotifications(ref);
  ref.onDispose(n.dispose);
  ref.listen<Map<String, DownloadEntry>>(downloadsProvider, (_, next) {
    n.onDownloads(next);
  });
  ref.listen<AsyncValue<List<TmdbMovie>>>(requestsProvider, (_, next) {
    if (next is AsyncData<List<TmdbMovie>>) n.onRequests(next.value);
  });
  // Al cerrar la sesión no debe quedar el progreso de descargas en la barra.
  ref.listen(sessionProvider, (_, next) {
    if (next == null) n.reset();
  });
});

class _AppNotifications {
  _AppNotifications(this.ref);
  final Ref ref;

  // ---------- descargas ----------
  Map<String, DownloadEntry> _latest = const {};
  Set<String> _active = {};
  final _finished = <String>[]; // títulos terminados desde que empezó la tanda
  Timer? _timer;
  bool _shown = false;

  void dispose() => _timer?.cancel();

  void reset() {
    _timer?.cancel();
    _timer = null;
    _active = {};
    _finished.clear();
    if (_shown) NativeBridge.clearDownloadProgress();
    _shown = false;
  }

  void onDownloads(Map<String, DownloadEntry> all) {
    _latest = all;
    // Pasos de estado inmediatos (empezar/terminar); el progreso se agrupa cada ~1 s.
    final now = {
      for (final e in all.values)
        if (e.state == DlState.downloading || e.state == DlState.queued) e.id
    };
    final changed = now.length != _active.length || !now.containsAll(_active);
    for (final id in _active.difference(now)) {
      final e = all[id];
      if (e != null && e.state == DlState.done) _finished.add(_titleOf(e));
    }
    _active = now;
    if (changed) {
      _timer?.cancel();
      _timer = null;
      _flush();
    } else {
      _timer ??= Timer(const Duration(milliseconds: 1000), () {
        _timer = null;
        _flush();
      });
    }
  }

  String _titleOf(DownloadEntry e) {
    try {
      final v = e.item;
      final show = v.show;
      return (show != null && show.isNotEmpty) ? show : v.title;
    } catch (_) {
      return 'Descarga';
    }
  }

  void _flush() {
    final all = _latest;
    final bajando = [
      for (final e in all.values)
        if (e.state == DlState.downloading) e
    ];
    final enCola =
        all.values.where((e) => e.state == DlState.queued).length;
    if (bajando.isEmpty && enCola == 0) {
      if (_shown) {
        _shown = false;
        NativeBridge.clearDownloadProgress();
      }
      if (_finished.isNotEmpty) {
        final f = [..._finished];
        _finished.clear();
        Sfx.play(Snd.notificacion, force: true);
        NativeBridge.notify(
            7000,
            f.length == 1 ? 'Descarga completada' : 'Descargas completadas',
            f.length == 1
                ? f.first
                : '${f.length} elementos listos para ver sin conexión.');
      }
      return;
    }
    var rec = 0, tot = 0;
    for (final e in [...bajando]) {
      rec += e.received;
      tot += e.total;
    }
    final pct = tot > 0 ? (rec * 100 ~/ tot).clamp(0, 100) : -1;
    final total = bajando.length + enCola;
    final title = total == 1 && bajando.length == 1
        ? 'Descargando ${_titleOf(bajando.first)}'
        : 'Descargando $total elementos';
    final parts = <String>[
      if (pct >= 0) '$pct %',
      if (enCola > 0) '$enCola en cola',
      if (bajando.isEmpty) 'Esperando',
    ];
    _shown = true;
    NativeBridge.downloadProgress(title, parts.join(' · '), pct);
  }

  // ---------- peticiones atendidas ----------
  void onRequests(List<TmdbMovie> list) {
    // Solo con la lista que acaba de dar el servidor (no con la copia guardada).
    if (!ref.read(remoteProvider).connected) return;
    final prefs = ref.read(prefsProvider);
    final host = ref.read(sessionProvider)?.host ?? '';
    final me = requesterName(prefs);
    final seenKey = 'req_seen:$host:$me';
    String k(TmdbMovie m) => m.type == 'tv' ? 'tv${m.id}' : '${m.id}';
    final mine = [
      for (final m in list)
        if (m.inLibrary && m.requestedBy.contains(me)) m
    ];
    final ids = {for (final m in mine) k(m)};
    final raw = prefs.getString(seenKey);
    if (raw == null) {
      // Primera vez: lo que ya estaba disponible no se avisa.
      prefs.setString(seenKey, jsonEncode(ids.toList()));
      return;
    }
    Set<String> seen;
    try {
      seen = {for (final e in jsonDecode(raw) as List) '$e'};
    } catch (_) {
      seen = {};
    }
    final fresh = [
      for (final m in mine)
        if (!seen.contains(k(m))) m
    ];
    if (fresh.isEmpty) return;
    prefs.setString(seenKey, jsonEncode({...seen, ...ids}.toList()));
    final inbox = ref.read(inboxProvider.notifier);
    final now = DateTime.now().millisecondsSinceEpoch;
    Sfx.play(Snd.notificacion, force: true); // una vez, aunque lleguen varias a la vez
    for (final m in fresh) {
      inbox.add(InboxItem(
          key: k(m),
          title: m.title,
          type: m.type,
          year: m.year,
          posterUrl: m.posterUrl,
          ms: now));
      final what = m.isTv ? 'La serie' : 'La película';
      final label = m.year == null ? m.title : '${m.title} (${m.year})';
      NativeBridge.notify(8000 + (k(m).hashCode & 0xFFFF), 'Ya está disponible',
          '$what $label que pediste ya está en la biblioteca.');
    }
  }
}
