import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:path/path.dart' as p;
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'avatar_editor.dart';
import 'library_page.dart';

/// Últimas líneas de registro (todo lo que el servidor imprime con print).
final appLog = ValueNotifier<List<String>>(const []);

void _log(String line) {
  final t = DateTime.now().toIso8601String().substring(11, 19);
  final next = [...appLog.value, '$t $line'];
  appLog.value = next.length > 300 ? next.sublist(next.length - 300) : next;
}

void main(List<String> args) {
  runZonedGuarded(
    () => _main(args),
    (e, s) => _log('ERROR: $e'),
    zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) {
      parent.print(zone, line);
      _log(line);
    }),
  );
}

Future<void> _main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  // Notificaciones de Windows. "requireCreate" crea un acceso directo en el menú Inicio,
  // que Windows necesita para mostrar avisos de una app que no está empaquetada (MSIX).
  await localNotifier.setup(
      appName: 'Mi Streaming Server',
      shortcutPolicy: ShortcutPolicy.requireCreate);
  // Al iniciar con Windows se pasa --minimized para arrancar directamente en la bandeja.
  launchAtStartup.setup(
      appName: 'Mi Streaming Server',
      appPath: Platform.resolvedExecutable,
      args: ['--minimized']);
  final prefs = await SharedPreferences.getInstance();
  final minimized = args.contains('--minimized');
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
        size: Size(1280, 780),
        minimumSize: Size(980, 620),
        center: true,
        title: 'Mi Streaming Server'),
    () async {
      if (minimized) {
        await windowManager.hide();
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    },
  );
  await windowManager.setPreventClose(true); // cerrar = minimizar a la bandeja
  runApp(MaterialApp(
    title: 'Mi Streaming Server',
    theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        visualDensity: VisualDensity.compact),
    home: HomePage(prefs: prefs),
  ));
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.prefs});
  final SharedPreferences prefs;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TrayListener, WindowListener {
  MediaServer? _server;
  String _root = '';
  int _port = 8080;
  String _tmdbKey = '';
  bool _autostart = false, _busy = false;
  String? _error;
  int _page = 0; // 0 biblioteca, 1 peticiones, 2 dispositivos, 3 perfiles, 4 ajustes, 5 registro
  String? _selectedId; // película o serie abierta en el editor de carátulas
  List<String> _addresses = [];
  bool _openAccess = true; // conexión automática (sin PIN)
  final _importing = <String>{}; // peticiones que se están copiando a la biblioteca
  StreamSubscription<NewRequestEvent>? _arrivalsSub;
  final _toasts = <LocalNotification>{}; // se guardan mientras estén en pantalla

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    _root = widget.prefs.getString('root') ?? '';
    _port = widget.prefs.getInt('port') ?? 8080;
    _tmdbKey = widget.prefs.getString('tmdbKey') ?? '';
    _openAccess = widget.prefs.getBool('openAccess') ?? true;
    _initTray();
    launchAtStartup.isEnabled().then((v) {
      if (mounted) setState(() => _autostart = v);
    });
    if (_root.isNotEmpty) _start();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    _arrivalsSub?.cancel();
    _server?.stop();
    super.dispose();
  }

  // ---------- bandeja y ventana ----------
  Future<void> _initTray() async {
    await trayManager.setIcon('assets/tray.ico');
    await trayManager.setToolTip('Mi Streaming Server');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: 'Abrir'),
      MenuItem.separator(),
      MenuItem(key: 'exit', label: 'Salir'),
    ]));
  }

  @override
  void onTrayIconMouseDown() => _show();
  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();
  @override
  void onTrayMenuItemClick(MenuItem item) {
    if (item.key == 'show') _show();
    if (item.key == 'exit') _exit();
  }

  @override
  void onWindowClose() => windowManager.hide();

  Future<void> _show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _exit() async {
    await _server?.stop();
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  // ---------- servidor ----------
  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final data = p.join(Platform.environment['APPDATA'] ?? Directory.current.path, 'MiStreaming');
    final server = MediaServer(ServerConfig(
        root: _root,
        port: _port,
        dataDir: data,
        tmdbKey: _tmdbKey,
        openAccess: _openAccess));
    try {
      await server.start();
      _server = server;
      _arrivalsSub?.cancel();
      _arrivalsSub = server.requestArrivals.listen(_notifyRequest);
      _addresses = await MediaServer.localAddresses(_port);
    } catch (e) {
      _error = e is StateError ? e.message : 'No se pudo iniciar: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _stop() async {
    await _arrivalsSub?.cancel();
    _arrivalsSub = null;
    await _server?.stop();
    if (mounted) setState(() => _addresses = []);
  }

  Future<void> _restartIfRunning() async {
    if (_server?.running ?? false) {
      await _stop();
      await _start();
    }
  }

  Future<void> _pickFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    await widget.prefs.setString('root', dir);
    setState(() => _root = dir);
    if (_server?.running ?? false) {
      await _restartIfRunning();
    } else {
      await _start();
    }
  }

  Future<void> _setPort(String v) async {
    final port = int.tryParse(v);
    if (port == null || port < 1024 || port > 65535) return;
    await widget.prefs.setInt('port', port);
    setState(() => _port = port);
    await _restartIfRunning();
  }

  Future<void> _setOpenAccess(bool v) async {
    await widget.prefs.setBool('openAccess', v);
    setState(() => _openAccess = v);
    _server?.setOpenAccess(v); // al instante, sin reiniciar
  }

  Future<void> _setTmdbKey(String v) async {
    await widget.prefs.setString('tmdbKey', v.trim());
    setState(() => _tmdbKey = v.trim());
    await _restartIfRunning();
  }

  Future<void> _toggleAutostart(bool v) async {
    v ? await launchAtStartup.enable() : await launchAtStartup.disable();
    setState(() => _autostart = v);
  }

  /// Crea las reglas de entrada (TCP del API y UDP del descubrimiento); pide permisos de admin.
  Future<void> _openFirewall() async {
    final f = File(p.join(Directory.systemTemp.path, 'mistreaming_fw.cmd'));
    await f.writeAsString('@echo off\r\n'
        'netsh advfirewall firewall delete rule name="Mi Streaming TCP" >nul\r\n'
        'netsh advfirewall firewall delete rule name="Mi Streaming UDP" >nul\r\n'
        'netsh advfirewall firewall add rule name="Mi Streaming TCP" dir=in action=allow protocol=TCP localport=$_port profile=private\r\n'
        'netsh advfirewall firewall add rule name="Mi Streaming UDP" dir=in action=allow protocol=UDP localport=41234 profile=private\r\n');
    await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      "Start-Process -FilePath cmd.exe -ArgumentList '/c \"${f.path}\"' -Verb RunAs",
    ]);
  }

  // ---------- avisos ----------
  /// Notificación de Windows cuando un dispositivo hace una petición nueva.
  /// Funciona con la ventana oculta en la bandeja; al pulsarla se abre la ventana.
  Future<void> _notifyRequest(NewRequestEvent e) async {
    final also = e.alsoBy.isEmpty
        ? ''
        : '\nTambién la habían pedido: ${e.alsoBy.join(', ')}';
    final n = LocalNotification(
        title: 'Nueva petición', body: '${e.device} pidió: ${e.label}$also');
    n.onClick = () {
      _toasts.remove(n);
      if (mounted) setState(() => _page = 1);
      _show();
    };
    n.onClose = (_) => _toasts.remove(n);
    _toasts.add(n);
    try {
      await n.show();
    } catch (err) {
      _toasts.remove(n);
      print('[aviso] no se pudo mostrar la notificación: $err');
    }
  }

  // ---------- dispositivos ----------
  Future<void> _renameDevice(PairedDevice d) async {
    final name = await showDialog<String>(
        context: context, builder: (_) => _RenameDialog(device: d));
    if (name != null) _server?.renameDevice(d.token, name);
  }

  Widget _devicesPage(MediaServer? s) {
    final list = s != null && s.running ? s.pairedList : const <PairedDevice>[];
    final online = list.where((d) => d.connected).length;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Dispositivos emparejados',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(width: 16),
          if (list.isNotEmpty)
            Text('$online de ${list.length} conectados',
                style: const TextStyle(color: Colors.white60)),
          const Spacer(),
          const _Dot(color: Colors.greenAccent, label: 'Conectado'),
          const SizedBox(width: 16),
          const _Dot(color: Colors.orangeAccent, label: 'Vinculado, desconectado'),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: list.isEmpty
              ? const Center(
                  child: Text(
                      'Ningún dispositivo emparejado. Abre la app de Lumen en el móvil: se conecta sola (o con el PIN, si desactivaste la conexión automática).',
                      style: TextStyle(color: Colors.white60)))
              : GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 520, mainAxisExtent: 104),
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final d = list[i];
                    final outdated = d.versionCode != null &&
                        s!.updateCode != null &&
                        d.versionCode! < s.updateCode!;
                    final ver = d.version == null
                        ? 'Versión sin informar (cliente antiguo)'
                        : 'v${d.version}'
                            '${d.versionCode != null ? ' (${d.versionCode})' : ''}';
                    final seen = d.connected
                        ? 'Conectado ahora mismo'
                        : 'Visto ${_fmtSeen(d.lastSeen)}';
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 5, right: 14),
                                child: Tooltip(
                                    message: d.connected
                                        ? 'Conectado'
                                        : 'Vinculado pero desconectado',
                                    child: Icon(Icons.circle,
                                        size: 14,
                                        color: d.connected
                                            ? Colors.greenAccent
                                            : Colors.orangeAccent)),
                              ),
                              Expanded(
                                child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(children: [
                                        Flexible(
                                          child: Text(d.label,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                            '…${d.token.substring(d.token.length - 4)}',
                                            style: const TextStyle(
                                                color: Colors.white30,
                                                fontSize: 11)),
                                      ]),
                                      if (d.alias != null)
                                        Text('Original: ${d.deviceName}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                color: Colors.white54,
                                                fontSize: 12)),
                                      const SizedBox(height: 6),
                                      _InfoLine(
                                          icon: Icons.system_update_alt,
                                          text: ver,
                                          extra: outdated
                                              ? 'Nueva: ${s!.updateVersion}'
                                              : null,
                                          color: d.version == null
                                              ? Colors.white38
                                              : Colors.white70),
                                      const SizedBox(height: 2),
                                      _InfoLine(
                                          icon: Icons.schedule,
                                          text: seen,
                                          color: d.connected
                                              ? Colors.greenAccent
                                              : Colors.white70),
                                    ]),
                              ),
                              Column(mainAxisSize: MainAxisSize.min, children: [
                                IconButton(
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(Icons.edit_outlined),
                                    tooltip: 'Cambiar nombre',
                                    onPressed: () => _renameDevice(d)),
                                IconButton(
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(Icons.delete_outline),
                                    tooltip: 'Revocar',
                                    onPressed: () => s!.revoke(d.token)),
                              ]),
                            ]),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }

  // ---------- perfiles de usuario ----------
  /// Abre la carpeta de avatares en el Explorador (la crea si aún no existe).
  Future<void> _openAvatarsFolder(MediaServer s) async {
    try {
      final dir = Directory(s.avatarsPath)..createSync(recursive: true);
      await Process.start('explorer', [dir.path]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('No se pudo abrir la carpeta: $e')));
      }
    }
  }

  /// Abre la carpeta de actualizaciones (donde se deja el .apk del cliente Android).
  Future<void> _openUpdatesFolder(MediaServer s) async {
    try {
      final dir = Directory(s.updatesPath)..createSync(recursive: true);
      await Process.start('explorer', [dir.path]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('No se pudo abrir la carpeta: $e')));
      }
    }
  }

  /// Elige una imagen cualquiera, la encuadras en el editor y se guarda como avatar.
  Future<void> _addAvatar(MediaServer s) async {
    final pick = await FilePicker.platform.pickFiles(
        dialogTitle: 'Imagen para el avatar',
        type: FileType.custom,
        allowedExtensions: AvatarTool.extensions);
    final path = pick?.files.single.path;
    if (path == null || !mounted) return;
    final id = await showAvatarEditor(context, s, path);
    if (id == null || !mounted) return;
    setState(() {});
    final i = id.indexOf(avatarPackSep);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(i < 0
            ? 'Avatar "$id" guardado en la carpeta.'
            : 'Avatar "${id.substring(i + 1)}" guardado en el paquete "${id.substring(0, i)}".')));
  }

  /// Convierte de golpe las imágenes de la carpeta que no cumplen el formato.
  Future<void> _fixAvatars(MediaServer s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Arreglar la carpeta de avatares'),
        content: const Text(
            'Convierte a JPG de $avatarPixels × $avatarPixels px, con recorte centrado, las imágenes '
            'de la carpeta que no cumplan el formato: PNG, WebP, GIF, BMP, JPG de otro tamaño '
            'o con un nombre no válido, tanto en la carpeta principal como en los paquetes '
            '(subcarpetas).\n\n'
            'Los originales se guardan en una subcarpeta "originales" dentro de cada carpeta.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Arreglar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final res = await s.fixAvatarFolder();
    if (!mounted) return;
    setState(() {});
    if (res.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('No había nada que arreglar.')));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${res.where((r) => r.ok).length} de ${res.length} convertidas'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final r in res)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('${r.ok ? '✓' : '✗'} ${r.file}: ${r.message}',
                      style: TextStyle(color: r.ok ? null : Colors.redAccent, fontSize: 13)),
                ),
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar'))],
      ),
    );
  }

  Future<void> _resetPin(MediaServer s, UserProfile u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Quitar el PIN de "${u.username}"'),
        content: const Text(
            'El perfil quedará sin PIN y cualquiera podrá entrar en él hasta que '
            'su dueño ponga uno nuevo desde la app.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Quitar PIN')),
        ],
      ),
    );
    if (ok == true) s.resetProfilePin(u.username);
  }

  Future<void> _deleteProfile(MediaServer s, UserProfile u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Eliminar el perfil "${u.username}"'),
        content: const Text(
            'Se borran también su progreso, su "Continuar viendo" y sus peticiones '
            '(las que nadie más haya pedido). No se puede deshacer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok == true) s.deleteProfile(u.username);
  }

  Widget _profilesPage(MediaServer? s) {
    final running = s != null && s.running;
    final list = running ? s.profileList : const <UserProfile>[];
    final devices = running ? s.profileDevices : const <String, int>{};
    final problems = running ? s.avatarProblems : const <String, String>{};
    final avatarCount = running ? s.avatarCount : 0;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Perfiles', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(width: 16),
          Text('${list.length} de $maxProfiles', style: const TextStyle(color: Colors.white60)),
          const Spacer(),
          Text('$avatarCount ${avatarCount == 1 ? 'avatar' : 'avatares'} en la carpeta',
              style: const TextStyle(color: Colors.white60)),
          const SizedBox(width: 12),
          OutlinedButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('Abrir carpeta de avatares'),
              onPressed: s == null ? null : () => _openAvatarsFolder(s)),
        ]),
        const SizedBox(height: 8),
        Text(
            'Avatares: archivos .jpg cuadrados de $avatarPixels × $avatarPixels px (máx. '
            '${avatarMaxBytes ~/ 1024} KB). El nombre del archivo (sin .jpg) es el id del avatar: '
            'solo letras, números, - y _. Con "Añadir imagen" cualquier foto se recorta y se '
            'adapta sola; al añadirla eliges el paquete (o creas uno nuevo). Los paquetes son '
            'subcarpetas de la carpeta de avatares y su nombre es el que verá el cliente. '
            'Los perfiles se crean desde la app del móvil.',
            style: const TextStyle(color: Colors.white60, fontSize: 12)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Añadir imagen'),
              onPressed: s == null ? null : () => _addAvatar(s)),
          OutlinedButton.icon(
              icon: const Icon(Icons.auto_fix_high),
              label: const Text('Arreglar carpeta'),
              onPressed: s == null ? null : () => _fixAvatars(s)),
        ]),
        if (problems.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
              'Ignorados: ${problems.entries.map((e) => '${e.key} (${e.value})').join(', ')}',
              style: const TextStyle(color: Colors.amber, fontSize: 12)),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: list.isEmpty
              ? const Center(
                  child: Text(
                      'Aún no hay perfiles. Se crean desde la app del móvil al emparejarla.',
                      style: TextStyle(color: Colors.white60)))
              : GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 460, mainAxisExtent: 84),
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final u = list[i];
                    final file = s!.avatarFileOf(u.avatar);
                    final n = devices[u.key] ?? 0;
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          radius: 24,
                          backgroundColor: Colors.indigo.shade700,
                          foregroundImage: file == null
                              ? null
                              : ResizeImage(FileImage(file), width: 96),
                          child: Text(u.initial),
                        ),
                        title: Row(children: [
                          Flexible(
                              child: Text(u.username,
                                  maxLines: 1, overflow: TextOverflow.ellipsis)),
                          if (u.hasPin)
                            const Padding(
                                padding: EdgeInsets.only(left: 6),
                                child: Icon(Icons.lock_outline, size: 14, color: Colors.white54)),
                        ]),
                        subtitle: Text(
                            [
                              n == 0 ? 'Sin dispositivos' : '$n ${n == 1 ? 'dispositivo' : 'dispositivos'}',
                              u.lastSeenMs == 0 ? 'nunca usado' : 'visto ${_ago(u.lastSeenMs)}',
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (u.hasPin)
                            IconButton(
                                icon: const Icon(Icons.lock_open),
                                tooltip: 'Quitar PIN',
                                onPressed: () => _resetPin(s, u)),
                          IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'Eliminar perfil',
                              onPressed: () => _deleteProfile(s, u)),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }

  // ---------- peticiones ----------
  static const _videoExts = ['mkv', 'mp4', 'm4v', 'avi', 'mov', 'webm', 'wmv', 'flv', 'ts'];

  String _ago(int ms) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return 'ahora';
    if (d.inHours < 1) return 'hace ${d.inMinutes} min';
    if (d.inDays < 1) return 'hace ${d.inHours} h';
    return 'hace ${d.inDays} d';
  }

  String _impKey(MovieRequestInfo r) => '${r.type}:${r.tmdbId}';

  /// Elige el archivo de la película, lo copia (o mueve) a la biblioteca y lo enlaza con TMDB.
  /// Con una serie, en cambio, se eligen varios capítulos (ver [_addEpisodes]).
  Future<void> _addToLibrary(MovieRequestInfo r) async {
    if (r.type == 'tv') return _addEpisodes(r);
    final s = _server;
    if (s == null) return;
    final pick = await FilePicker.platform.pickFiles(
        dialogTitle: 'Archivo de "${r.label}"',
        type: FileType.custom,
        allowedExtensions: _videoExts);
    final path = pick?.files.single.path;
    if (path == null || !mounted) return;
    final move = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Añadir "${r.label}"'),
        content: Text('${p.basename(path)}\n\n¿Copiar el archivo a la biblioteca o moverlo?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Copiar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Mover')),
        ],
      ),
    );
    if (move == null || !mounted) return;
    setState(() => _importing.add(_impKey(r)));
    String msg;
    try {
      msg = await s.fulfillRequest(r.tmdbId, path, move: move);
    } catch (e) {
      msg = e is StateError ? e.message : 'No se pudo añadir: $e';
    }
    if (!mounted) return;
    setState(() => _importing.remove(_impKey(r)));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Serie pedida: se eligen uno o varios capítulos (los de una temporada, o los que falten),
  /// se confirma a qué temporada y número corresponde cada uno y se guardan en
  /// "<serie>/Temporada NN". Sirve también para añadir temporadas a una serie ya existente.
  Future<void> _addEpisodes(MovieRequestInfo r) async {
    final s = _server;
    if (s == null) return;
    final pick = await FilePicker.platform.pickFiles(
        dialogTitle: 'Capítulos de "${r.label}" (puedes elegir varios)',
        type: FileType.custom,
        allowedExtensions: _videoExts,
        allowMultiple: true);
    final paths = [
      for (final f in pick?.files ?? const <PlatformFile>[])
        if (f.path != null) f.path!
    ];
    if (paths.isEmpty || !mounted) return;
    final plan = await showDialog<_EpisodesChoice>(
      context: context,
      builder: (_) => _EpisodesDialog(label: r.label, paths: paths),
    );
    if (plan == null || !mounted) return;
    setState(() => _importing.add(_impKey(r)));
    String msg;
    try {
      msg = await s.fulfillSeriesRequest(r.tmdbId, plan.episodes,
          move: plan.move);
    } catch (e) {
      msg = e is StateError ? e.message : 'No se pudo añadir: $e';
    }
    if (!mounted) return;
    setState(() => _importing.remove(_impKey(r)));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _deleteRequest(MovieRequestInfo r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Quitar "${r.label}"'),
        content: const Text('Se borra la petición para todos los dispositivos.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Quitar')),
        ],
      ),
    );
    if (ok == true) _server?.deleteRequest(r.tmdbId, r.type);
  }

  Widget _requestsPage(MediaServer? s) {
    final list = s != null && s.running ? s.requestList : const <MovieRequestInfo>[];
    final pending = list.where((r) => !r.inLibrary).length;
    const noPoster = ColoredBox(color: Colors.black26, child: Icon(Icons.movie));
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Peticiones', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(width: 12),
          if (pending > 0) Badge(label: Text('$pending')),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: list.isEmpty
              ? const Center(
                  child: Text('Ninguna petición por ahora.',
                      style: TextStyle(color: Colors.white60)))
              : GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 520, mainAxisExtent: 132),
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final r = list[i];
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: SizedBox(
                              width: 70,
                              height: 105,
                              child: r.posterUrl == null
                                  ? noPoster
                                  : Image.network(r.posterUrl!,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => noPoster),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(r.label,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 4),
                                  Text(
                                      r.inLibrary
                                          ? (r.type == 'tv'
                                              ? 'Serie · Ya está en la biblioteca. Puedes añadir más capítulos o temporadas.'
                                              : 'Ya está en la biblioteca')
                                          : '${r.type == 'tv' ? 'Serie · ' : ''}Pedida por ${r.by.join(', ')} · ${_ago(r.createdMs)}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 12, color: Colors.white60)),
                                  if (_importing.contains(_impKey(r)))
                                    const Padding(
                                        padding: EdgeInsets.only(top: 6),
                                        child: LinearProgressIndicator()),
                                ]),
                          ),
                          Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (r.type == 'tv')
                                  // Una serie se puede ampliar siempre: más capítulos o temporadas.
                                  IconButton(
                                      icon: Icon(Icons.playlist_add,
                                          color: r.inLibrary
                                              ? Colors.greenAccent
                                              : null),
                                      tooltip: r.inLibrary
                                          ? 'Añadir más capítulos o temporadas'
                                          : 'Añadir capítulos a la biblioteca',
                                      onPressed: _importing.contains(_impKey(r))
                                          ? null
                                          : () => _addToLibrary(r))
                                else if (r.inLibrary)
                                  const Padding(
                                      padding: EdgeInsets.all(8),
                                      child: Icon(Icons.check_circle,
                                          color: Colors.greenAccent))
                                else
                                  IconButton(
                                      icon: const Icon(Icons.library_add),
                                      tooltip: 'Añadir a la biblioteca',
                                      onPressed: _importing.contains(_impKey(r))
                                          ? null
                                          : () => _addToLibrary(r)),
                                PopupMenuButton<String>(
                                  onSelected: (v) {
                                    if (v == 'copy') {
                                      Clipboard.setData(ClipboardData(text: r.label));
                                    }
                                    if (v == 'tmdb') {
                                      Process.run('cmd', [
                                        '/c',
                                        'start',
                                        '',
                                        'https://www.themoviedb.org/${r.type == 'tv' ? 'tv' : 'movie'}/${r.tmdbId}'
                                      ]);
                                    }
                                    if (v == 'delete') _deleteRequest(r);
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(value: 'copy', child: Text('Copiar título')),
                                    PopupMenuItem(value: 'tmdb', child: Text('Abrir en TMDB')),
                                    PopupMenuItem(value: 'delete', child: Text('Quitar petición')),
                                  ],
                                ),
                              ]),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }

  // ---------- ajustes ----------
  Widget _card(String title, List<Widget> children) => Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(color: Colors.white70)),
            const SizedBox(height: 8),
            ...children,
          ])));

  Widget _settingsPage(MediaServer? s) {
    final running = s != null && s.running;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(children: [
                _card('Carpeta y puerto', [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder),
                    title: Text(_root.isEmpty ? 'Elige la carpeta de videos' : _root,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: TextButton(
                        onPressed: _pickFolder, child: const Text('Cambiar')),
                  ),
                  TextFormField(
                    initialValue: '$_port',
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Puerto (Enter para aplicar)'),
                    onFieldSubmitted: _setPort,
                  ),
                ]),
                _card('Carátulas y sinopsis (TMDB)', [
                  TextFormField(
                    initialValue: _tmdbKey,
                    obscureText: true,
                    decoration: const InputDecoration(
                        labelText: 'Clave de API de TMDB (Enter para aplicar)',
                        helperText:
                            'Gratis en themoviedb.org → Ajustes → API. Sin clave puedes poner carátulas desde tu PC o una URL.'),
                    onFieldSubmitted: _setTmdbKey,
                  ),
                  const SizedBox(height: 8),
                  Text(running && s.tmdbEnabled ? 'TMDB activo' : 'TMDB desactivado',
                      style: TextStyle(
                          color: running && s.tmdbEnabled
                              ? Colors.greenAccent
                              : Colors.grey)),
                ]),
              ]),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(children: [
                _card('Conexión de dispositivos', [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Conexión automática (sin PIN)'),
                    subtitle: Text(
                        _openAccess
                            ? 'Los dispositivos con Lumen se conectan solos con un PIN fijo que la app ya trae: no piden PIN, IP ni puerto.'
                            : 'Cada dispositivo nuevo debe escribir el PIN para conectarse.',
                        style: const TextStyle(color: Colors.white60)),
                    value: _openAccess,
                    onChanged: _setOpenAccess,
                  ),
                  if (_openAccess)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                          'El PIN fijo va dentro de la app, así que no es un candado real: '
                          'cualquiera que lo saque de ella podría entrar. Úsalo solo en una red de '
                          'confianza (la de tu casa) y no abras el puerto a internet con esto activado.',
                          style: TextStyle(color: Colors.orangeAccent, fontSize: 12.5)),
                    )
                  else ...[
                    const SizedBox(height: 8),
                    Center(
                        child: Text(running ? s.pin : '------',
                            style: const TextStyle(
                                fontSize: 40,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 8))),
                    const SizedBox(height: 4),
                    const Text(
                        'Introdúcelo en la app del móvil. Cambia tras cada emparejamiento.',
                        style: TextStyle(color: Colors.white60)),
                  ],
                ]),
                _card('Actualización del cliente Android', [
                  Text(
                      running && s.updateVersion != null
                          ? 'Se ofrece la versión ${s.updateVersion}'
                          : 'Sin APK en la carpeta',
                      style: TextStyle(
                          color: running && s.updateVersion != null
                              ? Colors.greenAccent
                              : Colors.grey)),
                  for (final e in (running ? s.updateSkipped : const <String, String>{}).entries)
                    Text('Ignorado ${e.key}: ${e.value}',
                        style: const TextStyle(color: Colors.orangeAccent)),
                  const SizedBox(height: 4),
                  const Text(
                      'Deja aquí el .apk nuevo (mismo paquete y misma firma, versionCode mayor). '
                      'Los móviles lo detectan y se actualizan solos.',
                      style: TextStyle(color: Colors.white60)),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                        onPressed: s == null ? null : () => _openUpdatesFolder(s),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Abrir carpeta de actualizaciones')),
                  ),
                ]),
                _card('Sistema', [
                  SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Iniciar con Windows (en la bandeja)'),
                      value: _autostart,
                      onChanged: _toggleAutostart),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                        onPressed: _openFirewall,
                        icon: const Icon(Icons.shield_outlined),
                        label: const Text('Abrir puertos en el firewall')),
                  ),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  // ---------- registro ----------
  Widget _logPage() => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Registro', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            TextButton.icon(
                onPressed: () => Clipboard.setData(
                    ClipboardData(text: appLog.value.join('\n'))),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copiar')),
            TextButton.icon(
                onPressed: () => appLog.value = const [],
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                label: const Text('Limpiar')),
          ]),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Colors.black26, borderRadius: BorderRadius.circular(8)),
              child: ValueListenableBuilder<List<String>>(
                valueListenable: appLog,
                builder: (_, lines, __) => SingleChildScrollView(
                  reverse: true,
                  child: SelectableText(
                    lines.isEmpty ? '(vacío)' : lines.join('\n'),
                    style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                  ),
                ),
              ),
            ),
          ),
        ]),
      );

  // ---------- interfaz ----------
  /// Barra superior: estado, direcciones, PIN y botón de iniciar/detener.
  Widget _header(MediaServer? s) {
    final running = s != null && s.running;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(children: [
        Icon(Icons.circle, size: 14, color: running ? Colors.greenAccent : Colors.grey),
        const SizedBox(width: 8),
        Text(running ? 'En marcha · ${s.videoCount} videos' : 'Detenido',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(width: 20),
        if (running)
          Expanded(
              child: SelectableText(_addresses.join('   ·   '),
                  maxLines: 1, style: const TextStyle(color: Colors.white70)))
        else
          const Spacer(),
        if (running && !_openAccess) ...[
          const Text('PIN ', style: TextStyle(color: Colors.white60)),
          Text(s.pin,
              style: const TextStyle(
                  fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 4)),
          const SizedBox(width: 20),
        ] else if (running) ...[
          const Icon(Icons.wifi_tethering, size: 18, color: Colors.greenAccent),
          const SizedBox(width: 6),
          const Text('Conexión automática',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(width: 20),
        ],
        FilledButton(
            onPressed: _busy || _root.isEmpty ? null : (running ? _stop : _start),
            child: Text(running ? 'Detener' : 'Iniciar')),
      ]),
    );
  }

  Widget _banner(String text, Color color) => Container(
        width: double.infinity,
        color: color.withOpacity(0.12),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        child: Text(text, style: TextStyle(color: color, fontSize: 12.5)),
      );

  Widget _body(MediaServer? s) {
    switch (_page) {
      case 0:
        return LibraryPage(
            server: s,
            selectedId: _selectedId,
            onSelect: (id) => setState(() => _selectedId = id));
      case 1:
        return _requestsPage(s);
      case 2:
        return _devicesPage(s);
      case 3:
        return _profilesPage(s);
      case 4:
        return _settingsPage(s);
      default:
        return _logPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _server;
    final running = s != null && s.running;
    return Scaffold(
      body: StreamBuilder<void>(
        stream: s?.changes,
        builder: (context, _) {
          final pending = running ? s.requestList.where((r) => !r.inLibrary).length : 0;
          final online = running ? s.pairedList.where((d) => d.connected).length : 0;
          return Column(children: [
            _header(s),
            if (_error != null) _banner(_error!, Colors.redAccent),
            if (running && !s.hasFfmpeg)
              _banner(
                  'No se encontró ffmpeg/ffprobe: sin miniaturas, metadatos ni transcodificación. '
                  'Copia ffmpeg.exe y ffprobe.exe junto a este programa.',
                  Colors.amber),
            const Divider(height: 1),
            Expanded(
              child: Row(children: [
                NavigationRail(
                  selectedIndex: _page,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (i) => setState(() => _page = i),
                  destinations: [
                    const NavigationRailDestination(
                        icon: Icon(Icons.video_library_outlined),
                        selectedIcon: Icon(Icons.video_library),
                        label: Text('Biblioteca')),
                    NavigationRailDestination(
                        icon: Badge(
                            isLabelVisible: pending > 0,
                            label: Text('$pending'),
                            child: const Icon(Icons.playlist_add_outlined)),
                        selectedIcon: Badge(
                            isLabelVisible: pending > 0,
                            label: Text('$pending'),
                            child: const Icon(Icons.playlist_add)),
                        label: const Text('Peticiones')),
                    NavigationRailDestination(
                        icon: Badge(
                            isLabelVisible: online > 0,
                            label: Text('$online'),
                            child: const Icon(Icons.devices_outlined)),
                        selectedIcon: Badge(
                            isLabelVisible: online > 0,
                            label: Text('$online'),
                            child: const Icon(Icons.devices)),
                        label: const Text('Dispositivos')),
                    const NavigationRailDestination(
                        icon: Icon(Icons.account_circle_outlined),
                        selectedIcon: Icon(Icons.account_circle),
                        label: Text('Perfiles')),
                    const NavigationRailDestination(
                        icon: Icon(Icons.settings_outlined),
                        selectedIcon: Icon(Icons.settings),
                        label: Text('Ajustes')),
                    const NavigationRailDestination(
                        icon: Icon(Icons.terminal_outlined),
                        selectedIcon: Icon(Icons.terminal),
                        label: Text('Registro')),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _body(s)),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

/// Punto de color con su etiqueta (leyenda de la lista de dispositivos).
class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.circle, size: 10, color: color),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12)),
      ]);
}

/// Línea de información con icono (versión, última conexión...). Si hay [extra] se
/// muestra al lado en naranja (p. ej. "Nueva: 0.2.0 (8)").
class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.icon, required this.text, this.extra, this.color});
  final IconData icon;
  final String text;
  final String? extra;
  final Color? color;

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 8),
        Flexible(
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 13)),
        ),
        if (extra != null) ...[
          const SizedBox(width: 10),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              decoration: BoxDecoration(
                  color: Colors.orangeAccent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10)),
              child: Text(extra!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
            ),
          ),
        ],
      ]);
}

/// "hace 5 min", "hoy 14:32", "ayer 09:10" o "12/11/2026 18:05".
String _fmtSeen(DateTime? t) {
  if (t == null) return 'sin registro';
  final now = DateTime.now();
  final diff = now.difference(t);
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  if (diff.inMinutes < 1) return 'hace un momento';
  if (diff.inMinutes < 60) return 'hace ${diff.inMinutes} min';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final days = today.difference(day).inDays;
  if (days == 0) return 'hoy $hm';
  if (days == 1) return 'ayer $hm';
  return '${two(t.day)}/${two(t.month)}/${t.year} $hm';
}

/// Diálogo para ponerle nombre a un dispositivo. Devuelve el texto escrito
/// (vacío = volver al nombre original) o null si se cancela.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.device});
  final PairedDevice device;
  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _c = TextEditingController(text: widget.device.label);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    return AlertDialog(
      title: const Text('Nombre del dispositivo'),
      content: TextField(
        controller: _c,
        autofocus: true,
        maxLength: 40,
        decoration: InputDecoration(
            labelText: 'Nombre',
            helperText: 'Original: ${d.deviceName}'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        if (d.alias != null)
          TextButton(
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('Restablecer')),
        FilledButton(
            onPressed: () => Navigator.pop(context, _c.text),
            child: const Text('Guardar')),
      ],
    );
  }
}

// ---------- peticiones de series: elegir capítulos ----------

/// Lo que decide el dueño en el diálogo de capítulos.
class _EpisodesChoice {
  const _EpisodesChoice(this.episodes, this.move);
  final List<EpisodeImport> episodes;
  final bool move;
}

/// Orden "natural" por nombre ("cap 2" antes que "cap 10").
int _natural(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final x = [for (final m in re.allMatches(a.toLowerCase())) m[0]!];
  final y = [for (final m in re.allMatches(b.toLowerCase())) m[0]!];
  for (var i = 0; i < x.length && i < y.length; i++) {
    final nx = int.tryParse(x[i]), ny = int.tryParse(y[i]);
    final c = nx != null && ny != null ? nx.compareTo(ny) : x[i].compareTo(y[i]);
    if (c != 0) return c;
  }
  return x.length.compareTo(y.length);
}

class _EpRow {
  _EpRow(this.path, int season, int episode)
      : season = TextEditingController(text: '$season'),
        episode = TextEditingController(text: '$episode');
  final String path;
  final TextEditingController season, episode;
}

/// Lista los archivos elegidos con su temporada y su capítulo (sugeridos por el nombre del
/// archivo, editables) y pregunta si copiar o mover.
class _EpisodesDialog extends StatefulWidget {
  const _EpisodesDialog({required this.label, required this.paths});
  final String label;
  final List<String> paths;

  @override
  State<_EpisodesDialog> createState() => _EpisodesDialogState();
}

class _EpisodesDialogState extends State<_EpisodesDialog> {
  final _rows = <_EpRow>[];
  final _removed = <_EpRow>[];
  final _all = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    final sorted = [...widget.paths]
      ..sort((a, b) => _natural(p.basename(a), p.basename(b)));
    final guesses = [for (final f in sorted) guessEpisode(f)];

    // Temporada por defecto: la que más repiten los nombres que la dicen con claridad.
    final counts = <int, int>{};
    for (final g in guesses) {
      if (g != null && g.explicitSeason) {
        counts[g.season] = (counts[g.season] ?? 0) + 1;
      }
    }
    var def = 1, best = 0;
    counts.forEach((s, n) {
      if (n > best) {
        best = n;
        def = s;
      }
    });

    final seasons = <int>[];
    final eps = <int?>[];
    final used = <String>{};
    for (final g in guesses) {
      final s = g != null && g.explicitSeason ? g.season : def;
      seasons.add(s);
      eps.add(g?.episode);
      if (g != null) used.add('$s/${g.episode}');
    }
    // Los que no traen número de capítulo reciben el primer número libre de su temporada.
    for (var i = 0; i < eps.length; i++) {
      if (eps[i] != null) continue;
      var n = 1;
      while (used.contains('${seasons[i]}/$n')) {
        n++;
      }
      used.add('${seasons[i]}/$n');
      eps[i] = n;
    }
    for (var i = 0; i < sorted.length; i++) {
      _rows.add(_EpRow(sorted[i], seasons[i], eps[i]!));
    }
    _all.text = seasons.toSet().length == 1 ? '${seasons.first}' : '';
  }

  @override
  void dispose() {
    for (final r in [..._rows, ..._removed]) {
      r.season.dispose();
      r.episode.dispose();
    }
    _all.dispose();
    super.dispose();
  }

  void _setAllSeasons(String v) {
    final n = int.tryParse(v.trim());
    if (n == null) return;
    setState(() {
      _error = null;
      for (final r in _rows) {
        r.season.text = '$n';
      }
    });
  }

  void _submit(bool move) {
    final out = <EpisodeImport>[];
    final seen = <String>{};
    for (final r in _rows) {
      final s = int.tryParse(r.season.text.trim());
      final e = int.tryParse(r.episode.text.trim());
      final name = p.basename(r.path);
      if (s == null || s < 0 || s > 99) {
        return _fail('Temporada inválida en "$name" (de 0 a 99; 0 = especiales).');
      }
      if (e == null || e < 1 || e > 999) {
        return _fail('Capítulo inválido en "$name" (de 1 a 999).');
      }
      if (!seen.add('$s/$e')) {
        return _fail('Dos archivos tienen la temporada $s, capítulo $e.');
      }
      out.add(EpisodeImport(r.path, s, e));
    }
    if (out.isEmpty) return _fail('No queda ningún capítulo.');
    Navigator.pop(context, _EpisodesChoice(out, move));
  }

  void _fail(String m) => setState(() => _error = m);

  Widget _num(TextEditingController c, String label) => SizedBox(
        width: 64,
        child: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          onChanged: (_) => setState(() => _error = null),
          decoration: InputDecoration(
              isDense: true,
              labelText: label,
              border: const OutlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Añadir a "${widget.label}"'),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'Cada temporada se guarda en su subcarpeta dentro de la carpeta de la serie '
                '(Temporada 01, Temporada 02...). Revisa la temporada y el capítulo de cada archivo.',
                style: TextStyle(fontSize: 12, color: Colors.white60)),
            const SizedBox(height: 12),
            Row(children: [
              const Text('Temporada para todos:'),
              const SizedBox(width: 8),
              SizedBox(
                width: 64,
                child: TextField(
                  controller: _all,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  onChanged: _setAllSeasons,
                  decoration: const InputDecoration(
                      isDense: true, border: OutlineInputBorder()),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 340),
              child: SingleChildScrollView(
                child: Column(children: [
                  for (final r in _rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(children: [
                        Expanded(
                          child: Tooltip(
                            message: r.path,
                            child: Text(p.basename(r.path),
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _num(r.season, 'Temp.'),
                        const SizedBox(width: 6),
                        _num(r.episode, 'Cap.'),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: 'Quitar de la lista',
                          onPressed: () => setState(() {
                            _rows.remove(r);
                            _removed.add(r);
                            _error = null;
                          }),
                        ),
                      ]),
                    ),
                ]),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.redAccent)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        TextButton(
            onPressed: () => _submit(false), child: const Text('Copiar')),
        FilledButton(
            onPressed: () => _submit(true), child: const Text('Mover')),
      ],
    );
  }
}