import 'package:dio/dio.dart' show DioException;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import 'api.dart';
import 'book_playback.dart';
import 'core.dart';
import 'downloads.dart' show confirmAction, downloadsProvider;
import 'peticiones.dart' show requestsProvider;
import 'progress_sync.dart';
import 'remote.dart';
import 'sounds.dart';
import 'tv.dart'
    show
        TvFocusable,
        TvFocusBuilder,
        TvFocusRing,
        TvTextEntry,
        kFocusCurve,
        kFocusDuration,
        kFocusRing,
        kFocusWidth,
        tvModeProvider;

// ===========================================================================
//  Perfiles de usuario (¿quién está viendo?)
//  - Cada perfil tiene un nombre de usuario (el identificador), un avatar elegido entre
//    los .jpg que el dueño deja en la carpeta del servidor y un PIN opcional de 4 dígitos.
//  - El progreso, el "Continuar viendo" y las peticiones pertenecen al perfil.
//  - Ojo: nada que ver con el "perfil" de una película (la ficha de TMDB).
// ===========================================================================

const _bg = Color(0xFF141414);
const _red = Color(0xFFE50914);

/// Perfil cuyo PIN ya se comprobó en esta ejecución de la app. Si el perfil activo tiene PIN
/// y no coincide, se pide el PIN al abrir la app.
class UnlockedProfileNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? key) => state = key;
}

final unlockedProfileProvider =
    NotifierProvider<UnlockedProfileNotifier, String?>(
        UnlockedProfileNotifier.new);

/// Perfiles del servidor y el que usa este dispositivo. null = el servidor no tiene perfiles
/// (versión anterior) o no responde: en ese caso no se pide elegir perfil.
final profilesProvider = FutureProvider.autoDispose<ProfilesData?>((ref) async {
  final api = ref.watch(apiProvider);
  if (api == null) return null;
  try {
    final d = await api.profiles();
    // Se recuerda el nombre para poder firmar peticiones aunque el servidor se apague.
    final prefs = ref.read(prefsProvider);
    final cur = d.currentProfile;
    if (cur != null) {
      await prefs.setString('profile_username', cur.username);
    } else {
      await prefs.remove('profile_username');
    }
    return d;
  } on DioException catch (e) {
    if (e.response?.statusCode == 401) {
      Future.microtask(() => ref.read(sessionProvider.notifier).clear());
    }
    return null;
  }
});

/// Avatares (.jpg) disponibles en la carpeta del servidor.
final avatarsProvider =
    FutureProvider.autoDispose<List<AvatarInfo>>((ref) async {
  final api = ref.watch(apiProvider);
  if (api == null) return [];
  return api.avatars();
});

/// Tras cambiar de perfil (o crear uno): recuerda el cambio y recarga todo lo que depende
/// del perfil. El progreso local de las descargas solo se reinicia si de verdad cambió de
/// persona (así no se pierde lo pendiente al desbloquear el mismo perfil).
void _afterProfileChange(WidgetRef ref, UserProfile p) {
  final prev = ref.read(profilesProvider).valueOrNull?.current;
  final changed = prev != null && normalizeUsername(prev) != p.key;
  ref.read(unlockedProfileProvider.notifier).set(p.key);
  ref.read(prefsProvider).setString('profile_username', p.username);
  if (changed) {
    BookPlayback.stop();
    ref.read(downloadsProvider.notifier).resetProgressLocal();
  }
  ref.invalidate(profilesProvider);
  ref.invalidate(libraryProvider);
  ref.invalidate(showsProvider);
  ref.invalidate(requestsProvider);
}

/// Este dispositivo pasa a actuar como [u]. Antes sube al perfil anterior el progreso
/// que tuviera pendiente. Lanza si el PIN es incorrecto o no hay conexión.
Future<void> switchProfile(WidgetRef ref, UserProfile u, {String? pin}) async {
  final api = ref.read(apiProvider);
  if (api == null) throw StateError('Sin sesión');
  await ref.read(downloadsProvider.notifier).syncProgress();
  // Lo pendiente se sube mientras el perfil activo en el servidor sigue siendo el actual:
  // si se subiera después del cambio acabaría en el perfil nuevo.
  await ref.read(progressSyncProvider).flushNow();
  final p = await api.selectProfile(u.username, pin: pin);
  _afterProfileChange(ref, p);
}

/// Solo se usa para errores: suena el aviso.
void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(errorSnack(text));

// ---------------------------------------------------------------------------
//  Avatar
// ---------------------------------------------------------------------------

/// Avatar redondo del perfil. Sin avatar (o si no carga) muestra su inicial sobre un color
/// que sale del nombre.
class AvatarCircle extends StatelessWidget {
  const AvatarCircle(
      {super.key, required this.api, required this.profile, this.radius = 24});
  final Api? api;
  final UserProfile profile;
  final double radius;

  static Color colorFor(String name) {
    var h = 0;
    for (final c in name.toLowerCase().codeUnits) {
      h = (h * 31 + c) & 0xFFFFFF;
    }
    return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.45, 0.32).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final id = profile.avatar;
    final a = api;
    final hasImage = id != null && a != null;
    return CircleAvatar(
      radius: radius,
      backgroundColor: colorFor(profile.username),
      foregroundImage: hasImage
          ? ResizeImage(
              NetworkImage(a.avatarUrl(id, profile.avatarV),
                  headers: a.authHeaders),
              width: (radius * 6).round().clamp(64, 512).toInt())
          : null,
      onForegroundImageError: hasImage ? (_, __) {} : null,
      child: Text(profile.initial,
          style: TextStyle(
              fontSize: radius * 0.95,
              fontWeight: FontWeight.w700,
              color: Colors.white)),
    );
  }
}

/// Avatar de la barra superior: abre el selector para cambiar de perfil.
/// No aparece si el servidor no tiene perfiles o está apagado.
class ProfileButton extends ConsumerWidget {
  const ProfileButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiProvider);
    final cur = ref.watch(profilesProvider).valueOrNull?.currentProfile;
    if (api == null || cur == null || ref.watch(serverOfflineProvider)) {
      return const SizedBox.shrink();
    }
    return IconButton(
      tooltip: 'Cambiar de perfil (${cur.username})',
      icon: AvatarCircle(api: api, profile: cur, radius: 14),
      onPressed: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => const ProfilePickerScreen())),
    );
  }
}

// ---------------------------------------------------------------------------
//  Teclado de PIN
// ---------------------------------------------------------------------------

/// Teclado numérico de [pinLength] dígitos. [onSubmit] recibe el PIN completo y devuelve
/// el mensaje de error, o null si todo fue bien.
class _PinPad extends StatefulWidget {
  const _PinPad({required this.onSubmit});
  final Future<String?> Function(String pin) onSubmit;

  @override
  State<_PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<_PinPad> {
  String _pin = '';
  String? _error;
  bool _busy = false;

  Future<void> _digit(String d) async {
    if (_busy || _pin.length >= pinLength) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length < pinLength) return;
    setState(() => _busy = true);
    final err = await widget.onSubmit(_pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (err != null) {
        _error = err;
        _pin = '';
      }
    });
  }

  void _back() {
    if (_busy || _pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _error = null;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final ch = e.character;
    if (ch != null && ch.length == 1 && '0123456789'.contains(ch)) {
      _digit(ch);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.backspace) {
      _back();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _key(String label,
      {VoidCallback? onTap, IconData? icon, bool autofocus = false}) {
    // En TV las teclas son más grandes (se pulsan con el mando) y la enfocada se aclara; el aro
    // blanco lo pone el tema y, al ser el botón un círculo, lo sigue exacto.
    final tv = ProviderScope.containerOf(context).read(tvModeProvider);
    final size = tv ? 76.0 : 64.0;
    return Padding(
      padding: const EdgeInsets.all(6),
      child: SizedBox(
        width: size,
        height: size,
        child: onTap == null
            ? null
            : TextButton(
                autofocus: autofocus,
                style: TextButton.styleFrom(
                        shape: const CircleBorder(),
                        backgroundColor: Colors.white10,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.zero)
                    .copyWith(
                        backgroundColor: WidgetStateProperty.resolveWith((s) =>
                            s.contains(WidgetState.focused)
                                ? Colors.white24
                                : Colors.white10)),
                onPressed: _busy ? null : onTap,
                child: icon != null
                    ? Icon(icon, size: tv ? 28 : 24)
                    : Text(label,
                        style: TextStyle(
                            fontSize: tv ? 28 : 24,
                            fontWeight: FontWeight.w600)),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // En TV el foco empieza en el 5 y las flechas del mando se mueven entre las teclas; este
    // Focus solo recoge las cifras del mando (mandos con teclado numérico) y la tecla de borrar.
    final tv = ProviderScope.containerOf(context).read(tvModeProvider);
    return Focus(
      autofocus: !tv,
      canRequestFocus: !tv,
      skipTraversal: tv,
      onKeyEvent: _onKey,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (var i = 0; i < pinLength; i++)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < _pin.length ? Colors.white : Colors.transparent,
                border: Border.all(color: Colors.white54, width: 2),
              ),
            ),
        ]),
        SizedBox(
          height: 44,
          child: Center(
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(_error ?? '',
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ),
        ),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9']
        ])
          Row(mainAxisSize: MainAxisSize.min, children: [
            for (final d in row)
              _key(d, onTap: () => _digit(d), autofocus: tv && d == '5'),
          ]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          _key(''),
          _key('0', onTap: () => _digit('0')),
          _key('', icon: Icons.backspace_outlined, onTap: _back),
        ]),
      ]),
    );
  }
}

/// Pide un PIN en un diálogo. Con [validate] se comprueba antes de cerrar (devuelve el
/// mensaje de error o null si es válido). Devuelve el PIN aceptado, o null si se cancela.
Future<String?> showPinPad(BuildContext context,
    {required String title,
    String? subtitle,
    Future<String?> Function(String pin)? validate}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: const Color(0xFF1F1F1F),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(title,
                  textAlign: TextAlign.center,
                  style: Theme.of(ctx).textTheme.titleMedium),
              if (subtitle != null)
                Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(subtitle,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 13))),
              const SizedBox(height: 16),
              _PinPad(onSubmit: (pin) async {
                final err = validate == null ? null : await validate(pin);
                if (err == null && ctx.mounted) Navigator.pop(ctx, pin);
                return err;
              }),
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancelar')),
            ]),
          ),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
//  ¿Quién está viendo?
// ---------------------------------------------------------------------------

/// Selector de perfil estilo Netflix. Sin perfil activo hace de pantalla de entrada
/// ([dismissible] = false); abierto desde la barra permite cambiar de perfil o administrarlos.
class ProfilePickerScreen extends ConsumerStatefulWidget {
  const ProfilePickerScreen({super.key, this.dismissible = true});
  final bool dismissible;

  @override
  ConsumerState<ProfilePickerScreen> createState() => _ProfilePickerState();
}

class _ProfilePickerState extends ConsumerState<ProfilePickerScreen> {
  bool _manage = false;
  String? _busyKey;

  void _done() {
    if (mounted && Navigator.canPop(context)) Navigator.pop(context);
  }

  Future<void> _choose(UserProfile u) async {
    if (_manage) {
      await Navigator.push(context,
          MaterialPageRoute(builder: (_) => ProfileEditScreen(profile: u)));
      return;
    }
    if (u.hasPin) {
      final ok = await showPinPad(context, title: 'PIN de ${u.username}',
          validate: (pin) async {
        try {
          await switchProfile(ref, u, pin: pin);
          return null;
        } catch (e) {
          return errText(e);
        }
      });
      if (ok != null) _done();
      return;
    }
    setState(() => _busyKey = u.key);
    try {
      await switchProfile(ref, u);
      _done();
    } catch (e) {
      if (mounted) _snack(context, errText(e));
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Future<void> _add() async {
    final created = await Navigator.push<bool>(
        context, MaterialPageRoute(builder: (_) => const ProfileEditScreen()));
    if (created == true) _done();
  }

  /// Una opción del selector en TV: el aro rodea EL AVATAR (círculo concéntrico, 4 px de hueco),
  /// no el rectángulo de la ficha entera. El perfil activo lleva un aro tenue en reposo; con el
  /// foco el aro es blanco, el conjunto crece un poco y el nombre se enciende.
  Widget _tvTile(
      {required bool focused,
      required Widget disc,
      required String label,
      bool current = false,
      List<Widget> overlays = const []}) {
    return AnimatedScale(
      scale: focused ? 1.06 : 1,
      duration: kFocusDuration,
      curve: kFocusCurve,
      child: SizedBox(
        width: 112,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: kFocusDuration,
            curve: kFocusCurve,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: focused
                      ? kFocusRing
                      : (current ? Colors.white38 : Colors.transparent),
                  width: kFocusWidth),
            ),
            child: Stack(alignment: Alignment.center, children: [disc, ...overlays]),
          ),
          const SizedBox(height: 8),
          AnimatedDefaultTextStyle(
            duration: kFocusDuration,
            curve: kFocusCurve,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 15,
                fontWeight: focused || current ? FontWeight.w700 : FontWeight.w500,
                color: focused ? Colors.white : Colors.white70),
            child: Text(label),
          ),
        ]),
      ),
    );
  }

  Widget _tile(Api? api, UserProfile u, bool isCurrent,
      {bool autofocus = false}) {
    final busy = _busyKey == u.key;
    if (ref.read(tvModeProvider)) {
      return TvFocusBuilder(
        autofocus: autofocus,
        onTap: _busyKey == null ? () => _choose(u) : null,
        builder: (_, f) => _tvTile(
          focused: f,
          current: isCurrent && !_manage,
          label: u.username,
          disc: AvatarCircle(api: api, profile: u, radius: 46),
          overlays: [
            if (_manage)
              const CircleAvatar(
                  radius: 46,
                  backgroundColor: Colors.black54,
                  child: Icon(Icons.edit, size: 30, color: Colors.white)),
            if (busy) const CircularProgressIndicator(),
            if (u.hasPin && !_manage)
              const Positioned(
                  right: 0,
                  bottom: 0,
                  child: CircleAvatar(
                      radius: 12,
                      backgroundColor: Colors.black87,
                      child: Icon(Icons.lock, size: 14, color: Colors.white))),
          ],
        ),
      );
    }
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _busyKey == null ? () => _choose(u) : null,
      child: SizedBox(
        width: 112,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Stack(alignment: Alignment.center, children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: isCurrent && !_manage
                        ? Colors.white
                        : Colors.transparent,
                    width: 3),
              ),
              child: AvatarCircle(api: api, profile: u, radius: 46),
            ),
            if (_manage)
              const CircleAvatar(
                  radius: 46,
                  backgroundColor: Colors.black54,
                  child: Icon(Icons.edit, size: 30, color: Colors.white)),
            if (busy) const CircularProgressIndicator(),
            if (u.hasPin && !_manage)
              const Positioned(
                  right: 4,
                  bottom: 4,
                  child: CircleAvatar(
                      radius: 12,
                      backgroundColor: Colors.black87,
                      child: Icon(Icons.lock, size: 14, color: Colors.white))),
          ]),
          const SizedBox(height: 8),
          Text(u.username,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500)),
        ]),
      ),
    );
  }

  Widget _addTile({bool autofocus = false}) => ref.read(tvModeProvider)
      ? TvFocusBuilder(
          autofocus: autofocus,
          onTap: _busyKey == null ? _add : null,
          builder: (_, f) => _tvTile(
            focused: f,
            label: 'Añadir perfil',
            disc: const CircleAvatar(
                radius: 46,
                backgroundColor: Colors.white10,
                child: Icon(Icons.add, size: 40, color: Colors.white70)),
          ),
        )
      : InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _busyKey == null ? _add : null,
        child: const SizedBox(
          width: 112,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircleAvatar(
                radius: 52,
                backgroundColor: Colors.white10,
                child: Icon(Icons.add, size: 44, color: Colors.white70)),
            SizedBox(height: 8),
            Text('Añadir perfil', style: TextStyle(fontSize: 15)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(apiProvider);
    final data = ref.watch(profilesProvider).valueOrNull;
    final empty = data != null && data.items.isEmpty;
    final tv = ref.watch(tvModeProvider);
    // TV: el foco empieza en el perfil activo (o en el primero), no en el aire.
    final focusKey = data?.currentProfile?.key ?? data?.items.firstOrNull?.key;
    final title = _manage
        ? 'Administrar perfiles'
        : empty
            ? 'Crea tu perfil'
            : '¿Quién está viendo?';
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
          backgroundColor: _bg, automaticallyImplyLeading: widget.dismissible),
      body: data == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  if (empty)
                    const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                            'Elige un nombre de usuario y, si quieres, un avatar y un PIN.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white60))),
                  const SizedBox(height: 32),
                  Wrap(
                    spacing: tv ? 32 : 24,
                    runSpacing: tv ? 32 : 24,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final u in data.items)
                        _tile(api, u, data.currentProfile?.key == u.key,
                            autofocus: tv && u.key == focusKey),
                      if (data.items.length < data.max)
                        _addTile(autofocus: tv && data.items.isEmpty),
                    ],
                  ),
                  const SizedBox(height: 40),
                  if (data.items.isNotEmpty)
                    OutlinedButton(
                        onPressed: () => setState(() => _manage = !_manage),
                        child:
                            Text(_manage ? 'Listo' : 'Administrar perfiles')),
                ]),
              ),
            ),
    );
  }
}

/// Pantalla de entrada cuando el perfil activo tiene PIN y aún no se desbloqueó en esta
/// ejecución de la app.
class ProfileLockScreen extends ConsumerWidget {
  const ProfileLockScreen({super.key, required this.profile});
  final UserProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiProvider);
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                AvatarCircle(api: api, profile: profile, radius: 48),
                const SizedBox(height: 12),
                Text(profile.username,
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                const Text('Introduce tu PIN',
                    style: TextStyle(color: Colors.white60)),
                const SizedBox(height: 20),
                _PinPad(onSubmit: (pin) async {
                  try {
                    await switchProfile(ref, profile, pin: pin);
                    return null;
                  } catch (e) {
                    return errText(e);
                  }
                }),
                const SizedBox(height: 8),
                TextButton(
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ProfilePickerScreen())),
                    child: const Text('Cambiar de perfil')),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  Crear y editar perfil
// ---------------------------------------------------------------------------

/// Crea un perfil ([profile] = null) o edita uno: avatar, PIN y borrado. El nombre de
/// usuario es el identificador y no se puede cambiar después. Al guardar cierra devolviendo true.
class ProfileEditScreen extends ConsumerStatefulWidget {
  const ProfileEditScreen({super.key, this.profile});
  final UserProfile? profile;

  @override
  ConsumerState<ProfileEditScreen> createState() => _ProfileEditState();
}

class _ProfileEditState extends ConsumerState<ProfileEditScreen> {
  late final _name =
      TextEditingController(text: widget.profile?.username ?? '');
  String? _avatar;
  String? _newPin;
  bool _removePin = false;
  final _avatarKey = GlobalKey(); // para saltar a la sección de avatares
  bool _importProgress = true;
  bool _busy = false;
  String? _error;

  bool get _creating => widget.profile == null;

  @override
  void initState() {
    super.initState();
    _avatar = widget.profile?.avatar;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String? _nameError(ProfilesData? data) {
    final t = _name.text;
    if (!_creating || t.isEmpty) return null;
    final bad = validateUsername(t);
    if (bad != null) return bad;
    final k = normalizeUsername(t);
    if (data != null && data.items.any((p) => p.key == k)) {
      return 'Ese nombre de usuario ya existe.';
    }
    return null;
  }

  bool _changed() {
    final p = widget.profile;
    if (p == null) return true;
    return _avatar != p.avatar || _newPin != null || _removePin;
  }

  Future<String?> _askNewPin() async {
    final a = await showPinPad(context,
        title: 'Elige un PIN', subtitle: '$pinLength dígitos');
    if (a == null || !mounted) return null;
    final b = await showPinPad(context,
        title: 'Repite el PIN',
        validate: (pin) async => pin == a ? null : 'Los PIN no coinciden.');
    return b == null ? null : a;
  }

  /// Guarda en el servidor. Devuelve el mensaje de error, o null si salió bien.
  Future<String?> _save(String? currentPin) async {
    final api = ref.read(apiProvider);
    if (api == null) return 'Sin sesión';
    final data = ref.read(profilesProvider).valueOrNull;
    try {
      final p = widget.profile;
      if (p == null) {
        final u = await api.createProfile(_name.text.trim(),
            avatar: _avatar,
            pin: _newPin,
            importProgress:
                _importProgress && (data?.hasDeviceProgress ?? false));
        _afterProfileChange(
            ref, u); // el servidor ya usa el perfil nuevo en este dispositivo
      } else {
        await api.updateProfile(p.username,
            setAvatar: _avatar != p.avatar,
            avatar: _avatar,
            pin: _newPin,
            removePin: _removePin,
            currentPin: currentPin);
        ref.invalidate(profilesProvider);
      }
      return null;
    } catch (e) {
      return errText(e);
    }
  }

  Future<void> _onSave() async {
    final p = widget.profile;
    if (p != null && p.hasPin) {
      // El propio guardado sirve de comprobación: si el PIN falla, el teclado lo indica.
      final ok = await showPinPad(context,
          title: 'PIN de ${p.username}',
          subtitle: 'Introduce el PIN actual para guardar los cambios.',
          validate: _save);
      if (ok != null && mounted) Navigator.pop(context, true);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await _save(null);
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  Future<void> _delete() async {
    final p = widget.profile!;
    final api = ref.read(apiProvider);
    if (api == null) return;
    final ok = await confirmAction(
        context,
        'Eliminar perfil',
        'Se borrarán el perfil "${p.username}", su progreso, su "Continuar viendo" y '
            'sus peticiones. No se puede deshacer.',
        'Eliminar');
    if (!ok || !mounted) return;
    Future<String?> run(String? pin) async {
      try {
        await api.deleteProfile(p.username, pin: pin);
        ref.invalidate(profilesProvider);
        ref.invalidate(requestsProvider);
        return null;
      } catch (e) {
        return errText(e);
      }
    }

    if (p.hasPin) {
      final done = await showPinPad(context,
          title: 'PIN de ${p.username}',
          subtitle: 'Introduce el PIN para eliminar el perfil.',
          validate: run);
      if (done != null && mounted) Navigator.pop(context, false);
      return;
    }
    final err = await run(null);
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context, false);
    } else {
      _snack(context, err);
    }
  }

  Widget _avatarGrid(Api? api, UserProfile preview) {
    final av = ref.watch(avatarsProvider);
    return av.when(
      loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator())),
      error: (e, _) =>
          Text(errText(e), style: const TextStyle(color: Colors.redAccent)),
      data: (list) {
        if (list.isEmpty) {
          return const Text(
              'El servidor aún no tiene avatares. Copia archivos .jpg a la carpeta de '
              'avatares del servidor (pestaña Perfiles → "Abrir carpeta de avatares"); '
              'las subcarpetas funcionan como paquetes. Después vuelve a abrir esta pantalla.',
              style: TextStyle(color: Colors.white60));
        }
        final tv = ref.read(tvModeProvider);
        Widget option(String? id, Widget child) {
          final selected = _avatar == id;
          if (tv) {
            // TV: el elegido lleva aro rojo; el enfocado, además, un aro blanco por fuera. Los dos
            // son círculos concéntricos con el avatar.
            return TvFocusBuilder(
              onTap: () => setState(() => _avatar = id),
              builder: (_, f) => AnimatedScale(
                scale: f ? 1.08 : 1,
                duration: kFocusDuration,
                curve: kFocusCurve,
                child: AnimatedContainer(
                  duration: kFocusDuration,
                  curve: kFocusCurve,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: f ? kFocusRing : Colors.transparent,
                        width: kFocusWidth),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: selected ? _red : Colors.transparent,
                          width: 3),
                    ),
                    child: child,
                  ),
                ),
              ),
            );
          }
          return InkWell(
            customBorder: const CircleBorder(),
            onTap: () => setState(() => _avatar = id),
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: selected ? _red : Colors.transparent, width: 3),
              ),
              child: child,
            ),
          );
        }

        // Un bloque por paquete (subcarpeta del servidor), cada uno con su fila que se
        // desliza hacia los lados. Los avatares sueltos van primero.
        final groups = <String, List<AvatarInfo>>{};
        for (final a in list) {
          groups.putIfAbsent(a.pack ?? '', () => []).add(a);
        }
        final hasPacks = groups.keys.any((k) => k.isNotEmpty);
        final firstKey = groups.keys.first;
        final titleStyle = Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(fontWeight: FontWeight.w800);

        Widget noneOption() => option(
            null,
            const CircleAvatar(
                radius: 32,
                backgroundColor: Colors.white10,
                child: Icon(Icons.person_off_outlined, color: Colors.white54)));

        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final e in groups.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 10),
              child: Text(
                  e.key.isEmpty ? (hasPacks ? 'Generales' : 'Avatares') : e.key,
                  style: titleStyle),
            ),
            SizedBox(
              height: tv ? 100 : 84,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                clipBehavior: tv ? Clip.none : Clip.hardEdge,
                itemCount: e.value.length + (e.key == firstKey ? 1 : 0),
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (_, i) {
                  final n = e.key == firstKey ? i - 1 : i;
                  if (n < 0) return Center(child: noneOption());
                  final a = e.value[n];
                  return Center(
                    child: option(
                        a.id,
                        AvatarCircle(
                            api: api,
                            profile: UserProfile(preview.username,
                                avatar: a.id, avatarV: a.v),
                            radius: 32)),
                  );
                },
              ),
            ),
          ],
        ]);
      },
    );
  }

  /// Papelera a la derecha del panel del PIN, de su misma altura.
  Widget _deleteButton() => Tooltip(
        message: 'Eliminar perfil',
        child: ref.read(tvModeProvider)
            // TV: el aro (radio 16) lo pone TvFocusable y coincide con la forma del botón.
            ? TvFocusable(
                borderRadius: 16,
                scale: 1,
                onTap: _busy ? null : _delete,
                child: Material(
                  color: Colors.redAccent.withOpacity(0.10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: Colors.redAccent.withOpacity(0.35)),
                  ),
                  child: SizedBox(
                    width: 58,
                    child: Center(
                      child: Icon(Icons.delete_outline_rounded,
                          size: 26,
                          color: _busy ? Colors.white24 : Colors.redAccent),
                    ),
                  ),
                ),
              )
            : Material(
          color: Colors.redAccent.withOpacity(0.10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.redAccent.withOpacity(0.35)),
          ),
          child: InkWell(
            customBorder:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            onTap: _busy ? null : _delete,
            child: SizedBox(
              width: 58,
              child: Center(
                child: Icon(Icons.delete_outline_rounded,
                    size: 26, color: _busy ? Colors.white24 : Colors.redAccent),
              ),
            ),
          ),
        ),
      );

  /// Tarjeta de seguridad: estado del PIN y sus acciones, siempre a la vista.
  Widget _pinSection(UserProfile? p) {
    final has = p?.hasPin ?? false;
    final String title, status;
    final bool active;
    if (_removePin) {
      active = false;
      title = 'PIN desactivado';
      status = 'Se quitará al guardar.';
    } else if (_newPin != null) {
      active = true;
      title = 'PIN activado';
      status =
          has ? 'Nuevo PIN listo para guardar.' : 'PIN listo para guardar.';
    } else if (has) {
      active = true;
      title = 'PIN activado';
      status = 'Se te pedirá el PIN actual al guardar.';
    } else {
      active = false;
      title = 'Sin PIN';
      status = 'Cualquiera puede entrar a este perfil.';
    }
    final accent = active ? _red : Colors.white38;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withOpacity(active ? 0.16 : 0.12)),
            child: Icon(active ? Icons.lock_rounded : Icons.lock_open_rounded,
                size: 22, color: accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(status,
                  style:
                      const TextStyle(color: Colors.white60, fontSize: 12.5)),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
              if (has || _newPin != null)
                TextButton(
                    style:
                        TextButton.styleFrom(foregroundColor: Colors.white60),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              _newPin = null;
                              _removePin = has && !_removePin;
                            }),
                    child: Text(_removePin
                        ? 'Mantener PIN'
                        : (has ? 'Quitar PIN' : 'Descartar'))),
              FilledButton.tonalIcon(
                  icon: const Icon(Icons.pin_outlined, size: 18),
                  label: Text(
                      has || _newPin != null ? 'Cambiar PIN' : 'Añadir PIN'),
                  onPressed: _busy
                      ? null
                      : () async {
                          final pin = await _askNewPin();
                          if (pin != null && mounted) {
                            setState(() {
                              _newPin = pin;
                              _removePin = false;
                            });
                          }
                        }),
            ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(apiProvider);
    final data = ref.watch(profilesProvider).valueOrNull;
    final tv = ref.watch(tvModeProvider);
    final p = widget.profile;
    final nameErr = _nameError(data);
    final canSave = !_busy &&
        _changed() &&
        (!_creating ||
            (_name.text.trim().isNotEmpty &&
                nameErr == null &&
                validateUsername(_name.text) == null));
    final preview = UserProfile(
        _name.text.trim().isEmpty ? '?' : _name.text.trim(),
        avatar: _avatar,
        avatarV: ref
                .watch(avatarsProvider)
                .valueOrNull
                ?.where((a) => a.id == _avatar)
                .map((a) => a.v)
                .firstOrNull ??
            0);
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: Text(_creating ? 'Nuevo perfil' : 'Editar perfil'),
        actions: [
          TextButton(
              onPressed: canSave ? _onSave : null,
              child: Text(_creating ? 'Crear' : 'Guardar')),
        ],
      ),
      body: _tvColumn(tv, ListView(padding: EdgeInsets.all(tv ? 28 : 20), children: [
        // Cabecera: avatar actual (al tocarlo salta a la lista de avatares) y nombre.
        Center(
          child: () {
            void jump() {
              final ctx = _avatarKey.currentContext;
              if (ctx != null) {
                Scrollable.ensureVisible(ctx,
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeOutCubic);
              }
            }

            final head = Stack(children: [
              AvatarCircle(api: api, profile: preview, radius: 56),
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                      color: _red,
                      shape: BoxShape.circle,
                      border: Border.all(color: _bg, width: 3)),
                  child: const Icon(Icons.edit, size: 16, color: Colors.white),
                ),
              ),
            ]);
            if (!tv) {
              return InkWell(
                  customBorder: const CircleBorder(), onTap: jump, child: head);
            }
            // TV: aro circular concéntrico con el avatar (4 px de hueco), como en el selector.
            return TvFocusBuilder(
              onTap: jump,
              builder: (_, f) => AnimatedScale(
                scale: f ? 1.04 : 1,
                duration: kFocusDuration,
                curve: kFocusCurve,
                child: AnimatedContainer(
                  duration: kFocusDuration,
                  curve: kFocusCurve,
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: f ? kFocusRing : Colors.transparent,
                        width: kFocusWidth),
                  ),
                  child: head,
                ),
              ),
            );
          }(),
        ),
        const SizedBox(height: 24),
        // TV: el campo no lleva etiqueta flotante, ayuda ni contador dentro (harían el recuadro
        // del aro más alto que el contorno del campo): la etiqueta va encima y la ayuda debajo.
        if (tv)
          const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 8),
              child: Text('Nombre de usuario',
                  style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600))),
        TvTextEntry(
            borderRadius: 12,
            child: TextField(
          controller: _name,
          enabled: _creating && !_busy,
          maxLength: usernameMaxLength,
          autocorrect: false,
          textInputAction: TextInputAction.done,
          inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
          decoration: InputDecoration(
            labelText: tv ? null : 'Nombre de usuario',
            hintText: tv ? 'Escribe un nombre de usuario' : null,
            hintStyle: const TextStyle(color: Colors.white38),
            counterText: tv ? '' : null,
            helperText: tv
                ? null
                : (_creating
                    ? 'Es tu identificador y no se podrá cambiar después.'
                    : 'Es tu identificador y no se puede cambiar.'),
            errorText: tv ? null : nameErr,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(tv ? 12 : 4)),
          ),
          onChanged: (_) => setState(() {}),
        )),
        if (tv)
          Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                  nameErr ??
                      (_creating
                          ? 'Es tu identificador y no se podrá cambiar después.'
                          : 'Es tu identificador y no se puede cambiar.'),
                  style: TextStyle(
                      fontSize: 12.5,
                      color: nameErr != null
                          ? Colors.redAccent
                          : Colors.white54))),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: _pinSection(p)),
            if (!_creating) ...[
              const SizedBox(width: 10),
              _deleteButton(),
            ],
          ]),
        ),
        if (_creating && (data?.hasDeviceProgress ?? false)) ...[
          const SizedBox(height: 12),
          TvFocusRing(
            enabled: tv,
            radius: 16,
            // Material con la forma de la tarjeta: el velo de foco queda recortado a sus esquinas
            // (antes el rectángulo del ListTile se salía de ellas).
            child: Material(
            color: const Color(0xFF1C1C1E),
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Colors.white10),
            ),
            child: CheckboxListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              controlAffinity: ListTileControlAffinity.leading,
              value: _importProgress,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _importProgress = v ?? true),
              title:
                  const Text('Traer lo que ya había visto en este dispositivo'),
              subtitle: const Text(
                  'Conserva tu progreso y "Continuar viendo" de antes de que existieran los perfiles.',
                  style: TextStyle(fontSize: 12)),
            ),
          )),
        ],
        if (_error != null)
          Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_error!,
                  style: const TextStyle(color: Colors.redAccent))),
        if (_busy)
          const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Center(child: CircularProgressIndicator())),
        // Los avatares van al final: es la sección que más crece (paquetes y filas).
        const SizedBox(height: 28),
        Divider(color: Colors.white.withOpacity(0.08), height: 1),
        const SizedBox(height: 20),
        Text('Elige un avatar',
            key: _avatarKey, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        _avatarGrid(api, preview),
        const SizedBox(height: 24),
      ])),
    );
  }

  /// En TV el contenido se queda en una columna centrada (si no, el campo y las tarjetas
  /// ocuparían los 1920 px); en móvil no cambia nada.
  Widget _tvColumn(bool tv, Widget child) => tv
      ? Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760), child: child))
      : child;
}
