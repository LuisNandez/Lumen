import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show DioException;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import 'api.dart';
import 'core.dart';
import 'remote.dart';
import 'sounds.dart';
import 'tmdb.dart';
import 'trailer_player.dart';
import 'tv.dart'
    show TvFocusable, TvTextEntry, tvInEditableText, tvModeProvider;

// ===========================================================================
//  Peticiones: explora el catálogo de TMDB (sin video) y pide las películas
//  que faltan. Solo se guarda en el servidor el id de lo que se pide.
// ===========================================================================

const _bg = Color(0xFF121214);
const _red = Color(0xFFE50914);
const _surface = Color(0xFF1B1B1F);
const _sheetBg = Color(0xFF1A1A1D);
const _gold = Color(0xFFFFC53D);
const _green = Color(0xFF3DD68C);

/// Un elemento pulsable. En TV se enfoca con el mando y lleva un aro blanco bien visible (el
/// `GestureDetector` suelto no recibe foco, por eso antes no se podía llegar con las flechas);
/// en móvil y escritorio es un toque normal.
Widget _tapTv(bool tv, VoidCallback onTap,
        {required Widget child, double radius = 12, double scale = 1.0}) =>
    tv
        ? TvFocusable(
            borderRadius: radius,
            scale: scale,
            nearestScrollOnly: true,
            onTap: onTap,
            child: child)
        : GestureDetector(
            behavior: HitTestBehavior.opaque, onTap: onTap, child: child);

/// Géneros de película de TMDB.
final genresProvider = FutureProvider.autoDispose
    .family<List<TmdbGenre>, String>((ref, type) async {
  final cat = ref.watch(catalogProvider);
  if (cat == null) return const <TmdbGenre>[];
  return cat.genres(type);
});

/// Películas pedidas por todos los dispositivos. Pedir o quitar actualiza la lista
/// con la respuesta del servidor, sin volver a descargarla.
class RequestsNotifier extends AutoDisposeAsyncNotifier<List<TmdbMovie>> {
  /// true si la última acción de [setRequested] quedó en cola por no haber servidor.
  bool lastQueued = false;

  String get _host => ref.read(sessionProvider)?.host ?? '';
  String get _cacheKey => 'requests_cache:$_host';
  String get _pendKey => 'requests_pending:$_host';
  String get _me => requesterName(ref.read(prefsProvider));

  void _saveCache(List<TmdbMovie> l) {
    try {
      ref
          .read(prefsProvider)
          .setString(_cacheKey, jsonEncode([for (final m in l) m.toJson()]));
    } catch (_) {}
  }

  List<TmdbMovie> _loadCache() {
    try {
      final raw = ref.read(prefsProvider).getString(_cacheKey);
      if (raw == null) return [];
      return [
        for (final e in jsonDecode(raw) as List)
          TmdbMovie.fromJson((e as Map).cast<String, dynamic>())
      ];
    } catch (_) {
      return [];
    }
  }

  /// Peticiones hechas (o quitadas) sin servidor; se envían cuando vuelve a encenderse.
  List<({TmdbMovie movie, bool want})> _loadPending() {
    try {
      final raw = ref.read(prefsProvider).getString(_pendKey);
      if (raw == null) return [];
      return [
        for (final e in jsonDecode(raw) as List)
          (
            movie: TmdbMovie.fromJson(
                ((e as Map)['movie'] as Map).cast<String, dynamic>()),
            want: e['want'] == true
          )
      ];
    } catch (_) {
      return [];
    }
  }

  void _savePending(List<({TmdbMovie movie, bool want})> l) {
    final p = ref.read(prefsProvider);
    if (l.isEmpty) {
      p.remove(_pendKey);
    } else {
      p.setString(
          _pendKey,
          jsonEncode([
            for (final e in l) {'want': e.want, 'movie': e.movie.toJson()}
          ]));
    }
  }

  /// Aplica una petición/retirada de este dispositivo sobre [list].
  List<TmdbMovie> _applyOp(List<TmdbMovie> list, TmdbMovie m, bool want) {
    final me = _me;
    final out = [...list];
    final i = out.indexWhere((x) => x.id == m.id && x.type == m.type);
    final old = i >= 0 ? out.removeAt(i) : null;
    final by = [...(old?.requestedBy ?? const <String>[])]..remove(me);
    if (want) {
      by.add(me);
      out.insert(
          0,
          (old ?? m).withRequest(true, by,
              old?.createdMs ?? DateTime.now().millisecondsSinceEpoch));
    } else if (by.isNotEmpty) {
      out.insert(
          i < 0 ? 0 : i, (old ?? m).withRequest(true, by, old?.createdMs));
    }
    return out;
  }

  /// Envía al servidor lo que quedó en cola. Si sigue sin conexión, lanza y conserva todo.
  Future<void> _flushPending(Api api) async {
    final pend = _loadPending();
    if (pend.isEmpty) return;
    for (final p in pend) {
      try {
        if (p.want) {
          await api.addRequest(p.movie.id, type: p.movie.type);
        } else {
          await api.removeRequest(p.movie.id, type: p.movie.type);
        }
      } on DioException catch (e) {
        if (e.response == null) rethrow;
        // 409 (ya está en la biblioteca) u otro error del servidor: se descarta esa.
      }
    }
    _savePending([]);
  }

  @override
  Future<List<TmdbMovie>> build() async {
    final api = ref.watch(apiProvider);
    // Mientras hay servidor, se refresca cada 2 min (otros dispositivos también piden) y la
    // copia guardada en este dispositivo se mantiene al día.
    final timer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (!ref.read(serverOfflineProvider)) ref.invalidateSelf();
    });
    ref.onDispose(timer.cancel);
    // Cuando el servidor se vuelve a encender, envía lo pendiente y recarga la lista real.
    ref.listen<bool>(serverOfflineProvider, (prev, next) {
      if (prev == true && !next) ref.invalidateSelf();
    });
    if (api == null) return const <TmdbMovie>[];
    try {
      await _flushPending(api);
      final data = await api.requestsData();
      _saveCache(data.items);
      await ref
          .read(prefsProvider)
          .setStringList('owned_keys:$_host', data.owned.toList());
      return data.items;
    } on DioException catch (e) {
      if (e.response != null) rethrow; // el servidor respondió con un error
      var list = _loadCache();
      for (final p in _loadPending()) {
        list = _applyOp(list, p.movie, p.want);
      }
      return list;
    }
  }

  TmdbMovie _result(List<TmdbMovie> list, TmdbMovie m, bool want) {
    if (want) {
      for (final x in list) {
        if (x.id == m.id && x.type == m.type) return x;
      }
    }
    return m.withRequest(false, const []);
  }

  Future<TmdbMovie> setRequested(TmdbMovie m, bool want) async {
    final api = ref.read(apiProvider);
    if (api == null) throw StateError('Sin sesión');
    final current = await future; // si aún carga, espera para no pisar la lista
    lastQueued = false;
    if (!ref.read(serverOfflineProvider)) {
      try {
        final r = want
            ? await api.addRequest(m.id, type: m.type)
            : (await api.removeRequest(m.id, type: m.type)) ??
                m.withRequest(false, const []);
        final list = [...current]
          ..removeWhere((x) => x.id == m.id && x.type == m.type);
        if (r.requested) list.insert(0, r);
        state = AsyncData(list);
        _saveCache(list);
        return r;
      } on DioException catch (e) {
        if (e.response != null) rethrow;
        // sin conexión con el servidor: se deja en cola
      }
    }
    // Servidor apagado: se guarda en este dispositivo y se envía al volver. Manda la última
    // decisión sobre cada título.
    lastQueued = true;
    final pend = _loadPending()
      ..removeWhere((e) => e.movie.id == m.id && e.movie.type == m.type)
      ..add((movie: m, want: want));
    _savePending(pend);
    final list = _applyOp(current, m, want);
    state = AsyncData(list);
    return _result(list, m, want);
  }
}

final requestsProvider =
    AsyncNotifierProvider.autoDispose<RequestsNotifier, List<TmdbMovie>>(
        RequestsNotifier.new);

/// Claves de TMDB de lo que ya está en la biblioteca. Se guardan en el dispositivo cada vez
/// que se carga la lista, así las etiquetas "En biblioteca" también salen sin servidor.
final ownedKeysProvider = Provider<Set<String>>((ref) {
  ref.watch(requestsProvider); // se recalcula cuando la lista se recarga
  final host = ref.read(sessionProvider)?.host ?? '';
  try {
    return ref.read(prefsProvider).getStringList('owned_keys:$host')?.toSet() ??
        <String>{};
  } catch (_) {
    return <String>{};
  }
});

TmdbMovie _withOwned(TmdbMovie m, Set<String> owned) {
  final key = m.type == 'tv' ? 'tv${m.id}' : '${m.id}';
  return !m.inLibrary && owned.contains(key) ? m.withInLibrary(true) : m;
}

/// Estado real de una película: las peticiones guardadas mandan sobre lo que traía la lista,
/// y la biblioteca (guardada en el dispositivo) marca lo que ya se tiene.
TmdbMovie _effective(TmdbMovie m, List<TmdbMovie>? reqs, Set<String> owned) {
  var out = m;
  if (reqs != null) {
    out = m.withRequest(false, const []);
    for (final r in reqs) {
      if (r.id == m.id && r.type == m.type) {
        out = m.withRequest(true, r.requestedBy, r.createdMs);
        break;
      }
    }
  }
  return _withOwned(out, owned);
}

bool _mine(WidgetRef ref, TmdbMovie m) =>
    m.requestedBy.contains(requesterName(ref.read(prefsProvider)));

/// Pide la película, o quita la petición de este dispositivo si ya la había pedido.
Future<void> _toggle(BuildContext context, WidgetRef ref, TmdbMovie m) async {
  final want = !_mine(ref, m);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final notifier = ref.read(requestsProvider.notifier);
    await notifier.setRequested(m, want);
    final what = want ? 'Pedida: ${m.title}' : 'Petición quitada';
    messenger.showSnackBar(SnackBar(
        content: Text(notifier.lastQueued
            ? '$what. Servidor apagado: se enviará cuando vuelva a encenderse.'
            : what)));
  } catch (e) {
    messenger.showSnackBar(errorSnack(errText(e)));
  }
}

String _ago(int? ms) {
  if (ms == null) return '';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return 'ahora';
  if (d.inHours < 1) return 'hace ${d.inMinutes} min';
  if (d.inDays < 1) return 'hace ${d.inHours} h';
  return 'hace ${d.inDays} d';
}

Future<T?> _sheet<T>(BuildContext context, WidgetBuilder builder) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: _sheetBg,
      // Pantalla ancha (TV, escritorio): la hoja queda centrada, no a todo lo ancho.
      constraints: MediaQuery.sizeOf(context).width >= 900
          ? const BoxConstraints(maxWidth: 760)
          : null,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: builder,
    );

void _showMovie(BuildContext context, TmdbMovie m) {
  final tv = ProviderScope.containerOf(context).read(tvModeProvider);
  final pf = FocusManager.instance.primaryFocus;
  // Sin foco en el buscador: al cerrar la ficha no vuelve a abrirse el teclado.
  // En TV NO se quita el foco (la tarjeta o la película parecida que se pulsó): Flutter lo
  // recuerda y, al cerrar la ficha, lo devuelve ahí en vez de perderlo. Solo se suelta si el
  // foco está dentro de un campo de texto.
  if (!tv || tvInEditableText(pf)) pf?.unfocus();
  _sheet<void>(context, (_) => _MovieSheet(base: m)).then((_) {
    if (!tv) return;
    // Si el elemento que tenía el foco ya no existe (p. ej. se quitó la petición y desapareció
    // de la lista), el foco pasa al primer elemento disponible en vez de quedarse perdido.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      final now = FocusManager.instance.primaryFocus;
      if (now == null || now is FocusScopeNode)
        FocusScope.of(context).nextFocus();
    });
  });
}

// ---------------------------------------------------------------------------
//  Pantalla
// ---------------------------------------------------------------------------

class PeticionesScreen extends StatelessWidget {
  const PeticionesScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        backgroundColor: _bg,
        body: SafeArea(bottom: false, child: PeticionesView(showTitle: true)),
      );
}

/// Explorar + Pedidas. Con el servidor apagado sigue funcionando: el catálogo viene de TMDB
/// (clave que entregó el servidor al emparejar) y lo que se pide queda en cola.
///
/// Una sola cabecera compacta (título + selector Explorar/Pedidas) sustituye a la barra de
/// título y a las pestañas de antes. Con [showTitle] en false (modo sin servidor, dentro de
/// otra pantalla con su propia barra) solo se dibuja el selector.
class PeticionesView extends ConsumerWidget {
  const PeticionesView({super.key, this.showTitle = false});

  final bool showTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(serverOfflineProvider);
    final canExplore =
        !offline || (ref.watch(catalogProvider)?.canExploreOffline ?? false);
    final info = ref.watch(serverInfoProvider).valueOrNull;
    final count = ref.watch(requestsProvider).valueOrNull?.length ?? 0;
    final Widget content = !canExplore
        ? const _Pedidas(canExplore: false)
        : (!offline && info != null && !info.tmdb)
            ? const _EmptyState(
                icon: Icons.key_off_rounded,
                title: 'Falta la clave de TMDB',
                subtitle:
                    'Añádela en la ventana del servidor para poder explorar y pedir '
                    'películas.')
            : const TabBarView(children: [
                _TabPage(index: 0, child: _Explorer()),
                _TabPage(index: 1, child: _Pedidas(canExplore: true)),
              ]);
    return DefaultTabController(
      length: 2,
      child: Column(children: [
        _TopBar(showTitle: showTitle, canExplore: canExplore, count: count),
        if (offline) _OfflineBanner(explore: canExplore),
        Expanded(child: content),
      ]),
    );
  }
}

/// En TV, al enfocar algo de dentro (el tráiler, la fila de parecidas...), el bloque entero se
/// centra en la zona visible de la ficha, para verlo bien y ver lo que hay alrededor.
class _CenterOnFocus extends ConsumerWidget {
  const _CenterOnFocus({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(tvModeProvider)) return child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (has) {
        if (!has ||
            FocusManager.instance.highlightMode !=
                FocusHighlightMode.traditional) {
          return;
        }
        // Después de que Flutter haya desplazado lo justo para ver el elemento.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          Scrollable.ensureVisible(context,
              alignment: 0.5,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic);
        });
      },
      child: child,
    );
  }
}

/// En TV la pestaña que no se ve no puede recibir el foco (el Explorar se mantiene vivo detrás
/// de Pedidas y el mando acabaría en tarjetas invisibles).
class _TabPage extends StatelessWidget {
  const _TabPage({required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final anim = DefaultTabController.of(context).animation!;
    return AnimatedBuilder(
      animation: anim,
      builder: (_, c) =>
          ExcludeFocus(excluding: (anim.value - index).abs() > 0.5, child: c!),
      child: child,
    );
  }
}

/// Lo que se muestra en la biblioteca cuando el servidor está apagado.
class PeticionesOffline extends StatelessWidget {
  const PeticionesOffline({super.key});
  @override
  Widget build(BuildContext context) => const PeticionesView();
}

class _TopBar extends ConsumerWidget {
  const _TopBar(
      {required this.showTitle, required this.canExplore, required this.count});
  final bool showTitle, canExplore;
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tv = ref.watch(tvModeProvider);
    if (!showTitle && !canExplore) return const SizedBox.shrink();
    final sw = canExplore
        ? _TabSwitch(controller: DefaultTabController.of(context), count: count)
        : null;
    return Padding(
      padding:
          EdgeInsets.fromLTRB(tv ? 28 : 16, showTitle ? 4 : 8, tv ? 28 : 16, 8),
      child: showTitle
          ? Row(children: [
              Expanded(
                  child: Text('Peticiones',
                      style: TextStyle(
                          fontSize: tv ? 30 : 25,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.4))),
              if (sw != null) SizedBox(width: tv ? 300 : 202, child: sw),
            ])
          : sw!,
    );
  }
}

/// Selector Explorar / Pedidas: una píldora con un indicador que se desliza, también al
/// arrastrar entre páginas.
class _TabSwitch extends ConsumerWidget {
  const _TabSwitch({required this.controller, required this.count});
  final TabController controller;
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tv = ref.watch(tvModeProvider);
    final anim = controller.animation!;
    // Alto de cada pestaña por dentro (contenedor menos 3 px de margen arriba y abajo): el aro de
    // foco y el indicador rojo usan este mismo radio para que sean idénticos.
    final boxH = tv ? 48.0 : 38.0;
    final r = (boxH - 6) / 2;
    return AnimatedBuilder(
      animation: anim,
      builder: (_, __) {
        final v = anim.value.clamp(0.0, 1.0);
        Widget label(int i, String text, {int badge = 0}) {
          final sel = (v - i).abs() < 0.5;
          return Expanded(
            child: _tapTv(
              tv,
              () => controller.animateTo(i),
              radius: r,
              child: Center(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(text,
                      style: TextStyle(
                          fontSize: tv ? 15 : 13.5,
                          fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
                          color: sel ? Colors.white : Colors.white60)),
                  if (badge > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                          color: Colors.white.withOpacity(sel ? 0.25 : 0.12),
                          borderRadius: BorderRadius.circular(9)),
                      child: Text('$badge',
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                    ),
                  ],
                ]),
              ),
            ),
          );
        }

        return Container(
          height: boxH,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.07),
              borderRadius: BorderRadius.circular(boxH / 2)),
          child: Stack(children: [
            Align(
              alignment: Alignment(-1 + 2 * v, 0),
              child: FractionallySizedBox(
                widthFactor: 0.5,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                      color: _red, borderRadius: BorderRadius.circular(r)),
                ),
              ),
            ),
            Row(children: [
              label(0, 'Explorar'),
              label(1, 'Pedidas', badge: count),
            ]),
          ]),
        );
      },
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.explore});
  final bool explore;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.orange.withOpacity(0.35))),
        child: Row(children: [
          Icon(Icons.cloud_off_rounded,
              size: 16, color: Colors.orange.shade300),
          const SizedBox(width: 10),
          Expanded(
              child: Text(
                  explore
                      ? 'Servidor apagado. Puedes explorar y pedir: se enviará al '
                          'volver a encenderse.'
                      : 'Servidor apagado. Mostrando las últimas peticiones guardadas. '
                          'Para explorar sin servidor, conéctate una vez con él encendido.',
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: Colors.orange.shade100))),
        ]),
      );
}

// ---------------------------------------------------------------------------
//  Piezas compartidas
// ---------------------------------------------------------------------------

/// Píldora de selección: tenue si no está elegida, roja si lo está.
class _Pill extends ConsumerWidget {
  const _Pill(this.label,
      {required this.selected,
      required this.onTap,
      this.icon,
      this.trailing,
      this.dense = false,
      this.margin = const EdgeInsets.only(right: 6)});
  final String label;
  final bool selected, dense;
  final VoidCallback? onTap;
  final IconData? icon, trailing;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tv = ref.watch(tvModeProvider);
    final fg = selected ? Colors.white : Colors.white.withOpacity(0.78);
    final h = tv ? (dense ? 36.0 : 42.0) : (dense ? 28.0 : 32.0);
    final pill = Material(
      color: selected ? _red : Colors.white.withOpacity(0.07),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // En TV el foco y el OK los gestiona TvFocusable (aro blanco).
        onTap: tv ? null : onTap,
        child: SizedBox(
          height: h,
          child: Padding(
            padding:
                EdgeInsets.symmetric(horizontal: tv ? 18 : (dense ? 11 : 14)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[
                Icon(icon, size: tv ? 18 : 15, color: fg),
                const SizedBox(width: 5),
              ],
              Text(label,
                  style: TextStyle(
                      fontSize: tv ? 14.5 : (dense ? 12.5 : 13.5),
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: fg)),
              if (trailing != null) ...[
                const SizedBox(width: 2),
                Icon(trailing, size: tv ? 18 : 16, color: fg),
              ],
            ]),
          ),
        ),
      ),
    );
    return Padding(
      padding: margin,
      child: tv
          ? TvFocusable(
              borderRadius: h / 2,
              scale: 1,
              nearestScrollOnly: true,
              onTap: onTap,
              child: pill)
          : pill,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState(
      {required this.icon,
      required this.title,
      this.subtitle,
      this.actionLabel,
      this.onAction});
  final IconData icon;
  final String title;
  final String? subtitle, actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withOpacity(0.06)),
              child: Icon(icon, size: 34, color: Colors.white38),
            ),
            const SizedBox(height: 18),
            Text(title,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13.5, height: 1.4, color: Colors.white54)),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: _red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 22, vertical: 12),
                    shape: const StadiumBorder()),
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ]),
        ),
      );
}

/// Estrella dorada con la nota.
class _Rating extends StatelessWidget {
  const _Rating(this.value, {this.size = 12});
  final double value;
  final double size;
  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.star_rounded, size: size + 2, color: _gold),
        const SizedBox(width: 2),
        Text(value.toStringAsFixed(1),
            style: TextStyle(
                fontSize: size,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
      ]);
}

/// Etiqueta pequeña sobre el póster ("En biblioteca", "Pedida").
class _PosterBadge extends StatelessWidget {
  const _PosterBadge(this.icon, this.color, this.text);
  final IconData icon;
  final Color color;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(5, 2, 7, 2),
        decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.68),
            borderRadius: BorderRadius.circular(10)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(text,
              style: const TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
        ]),
      );
}

class _Poster extends StatelessWidget {
  const _Poster({required this.url, this.width, this.radius = 10});

  /// Con [width] mide width × width·1.5; sin él rellena el espacio que le den.
  final String? url;
  final double? width;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final placeholder = DecoratedBox(
      decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF2A2A2F), Color(0xFF1A1A1D)])),
      child: Center(
          child: Icon(Icons.movie_outlined,
              color: Colors.white24, size: width != null ? width! * 0.38 : 30)),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: width == null ? null : width! * 1.5,
        child: url == null
            ? placeholder
            : Stack(fit: StackFit.expand, children: [
                placeholder,
                Image.network(
                  url!,
                  fit: BoxFit.cover,
                  cacheWidth: 300,
                  frameBuilder: (_, child, frame, sync) => sync
                      ? child
                      : AnimatedOpacity(
                          opacity: frame == null ? 0 : 1,
                          duration: const Duration(milliseconds: 300),
                          child: child),
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ]),
      ),
    );
  }
}

const _langs = {
  'es': 'Español',
  'en': 'Inglés',
  'ja': 'Japonés',
  'ko': 'Coreano',
  'fr': 'Francés',
  'de': 'Alemán',
  'it': 'Italiano',
  'pt': 'Portugués',
  'zh': 'Chino',
};
const _sortLabels = {
  'popularity': 'Popularidad',
  'rating': 'Valoración',
  'votes': 'Más votadas',
  'date': 'Más recientes',
  'date_asc': 'Más antiguas',
};
const _statusLabels = {
  'airing': 'En emisión',
  'ended': 'Finalizada',
  'canceled': 'Cancelada',
};
const _months = [
  'ene',
  'feb',
  'mar',
  'abr',
  'may',
  'jun',
  'jul',
  'ago',
  'sep',
  'oct',
  'nov',
  'dic'
];

/// "2026-11-20" → "20 nov 2026".
String _fmtDate(String? iso) {
  final d = DateTime.tryParse(iso ?? '');
  if (d == null) return iso ?? '';
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// "Dune 2021" → (Dune, 2021). Solo reconoce años entre 1900 y el año que viene, al final.
({String text, int? year}) _splitYear(String raw) {
  final t = raw.trim();
  final m = RegExp(r'^(.*\S)\s+((?:19|20)\d{2})$').firstMatch(t);
  if (m != null) {
    final y = int.parse(m[2]!);
    if (y <= DateTime.now().year + 1) return (text: m[1]!, year: y);
  }
  return (text: t, year: null);
}

class _Explorer extends ConsumerStatefulWidget {
  const _Explorer();
  @override
  ConsumerState<_Explorer> createState() => _ExplorerState();
}

class _ExplorerState extends ConsumerState<_Explorer>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  @override
  bool get wantKeepAlive => true;

  final _scroll = ScrollController();
  final _search = TextEditingController();
  final _focus = FocusNode();
  double _kb = 0; // alto del teclado en el último cambio
  final _items = <TmdbMovie>[];
  final _ids = <int>{};
  // popular | trending | top | most_voted | recent | now | upcoming | year | genre | search
  // | foryou (sugerencias a partir de lo pedido y de la biblioteca)
  String _list = 'popular';
  ExploreFilters _filters = const ExploreFilters();
  String _type = 'movie'; // movie | tv
  int _page = 0, _totalPages = 1, _total = 0;
  bool _loading = false;
  String? _error;
  int _gen = 0; // descarta las respuestas de una consulta anterior
  bool _compact = false; // la cabecera se pliega al bajar por la lista

  String _query = ''; // texto de la búsqueda en curso
  bool _literal =
      false; // la búsqueda sin año no dio nada: se buscó el texto tal cual
  bool _fyFallback =
      false; // "Para ti" no tenía de dónde sugerir y mostró la tendencia

  // Sugerencias mientras se escribe y búsquedas recientes.
  Timer? _debounce;
  int _suggGen = 0;
  List<TmdbMovie> _sugg = const [];
  List<String> _recent = const [];
  static const _recentKey = 'explore_recent';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    _focus.addListener(() {
      if (mounted) setState(() {});
    });
    try {
      _recent = ref.read(prefsProvider).getStringList(_recentKey) ?? const [];
    } catch (_) {}
    _more();
  }

  /// Si el teclado se cierra (botón atrás, gesto...), el buscador pierde el foco.
  @override
  void didChangeMetrics() {
    final v = View.of(context).viewInsets.bottom;
    if (_kb > 0 && v == 0 && _focus.hasFocus) _focus.unfocus();
    _kb = v;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _focus.dispose();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onScroll() {
    final p = _scroll.position;
    if (p.pixels >= p.maxScrollExtent - 600) _more();
    // TV: el mando desplaza con el foco (no cuenta como gesto del usuario), así que la cabecera
    // se pliega según la posición: abajo del todo se esconde y al volver a la primera fila
    // reaparece (con histéresis para que no parpadee).
    if (ref.read(tvModeProvider)) {
      final want = p.pixels > 140 ? true : (p.pixels < 40 ? false : _compact);
      if (want != _compact) setState(() => _compact = want);
      return;
    }
    // Al bajar por la lista se pliegan categorías y filtros para ganar sitio; al subir
    // (o al volver arriba) reaparecen.
    final dir = p.userScrollDirection;
    if (!_compact && dir == ScrollDirection.reverse && p.pixels > 140) {
      setState(() => _compact = true);
    } else if (_compact && (dir == ScrollDirection.forward || p.pixels < 40)) {
      setState(() => _compact = false);
    }
  }

  /// Los filtros se aplican a casi todas las listas; en la búsqueda solo vale el año.
  bool get _accepts =>
      _list == 'search' ||
      (_list != 'foryou' && listAcceptsFilters(_list, _type));

  /// Los filtros que de verdad se envían con la lista actual.
  ExploreFilters get _eff => _list == 'search'
      ? ExploreFilters(year: _filters.year)
      : _accepts
          ? _filters
          : const ExploreFilters();

  /// Empieza de cero con la lista y los filtros actuales.
  void _reload() {
    _gen++;
    setState(() {
      _items.clear();
      _ids.clear();
      _page = 0;
      _totalPages = 1;
      _total = 0;
      _error = null;
      _loading = false;
      _literal = false;
      _fyFallback = false;
      _compact = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _more();
  }

  /// Sugerencias a partir de lo que se ha pedido y de lo que hay en la biblioteca:
  /// los "parecidos" que TMDB recomienda de cada uno, mezclados y sin repetir.
  Future<DiscoverPage> _forYou(Catalog cat, int gen) async {
    final reqs = ref.read(requestsProvider).valueOrNull ?? const <TmdbMovie>[];
    final owned = ref.read(ownedKeysProvider);
    final tv = _type == 'tv';
    final seeds = <int>[];
    for (final r in reqs) {
      if (r.type == _type && !seeds.contains(r.id)) seeds.add(r.id);
      if (seeds.length >= 3) break;
    }
    for (final k in owned) {
      final isTv = k.startsWith('tv');
      final id = int.tryParse(isTv ? k.substring(2) : k);
      if (id == null || isTv != tv || seeds.contains(id)) continue;
      seeds.add(id);
      if (seeds.length >= 6) break;
    }
    final lists = await Future.wait([
      for (final id in seeds)
        () async {
          try {
            return (await cat.recommendations(id, type: _type)).items;
          } catch (_) {
            return <TmdbMovie>[];
          }
        }()
    ]);
    final out = <TmdbMovie>[];
    final seen = <int>{...seeds};
    for (var i = 0; out.length < 60; i++) {
      var any = false;
      for (final l in lists) {
        if (i >= l.length) continue;
        any = true;
        final m = l[i];
        if (!_withOwned(m, owned).inLibrary && seen.add(m.id)) out.add(m);
      }
      if (!any) break;
    }
    if (out.isEmpty) {
      if (gen == _gen) _fyFallback = true;
      return cat.discover(list: 'trending', type: _type);
    }
    return DiscoverPage(out, 1, 1, out.length);
  }

  /// Búsqueda por título. Un año al final del texto ("Dune 2021") filtra por ese año; si así
  /// no sale nada, se busca el texto completo.
  Future<DiscoverPage> _searchPage(Catalog cat) async {
    final s = _splitYear(_query);
    final explicit = _filters.year;
    final year = _literal ? explicit : (explicit ?? s.year);
    final r = await cat.discover(
        list: 'search',
        page: _page + 1,
        filters: ExploreFilters(year: year),
        q: _literal ? _query : s.text,
        type: _type);
    if (r.items.isEmpty &&
        _page == 0 &&
        !_literal &&
        s.year != null &&
        explicit == null) {
      _literal = true;
      return cat.discover(list: 'search', q: _query, type: _type);
    }
    return r;
  }

  Future<void> _more() async {
    final cat = ref.read(catalogProvider);
    if (cat == null || _loading || _page >= _totalPages) return;
    if (_list == 'genre' && _filters.genre == null) return;
    if (_list == 'search' && _query.isEmpty) return;
    final gen = _gen;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final DiscoverPage r;
      if (_list == 'foryou') {
        r = await _forYou(cat, gen);
      } else if (_list == 'search') {
        r = await _searchPage(cat);
      } else {
        r = await cat.discover(
            list: _list, page: _page + 1, filters: _eff, type: _type);
      }
      if (!mounted || gen != _gen) return;
      setState(() {
        for (final m in r.items) {
          if (_ids.add(m.id)) _items.add(m);
        }
        _page = r.page;
        _totalPages = r.totalPages;
        _total = r.totalResults;
      });
      // Si la página no llena la pantalla (tablet, TV) no habrá scroll: pide la siguiente.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _scroll.hasClients &&
            _scroll.position.maxScrollExtent <= 0) {
          _more();
        }
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() => _error = errText(e));
    } finally {
      if (mounted && gen == _gen) setState(() => _loading = false);
    }
  }

  void _clearSearchBox() {
    _debounce?.cancel();
    _suggGen++;
    _search.clear();
    _sugg = const [];
    _query = '';
  }

  void _pickType(String t) {
    if (t == _type) return;
    _type = t;
    _clearSearchBox();
    _list = 'popular';
    // Los géneros y los estados dependen del tipo; lo demás se conserva.
    _filters = _filters.without(genre: true, status: true);
    _reload();
  }

  void _pick(String list) {
    _clearSearchBox();
    _list = list;
    _reload();
  }

  void _setFilters(ExploreFilters f) {
    _filters = f;
    _reload();
  }

  void _submitSearch() {
    final t = _search.text.trim();
    _debounce?.cancel();
    _suggGen++;
    _sugg = const [];
    _focus.unfocus();
    if (t.isEmpty) {
      if (_list == 'search') _pick('popular');
      return;
    }
    _query = t;
    _list = 'search';
    _addRecent(t);
    _reload();
  }

  void _addRecent(String t) {
    final l = [t, ..._recent.where((e) => e.toLowerCase() != t.toLowerCase())]
        .take(8)
        .toList();
    _recent = l;
    try {
      ref.read(prefsProvider).setStringList(_recentKey, l);
    } catch (_) {}
  }

  void _clearRecent() {
    setState(() => _recent = const []);
    try {
      ref.read(prefsProvider).remove(_recentKey);
    } catch (_) {}
  }

  void _onTextChanged(String v) {
    setState(() {});
    _debounce?.cancel();
    final t = v.trim();
    if (t.length < 2) {
      _suggGen++;
      if (_sugg.isNotEmpty) setState(() => _sugg = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _fetchSugg(t));
  }

  /// Los primeros resultados de lo que se está escribiendo.
  Future<void> _fetchSugg(String t) async {
    final cat = ref.read(catalogProvider);
    if (cat == null) return;
    final g = ++_suggGen;
    final s = _splitYear(t);
    try {
      final r = await cat.discover(
          list: 'search',
          filters: ExploreFilters(year: _filters.year ?? s.year),
          q: s.text,
          type: _type);
      if (!mounted || g != _suggGen) return;
      setState(() => _sugg = r.items.take(6).toList());
    } catch (_) {
      // las sugerencias son un extra: si fallan, no se muestra nada
    }
  }

  Future<void> _openFilters() async {
    final search = _list == 'search';
    final r = await _sheet<ExploreFilters>(
      context,
      (_) => _FiltersSheet(
          initial: search ? ExploreFilters(year: _filters.year) : _filters,
          type: _type,
          list: _list,
          search: search),
    );
    if (r == null || !mounted) return;
    _setFilters(search ? _filters.withYears(year: r.year) : r);
  }

  Future<void> _pickYear() async {
    final r = await _sheet<_YearPick>(
        context, (_) => _YearSheet(current: _eff, decades: _list != 'search'));
    if (r == null || !mounted) return;
    _setFilters(_filters.withYears(year: r.year, from: r.from, to: r.to));
  }

  ExploreFilters _withGenre(int id) => ExploreFilters(
      genre: id,
      year: _filters.year,
      yearFrom: _filters.yearFrom,
      yearTo: _filters.yearTo,
      minRating: _filters.minRating,
      sort: _filters.sort,
      language: _filters.language,
      status: _filters.status);

  String _genreName(int id) {
    final g = ref.read(genresProvider(_type)).valueOrNull;
    if (g == null) return 'Género';
    for (final x in g) {
      if (x.id == id) return x.name;
    }
    return 'Género';
  }

  String _yearLabel(ExploreFilters f) {
    if (f.year != null) return '${f.year}';
    if (f.yearFrom != null && f.yearTo == f.yearFrom! + 9)
      return '${f.yearFrom}s';
    return '${f.yearFrom ?? '…'}–${f.yearTo ?? '…'}';
  }

  /// "11,578 películas". Para "Para ti" cuenta las sugerencias.
  String _countLabel() {
    if (_list == 'genre' && _filters.genre == null) return '';
    if (_list == 'foryou') {
      return (_items.isEmpty || _fyFallback) ? '' : '${_items.length} para ti';
    }
    if (_total <= 0) return '';
    final n = _total
        .toString()
        .replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    return '$n ${_type == 'tv' ? 'series' : 'películas'}';
  }

  // ---------------- cabecera ----------------

  /// Buscador y botón de filtros, en una sola línea.
  Widget _searchRow() {
    final tv = ref.read(tvModeProvider);
    final n = _eff.count;
    final enabled = _accepts;
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(21),
        borderSide: c == Colors.transparent
            ? BorderSide.none
            : BorderSide(color: c, width: w));
    return Padding(
      padding: EdgeInsets.fromLTRB(tv ? 28 : 16, tv ? 4 : 0, tv ? 28 : 16, 8),
      child: Row(children: [
        Expanded(
          child: TvTextEntry(
              borderRadius: 21, // el mismo que el del campo (ver `border` arriba)
              child: TextField(
            controller: _search,
            focusNode: _focus,
            onTapOutside: (_) => _focus.unfocus(),
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _submitSearch(),
            onChanged: _onTextChanged,
            cursorColor: _red,
            style: TextStyle(fontSize: tv ? 16 : 14.5),
            decoration: InputDecoration(
              hintText: _type == 'tv'
                  ? 'Buscar serie… (ej. Dark 2017)'
                  : 'Buscar película… (ej. Dune 2021)',
              hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
              isDense: true,
              filled: true,
              fillColor: Colors.white.withOpacity(0.07),
              contentPadding: EdgeInsets.symmetric(vertical: tv ? 14 : 11),
              prefixIcon: const Icon(Icons.search_rounded,
                  size: 21, color: Colors.white54),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 46, minHeight: 42),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close_rounded, size: 19),
                      onPressed: () {
                        if (_list == 'search') {
                          _pick('popular');
                        } else {
                          setState(_clearSearchBox);
                        }
                      }),
              suffixIconConstraints:
                  const BoxConstraints(minWidth: 42, minHeight: 42),
              border: border(Colors.transparent),
              enabledBorder: border(Colors.transparent),
              focusedBorder: border(_red.withOpacity(0.75), 1.2),
            ),
          )),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: enabled ? 'Filtros' : 'Esta lista no admite filtros',
          child: Opacity(
            opacity: enabled ? 1 : 0.4,
            child: Material(
              color: n > 0
                  ? _red.withOpacity(0.2)
                  : Colors.white.withOpacity(0.07),
              shape: const CircleBorder(),
              child: _filterButton(tv, enabled, n),
            ),
          ),
        ),
      ]),
    );
  }

  /// Botón de filtros. En TV es un elemento enfocable con aro blanco.
  Widget _filterButton(bool tv, bool enabled, int n) {
    final size = tv ? 52.0 : 42.0;
    final icon = SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Badge(
            isLabelVisible: n > 0,
            backgroundColor: _red,
            label: Text('$n'),
            child: Icon(Icons.tune_rounded, size: tv ? 24 : 21)),
      ),
    );
    if (tv) {
      return TvFocusable(
          borderRadius: size / 2,
          scale: 1,
          nearestScrollOnly: true,
          onTap: enabled ? _openFilters : null,
          child: icon);
    }
    return InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? _openFilters : null,
        child: icon);
  }

  /// Película/Serie + categorías (cada una es una lista distinta de TMDB), en una línea.
  Widget _categoryRow() {
    final tvMode = ref.read(tvModeProvider);
    final tv = _type == 'tv';
    final lists = [
      ('popular', 'Populares'),
      ('trending', 'Tendencia'),
      ('top', 'Mejor valoradas'),
      ('most_voted', 'Más vistas'),
      ('recent', 'Recientes'),
      ('now', tv ? 'En emisión' : 'En cines'),
      ('upcoming', 'Próximamente'),
      ('year', 'Estrenos ${DateTime.now().year}'),
      ('genre', 'Por género'),
      ('foryou', 'Para ti'),
    ];
    return SizedBox(
      height: tvMode ? 58 : 40,
      child: Row(children: [
        SizedBox(width: tvMode ? 28 : 16),
        _TypeToggle(tv: tv, onChanged: _pickType),
        Container(
            width: 1,
            height: 18,
            margin: const EdgeInsets.symmetric(horizontal: 10),
            color: Colors.white12),
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.fromLTRB(
                tvMode ? 4 : 0, tvMode ? 8 : 4, 16, tvMode ? 8 : 4),
            children: [
              for (final l in lists)
                _Pill(l.$2, selected: _list == l.$1, onTap: () => _pick(l.$1)),
            ],
          ),
        ),
      ]),
    );
  }

  /// Año + filtros activos (cada uno se quita con su aspa) + total de resultados.
  Widget _filterStrip() {
    final tvMode = ref.read(tvModeProvider);
    final f = _eff;
    final chips = <Widget>[];
    Widget removable(String label, VoidCallback onRemove) => _Pill(label,
        selected: true,
        dense: true,
        trailing: Icons.close_rounded,
        onTap: onRemove);
    if (_accepts) {
      final hasYear = f.year != null || f.yearFrom != null || f.yearTo != null;
      chips.add(_Pill(hasYear ? _yearLabel(f) : 'Año',
          selected: hasYear,
          dense: true,
          trailing: Icons.keyboard_arrow_down_rounded,
          onTap: _pickYear));
    }
    if (_list != 'search') {
      if (f.genre != null) {
        chips.add(removable(_genreName(f.genre!),
            () => _setFilters(_filters.without(genre: true))));
      }
      if (f.minRating != null) {
        chips.add(removable('★ ${f.minRating!.toStringAsFixed(0)}+',
            () => _setFilters(_filters.without(rating: true))));
      }
      if (f.sort != null) {
        chips.add(removable(_sortLabels[f.sort] ?? f.sort!,
            () => _setFilters(_filters.without(sort: true))));
      }
      if (f.language != null) {
        chips.add(removable(_langs[f.language] ?? f.language!,
            () => _setFilters(_filters.without(language: true))));
      }
      if (f.status != null && _type == 'tv') {
        chips.add(removable(_statusLabels[f.status] ?? f.status!,
            () => _setFilters(_filters.without(status: true))));
      }
      if (!f.isEmpty) {
        chips.add(_tapTv(
          tvMode,
          () => _setFilters(const ExploreFilters()),
          radius: tvMode ? 18 : 16, // la mitad del alto de la fila (36 en TV)
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Center(
                child: Text('Limpiar',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.white54))),
          ),
        ));
      }
    }
    final count = _countLabel();
    if (chips.isEmpty && count.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: tvMode ? 50 : 36,
      child: Row(children: [
        Expanded(
          child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.fromLTRB(
                  tvMode ? 28 : 16, tvMode ? 7 : 4, 8, tvMode ? 7 : 4),
              children: chips),
        ),
        if (count.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(right: tvMode ? 28 : 16),
            child: Text(count,
                style: TextStyle(
                    fontSize: tvMode ? 13 : 11.5, color: Colors.white38)),
          ),
      ]),
    );
  }

  /// Categorías y filtros: se pliegan al bajar por la lista.
  Widget _collapsible() => ClipRect(
        child: AnimatedAlign(
          alignment: Alignment.topCenter,
          heightFactor: _compact ? 0 : 1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: IgnorePointer(
            ignoring: _compact,
            // Plegada no se puede enfocar (el mando acabaría en algo invisible).
            child: ExcludeFocus(
              excluding: _compact,
              child: AnimatedOpacity(
                opacity: _compact ? 0 : 1,
                duration: const Duration(milliseconds: 160),
                child: Column(children: [_categoryRow(), _filterStrip()]),
              ),
            ),
          ),
        ),
      );

  // ---------------- búsqueda: recientes y sugerencias ----------------

  static const _label = TextStyle(
      fontSize: 11,
      letterSpacing: 1,
      fontWeight: FontWeight.w600,
      color: Colors.white38);

  Widget _suggestions(List<TmdbMovie>? reqs, Set<String> owned) {
    final t = _search.text.trim();
    Widget tile(TmdbMovie m) {
      final meta = [
        if (m.year != null) '${m.year}',
        if (m.isTv) 'Serie',
        if (m.rating != null) '★ ${m.rating!.toStringAsFixed(1)}',
      ].join(' · ');
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showMovie(context, m),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(children: [
            _Poster(url: m.posterUrl, width: 38, radius: 6),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(m.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(meta,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white54)),
                  ]),
            ),
            if (m.inLibrary)
              const Icon(Icons.check_circle_rounded, size: 18, color: _green)
            else if (m.requested)
              const Icon(Icons.bookmark_rounded, size: 18, color: _red),
          ]),
        ),
      );
    }

    return TextFieldTapRegion(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        children: t.isEmpty
            ? [
                Row(children: [
                  const Text('BÚSQUEDAS RECIENTES', style: _label),
                  const Spacer(),
                  TextButton(
                      onPressed: _clearRecent, child: const Text('Borrar')),
                ]),
                Wrap(runSpacing: 8, children: [
                  for (final r in _recent)
                    _Pill(r, selected: false, icon: Icons.history_rounded,
                        onTap: () {
                      _search.text = r;
                      _submitSearch();
                    }),
                ]),
              ]
            : [
                for (final m in _sugg) tile(_effective(m, reqs, owned)),
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _submitSearch,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                    child: Row(children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withOpacity(0.07)),
                        child: const Icon(Icons.search_rounded, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text('Ver todos los resultados de «$t»',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w500)),
                      ),
                      const Icon(Icons.chevron_right_rounded,
                          color: Colors.white38),
                    ]),
                  ),
                ),
              ],
      ),
    );
  }

  // ---------------- resultados ----------------

  Widget _footer() {
    if (_loading) {
      return const Padding(
          padding: EdgeInsets.all(22),
          child: Center(
              child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.4, color: _red))));
    }
    if (_error != null) {
      return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent)),
            TextButton(onPressed: _more, child: const Text('Reintentar')),
          ]));
    }
    if (_page >= _totalPages && _items.isNotEmpty) {
      return Padding(
          padding: const EdgeInsets.all(22),
          child: Center(
              child: Text(
                  _totalPages >= 500
                      ? 'Límite de TMDB: página 500.'
                      : 'No hay más resultados.',
                  style:
                      const TextStyle(fontSize: 12.5, color: Colors.white38))));
    }
    return const SizedBox(height: 20);
  }

  /// Rejilla de pósters a 2:3 exactos; el texto de debajo ocupa solo dos líneas.
  SliverGridDelegateWithFixedCrossAxisCount _gridFor(double maxW) {
    final tv = ref.read(tvModeProvider);
    final pad = tv ? _gridPad + 14 : _gridPad;
    final cols = maxW >= 600 ? (maxW / (tv ? 150 : 140)).floor() : 3;
    final w = (maxW - pad * 2 - _gridGap * (cols - 1)) / cols;
    return SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        crossAxisSpacing: _gridGap,
        mainAxisSpacing: tv ? 18 : 14,
        // En TV el texto va más grande (x1.15) y el foco agranda la tarjeta.
        mainAxisExtent: w * 1.5 + (tv ? 54 : 40));
  }

  Widget _skeleton(SliverGridDelegateWithFixedCrossAxisCount d) {
    Widget bar(double w) => Container(
        width: w,
        height: 10,
        decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(5)));
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(_gridPad, 4, _gridPad, 0),
      gridDelegate: d,
      itemCount: d.crossAxisCount * 5,
      itemBuilder: (_, __) =>
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
            child: DecoratedBox(
                decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(10)))),
        const SizedBox(height: 7),
        bar(64),
        const SizedBox(height: 5),
        bar(38),
      ]),
    );
  }

  Widget _genrePicker() => ref.watch(genresProvider(_type)).when(
        data: (genres) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Elige un género',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Wrap(runSpacing: 8, children: [
              for (final g in genres)
                _Pill(g.name,
                    selected: false,
                    onTap: () => _setFilters(_withGenre(g.id))),
            ]),
          ]),
        ),
        loading: () =>
            const Center(child: CircularProgressIndicator(color: _red)),
        error: (e, _) => _EmptyState(
            icon: Icons.cloud_off_rounded,
            title: 'No se pudieron cargar los géneros',
            subtitle: errText(e)),
      );

  Widget _body(List<TmdbMovie>? reqs, Set<String> owned) {
    if (_list == 'genre' && _filters.genre == null) return _genrePicker();
    return LayoutBuilder(builder: (context, c) {
      final grid = _gridFor(c.maxWidth);
      if (_items.isEmpty) {
        if (_loading) return _skeleton(grid);
        if (_error != null) {
          return _EmptyState(
              icon: Icons.cloud_off_rounded,
              title: 'No se pudo cargar',
              subtitle: _error,
              actionLabel: 'Reintentar',
              onAction: _more);
        }
        final hasFilters = !_eff.isEmpty && _list != 'search';
        return _EmptyState(
            icon: Icons.search_off_rounded,
            title: 'Sin resultados',
            subtitle: hasFilters ? 'Prueba a quitar algún filtro.' : null,
            actionLabel: hasFilters ? 'Quitar filtros' : null,
            onAction:
                hasFilters ? () => _setFilters(const ExploreFilters()) : null);
      }
      final tv = ref.read(tvModeProvider);
      final pad = tv ? _gridPad + 14 : _gridPad;
      return CustomScrollView(
          controller: _scroll,
          // TV: construye filas de sobra para que ▼ siempre encuentre la siguiente fila.
          cacheExtent: tv ? 1200 : null,
          slivers: [
            if (_list == 'foryou' && _fyFallback)
              SliverToBoxAdapter(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(_gridPad, 4, _gridPad, 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(12)),
                  child: const Row(children: [
                    Icon(Icons.auto_awesome_rounded, size: 18, color: _gold),
                    SizedBox(width: 10),
                    Expanded(
                        child: Text(
                            'Aún no hay de dónde sugerir: pide algo y aquí saldrán '
                            'títulos parecidos. Mientras, la tendencia de la semana.',
                            style: TextStyle(
                                fontSize: 12.5,
                                height: 1.35,
                                color: Colors.white70))),
                  ]),
                ),
              ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(pad, 6, pad, 0),
              sliver: SliverGrid.builder(
                gridDelegate: grid,
                itemCount: _items.length,
                itemBuilder: (_, i) {
                  final m = _effective(_items[i], reqs, owned);
                  return _MovieCard(
                      movie: m, onTap: () => _showMovie(context, m));
                },
              ),
            ),
            SliverToBoxAdapter(child: _footer()),
          ]);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final reqs = ref.watch(requestsProvider).valueOrNull;
    final owned = ref.watch(ownedKeysProvider);
    // Con el buscador en uso, las sugerencias ocupan el lugar de la rejilla (que se
    // conserva debajo, con su scroll, para cuando se cierre).
    final typing = _focus.hasFocus &&
        (_search.text.trim().isNotEmpty || _recent.isNotEmpty);
    return Column(children: [
      _searchRow(),
      Expanded(
        child: Stack(fit: StackFit.expand, children: [
          Offstage(
            offstage: typing,
            child: Column(children: [
              _collapsible(),
              Expanded(child: _body(reqs, owned)),
            ]),
          ),
          if (typing)
            Positioned.fill(
                child:
                    ColoredBox(color: _bg, child: _suggestions(reqs, owned))),
        ]),
      ),
    ]);
  }
}

const _gridPad = 14.0;
const _gridGap = 10.0;

/// Película / Serie: dos iconos; el elegido muestra además su nombre. En TV son dos botones
/// con nombre, que se enfocan con ◀ ▶ y se eligen con OK.
class _TypeToggle extends ConsumerWidget {
  const _TypeToggle({required this.tv, required this.onChanged});
  final bool tv;
  final ValueChanged<String> onChanged;

  Widget _seg(bool tvMode, IconData icon, String label, bool sel, String type) {
    final box = AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      height: tvMode ? 38 : 28,
      padding: EdgeInsets.symmetric(horizontal: tvMode ? 14 : (sel ? 10 : 8)),
      decoration: BoxDecoration(
          color: sel ? _red : Colors.transparent,
          borderRadius: BorderRadius.circular(tvMode ? 19 : 14)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon,
            size: tvMode ? 20 : 16, color: sel ? Colors.white : Colors.white54),
        // En TV los dos llevan nombre: no hay que adivinar qué es cada icono.
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: (sel || tvMode)
              ? Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(label,
                      style: TextStyle(
                          fontSize: tvMode ? 14.5 : 12.5,
                          fontWeight: FontWeight.w600,
                          color: sel ? Colors.white : Colors.white60)))
              : const SizedBox.shrink(),
        ),
      ]),
    );
    return Tooltip(
      message: label,
      child: _tapTv(tvMode, () => onChanged(type), radius: 19, child: box),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tvMode = ref.watch(tvModeProvider);
    return Container(
      height: tvMode ? 46 : 32,
      padding: EdgeInsets.all(tvMode ? 4 : 2),
      decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(tvMode ? 23 : 16)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _seg(tvMode, Icons.movie_outlined, 'Películas', !tv, 'movie'),
        _seg(tvMode, Icons.tv_rounded, 'Series', tv, 'tv'),
      ]),
    );
  }
}

typedef _YearPick = ({int? year, int? from, int? to});

/// Atajo de año: "Siempre", los últimos años y las décadas.
class _YearSheet extends StatelessWidget {
  const _YearSheet({required this.current, required this.decades});
  final ExploreFilters current;
  final bool decades;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().year;
    final f = current;
    void pick({int? year, int? from, int? to}) =>
        Navigator.pop<_YearPick>(context, (year: year, from: from, to: to));
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Año de estreno',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
              Wrap(runSpacing: 8, children: [
                _Pill('Siempre',
                    selected: f.year == null &&
                        f.yearFrom == null &&
                        f.yearTo == null,
                    onTap: () => pick()),
                for (var y = now; y > now - 14; y--)
                  _Pill('$y',
                      selected: f.year == y, onTap: () => pick(year: y)),
              ]),
              if (decades) ...[
                const SizedBox(height: 18),
                const Text('DÉCADAS', style: _ExplorerState._label),
                const SizedBox(height: 10),
                Wrap(runSpacing: 8, children: [
                  for (var d = (now ~/ 10) * 10; d >= 1950; d -= 10)
                    _Pill('${d}s',
                        selected: f.yearFrom == d && f.yearTo == d + 9,
                        onTap: () => pick(from: d, to: d + 9)),
                ]),
              ],
            ]),
      ),
    );
  }
}

/// Hoja de filtros de Explorar. Devuelve los filtros elegidos (o nada si se cierra).
class _FiltersSheet extends ConsumerStatefulWidget {
  const _FiltersSheet(
      {required this.initial,
      required this.type,
      required this.list,
      required this.search});
  final ExploreFilters initial;
  final String type, list;

  /// En una búsqueda por título solo se puede filtrar por año.
  final bool search;
  @override
  ConsumerState<_FiltersSheet> createState() => _FiltersSheetState();
}

class _FiltersSheetState extends ConsumerState<_FiltersSheet> {
  int? _genre, _year, _from, _to;
  double? _rating;
  String? _sort, _lang, _status;
  late final TextEditingController _yearCtl;

  @override
  void initState() {
    super.initState();
    final f = widget.initial;
    _genre = f.genre;
    _year = f.year;
    _from = f.yearFrom;
    _to = f.yearTo;
    _rating = f.minRating;
    _sort = f.sort;
    _lang = f.language;
    _status = f.status;
    _yearCtl = TextEditingController(text: _year?.toString() ?? '');
  }

  @override
  void dispose() {
    _yearCtl.dispose();
    super.dispose();
  }

  ExploreFilters _build() => ExploreFilters(
      genre: _genre,
      year: _year,
      yearFrom: _from,
      yearTo: _to,
      minRating: _rating,
      sort: _sort,
      language: _lang,
      status: _status);

  Widget _title(String t) => Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 10),
      child: Text(t.toUpperCase(), style: _ExplorerState._label));

  @override
  Widget build(BuildContext context) {
    final tv = widget.type == 'tv';
    final now = DateTime.now().year;
    final fixedSort = widget.list == 'top' ||
        widget.list == 'most_voted' ||
        widget.list == 'recent';
    final genres = widget.search
        ? const <TmdbGenre>[]
        : (ref.watch(genresProvider(widget.type)).valueOrNull ??
            const <TmdbGenre>[]);
    return SafeArea(
      top: false,
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.85),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
              child: Row(children: [
                const Expanded(
                    child: Text('Filtros',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w700))),
                TextButton(
                    onPressed: () =>
                        Navigator.pop(context, const ExploreFilters()),
                    child: const Text('Limpiar')),
              ]),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _title(widget.search ? 'Año de estreno' : 'Año'),
                      TvTextEntry(
                          borderRadius: 14, // el del campo
                          child: TextField(
                        controller: _yearCtl,
                        keyboardType: TextInputType.number,
                        maxLength: 4,
                        cursorColor: _red,
                        decoration: InputDecoration(
                            hintText: 'Un año exacto, ej. 2019',
                            hintStyle: const TextStyle(color: Colors.white38),
                            isDense: true,
                            counterText: '',
                            filled: true,
                            fillColor: Colors.white.withOpacity(0.07),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 13),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none)),
                        onChanged: (v) {
                          final y = int.tryParse(v);
                          setState(() {
                            _year = (y != null && y >= 1900 && y <= now + 2)
                                ? y
                                : null;
                            if (_year != null) {
                              _from = null;
                              _to = null;
                            }
                          });
                        },
                      )),
                      if (!widget.search) ...[
                        const SizedBox(height: 10),
                        Wrap(runSpacing: 8, children: [
                          for (var d = (now ~/ 10) * 10; d >= 1950; d -= 10)
                            _Pill('${d}s', selected: _from == d && _to == d + 9,
                                onTap: () {
                              setState(() {
                                final on = _from == d && _to == d + 9;
                                _from = on ? null : d;
                                _to = on ? null : d + 9;
                                _year = null;
                                _yearCtl.clear();
                              });
                            }),
                        ]),
                        _title('Valoración mínima'),
                        Wrap(runSpacing: 8, children: [
                          _Pill('Cualquiera',
                              selected: _rating == null,
                              onTap: () => setState(() => _rating = null)),
                          for (final r in [6.0, 7.0, 8.0])
                            _Pill('★ ${r.toStringAsFixed(0)}+',
                                selected: _rating == r,
                                onTap: () => setState(() => _rating = r)),
                        ]),
                        if (genres.isNotEmpty) ...[
                          _title('Género'),
                          Wrap(runSpacing: 8, children: [
                            _Pill('Cualquiera',
                                selected: _genre == null,
                                onTap: () => setState(() => _genre = null)),
                            for (final g in genres)
                              _Pill(g.name,
                                  selected: _genre == g.id,
                                  onTap: () => setState(() => _genre = g.id)),
                          ]),
                        ],
                        if (tv) ...[
                          _title('Estado de la serie'),
                          Wrap(runSpacing: 8, children: [
                            _Pill('Cualquiera',
                                selected: _status == null,
                                onTap: () => setState(() => _status = null)),
                            for (final e in _statusLabels.entries)
                              _Pill(e.value,
                                  selected: _status == e.key,
                                  onTap: () => setState(() => _status = e.key)),
                          ]),
                        ],
                        _title('Idioma original'),
                        Wrap(runSpacing: 8, children: [
                          _Pill('Cualquiera',
                              selected: _lang == null,
                              onTap: () => setState(() => _lang = null)),
                          for (final e in _langs.entries)
                            _Pill(e.value,
                                selected: _lang == e.key,
                                onTap: () => setState(() => _lang = e.key)),
                        ]),
                        if (!fixedSort) ...[
                          _title('Ordenar por'),
                          Wrap(runSpacing: 8, children: [
                            _Pill('Por defecto',
                                selected: _sort == null,
                                onTap: () => setState(() => _sort = null)),
                            for (final e in _sortLabels.entries)
                              _Pill(e.value,
                                  selected: _sort == e.key,
                                  onTap: () => setState(() => _sort = e.key)),
                          ]),
                        ],
                      ],
                      const SizedBox(height: 12),
                    ]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: _red,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(50),
                      textStyle: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14))),
                  onPressed: () => Navigator.pop(context, _build()),
                  child: const Text('Aplicar filtros'),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  Pedidas: lo que han pedido todos los dispositivos.
// ---------------------------------------------------------------------------

enum _PedFilter { all, mine, ready }

class _Pedidas extends ConsumerStatefulWidget {
  const _Pedidas({required this.canExplore});

  /// Hay catálogo para explorar (si no, no se ofrece el atajo a Explorar).
  final bool canExplore;
  @override
  ConsumerState<_Pedidas> createState() => _PedidasState();
}

class _PedidasState extends ConsumerState<_Pedidas> {
  _PedFilter _f = _PedFilter.all;

  Future<void> _refresh() async {
    ref.invalidate(requestsProvider);
    await ref.read(requestsProvider.future);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(requestsProvider);
    final owned = ref.watch(ownedKeysProvider);
    final tv = ref.watch(tvModeProvider);
    return RefreshIndicator(
      color: _red,
      backgroundColor: _surface,
      onRefresh: _refresh,
      child: async.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: _red)),
        error: (e, _) => ListView(children: [
          SizedBox(
              height: 360,
              child: _EmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: 'No se pudieron cargar',
                  subtitle: errText(e))),
        ]),
        data: (raw) {
          final all = [for (final m in raw) _withOwned(m, owned)];
          final mineN = all.where((m) => _mine(ref, m)).length;
          final readyN = all.where((m) => m.inLibrary).length;
          final list = switch (_f) {
            _PedFilter.all => all,
            _PedFilter.mine => [
                for (final m in all)
                  if (_mine(ref, m)) m
              ],
            _PedFilter.ready => [
                for (final m in all)
                  if (m.inLibrary) m
              ],
          };
          return CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            cacheExtent: tv ? 1200 : null,
            slivers: [
              if (all.isNotEmpty)
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: tv ? 62 : 46,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.fromLTRB(tv ? 28 : 16, 6, 16, 8),
                      children: [
                        _Pill('Todas ${all.length}',
                            selected: _f == _PedFilter.all,
                            onTap: () => setState(() => _f = _PedFilter.all)),
                        _Pill('Mías $mineN',
                            selected: _f == _PedFilter.mine,
                            onTap: () => setState(() => _f = _PedFilter.mine)),
                        _Pill('Disponibles $readyN',
                            selected: _f == _PedFilter.ready,
                            onTap: () => setState(() => _f = _PedFilter.ready)),
                      ],
                    ),
                  ),
                ),
              if (list.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: all.isEmpty
                      ? _EmptyState(
                          icon: Icons.playlist_add_check_rounded,
                          title: 'Aún no hay peticiones',
                          subtitle:
                              'Explora el catálogo y pide las películas o series que '
                              'quieras ver.',
                          actionLabel:
                              widget.canExplore ? 'Explorar catálogo' : null,
                          onAction: widget.canExplore
                              ? () =>
                                  DefaultTabController.of(context).animateTo(0)
                              : null)
                      : _EmptyState(
                          icon: Icons.inbox_rounded,
                          title: _f == _PedFilter.mine
                              ? 'No has pedido nada todavía'
                              : 'Nada disponible aún',
                          subtitle: _f == _PedFilter.mine
                              ? 'Lo que pidas desde este dispositivo aparecerá aquí.'
                              : 'Cuando una petición llegue a la biblioteca, la verás aquí.'),
                )
              else if (tv)
                // TV: dos columnas (la pantalla es ancha y así se ven más peticiones a la vez).
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(28, 4, 28, 0),
                  sliver: SliverGrid.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 14,
                            mainAxisSpacing: 14,
                            mainAxisExtent: 152),
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final m = list[i];
                      final mine = _mine(ref, m);
                      return _RequestTile(
                        movie: m,
                        mine: mine,
                        onTap: () => _showMovie(context, m),
                        onRemove: (!m.inLibrary && mine)
                            ? () => _toggle(context, ref, m)
                            : null,
                      );
                    },
                  ),
                )
              else
                SliverList.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final m = list[i];
                    final mine = _mine(ref, m);
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: _RequestTile(
                        movie: m,
                        mine: mine,
                        onTap: () => _showMovie(context, m),
                        onRemove: (!m.inLibrary && mine)
                            ? () => _toggle(context, ref, m)
                            : null,
                      ),
                    );
                  },
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
            ],
          );
        },
      ),
    );
  }
}

class _RequestTile extends ConsumerWidget {
  const _RequestTile(
      {required this.movie,
      required this.mine,
      required this.onTap,
      this.onRemove});
  final TmdbMovie movie;
  final bool mine;
  final VoidCallback onTap;

  /// Solo si la petición es de este dispositivo y aún no está en la biblioteca.
  final VoidCallback? onRemove;

  Widget _status(IconData icon, Color color, String text) => Container(
        padding: const EdgeInsets.fromLTRB(6, 3, 9, 3),
        decoration: BoxDecoration(
            color: color.withOpacity(0.14),
            borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
        ]),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tv = ref.watch(tvModeProvider);
    final m = movie;
    final meta = [
      if (m.year != null) '${m.year}',
      m.isTv ? 'Serie' : 'Película',
    ].join(' · ');
    final by =
        m.displayBy.isEmpty ? '' : 'Pedida por ${m.displayBy.join(', ')}';
    final when = _ago(m.createdMs);
    final byLine =
        [if (by.isNotEmpty) by, if (when.isNotEmpty) when].join(' · ');
    final tile = Material(
      color: _surface,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: tv ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _Poster(url: m.posterUrl, width: 64, radius: 11),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(m.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              height: 1.2)),
                    ),
                    const SizedBox(height: 4),
                    Row(children: [
                      Text(meta,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white54)),
                      if (m.rating != null) ...[
                        const SizedBox(width: 8),
                        _Rating(m.rating!, size: 11.5),
                      ],
                    ]),
                    const SizedBox(height: 9),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      if (m.inLibrary)
                        _status(
                            Icons.check_circle_rounded, _green, 'Disponible')
                      else
                        _status(Icons.schedule_rounded, _gold, 'Pendiente'),
                      if (mine)
                        _status(Icons.person_rounded, Colors.white70, 'Tuya'),
                    ]),
                    if (byLine.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(byLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11.5, color: Colors.white38)),
                    ],
                  ]),
            ),
            if (onRemove != null)
              IconButton(
                tooltip: 'Quitar mi petición',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded,
                    size: 20, color: Colors.white54),
                onPressed: onRemove,
              ),
          ]),
        ),
      ),
    );
    return tv
        ? TvFocusable(
            borderRadius: 18,
            scale: 1.02,
            nearestScrollOnly: true,
            onTap: onTap,
            child: tile)
        : tile;
  }
}

// ---------------------------------------------------------------------------
//  Tarjeta de la rejilla y ficha
// ---------------------------------------------------------------------------

class _MovieCard extends ConsumerWidget {
  const _MovieCard({required this.movie, required this.onTap});
  final TmdbMovie movie;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tv = ref.watch(tvModeProvider);
    final m = movie;
    final card =
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(fit: StackFit.expand, children: [
            _Poster(url: m.posterUrl),
            // Degradado inferior para que la nota y el año se lean sobre cualquier póster.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 46,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                      gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                        Colors.transparent,
                        Colors.black.withOpacity(0.78),
                      ])),
                ),
              ),
            ),
            if (m.rating != null)
              Positioned(left: 7, bottom: 6, child: _Rating(m.rating!)),
            if (m.year != null)
              Positioned(
                right: 7,
                bottom: 6,
                child: Text('${m.year}',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.white70)),
              ),
            if (m.inLibrary)
              const Positioned(
                  top: 6,
                  left: 6,
                  child: _PosterBadge(
                      Icons.check_circle_rounded, _green, 'En biblioteca'))
            else if (m.requested)
              const Positioned(
                  top: 6,
                  left: 6,
                  child: _PosterBadge(
                      Icons.bookmark_rounded, Color(0xFFFF5A64), 'Pedida')),
          ]),
        ),
      ),
      const SizedBox(height: 6),
      Text(m.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.2)),
    ]);
    // TV: al enfocar, la tarjeta se agranda con un aro blanco y se centra en pantalla.
    if (tv)
      return TvFocusable(
          borderRadius: 10,
          scale: 1.06,
          nearestScrollOnly: true,
          onTap: onTap,
          child: card);
    return InkWell(
        borderRadius: BorderRadius.circular(10), onTap: onTap, child: card);
  }
}

/// Texto largo que se recorta a unas líneas con "Leer más".
class _Expandable extends StatefulWidget {
  const _Expandable(this.text);
  final String text;
  @override
  State<_Expandable> createState() => _ExpandableState();
}

class _ExpandableState extends State<_Expandable> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final long = widget.text.length > 170;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Sin AnimatedSize: al cambiar maxLines dejaba el texto expandido en una sola línea.
      Text(widget.text,
          maxLines: (_open || !long) ? null : 4,
          overflow:
              (_open || !long) ? TextOverflow.visible : TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 14,
              height: 1.45,
              color: Colors.white.withOpacity(0.82))),
      if (long)
        _tapTv(
          ProviderScope.containerOf(context).read(tvModeProvider),
          () => setState(() => _open = !_open),
          radius: 8,
          child: Padding(
            padding:
                const EdgeInsets.only(top: 6, left: 4, right: 4, bottom: 4),
            child: Text(_open ? 'Mostrar menos' : 'Leer más',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFFF5A64))),
          ),
        ),
    ]);
  }
}

/// Ficha de la película con el botón de pedir. Se actualiza sola al cambiar la petición.
class _MovieSheet extends ConsumerStatefulWidget {
  const _MovieSheet({required this.base});
  final TmdbMovie base;
  @override
  ConsumerState<_MovieSheet> createState() => _MovieSheetState();
}

class _MovieSheetState extends ConsumerState<_MovieSheet> {
  bool _busy = false;
  TmdbInfo? _info; // estado, temporadas... (se pide al abrir la ficha)
  List<TmdbMovie> _similar = const []; // títulos parecidos

  @override
  void initState() {
    super.initState();
    _loadExtras();
  }

  /// Datos extra de TMDB. Si fallan (sin conexión) la ficha se queda como estaba.
  Future<void> _loadExtras() async {
    final cat = ref.read(catalogProvider);
    if (cat == null) return;
    final b = widget.base;
    cat.info(b.id, type: b.type).then((i) {
      if (mounted) setState(() => _info = i);
    }).catchError((_) {});
    cat.recommendations(b.id, type: b.type).then((r) {
      if (mounted) setState(() => _similar = r.items.take(12).toList());
    }).catchError((_) {});
  }

  Color _statusColor(String? status) => switch (status) {
        'Returning Series' || 'In Production' => Colors.green.shade600,
        'Canceled' || 'Cancelled' => _red,
        _ => Colors.blueGrey.shade500,
      };

  Widget _tag(Widget child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8)),
        child: child,
      );

  Widget _tagText(String t) => _tag(Text(t,
      style: const TextStyle(
          fontSize: 12.5, fontWeight: FontWeight.w500, color: Colors.white70)));

  /// Estado de la serie o película y sus datos (temporadas, próximo capítulo...).
  Widget _infoBlock(TmdbMovie m) {
    final i = _info;
    if (i == null) return const SizedBox.shrink();
    final label = tmdbStatusLabel(i.status, m.type);
    final facts = [
      if (i.seasons != null)
        '${i.seasons} temporada${i.seasons == 1 ? '' : 's'}',
      if (i.episodes != null)
        '${i.episodes} episodio${i.episodes == 1 ? '' : 's'}',
      if (i.runtime != null) '${i.runtime} min',
    ].join(' · ');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (label != null) ...[
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
              color: _statusColor(i.status).withOpacity(0.9),
              borderRadius: BorderRadius.circular(20)),
          child: Text(label,
              style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
        ),
      ],
      if (facts.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(facts,
            style: const TextStyle(fontSize: 13, color: Colors.white70)),
      ],
      if (m.isTv && i.nextAir != null) ...[
        const SizedBox(height: 3),
        Text('Próximo episodio: ${_fmtDate(i.nextAir)}',
            style: const TextStyle(fontSize: 13, color: Colors.white70)),
      ] else if (m.isTv && i.lastAir != null) ...[
        const SizedBox(height: 3),
        Text('Último episodio: ${_fmtDate(i.lastAir)}',
            style: const TextStyle(fontSize: 13, color: Colors.white54)),
      ],
      if (i.genres.isNotEmpty) ...[
        const SizedBox(height: 3),
        Text(i.genres.join(' · '),
            style: const TextStyle(fontSize: 13, color: Colors.white54)),
      ],
    ]);
  }

  Widget _similarRow() {
    if (_similar.isEmpty) return const SizedBox.shrink();
    final tv = ref.watch(tvModeProvider);
    // TV: pósters mayores y con margen alrededor, para que el aro y el zoom del foco no se
    // recorten dentro de la fila.
    final pw = tv ? 124.0 : 100.0;
    return _CenterOnFocus(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 24),
        const Text('Parecidas',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 10),
        SizedBox(
          height: tv ? 262 : 196,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding:
                tv ? const EdgeInsets.fromLTRB(8, 10, 8, 10) : EdgeInsets.zero,
            itemCount: _similar.length,
            separatorBuilder: (_, __) => SizedBox(width: tv ? 14 : 10),
            itemBuilder: (_, i) {
              final s = _similar[i];
              void open() => _showMovie(
                  context,
                  _effective(s, ref.read(requestsProvider).valueOrNull,
                      ref.read(ownedKeysProvider)));
              final card = SizedBox(
                width: pw,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Poster(url: s.posterUrl, width: pw),
                      const SizedBox(height: 6),
                      Text(s.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              height: 1.2)),
                    ]),
              );
              if (tv) {
                return TvFocusable(
                    borderRadius: 10,
                    scale: 1.06,
                    nearestScrollOnly: true,
                    onTap: open,
                    child: card);
              }
              return InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: open,
                  child: card);
            },
          ),
        ),
      ]),
    );
  }

  Future<void> _tap(TmdbMovie m) async {
    setState(() => _busy = true);
    await _toggle(context, ref, m);
    if (mounted) setState(() => _busy = false);
  }

  Widget _cta(TmdbMovie m, bool mine) {
    final tv =
        ref.watch(tvModeProvider); // con el mando, el foco empieza en el botón
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
    const text = TextStyle(fontSize: 15, fontWeight: FontWeight.w600);
    Widget icon(IconData i) => _busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2.2, color: Colors.white))
        : Icon(i, size: 20);
    if (m.inLibrary) {
      return Container(
        height: 50,
        decoration: BoxDecoration(
            color: _green.withOpacity(0.13),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _green.withOpacity(0.4))),
        child:
            const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.check_circle_rounded, size: 20, color: _green),
          SizedBox(width: 8),
          Text('Ya está en tu biblioteca',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600, color: _green)),
        ]),
      );
    }
    if (mine) {
      return OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
            foregroundColor: Colors.white,
            side: const BorderSide(color: Colors.white24),
            textStyle: text,
            shape: shape),
        autofocus: tv,
        onPressed: _busy ? null : () => _tap(m),
        icon: icon(Icons.remove_circle_outline_rounded),
        label: const Text('Quitar mi petición'),
      );
    }
    return FilledButton.icon(
      style: FilledButton.styleFrom(
          backgroundColor: _red,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(50),
          textStyle: text,
          shape: shape),
      autofocus: tv,
      onPressed: _busy ? null : () => _tap(m),
      icon: icon(Icons.add_rounded),
      label: Text(m.requested
          ? 'Yo también la quiero'
          : (m.isTv ? 'Pedir serie' : 'Pedir película')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = _effective(widget.base, ref.watch(requestsProvider).valueOrNull,
        ref.watch(ownedKeysProvider));
    final mine = _mine(ref, m);
    final catalog = ref.watch(catalogProvider);
    final tv = ref.watch(tvModeProvider);
    return ConstrainedBox(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.92),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withOpacity(0.5),
                              blurRadius: 18,
                              offset: const Offset(0, 8)),
                        ]),
                    child: _Poster(
                        url: m.posterUrl, width: tv ? 132 : 108, radius: 14),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(m.title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 21,
                                  fontWeight: FontWeight.w700,
                                  height: 1.15,
                                  letterSpacing: -0.2)),
                          const SizedBox(height: 10),
                          Wrap(spacing: 6, runSpacing: 6, children: [
                            if (m.year != null) _tagText('${m.year}'),
                            if (m.rating != null)
                              _tag(_Rating(m.rating!, size: 12.5)),
                            _tagText(m.isTv ? 'Serie' : 'Película'),
                          ]),
                          _infoBlock(m),
                        ]),
                  ),
                ]),
                if (m.requestedBy.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Row(children: [
                    const Icon(Icons.people_alt_outlined,
                        size: 16, color: Colors.white38),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Pedida por ${m.displayBy.join(', ')}',
                          style: const TextStyle(
                              fontSize: 12.5, color: Colors.white54)),
                    ),
                  ]),
                ],
                const SizedBox(height: 16),
                (m.overview ?? '').isEmpty
                    ? const Text('Sin sinopsis.',
                        style: TextStyle(color: Colors.white54))
                    : _Expandable(m.overview!),
                if (catalog != null) ...[
                  const SizedBox(height: 20),
                  // TV: el tráiler se centra en la zona visible al enfocarlo y no ocupa más
                  // alto que ella (a todo el ancho de la ficha no cabría entero).
                  _CenterOnFocus(
                    child: tv
                        ? Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 560),
                              child: TrailerPlayer(
                                  key: ValueKey(m.id),
                                  catalog: catalog,
                                  tmdbId: m.id,
                                  type: m.type,
                                  title: m.title,
                                  year: m.year,
                                  tv: true),
                            ),
                          )
                        : TrailerPlayer(
                            key: ValueKey(m.id),
                            catalog: catalog,
                            tmdbId: m.id,
                            type: m.type,
                            title: m.title,
                            year: m.year),
                  ),
                ],
                _similarRow(),
                // TV: sitio extra al final para poder centrar también la fila de parecidas.
                if (tv) const SizedBox(height: 150),
              ],
            ),
          ),
        ),
        // Botón fijo abajo: se ve sin tener que bajar hasta el final de la ficha.
        DecoratedBox(
          decoration: BoxDecoration(
              color: _sheetBg,
              border: Border(
                  top: BorderSide(color: Colors.white.withOpacity(0.07)))),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: SizedBox(width: double.infinity, child: _cta(m, mine)),
            ),
          ),
        ),
      ]),
    );
  }
}
