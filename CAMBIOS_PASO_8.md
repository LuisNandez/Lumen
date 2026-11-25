# Paso 8 — Animación de entrada LUMEN

Archivos (misma ruta, sobrescribiendo):
  client/lib/splash.dart   (nuevo)
  client/lib/main.dart

Cambios en main.dart (por si lo tienes modificado y prefieres hacerlo a mano):
  1. import 'splash.dart';
  2. home: const SplashGate(child: Home()),
  3. Quitar la línea  Sfx.play(Snd.intro, force: true);  del final de main()
     (ahora el sonido de bienvenida lo lanza la animación cuando termina).

Ajustes rápidos en splash.dart:
  - Duración de la animación de letras: _intro (2400 ms) y los Interval de cada letra.
  - Espera máxima de carga: _maxWait (8 s).
  - Zoom de salida: el 11 de  1 + 11 * ...
