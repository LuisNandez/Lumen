# Paso 6 — Navegación con el mando en modo TV

Archivos (copia cada uno en su misma ruta, sobrescribiendo):
  client/lib/tv.dart
  client/lib/shell.dart
  client/lib/theater.dart
  client/lib/downloads.dart

## Cómo se mueve ahora el foco
La pantalla se divide en zonas: [menú lateral] | [pantalla]. Dentro de Inicio, la barra de arriba
(lupa, campanita) y las filas son dos zonas más.

- ◀ en el borde izquierdo de cualquier pantalla (primera carátula de una fila, botón Reproducir,
  lupa, campo de búsqueda...) salta al menú lateral, a la opción de la pestaña actual.
- ▶ en el menú vuelve a la pantalla actual, al elemento donde estabas (carátula, botón,
  campanita...), sin cambiar de sección. OK abre la sección de la opción marcada (la primera vez
  al primer elemento; después, donde lo dejaste).
- ▲ desde el botón Reproducir / Más información sube a la barra (lupa → ▶ campanita).
  ▼ desde la barra vuelve exactamente al elemento del que subiste.
- Atrás: de una pantalla al menú lateral; en el menú, de otra pestaña a Inicio; en Inicio, salir.
- Al abrir la campanita (o cualquier ficha) y volver con Atrás, el foco queda donde estaba.
- ◀/▶ solo saltan a elementos de la MISMA fila (antes podían saltar a una fila de abajo).

## Detalles técnicos
- tv.dart: TvTraversalPolicy (izquierda/derecha estrictas por fila), TvEdgeNotification (los
  campos de texto avisan al llegar al borde), tvInEditableText, tvUsable.
- shell.dart: menú lateral propio (_TvRail) en vez de NavigationRail, una zona de foco por
  pestaña (recuerda el último elemento), manejo de ◀ en el borde y de Atrás.
- theater.dart: memoria de regreso desde la barra superior y más filas precargadas en TV
  (cacheExtent) para que ▲/▼ siempre encuentren la fila siguiente.

No cambia nada en móvil ni en escritorio. Probar sin TV: flutter run --dart-define=TV=true
(con teclado: flechas, Enter y Esc).

- El menú lateral está oculto y solo aparece (deslizándose, por encima del contenido) mientras
  tiene el foco.
- Al abrir una película o serie (también sin conexión), el foco cae en el botón Reproducir.
