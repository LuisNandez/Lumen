import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';
import 'core.dart';
import 'downloads.dart';
import 'main.dart' show RemoteScreen;
import 'native.dart';
import 'profiles.dart';
import 'remote.dart';
import 'sounds.dart';
import 'updater.dart';
import 'progress_sync.dart';
import 'tv.dart'
    show
        focusSide,
        kFocusCurve,
        kFocusDuration,
        kFocusRing,
        kFocusWidth,
        tvModeProvider;

// ===========================================================================
//  Ajustes: perfil, servidor, dispositivos, reproducción y descargas.
//  Diseño: título grande, tarjeta de perfil y secciones agrupadas en tarjetas
//  redondeadas con un icono por fila. Sigue siendo accesible con el servidor
//  apagado (lo que necesita conexión aparece atenuado).
//  La vista de lista ya no existe: la biblioteca siempre es el modo teatro.
// ===========================================================================

const _bg = Color(0xFF141414);
const _red = Color(0xFFE50914);
const _card = Color(0xFF1E1E22);
const _hair = Color(0x14FFFFFF);

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _autoscrape(BuildContext context, Api api) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final started = await api.autoscrape();
      messenger.showSnackBar(SnackBar(
          content: Text(started
              ? 'Identificando en TMDB... la biblioteca se actualizará sola.'
              : 'El servidor no tiene clave de TMDB. Añádela en la app del servidor.')));
    } catch (e) {
      messenger.showSnackBar(errorSnack(errText(e)));
    }
  }

  Future<void> _forget(BuildContext context, WidgetRef ref) async {
    final ok = await confirmAction(
        context,
        'Olvidar servidor',
        'Este dispositivo se desvinculará del servidor y tendrás que emparejarlo '
            'otra vez con el PIN. Las descargas se conservan en el dispositivo.',
        'Olvidar');
    if (!ok) return;
    await ref.read(sessionProvider.notifier).clear();
    if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _resetProgress(
      BuildContext context, WidgetRef ref, Api api) async {
    final ok = await confirmAction(
        context,
        'Reiniciar progreso',
        'Se borrará el progreso y "Continuar viendo" de tu perfil. '
            'Los demás perfiles no se ven afectados.',
        'Reiniciar');
    if (!ok) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await api.resetProgress();
      ref.read(progressSyncProvider).clearCurrentProfile();
      ref.read(downloadsProvider.notifier).resetProgressLocal();
      ref.invalidate(libraryProvider);
      messenger.showSnackBar(
          const SnackBar(content: Text('Progreso de tu perfil reiniciado.')));
    } catch (e) {
      messenger.showSnackBar(errorSnack(errText(e)));
    }
  }

  Future<void> _importOldProgress(
      BuildContext context, WidgetRef ref, Api api) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final n = await api.importDeviceProgress();
      ref.invalidate(profilesProvider);
      ref.invalidate(libraryProvider);
      ref.invalidate(showsProvider);
      messenger.showSnackBar(SnackBar(
          content: Text(n > 0
              ? 'Progreso anterior importado ($n videos).'
              : 'No había progreso anterior que importar.')));
    } catch (e) {
      messenger.showSnackBar(errorSnack(errText(e)));
    }
  }

  void _go(BuildContext context, Widget screen) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final api = ref.watch(apiProvider);
    final offline = ref.watch(serverOfflineProvider);
    final tmdb = ref.watch(serverInfoProvider).valueOrNull?.tmdb ?? false;
    final others = ref.watch(remoteProvider).others;
    final cfg = ref.watch(settingsProvider);
    final cfgCtl = ref.read(settingsProvider.notifier);
    final dls = ref.watch(downloadsProvider).values.toList();
    final profile = ref.watch(profilesProvider).valueOrNull?.currentProfile;
    final tv = ref.watch(tvModeProvider);

    final used = downloadsUsedBytes(dls);
    final done = dls.where((e) => e.state == DlState.done).length;
    final pending = dls.length - done;
    final seen = [
      for (final e in dls)
        if (e.state == DlState.done && e.seen) e
    ];

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        bottom: false,
        // En TV la lista se queda en una columna centrada (si no, las filas ocuparían los
        // 1920 px de la pantalla) y se construye con margen para que ▼ siempre tenga fila.
        child: _TvColumn(
            tv: tv,
            child: ListView(
                cacheExtent: tv ? 800 : null,
                padding: const EdgeInsets.only(bottom: 40),
                children: [
                  // ---------------- Título ----------------
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 12, 20, 4),
                    child: Row(children: [
                      if (Navigator.of(context).canPop())
                        IconButton(
                            tooltip: 'Atrás',
                            icon: const Icon(Icons.arrow_back_rounded),
                            onPressed: () => Navigator.maybePop(context))
                      else
                        const SizedBox(width: 12),
                      const Text('Ajustes',
                          style: TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.6)),
                    ]),
                  ),

                  // ---------------- Perfil ----------------
                  if (profile != null) ...[
                    const SizedBox(height: 14),
                    _ProfileCard(
                      avatar:
                          AvatarCircle(api: api, profile: profile, radius: 30),
                      name: profile.username,
                      detail: profile.hasPin ? 'Protegido con PIN' : 'Sin PIN',
                      enabled: !offline,
                      onTap: () => _go(context, const ProfilePickerScreen()),
                    ),
                    _Group(children: [
                      _Tile(
                        icon: Icons.manage_accounts_outlined,
                        title: 'Editar mi perfil',
                        subtitle:
                            'Avatar y PIN. El nombre de usuario no se puede cambiar.',
                        enabled: !offline,
                        chevron: true,
                        onTap: () =>
                            _go(context, ProfileEditScreen(profile: profile)),
                      ),
                    ]),
                  ],

                  // ---------------- Servidor ----------------
                  const _Section('Servidor'),
                  _Group(children: [
                    _Tile(
                      icon: offline
                          ? Icons.cloud_off_rounded
                          : Icons.dns_outlined,
                      color: offline ? Colors.orangeAccent : null,
                      title: session?.name ?? 'Servidor',
                      subtitle:
                          '${session?.host ?? ''} · ${offline ? 'sin conexión' : 'conectado'}',
                      trailing: Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: offline
                                  ? Colors.orangeAccent
                                  : const Color(0xFF46D369))),
                    ),
                    _Tile(
                      icon: Icons.refresh_rounded,
                      title: 'Actualizar biblioteca',
                      subtitle:
                          'Vuelve a pedir la lista de películas y series.',
                      enabled: !offline,
                      onTap: () {
                        ref.invalidate(libraryProvider);
                        ref.invalidate(serverInfoProvider);
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Actualizando biblioteca...')));
                      },
                    ),
                    _Tile(
                      icon: Icons.travel_explore_rounded,
                      title: 'Identificar películas y series (TMDB)',
                      subtitle: offline
                          ? 'Necesitas conexión con el servidor.'
                          : tmdb
                              ? 'Busca carátulas y sinopsis de lo que aún no está identificado.'
                              : 'El servidor no tiene clave de TMDB.',
                      enabled: !offline && tmdb && api != null,
                      onTap: () => _autoscrape(context, api!),
                    ),
                    _Tile(
                      icon: Icons.logout_rounded,
                      title: 'Olvidar servidor',
                      subtitle:
                          'Desvincula este dispositivo y vuelve a emparejar.',
                      onTap: () => _forget(context, ref),
                    ),
                  ]),

                  // ---------------- Dispositivos ----------------
                  const _Section('Dispositivos'),
                  _Group(children: [
                    _Tile(
                      icon: Icons.cast_rounded,
                      title: 'Control remoto',
                      subtitle: offline
                          ? 'Necesitas conexión con el servidor.'
                          : others.isEmpty
                              ? 'No hay otros dispositivos conectados.'
                              : '${others.length} ${others.length == 1 ? 'dispositivo conectado' : 'dispositivos conectados'}',
                      enabled: !offline,
                      chevron: true,
                      onTap: () => _go(context, const RemoteScreen()),
                    ),
                    _Tile(
                      icon: Icons.phone_android_rounded,
                      title: 'Este dispositivo',
                      subtitle: deviceName(ref.read(prefsProvider)),
                    ),
                  ]),

                  // ---------------- Reproducción ----------------
                  const _Section('Reproducción'),
                  _Group(children: [
                    if (!tv)
                      _Tile(
                        icon: Icons.battery_charging_full_rounded,
                        title: 'Sin restricción de batería',
                        subtitle:
                            'Evita que el sistema cierre la app en segundo plano.',
                        onTap: NativeBridge.requestIgnoreBatteryOpts,
                      ),
                    _Tile(
                      icon: Icons.restart_alt_rounded,
                      title: 'Reiniciar mi progreso',
                      subtitle: offline
                          ? 'Necesitas conexión con el servidor.'
                          : 'Borra lo visto y "Continuar viendo" solo de tu perfil.',
                      enabled: !offline && api != null,
                      onTap: () => _resetProgress(context, ref, api!),
                    ),
                    if (ref
                            .watch(profilesProvider)
                            .valueOrNull
                            ?.hasDeviceProgress ??
                        false)
                      _Tile(
                        icon: Icons.history_rounded,
                        title: 'Importar progreso anterior',
                        subtitle: offline
                            ? 'Necesitas conexión con el servidor.'
                            : 'Trae a tu perfil lo que este dispositivo vio antes de los perfiles. '
                                'Lo que ya tengas se respeta.',
                        enabled: !offline && api != null,
                        onTap: () => _importOldProgress(context, ref, api!),
                      ),
                    if (ref.watch(
                        tvModeProvider)) // los sonidos solo existen en TV
                      _Tile(
                        icon: Icons.volume_up_rounded,
                        title: 'Sonidos de la interfaz',
                        subtitle:
                            'Efectos al navegar, recibir avisos, entrar en salas y descargar.',
                        trailing: Switch(
                            value: cfg.soundsEnabled,
                            activeColor: Colors.white,
                            activeTrackColor: _red,
                            onChanged: cfgCtl.setSounds),
                        onTap: () => cfgCtl.setSounds(!cfg.soundsEnabled),
                      ),
                  ]),

                  // ---------------- Descargas ----------------
                  const _Section('Descargas'),
                  _Group(children: [
                    _Tile(
                      icon: Icons.download_for_offline_outlined,
                      title: 'Gestionar descargas',
                      subtitle: '${fmtBytes(used)} en el dispositivo · $done '
                          '${done == 1 ? 'descargada' : 'descargadas'}'
                          '${pending > 0 ? ' · $pending pendientes' : ''}',
                      chevron: true,
                      onTap: () => _go(context, const DownloadsScreen()),
                    ),
                    _Tile(
                      icon: Icons.swap_vert_rounded,
                      title: 'Descargas simultáneas',
                      body: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 10),
                            if (tv)
                              _TvSegments(
                                  values: const [1, 2, 3],
                                  selected: cfg.parallelDownloads,
                                  onChanged: cfgCtl.setParallel)
                            else
                              SizedBox(
                                width: double.infinity,
                                child: SegmentedButton<int>(
                                  showSelectedIcon: false,
                                  style: SegmentedButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                          selectedBackgroundColor: Colors.white,
                                          selectedForegroundColor: Colors.black,
                                          foregroundColor: Colors.white70,
                                          side: const BorderSide(
                                              color: Colors.white24))
                                      .copyWith(
                                          side: focusSide(
                                              kFocusRing,
                                              const BorderSide(
                                                  color: Colors.white24))),
                                  segments: const [
                                    ButtonSegment(value: 1, label: Text('1')),
                                    ButtonSegment(value: 2, label: Text('2')),
                                    ButtonSegment(value: 3, label: Text('3')),
                                  ],
                                  selected: {cfg.parallelDownloads},
                                  onSelectionChanged: (s) =>
                                      cfgCtl.setParallel(s.first),
                                ),
                              ),
                            const SizedBox(height: 8),
                            const Text(
                                'Con series conviene más de una, pero 3 a la vez puede saturar el Wi-Fi.',
                                style: TextStyle(
                                    fontSize: 12,
                                    height: 1.3,
                                    color: Colors.white38)),
                          ]),
                    ),
                    _Tile(
                      icon: Icons.sync_rounded,
                      title: 'Reanudar solas',
                      subtitle:
                          'Las descargas interrumpidas continúan cuando el servidor vuelve a estar encendido.',
                      trailing: Switch(
                          value: cfg.autoResumeDownloads,
                          activeColor: Colors.white,
                          activeTrackColor: _red,
                          onChanged: cfgCtl.setAutoResume),
                      onTap: () =>
                          cfgCtl.setAutoResume(!cfg.autoResumeDownloads),
                    ),
                    _Tile(
                      icon: Icons.done_all_rounded,
                      title: 'Eliminar lo ya visto',
                      subtitle: seen.isEmpty
                          ? 'No hay descargas vistas.'
                          : 'Libera ${fmtBytes(downloadsUsedBytes(seen))} (${seen.length} '
                              '${seen.length == 1 ? 'descarga' : 'descargas'}).',
                      enabled: seen.isNotEmpty,
                      onTap: () => confirmDeleteSeen(context, ref),
                    ),
                    _Tile(
                      icon: Icons.delete_sweep_outlined,
                      color: Colors.redAccent,
                      title: 'Eliminar todas las descargas',
                      enabled: dls.isNotEmpty,
                      onTap: () => confirmDeleteAll(context, ref),
                    ),
                  ]),

                  // ---------------- Actualización ----------------
                  const _Section('Actualización'),
                  const _Group(children: [_UpdateTile()]),

                  // ---------------- Acerca de ----------------
                  const _Section('Acerca de'),
                  const _Group(children: [
                    _Tile(
                      icon: Icons.info_outline_rounded,
                      title: 'Lumen',
                      subtitle: 'Cliente para tu servidor en la red local.',
                    ),
                  ]),
                ])),
      ),
    );
  }
}

/// En TV centra el contenido con un ancho máximo; en el resto no hace nada.
class _TvColumn extends StatelessWidget {
  const _TvColumn({required this.tv, required this.child});
  final bool tv;
  final Widget child;

  @override
  Widget build(BuildContext context) => tv
      ? Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900), child: child))
      : child;
}

/// Aro blanco alrededor de una fila al enfocarla con el mando (solo en TV y navegando con
/// teclas: con el dedo no sale). El `radius` debe ser el del elemento de dentro (el mismo que le
/// des al `InkWell`), para que el aro y el velo de foco coincidan exactamente con su contorno.
class _FocusFrame extends StatefulWidget {
  const _FocusFrame({required this.tv, required this.builder, this.radius = 0});
  final bool tv;
  final double radius;
  final Widget Function(ValueChanged<bool> onFocusChange) builder;

  @override
  State<_FocusFrame> createState() => _FocusFrameState();
}

class _FocusFrameState extends State<_FocusFrame> {
  bool _focused = false;

  void _onFocus(bool v) {
    if (mounted && v != _focused) setState(() => _focused = v);
    // En TV, la fila enfocada se centra en pantalla con una animación suave (si no, la lista
    // solo se mueve lo justo y la selección acaba pegada al borde de arriba o de abajo).
    if (v &&
        widget.tv &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Scrollable.ensureVisible(context,
            alignment: 0.5, duration: kFocusDuration, curve: kFocusCurve);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ring = widget.tv &&
        _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    return AnimatedContainer(
      duration: kFocusDuration,
      curve: kFocusCurve,
      foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          border: Border.all(
              color: ring ? kFocusRing : Colors.transparent,
              width: kFocusWidth)),
      child: widget.builder(_onFocus),
    );
  }
}

/// Selector de opciones para TV (sustituye al SegmentedButton, cuyo aro quedaba tapado por los
/// segmentos vecinos y con las esquinas de cada segmento). Pista redondeada (radio 24) con
/// segmentos de 40 px (radio 20 = 24 − 4 de margen): cada aro coincide con su segmento.
class _TvSegments extends StatelessWidget {
  const _TvSegments(
      {required this.values, required this.selected, required this.onChanged});
  final List<int> values;
  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final seg = BorderRadius.circular(20);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
          color: const Color(0x12FFFFFF),
          borderRadius: BorderRadius.circular(24)),
      child: Row(children: [
        for (final v in values)
          Expanded(
            child: _FocusFrame(
              tv: true,
              radius: 20,
              builder: (onFocus) => AnimatedContainer(
                duration: kFocusDuration,
                curve: kFocusCurve,
                decoration: BoxDecoration(
                    color: v == selected ? _red : Colors.transparent,
                    borderRadius: seg),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: seg,
                    focusColor: const Color(0x1AFFFFFF),
                    onFocusChange: onFocus,
                    onTap: () => onChanged(v),
                    child: SizedBox(
                      height: 40,
                      child: Center(
                        child: Text('$v',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: v == selected
                                    ? Colors.white
                                    : Colors.white70)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Título de sección: barrita roja + texto en mayúsculas pequeñas.
class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 30, 16, 10),
        child: Row(children: [
          Container(
              width: 3,
              height: 13,
              decoration: BoxDecoration(
                  color: _red, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 9),
          Text(title.toUpperCase(),
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.8)),
        ]),
      );
}

/// Tarjeta redondeada que agrupa filas, con una línea fina entre ellas.
///
/// En TV cada fila se enfoca como una "placa" redondeada metida 6 px dentro de la tarjeta (radio
/// 12 = 18 de la tarjeta − 6 de margen: curvas concéntricas). Así el aro nunca se corta contra el
/// borde de la tarjeta y sigue el contorno de la fila también en la primera y la última.
class _Group extends ConsumerWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tv = ref.watch(tvModeProvider);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Padding(
            padding: EdgeInsets.only(left: tv ? 72 : 66, right: tv ? 6 : 0),
            child: const Divider(height: 0.5, thickness: 0.5, color: _hair)));
      }
      rows.add(children[i]);
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _hair, width: 0.8)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child:
            Material(color: Colors.transparent, child: Column(children: rows)),
      ),
    );
  }
}

/// Una fila: icono en recuadro, título, subtítulo y (opcional) control a la derecha.
class _Tile extends StatelessWidget {
  const _Tile(
      {required this.icon,
      required this.title,
      this.subtitle,
      this.body,
      this.onTap,
      this.trailing,
      this.enabled = true,
      this.chevron = false,
      this.color});
  final IconData icon;
  final String title;
  final String? subtitle;

  /// Contenido extra bajo el título (p. ej. un selector).
  final Widget? body;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool enabled, chevron;

  /// Color de acento de la fila (rojo para acciones destructivas).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? Colors.white;
    return Consumer(builder: (context, ref, _) {
      final tv = ref.watch(tvModeProvider);
      // TV: placa de 12 px de radio con 6 px de margen; móvil: fila a todo el ancho como siempre.
      final r = BorderRadius.circular(tv ? 12 : 0);
      return Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Padding(
            padding: EdgeInsets.all(tv ? 6 : 0),
            child: _FocusFrame(
              tv: tv,
              radius: tv ? 12 : 0,
              builder: (onFocus) => InkWell(
                borderRadius: r,
                focusColor: tv ? const Color(0x1AFFFFFF) : Colors.white12,
                onFocusChange: onFocus,
                onTap: enabled ? onTap : null,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: 16, vertical: tv ? 10 : 12),
                  child: Row(
                      // Con selector debajo, el icono se alinea con el título (no con el centro).
                      crossAxisAlignment: body != null
                          ? CrossAxisAlignment.start
                          : CrossAxisAlignment.center,
                      children: [
                        Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                                color: accent.withOpacity(0.09),
                                borderRadius: BorderRadius.circular(10)),
                            child: Icon(icon,
                                size: 20, color: color ?? Colors.white70)),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title,
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: color)),
                                if (subtitle != null)
                                  Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(subtitle!,
                                          style: const TextStyle(
                                              fontSize: 12.5,
                                              height: 1.3,
                                              color: Colors.white54))),
                                if (body != null) body!,
                              ]),
                        ),
                        if (trailing != null) ...[
                          const SizedBox(width: 10),
                          // En TV la fila entera es la parada de foco: el interruptor no lo es aparte
                          // (si no, haría falta pulsar ▶ y OK en vez de solo OK).
                          tv ? ExcludeFocus(child: trailing!) : trailing!,
                        ] else if (chevron && onTap != null) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.chevron_right_rounded,
                              color: Colors.white30, size: 22),
                        ],
                      ]),
                ),
              ),
            )),
      );
    });
  }
}

/// Tarjeta del perfil activo: avatar grande, nombre y estado del PIN.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard(
      {required this.avatar,
      required this.name,
      required this.detail,
      required this.enabled,
      required this.onTap});
  final Widget avatar;
  final String name, detail;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(20);
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: _hair, width: 0.8),
            gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF2A2A30), Color(0xFF1B1B1F)])),
        child: Material(
          color: Colors.transparent,
          child: _FocusFrame(
              tv: ProviderScope.containerOf(context).read(tvModeProvider),
              radius: 20,
              builder: (onFocus) => InkWell(
                    onFocusChange: onFocus,
                    borderRadius: radius,
                    focusColor: Colors.white12,
                    onTap: enabled ? onTap : null,
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Row(children: [
                        avatar,
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -0.2)),
                                const SizedBox(height: 3),
                                Row(children: [
                                  Icon(
                                      detail == 'Sin PIN'
                                          ? Icons.lock_open_rounded
                                          : Icons.lock_rounded,
                                      size: 13,
                                      color: Colors.white38),
                                  const SizedBox(width: 5),
                                  Text(detail,
                                      style: const TextStyle(
                                          fontSize: 12.5,
                                          color: Colors.white54)),
                                ]),
                              ]),
                        ),
                        const Text('Cambiar',
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.white54)),
                        const Icon(Icons.chevron_right_rounded,
                            color: Colors.white30, size: 22),
                      ]),
                    ),
                  )),
        ),
      ),
    );
  }
}

/// Estado de la versión instalada frente a la del servidor, con botón para comprobar/instalar.
class _UpdateTile extends ConsumerWidget {
  const _UpdateTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = ref.watch(updaterProvider);
    if (u.stage == UpdateStage.unsupported) {
      return const _Tile(
          icon: Icons.system_update_rounded,
          title: 'Actualización automática',
          subtitle: 'Solo disponible en Android.');
    }
    final info = u.info;
    final newer = u.hasUpdate && info != null;
    final sub = switch (u.stage) {
      UpdateStage.checking => 'Comprobando…',
      _ when newer =>
        'Hay una versión nueva: ${info.versionName} (tienes ${u.installedName})',
      UpdateStage.upToDate => 'Estás al día (${u.installedName})',
      _ => u.installedName.isEmpty
          ? 'Sin comprobar (necesita conexión con el servidor)'
          : 'Versión ${u.installedName}. No se pudo comprobar con el servidor.',
    };
    return _Tile(
      icon: newer
          ? Icons.system_update_rounded
          : Icons.check_circle_outline_rounded,
      color: newer ? _red : null,
      title: newer ? 'Actualizar la app' : 'Buscar actualizaciones',
      subtitle: sub,
      enabled: u.stage != UpdateStage.checking,
      onTap: () async {
        final n = ref.read(updaterProvider.notifier);
        if (!newer) await n.check();
        if (!context.mounted) return;
        final s = ref.read(updaterProvider);
        if (s.hasUpdate) {
          showUpdateDialog(context);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(s.stage == UpdateStage.upToDate
                  ? 'Ya tienes la última versión.'
                  : 'No se pudo comprobar con el servidor.')));
        }
      },
    );
  }
}
