import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared/shared.dart';

import 'api.dart';
import 'core.dart';
import 'native.dart';
import 'tv.dart' show tvModeProvider;

// ===========================================================================
//  Actualización automática (solo Android).
//  El servidor ofrece el .apk que haya en su carpeta `updates/`. Aquí se compara
//  con la versión instalada (versionCode), se descarga (reanudable), se verifica
//  (paquete, tamaño y SHA-256) y se entrega al instalador del sistema.
//  Android exige que el APK nuevo tenga el MISMO paquete y la MISMA firma.
// ===========================================================================

enum UpdateStage {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  verifying,
  needsPermission,
  installing,
  error,
  unsupported,
}

class UpdateState {
  const UpdateState(
      {this.stage = UpdateStage.idle,
      this.info,
      this.installedName = '',
      this.installedCode = 0,
      this.progress = 0,
      this.error});
  final UpdateStage stage;
  final AppUpdateInfo? info;
  final String installedName;
  final int installedCode;
  final double progress;
  final String? error;

  UpdateState copy(
          {UpdateStage? stage,
          AppUpdateInfo? info,
          double? progress,
          String? error,
          bool clearError = false}) =>
      UpdateState(
          stage: stage ?? this.stage,
          info: info ?? this.info,
          installedName: installedName,
          installedCode: installedCode,
          progress: progress ?? this.progress,
          error: clearError ? null : (error ?? this.error));

  bool get hasUpdate =>
      stage == UpdateStage.available ||
      stage == UpdateStage.downloading ||
      stage == UpdateStage.verifying ||
      stage == UpdateStage.needsPermission ||
      stage == UpdateStage.installing ||
      (stage == UpdateStage.error && info != null && info!.available);
}

const _dismissedKey = 'update_dismissed_code';

class UpdaterNotifier extends Notifier<UpdateState> {
  bool _busy = false;
  bool _cancel = false;

  @override
  UpdateState build() => const UpdateState();

  /// Versión que el usuario dijo "más tarde": no se le vuelve a abrir el diálogo solo.
  int get dismissedCode => ref.read(prefsProvider).getInt(_dismissedKey) ?? 0;
  void dismiss() {
    final c = state.info?.versionCode;
    if (c != null) ref.read(prefsProvider).setInt(_dismissedKey, c);
  }

  /// Pregunta al servidor si hay una versión más nueva que la instalada.
  Future<void> check() async {
    if (_busy) return; // no pisar una descarga en curso
    final api = ref.read(apiProvider);
    if (api == null) return;
    final me = await NativeBridge.appVersion();
    if (me == null) {
      state = const UpdateState(stage: UpdateStage.unsupported);
      return;
    }
    final base = UpdateState(
        stage: UpdateStage.checking,
        installedName: me.name,
        installedCode: me.code,
        info: state.info);
    state = base;
    try {
      final info = await api.updateInfo();
      if (!info.available || info.versionCode <= me.code) {
        // Ya está al día: borra APK viejos que hubieran quedado.
        unawaited(_cleanup(keep: null));
        state = UpdateState(
            stage: UpdateStage.upToDate,
            info: info,
            installedName: me.name,
            installedCode: me.code);
      } else if (info.packageName != me.package) {
        state = UpdateState(
            stage: UpdateStage.error,
            info: info,
            installedName: me.name,
            installedCode: me.code,
            error:
                'El APK del servidor es de otro paquete (${info.packageName}); no se puede instalar encima.');
      } else {
        state = UpdateState(
            stage: UpdateStage.available,
            info: info,
            installedName: me.name,
            installedCode: me.code);
      }
    } catch (e) {
      // Sin servidor / sin respuesta: no es un error para el usuario.
      state = UpdateState(
          stage: UpdateStage.idle,
          installedName: me.name,
          installedCode: me.code,
          info: base.info,
          error: errText(e));
    }
  }

  void cancelDownload() => _cancel = true;

  /// Descarga, verifica e instala. Si falta el permiso, abre Ajustes y espera a que
  /// el usuario vuelva y pulse otra vez (el APK ya queda descargado).
  Future<void> downloadAndInstall() async {
    final info = state.info;
    final api = ref.read(apiProvider);
    if (_busy || info == null || !info.available || api == null) return;
    _busy = true;
    _cancel = false;
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/update')
        ..createSync(recursive: true);
      final apk = File('${dir.path}/update-${info.versionCode}.apk');
      final part = '${apk.path}.part';

      if (!(apk.existsSync() && await _sha(apk) == info.sha256)) {
        if (apk.existsSync()) apk.deleteSync();
        state = state.copy(
            stage: UpdateStage.downloading, progress: 0, clearError: true);
        await _cleanup(keep: apk.path, keepPart: part);
        var tries = 0;
        while (true) {
          try {
            await api.downloadApk(part, info.size,
                cancelled: () => _cancel,
                onProgress: (got) => state = state.copy(
                    progress: info.size == 0 ? 0 : got / info.size));
            break;
          } catch (e) {
            if (_cancel) throw StateError('Descarga cancelada');
            // La red se corta a menudo en Wi-Fi: se reanuda desde lo ya bajado.
            if (++tries >= 4) rethrow;
            await Future<void>.delayed(const Duration(seconds: 2));
          }
        }
        state = state.copy(stage: UpdateStage.verifying);
        final p = File(part);
        if (p.lengthSync() != info.size ||
            await _sha(p) != info.sha256) {
          p.deleteSync();
          throw StateError(
              'El archivo descargado está dañado (no coincide el SHA-256). Inténtalo de nuevo.');
        }
        p.renameSync(apk.path);
      }

      if (!await NativeBridge.canInstallPackages()) {
        state = state.copy(stage: UpdateStage.needsPermission);
        await NativeBridge.openInstallSettings();
        return;
      }
      state = state.copy(stage: UpdateStage.installing);
      final r = await NativeBridge.installApk(apk.path);
      if (r == 'no_permission') {
        state = state.copy(stage: UpdateStage.needsPermission);
        await NativeBridge.openInstallSettings();
      } else if (r != 'ok') {
        throw StateError(r.replaceFirst('error: ', ''));
      } else {
        // El sistema muestra su pantalla de instalación; si el usuario cancela,
        // se vuelve a poder pulsar.
        state = state.copy(stage: UpdateStage.available);
      }
    } catch (e) {
      state = state.copy(
          stage: UpdateStage.error, error: errText(e).replaceFirst('Bad state: ', ''));
    } finally {
      _busy = false;
    }
  }

  Future<String> _sha(File f) async => (await sha256.bind(f.openRead()).first).toString();

  /// Borra APK y partes antiguos de la carpeta temporal.
  Future<void> _cleanup({String? keep, String? keepPart}) async {
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/update');
      if (!dir.existsSync()) return;
      for (final e in dir.listSync()) {
        if (e is File && e.path != keep && e.path != keepPart) e.deleteSync();
      }
    } catch (_) {}
  }
}

final updaterProvider =
    NotifierProvider<UpdaterNotifier, UpdateState>(UpdaterNotifier.new);

String _mb(int b) => '${(b / 1048576).toStringAsFixed(1)} MB';

/// Diálogo de actualización: versión, progreso y botones. Se abre solo (una vez por
/// versión) o desde Ajustes.
Future<void> showUpdateDialog(BuildContext context) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _UpdateDialog());

class _UpdateDialog extends ConsumerWidget {
  const _UpdateDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = ref.watch(updaterProvider);
    final n = ref.read(updaterProvider.notifier);
    final tv = ref.watch(tvModeProvider); // con el mando, el foco empieza en el botón principal
    final info = u.info;
    final busy = u.stage == UpdateStage.downloading ||
        u.stage == UpdateStage.verifying ||
        u.stage == UpdateStage.installing;

    String body;
    switch (u.stage) {
      case UpdateStage.downloading:
        body = 'Descargando… ${(u.progress * 100).toStringAsFixed(0)} %';
      case UpdateStage.verifying:
        body = 'Verificando el archivo…';
      case UpdateStage.installing:
        body = 'Abriendo el instalador…';
      case UpdateStage.needsPermission:
        body =
            'Android necesita tu permiso para instalar la actualización. Activa '
            '"Permitir de esta fuente" en la pantalla que se abrió, vuelve aquí y '
            'pulsa Instalar otra vez (el archivo ya está descargado).';
      case UpdateStage.error:
        body = u.error ?? 'Error desconocido';
      case UpdateStage.upToDate:
        body = 'Ya tienes la última versión.';
      default:
        body = info == null
            ? ''
            : 'Hay una versión nueva: ${info.versionName} (tienes ${u.installedName}). '
                'Tamaño: ${_mb(info.size)}. Tus perfiles y descargas se conservan.';
    }

    return AlertDialog(
      title: const Text('Actualización disponible'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(body),
        if (u.stage == UpdateStage.downloading) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: u.progress == 0 ? null : u.progress),
        ],
      ]),
      actions: [
        if (u.stage == UpdateStage.downloading)
          TextButton(
              autofocus: tv,
              onPressed: n.cancelDownload,
              child: const Text('Cancelar')),
        if (!busy)
          TextButton(
              autofocus: tv && u.stage == UpdateStage.upToDate,
              onPressed: () {
                if (u.stage == UpdateStage.available) n.dismiss();
                Navigator.pop(context);
              },
              child: Text(u.stage == UpdateStage.upToDate ? 'Cerrar' : 'Más tarde')),
        if (!busy && u.stage != UpdateStage.upToDate)
          FilledButton(
              autofocus: tv,
              onPressed: n.downloadAndInstall,
              child: Text(u.stage == UpdateStage.error ? 'Reintentar' : 'Instalar')),
      ],
    );
  }
}