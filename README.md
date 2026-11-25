# Mi Streaming — fases 1-6

packages/shared       modelos y constantes (Dart puro)
packages/server_core  lógica del servidor (API, streaming, HLS, subtítulos, WebSocket, descubrimiento)
server/               servidor en modo consola (opcional)
server_app/           servidor con ventana, bandeja e inicio con Windows (recomendado)
client/               app Flutter (Android; iOS y TV más adelante)

## Servidor de escritorio (Windows) — server_app
cd server_app
flutter create . --platforms=windows --project-name server_app   # genera windows/ sin tocar lib/
rm -rf test                                                      # test de ejemplo que ya no aplica
flutter pub get
flutter run -d windows
flutter build windows --release        # -> build\windows\x64\runner\Release\
- Copia ffmpeg.exe y ffprobe.exe en la carpeta Release, junto a server_app.exe.
- Datos (tokens, caché, miniaturas, progreso) en %APPDATA%\MiStreaming.
- Cerrar la ventana la oculta en la bandeja; "Salir" en el menú del icono cierra el servidor.
- "Abrir puertos en el firewall" crea reglas TCP (API) y UDP 41234 (descubrimiento) en red privada.
- Opcional, para no ver parpadeo al arrancar con Windows: en windows/runner/flutter_window.cpp,
  elimina/comenta this->Show() dentro de SetNextFrameCallback (la app ya se oculta sola con --minimized).
- Para distribuir: comprime la carpeta Release (o crea un instalador con Inno Setup).

## Servidor de consola
cd server && dart pub get && dart run bin/server.dart "D:\Videos" 8080
(los datos van a ./data; tokens.json ahora vive ahí, así que hay que volver a emparejar)

## Cliente
flutter pub get (en client/) y flutter run. Manifiesto: INTERNET + usesCleartextTraffic="true".

## Fase 6 — control remoto
- Todos los dispositivos conectados aparecen en el icono de "cast" de la biblioteca.
- Desde cualquiera puedes pausar, saltar ±30 s o parar la reproducción de otro.
- Mantén pulsado un video de la biblioteca para reproducirlo en otro dispositivo.
- El servidor vigila la carpeta: al añadir o quitar videos reescanea solo y avisa a los clientes.

## Primeros pasos tras descomprimir (PowerShell, desde la carpeta mi_streaming)
cd packages\server_core; dart pub get
cd ..\..\server;        dart pub get
cd ..\client;           flutter pub get
cd ..\server_app;       flutter pub get
# Cada carpeta es un proyecto independiente: no ejecutes "flutter create" en la raíz.
# android/ va dentro de client/ y windows/ dentro de server_app/.

## Mejoras posteriores
- Miniaturas: el servidor prueba JPG y luego PNG y registra el error exacto de ffmpeg si falla
  (panel "Registro" de la app del servidor). El cliente reintenta al llegar los metadatos o al refrescar.
- El servidor avisa a los clientes cuando termina de analizar metadatos (la biblioteca se refresca sola).
- Android nativo (Kotlin): imagen en imagen y soporte de Android TV. Ver android_native/.

## Fase 7 — modo teatro y perfiles (estilo Netflix / Plex)
- En la biblioteca, el icono de teatro (🎭) abre el modo teatro; el icono de lista vuelve a la vista clásica.
  La elección se recuerda.
- Modo teatro: cartel principal con fondo grande, filas "Continuar viendo", "Agregados recientemente",
  una fila por género, "Sin identificar" y "Toda la biblioteca". Toca una carátula para ver su ficha;
  mantenla pulsada para reproducir, enviarla a otro dispositivo o editar su perfil.
- Los datos salen de TMDB (carátula, fondo, sinopsis, valoración, reparto, año, géneros, id de IMDb).
  Clave gratis en themoviedb.org → Ajustes → API. Se escribe en la ventana del servidor
  ("Carátulas y sinopsis (TMDB)") o en consola: `dart run bin/server.dart "D:\Videos" 8080 TU_CLAVE`
  (o variable de entorno TMDB_KEY). Acepta la clave v3 o el token de lectura v4.
- Al escanear, el servidor identifica solo cada video por su nombre de archivo ("Dune.2024.1080p.mkv").
  Lo que no acierte se corrige en la ficha → "Editar perfil" → "Buscar en TMDB".
- Editor de perfil: título, año, valoración, duración, lema, géneros, dirección, reparto, sinopsis y
  URL de carátula/fondo propios. "Restablecer perfil" borra todo y vuelve al nombre del archivo.
- Datos en `profiles.json` y carpeta `art/` dentro de la carpeta de datos del servidor.
- Sin clave de TMDB todo sigue funcionando: los perfiles se editan a mano.

## Fase 8 — series y capítulos (como Plex)
- El servidor detecta las series por la carpeta y el nombre del archivo. La serie es el nombre de la
  carpeta (se saltan las carpetas "Temporada N"); el capítulo sale del nombre del archivo.
  Formatos reconocidos: `S01E02`, `1x02`, `Temporada 1 Capitulo 2`, y dentro de una carpeta
  "Temporada N" también `Capitulo 2` o `02 - Nombre.mkv`.
      Series/Breaking Bad (2008)/Temporada 1/Breaking.Bad.S01E02.mkv
      Series/Dark/Season 2/05 - Algo.mkv
      Mr.Robot.S01E01.mkv                     (suelto: la serie sale del nombre del archivo)
- Con clave de TMDB, la serie se enlaza una vez (carátula, fondo, sinopsis, reparto) y cada capítulo
  recibe su nombre, número, sinopsis e imagen. Sin clave, se muestran con el nombre del archivo
  ("Episodio N" si no trae nombre).
- En el modo teatro las series aparecen como una sola carátula (filas "Series" y "Películas").
  Al tocarla se abre su ficha con todos los capítulos agrupados por temporada, con progreso, y un
  botón para reanudar el capítulo que toca. Mantén pulsada una serie o un capítulo para más opciones.
- ¿Serie mal identificada? Ficha → "¿No es esta serie? Corregir" → elige la correcta en TMDB.
- Los capítulos siguen en la vista de lista clásica como "Serie · T1E02 · Nombre".
- API nueva: GET /api/shows, GET /api/shows/<id>, imágenes en /api/shows/<id>/poster|backdrop y
  /api/videos/<id>/still.

## Fase 9 — peticiones (películas que aún no tienes)
- Icono "+ lista" (Peticiones) en la barra de la biblioteca y del modo teatro. Dos pestañas:
  **Explorar** (catálogo de TMDB, sin video) y **Pedidas** (lo que han pedido todos los dispositivos).
- Explorar usa los endpoints `discover` de TMDB: **Populares**, **Mejor valoradas** (mínimo 300 votos),
  **Estrenos del año** y **Por género**, más una búsqueda por título (`search/movie`).
- Scroll infinito: cada página trae 20 películas y se pide la siguiente al acercarte al final.
  TMDB limita a 500 páginas por combinación de filtros (el servidor lo respeta).
- Pedir una película guarda solo su id de TMDB en `requests.json` (más un resumen mínimo para listarla
  y los dispositivos que la pidieron). No se guarda el catálogo.
  Si varios dispositivos piden lo mismo, queda una sola petición; "Quitar" solo retira la tuya.
- Las películas que ya están en la biblioteca se marcan "En biblioteca" y no se pueden pedir.
  Las pedidas que luego añadas aparecen como "Ya disponible".
- Requiere la clave de TMDB en el servidor. Respuestas de TMDB en caché 10 min.
- API nueva: GET /api/tmdb/discover?list=popular|top|year|genre|search&page=&genre=&year=&q=,
  GET /api/tmdb/genres, GET/POST /api/requests (`{"tmdbId": 123}`), DELETE /api/requests/<tmdbId>.

### Peticiones en el servidor
- La ventana del servidor tiene una tarjeta **Peticiones** con lo que piden los dispositivos
  (carátula, título, quién la pidió y cuándo). También se anotan en el panel "Registro".
- **Añadir a la biblioteca** (icono de +): eliges el archivo de la película, el servidor lo **copia o mueve**
  a la raíz de la carpeta de videos como "Título (año).ext", reescanea y lo enlaza con su ficha de TMDB
  **por id** (carátula, sinopsis...). Los dispositivos ven la petición como "Ya disponible".
  Va en la raíz a propósito: 2 o más videos sueltos en una misma subcarpeta se toman por una serie.
- Menú ⋮: copiar el título (para buscar el archivo), abrir la ficha en TMDB y **Quitar petición**
  (la borra para todos).
- **Series**: en una petición de serie el icono (lista con +) abre un selector de archivos donde eliges
  **varios capítulos** a la vez. Una ventana muestra cada archivo con su **temporada** y su **capítulo**
  (los sugiere por el nombre: S01E02, 1x02, "Capítulo 2"...; todo editable, y hay un campo
  "Temporada para todos"). Al confirmar (**Copiar** o **Mover**) quedan en
  `<Serie (año)>/Temporada NN/<Serie> SxxExx.ext`, o sea, cada temporada en su **subcarpeta dentro de la
  carpeta de la serie** ("Especiales" para la temporada 0). Se reescanea, se enlaza la serie con TMDB
  **por id** y se traen los nombres de los capítulos.
  - Sirve también para **añadir una temporada nueva** o **completar** una que ya está: si la serie ya
    está en la biblioteca se usa su misma carpeta (y la subcarpeta de la temporada si ya existía), y el
    icono sigue disponible (en verde) aunque la serie ya esté. Los capítulos que ya existen no se pisan:
    se omiten y se avisa.

## Fase 10 — avisos de peticiones, estado de dispositivos y video en la ficha de película
Tras actualizar, ejecuta `flutter pub get` en `server_app/` (nueva dependencia: `local_notifier`).

### Notificación de Windows al llegar una petición (server_app)
- Cuando un dispositivo pide una película, el servidor muestra un aviso de Windows
  ("Nueva petición — Sala pidió: Dune (2024)"). Funciona con la ventana oculta en la bandeja;
  al pulsar el aviso se abre la ventana.
- Solo avisa si ese dispositivo no la había pedido ya. Si otros dispositivos ya la habían pedido,
  el aviso lo indica.
- La primera vez se crea un acceso directo en el menú Inicio (Windows lo exige para avisos de
  apps sin instalador). Si no ves los avisos, revisa que el modo "No molestar" / asistente de
  concentración de Windows no los esté silenciando.

### Dispositivos con indicador de estado y nombre propio (server_app)
- Tarjeta **Dispositivos emparejados**: punto **verde** = conectado ahora; punto **naranja** =
  vinculado pero desconectado. Cabecera con el resumen ("2 de 3 conectados").
- Icono de lápiz: asigna un nombre al dispositivo (vacío o "Restablecer" vuelve al original).
  Ese nombre se usa en la ventana del servidor, en las peticiones, en el aviso de Windows y en la
  lista de dispositivos de "cast" de los clientes.
- Los nombres se guardan en `device_names.json` (junto a `tokens.json`). El nombre original del
  dispositivo no se toca: es con el que el cliente reconoce cuáles son sus peticiones.
- El servidor hace ping al WebSocket cada 15 s: si un móvil pierde el Wi-Fi sin cerrar la conexión,
  pasa a naranja en unos segundos. "Revocar" ahora también corta la conexión si estaba conectado.

### Video en la ficha de película (client)
- Igual que las series listan sus capítulos abajo, la ficha de una película muestra, al final,
  una fila con la imagen del video, duración, progreso, "Visto" y datos del archivo
  (calidad, códec, tamaño). Tocar reproduce; mantener pulsado abre las opciones
  (reproducir en otro dispositivo, editar perfil...).

## Fase 11 — descargas (ver películas con el servidor apagado)
Tras actualizar, ejecuta `flutter pub get` en `client/` (nueva dependencia: `path_provider`). El servidor no cambia.

### Descargar
- En la ficha de una película hay un botón **Descargar** (también en el menú de mantener pulsado). Pide confirmación
  mostrando el tamaño: se baja el **archivo original** (el mismo que el Direct Play), así que ocupa lo que pesa en el servidor.
- Junto al video se guardan en el dispositivo: **carátula, fondo, miniatura, la ficha completa** (título, año, valoración,
  duración, lema, géneros, dirección, reparto, sinopsis, IMDb) y los **subtítulos externos**. Los subtítulos incrustados
  ya vienen dentro del video.
- Una descarga a la vez, con cola. Se puede **pausar, reanudar y cancelar**; se reanuda por donde iba (HTTP Range).
  Si se corta la conexión o se cierra la app, queda como "Interrumpida" y se reanuda sola cuando el servidor vuelve.
- Icono ⬇ en la barra (teatro y lista) → pantalla **Descargas**: estado, progreso, espacio usado y eliminar.
- Datos en `<carpeta de datos de la app>/downloads/<id>/`; el índice, en SharedPreferences. Desinstalar la app los borra.

### Servidor apagado
- Si el servidor no responde, la app abre un **teatro sin conexión** con solo las películas descargadas: cartel principal,
  "Continuar viendo", "Descargadas recientemente", filas por género y búsqueda. Todo (imágenes y datos) sale del dispositivo.
- Siguen disponibles **Peticiones** (se envían al volver el servidor) y la gestión de **Descargas**.
- La reproducción es local (sin transcodificación, sin intro/capítulo siguiente). Audio y subtítulos se eligen en el menú ⚙.
- El progreso que veas sin conexión se guarda en el dispositivo y **se sube al servidor** al volver. Cada dispositivo tiene
  su propio progreso y su propio "Continuar viendo": lo que ves en uno no afecta a los demás,
  y un dispositivo nuevo empieza limpio. En Ajustes → Reproducción puedes reiniciar el progreso
  de ese dispositivo.
- Si corriges el perfil de una película en el servidor (título, carátula, sinopsis...), la copia descargada se **actualiza sola**
  la próxima vez que se conecte.

## Fase 12 — descargas de series, ajustes y gestor de descargas
No hay dependencias nuevas ni cambios en el servidor. Archivos nuevos/cambiados en `client/lib/`:
`downloads.dart` (reescrito), `settings.dart` (nuevo), `core.dart`, `api.dart`, `main.dart`, `theater.dart`.

### Series
- En la ficha de una serie, botón **Descargar**: toda la serie, una temporada, solo capítulos sin ver o
  desde el capítulo que toca. Cada capítulo también tiene su icono de descarga (estado y progreso).
  Mantener pulsada una serie → "Descargar capítulos...".
- Cada capítulo es una descarga normal (pausar, reanudar, cancelar). Se guarda además la ficha, carátula y
  fondo de la serie, y la imagen de cada capítulo.
- Sin servidor: el teatro sin conexión muestra una carátula por serie; su ficha lista los capítulos
  descargados por temporada, con "Reanudar T1 · E3" y "Siguiente episodio" al terminar uno.

### Descargas (pantalla reorganizada)
- Pestañas **En curso** (con puesto en la cola), **Películas** y **Series** (agrupadas, con acciones por serie).
- Resumen con espacio usado y progreso global; pausar/reanudar todo; "Descargar la siguiente" para priorizar.

### Ajustes (icono de engranaje)
- Servidor: actualizar biblioteca, identificar en TMDB, olvidar servidor.
- Biblioteca: vista Teatro / Lista. Dispositivos: control remoto.
- Descargas: simultáneas (1-3), reanudar solas, eliminar lo ya visto, eliminar todo.
- Las barras de arriba quedan en: buscar, peticiones, descargas y ajustes.

## Fase 13 — Explorar mejorado (peticiones)

### Categorías (chips de la pestaña Explorar)
- **Populares**, **Tendencia** (semana), **Mejor valoradas**, **Más vistas**, **Recientes**, **En cines** /
  **En emisión** (series), **Próximamente**, **Estrenos del año**, **Por género** y **Para ti**.
- "Más vistas" ordena por número de votos en TMDB (TMDB no publica visualizaciones; es el mejor equivalente).
- "Para ti" mezcla los títulos que TMDB recomienda a partir de lo pedido y de la biblioteca; sin nada de
  donde partir, muestra la tendencia.
- En Populares, Mejor valoradas y Más vistas hay una fila de atajos: **Siempre**, los últimos 10 años y
  décadas → "mejor valoradas de todos los tiempos" y "mejor valoradas de 2019" en un toque.

### Filtros (icono con contador)
- Año exacto o década, valoración mínima, género, idioma original, orden, y **estado de la serie**
  (en emisión / finalizada / cancelada). Se combinan entre sí y con la categoría; los activos salen como
  chips que se quitan uno a uno.
- Tendencia y En cines usan un endpoint fijo de TMDB y no admiten filtros.

### Búsqueda
- Sugerencias mientras escribes (primeros resultados) y búsquedas recientes.
- Búsqueda por año: filtro de año, o escribirlo al final ("Dune 2021"); si así no sale nada, se busca el texto completo.

### Estado de las series
- La ficha muestra el estado (En emisión / Finalizada / Cancelada), temporadas, episodios, próximo o último
  episodio, y títulos "Parecidas". TMDB solo da el estado en la ficha de cada serie, no en las listas.

### Técnico
- `shared`: `ExploreFilters`, `buildDiscoverQuery`, `TmdbInfo`; servidor y cliente (TMDB directo sin servidor)
  usan el mismo código.
- Servidor: `/api/tmdb/discover` acepta `yearFrom`, `yearTo`, `minRating`, `sort`, `lang`, `status`;
  nuevas rutas `/api/tmdb/<type>/<id>/info` y `/recommendations`.

## Fase 14 — perfiles de usuario (¿quién está viendo?)
Sin dependencias nuevas. Servidor `0.5.0`. Un servidor anterior sigue funcionando con este cliente (simplemente no pide perfil).
No confundir con el "perfil" de una película (la ficha de TMDB): aquí un perfil es una persona.

### Qué es un perfil
- **Nombre de usuario**: es el identificador. 2-20 caracteres (letras, números, `.`, `-`, `_`, sin espacios), único sin distinguir
  mayúsculas. No se puede cambiar después: el progreso y las peticiones cuelgan de él.
- **Avatar**: uno de los `.jpg` de la carpeta de avatares del servidor (opcional; sin avatar se muestra la inicial).
- **PIN** (opcional): 4 dígitos. Se guarda con sal y hash, nunca en claro. 5 fallos seguidos bloquean ese perfil 60 s.
- Hasta 8 perfiles por servidor.
- **Lo que pasa a ser del perfil** (antes era del dispositivo): progreso, "Continuar viendo", y las peticiones
  (en el servidor aparecen con el nombre de usuario). Cada perfil empieza limpio. Los dispositivos siguen emparejándose con el PIN de siempre.

### Carpeta de avatares
- Servidor de Windows: `%APPDATA%\MiStreaming\avatars` (pestaña **Perfiles** → "Abrir carpeta de avatares").
- Servidor de consola: `data/avatars` (ya existe vacía en `server/data/avatars`).
- Se relee en cada consulta: basta con copiar un `.jpg` para que aparezca, sin reiniciar.
- El id del avatar es el nombre del archivo sin `.jpg`: solo letras, números, `-` y `_` (`panda.jpg`, `astronauta_02.jpg`).
  Se ordenan por nombre. Los archivos que no cumplan se ignoran y la pestaña Perfiles dice cuáles y por qué.

#### Herramienta de recorte (no hace falta preparar la imagen a mano)
El servidor convierte cualquier imagen (JPG, PNG, WebP, GIF, BMP, TIFF, ICO; corrige la orientación de las fotos del móvil y aplana las
transparencias) en un JPG de 512 × 512 px listo para usar:
- **Servidor de Windows** → pestaña **Perfiles** → **Añadir imagen**: eliges el archivo, arrastras para encuadrar, acercas con la rueda o el
  control, o pasas a **Ajustar entera** (imagen completa centrada con fondo difuminado, oscuro, blanco o negro) y le pones nombre.
  **Arreglar carpeta** convierte de una vez los archivos de la carpeta que no cumplan; los originales pasan a `avatars/originales`.
- **Servidor de consola** → `server.exe avatar foto.png [--id panda] [--ajustar] [--zoom 1.5] [--x -0.3] [--y 0] [--fondo blanco] [--reemplazar]`
  y `server.exe avatar --arreglar`. Ver `server.exe avatar --ayuda`.

#### Configuración de imagen para la app que crea los avatares
| Parámetro | Valor |
|---|---|
| Formato | JPEG (`.jpg`), baseline o progresivo, sRGB, sin transparencia |
| Tamaño | **512 × 512 px**, cuadrado (el servidor no recorta ni redimensiona) |
| Calidad | 85-90 (suele quedar en 40-120 KB) |
| Peso máximo | 2 MB (límite duro: más pesado se ignora) |
| Forma | Cuadrada y sin esquinas redondeadas: la app la recorta en círculo |
| Margen de seguridad | Sujeto centrado dentro del círculo inscrito, ~10 % de margen (las esquinas se pierden) |
| Nombre | `[A-Za-z0-9_-]+.jpg`, sin espacios ni acentos |
Se muestra de 28 px (barra) a 112 px (selector); 512 px sale nítido hasta en pantallas de 3x y TV.

### Uso en el cliente
- Al abrir la app sin perfil activo sale **¿Quién está viendo?** (crear, elegir y administrar). Un perfil con PIN lo pide al elegirlo y al abrir la app.
- El avatar de la barra superior cambia de perfil. En Ajustes → Perfil: cambiar de perfil y editar avatar/PIN.
- El primer perfil que crees en un dispositivo puede **traer el progreso que ya tenía** (casilla al crearlo).
- Cambiar o quitar el PIN, cambiar el avatar y borrar el perfil piden el PIN actual. Si se olvida, el servidor lo quita desde **Perfiles**.
- Borrar un perfil elimina su progreso y sus peticiones (las que nadie más haya pedido). Revocar un dispositivo no borra perfiles.
- El servidor avisa por WebSocket cuando cambia la lista de perfiles, así que los demás dispositivos se actualizan solos.

### Servidor de escritorio
Nueva pestaña **Perfiles**: lista (avatar, PIN, dispositivos que lo usan, última vez visto), quitar PIN, eliminar perfil y abrir la carpeta de avatares.

### API nueva
- `GET /api/profiles` → `{items, current, max, avatarCount, hasDeviceProgress}`; `POST /api/profiles` `{username, avatar?, pin?, importProgress?}`
  (el dispositivo pasa a usar el perfil nuevo); `PUT /api/profiles/<u>` `{avatar?, pin?, removePin?, currentPin?}`;
  `DELETE /api/profiles/<u>` (PIN en el encabezado `x-profile-pin`); `POST /api/profiles/<u>/select` `{pin?}`.
- `GET /api/avatars` y `GET /api/avatars/<id>` (JPEG, `?v=` para la caché).
- El perfil activo de cada dispositivo vive en el servidor (`device_profiles.json`); los perfiles, en `users.json`.
- Sin perfil activo el servidor no guarda progreso (responde 409) y devuelve posiciones a 0.

### Límites a tener en cuenta
- El PIN es un bloqueo familiar, no seguridad fuerte: son 4 dígitos. Cambiar de perfil con PIN lo exige el servidor;
  pedir el PIN al abrir la app lo hace el cliente.
- El progreso visto sin conexión se sube al perfil que estaba activo; al cambiar de perfil se sube antes de cambiar.
- Las peticiones hechas antes de esta fase conservan el nombre del dispositivo y ya no cuentan como "tuyas".

## Fase 15 — actualización automática del cliente Android

Dejas un `.apk` nuevo en la carpeta `updates/` del servidor y los móviles se actualizan solos.

### Cómo se usa
1. Sube `version` en `client/pubspec.yaml` **incluyendo el número de build**: `0.2.0+2`. El número tras el `+` es el
   `versionCode` y **debe aumentar en cada versión** (Android no instala una versión igual o menor).
2. Compila: `flutter build apk --release` (APK único; **no** uses `--split-per-abi`, cambia el versionCode por ABI).
3. Copia `build/app/outputs/flutter-apk/app-release.apk` a la carpeta de actualizaciones del servidor
   (`%APPDATA%\MiStreaming\updates`, botón **Abrir carpeta de actualizaciones** en Ajustes de la app de escritorio).
4. En unos segundos el servidor lee la versión del APK, calcula su SHA-256 y avisa por WebSocket. Los clientes
   conectados muestran "Actualización disponible"; los demás lo comprueban al abrir la app / reconectar.
   Si hay varios `.apk`, se ofrece el de `versionCode` más alto. Los APK dañados o a medio copiar se ignoran (se ve el motivo).

### Medidas para que funcione
- **Misma firma siempre.** Android rechaza una actualización firmada con otra clave. El release usaba la clave de
  depuración de cada PC. Crea un keystore una vez y **guárdalo a salvo** (si lo pierdes, hay que desinstalar y reinstalar):
  `keytool -genkey -v -keystore mistreaming.jks -keyalg RSA -keysize 2048 -validity 10000 -alias mistreaming`
  y crea `client/android/key.properties`:
  ```
  storeFile=../mistreaming.jks
  storePassword=...
  keyAlias=mistreaming
  keyPassword=...
  ```
  `build.gradle.kts` lo usa si existe. **El primer APK con el keystore nuevo ya no actualiza encima de uno firmado con
  la clave de depuración**: instálalo a mano una vez (desinstalando antes); de ahí en adelante todo es automático.
- **Mismo paquete** (`com.example.client`): el cliente rechaza un APK de otro paquete.
- **Integridad**: el cliente comprueba tamaño y SHA-256 antes de instalar; la descarga se reanuda si se corta.
- **Autenticación**: el APK solo se sirve con el token de un dispositivo emparejado (`GET /api/update/android/apk`, con Range).
- **Permiso**: la primera vez Android pide "Permitir instalar apps de esta fuente"; la app abre ese ajuste y, al volver,
  se pulsa Instalar de nuevo (el archivo ya está descargado).
- No interrumpe la reproducción: el aviso solo sale en la pantalla principal, una vez por versión ("Más tarde" la
  silencia); siempre se puede instalar desde Ajustes → Actualización.
- Los datos (perfiles, descargas, sesión) se conservan: es una actualización, no reinstalación.

### API nueva
- `GET /api/update/android` → `{available, package, versionCode, versionName, size, sha256}` (`{available:false}` si no hay APK).
- `GET /api/update/android/apk` → el APK. WebSocket: mensaje `{"type":"update"}` cuando cambia.

### Notas
- Parte nueva en `packages/server_core/lib/src/updates.dart` (lector de ZIP + manifest binario, sin dependencias) y
  `client/lib/updater.dart`. Nuevo en el cliente: dependencia `crypto`; Kotlin: `MainActivity.kt` (también en `android_native/`).
- Tras copiar los archivos ejecuta `flutter pub get` en `client/` y reconstruye. Esta versión no se compiló ni probó en el
  entorno donde se escribió (sin Dart/Flutter): si `flutter analyze` marca algo, avísame.

## Fase 16 — novedades (capítulos nuevos de series que ya tenías)
Sin dependencias nuevas. Servidor `0.6.0`. Un servidor anterior sigue funcionando con este cliente (la campanita
simplemente no muestra nada).

### Qué cuenta como "nuevo"
- Un capítulo es nuevo si **su serie ya estaba en la biblioteca** cuando llegó: se compara su fecha de alta (la misma de
  "Agregados recientemente") con la del **primer capítulo** de la serie. Si llegó más de **24 horas después**, es nuevo.
- Una **serie que se añade de golpe** (todos sus capítulos dentro de las primeras 24 h) **no avisa**. Los capítulos que
  lleguen después de esa ventana, sí.
- Lo que ya había en la biblioteca al actualizar **no** cuenta: el servidor anota la fecha en que ejecutó por primera vez
  esta versión (`baselineMs` en `news.json`) y solo avisa de lo posterior.
- Las novedades duran 30 días (máx. 50 series) y desaparecen solas cuando ese perfil ya vio todos los capítulos nuevos.
- Es **por perfil**: qué novedades abrió y qué capítulos vio es de cada persona.

### En el cliente
- **Campanita** con contador en la barra (teatro y lista). Abre **Novedades**: una entrada por serie (como Netflix) con la
  imagen del primer capítulo nuevo sin ver, "Nuevo capítulo · T2 · E5" o "3 capítulos nuevos · T2 · E5–E7", cuándo llegó y
  un botón de reproducir. Un punto rojo marca lo que aún no abriste; "Marcar todo como leído" (✓✓) apaga todos los puntos.
- Abrir la serie (desde Novedades o desde la biblioteca) apaga su punto. Dentro de la serie, los capítulos nuevos que no has
  visto llevan la etiqueta **NUEVO** hasta que los veas.
- Si llega un capítulo mientras tienes la app abierta, sale un aviso breve ("Nuevo capítulo de Dark · T2 · E5") con acceso
  directo a Novedades (no interrumpe el reproductor, y no avisa al abrir la app ni al cambiar de perfil).
- Se actualiza solo: el servidor ya avisa por WebSocket cuando cambia la biblioteca.

### API nueva
- `GET /api/news` → `{items: [{showId, show, posterV, backdropV, latestMs, unread, episodes: [{id, season, episode, title,
  stillV, durationMs, addedMs, watched}]}], unread}` (del perfil activo).
- `POST /api/news/read` `{"showId": "..."}` marca una; sin cuerpo marca todas. Sin perfil activo responde 409.
- Datos en `news.json` (junto a `progress.json`). Borrar un perfil borra también lo suyo.

### Notas
- Esta versión no se compiló ni probó en el entorno donde se escribió (sin Dart/Flutter): si `flutter analyze` marca algo, avísame.
- La fecha de alta sale de las fechas del archivo la primera vez que el servidor lo ve (la mayor entre modificación y creación).
  Si pruebas con un archivo que ya existía en el disco antes de actualizar el servidor, no contará como nuevo.

## Fase 17 — chat de voz en la sala de espera
Tras copiar los archivos ejecuta `flutter pub get` en `client/` (dependencia nueva: `flutter_webrtc`). Hay que **recompilar el servidor
y el cliente** (el cliente sube a `0.1.7+13`). Un servidor anterior sigue funcionando, pero el chat de voz avisa de que no lo admite.

### Qué hace
- Mientras la función **aún no empieza** (vestíbulo de la pestaña **Sala**), los sentados pueden hablar entre sí. En la tarjeta
  **Chat de voz** hay un interruptor para **activar y desactivar**; ya activado, un botón para **silenciar el micrófono** y otro para
  elegir **altavoz / auricular**.
- **Quién habla se ve en la sala**: la butaca de quien habla se ilumina (aro verde con brillo y nombre en verde), una insignia de
  micrófono marca a quienes están en el chat (roja si lo silenciaron) y la tarjeta lista «Hablando: ...».
- Es opcional y de cada persona: quien no lo activa sigue en la sala sin oír ni ser oído.
- **Al pulsar «Comenzar función» el chat de voz se corta solo** para todos (el audio de la película y el micrófono se
  pisarían). Salir de la sala o perder la conexión con el servidor también lo corta.
- La primera vez Android pide permiso de micrófono. Si el dispositivo no tiene micrófono (TV box) se avisa y no se une.

### Cómo funciona
- El audio va **directo entre dispositivos** (WebRTC, cancelación de eco, reducción de ruido y control de ganancia), sin pasar por
  el servidor ni salir de la red local (sin servidores STUN). Es una malla completa: pensado para unas pocas personas (hasta 8 perfiles).
- El servidor solo anota quién está en el chat y reenvía las señales de conexión por el WebSocket existente.
  Quien entra llama a quienes ya estaban, así dos personas nunca se llaman a la vez.
- Quién habla lo mide cada dispositivo con las estadísticas de WebRTC (nivel del audio recibido de cada persona y del micrófono
  propio). Lo propio solo se mide si hay al menos otra persona conectada por voz.
- Una conexión que falla la reintenta quien llamó (2 veces).

### Archivos
- Nuevo: `client/lib/voice.dart` (`voiceProvider`), `client/android/app/proguard-rules.pro`.
- Cambiados: `client/lib/sala.dart` (tarjeta de voz y butacas), `client/lib/cinema.dart` (aro, brillo e insignia de micrófono),
  `client/lib/remote.dart` (campos `voice`/`muted` de `PartyMember` y mensajes de voz), `client/pubspec.yaml`,
  `client/android/app/src/main/AndroidManifest.xml` (RECORD_AUDIO, MODIFY_AUDIO_SETTINGS, red; micrófono **no** obligatorio),
  `client/android/app/build.gradle.kts` (reglas de R8), `packages/server_core/lib/src/remote.dart`.

### Protocolo (WebSocket)
- Cliente → servidor: `voice_join {room}`, `voice_leave {room}`, `voice_mute {room, muted}`, `voice_signal {room, to, data}`.
- Servidor → cliente: `voice_peers {room, peers: [ids]}` (a quién llamar), `voice_signal {room, from, data}`; y en cada miembro de
  `party_state`/`parties` los campos nuevos `voice` y `muted`.
- Solo se admite en salas que no han empezado; `party_start` vacía el chat de voz.

### Notas
- Esta versión no se compiló ni probó en el entorno donde se escribió (sin Dart/Flutter): si `flutter analyze` marca algo, avísame.
- `flutter_webrtc` añade unos 15-20 MB al APK. Si alguna vez la compilación de Android se queja de la versión del plugin, sube o
  baja `flutter_webrtc` en `client/pubspec.yaml`.
- Con la app minimizada Android puede cortar el micrófono; el chat de voz está pensado para usarlo con la app abierta en la Sala.

### Fase 17b — calidad de voz
- Captura solo de voz (sin vídeo), mono a 48 kHz, con cancelación de eco, supresión de ruido de fondo, filtro de graves, detección de
  ruido de teclas/golpes y control automático de volumen.
- Opus ajustado para voz (`_tuneSdp` en `voice.dart`): ~40 kbps, corrección de pérdidas (FEC) para que un paquete perdido no corte
  la voz, sin DTX (no se come el inicio de las frases) y paquetes de 20 ms (10-60 ms según la red).

## Fase 18 — modo TV (Android TV / Google TV)
Mismo cliente, interfaz adaptada cuando detecta una TV (no hay una app aparte). Versión `0.1.8+14`.
- **Detección**: `MainActivity.kt` (`isTv`: modo de interfaz televisión o Leanback) → `NativeBridge.isTv()` → `tvModeProvider`
  (`client/lib/tv.dart`). Para probar el modo TV en un móvil o en el escritorio: `flutter run --dart-define=TV=true`.
- **Foco con mando** (`tv.dart`): tema con aro blanco en botones y relleno claro en listas/interruptores, texto ×1.15 y el widget
  `TvFocusable` (tarjetas y carátulas que no son botón: se enfocan con las flechas, OK las activa, se agrandan con aro blanco y se
  desplazan a la vista; con el dedo no cambia nada). Flutter ya traduce flechas y OK/Select.
- **Navegación** (`shell.dart`): en TV el menú es una barra **lateral izquierda** (Inicio · Sala · Peticiones · Cuenta) en lugar de la inferior.
- **Sala** (`sala.dart`): en TV (o pantalla ancha ≥ 900 dp) butacas a la izquierda y la información a la derecha, sin bajar; el botón
  principal (Abrir sala / Comenzar / Sentarme) toma el foco al abrir.
- **Chat de voz sin micrófono** (`voice.dart`): si no hay micrófono (TV) o se deniega el permiso, se entra **solo para escuchar**
  (insignia de micrófono en silencio) en vez de dar error.
- **Catálogo** (`theater.dart`): en TV las carátulas (`PosterCard`) usan `TvFocusable` (zoom + aro blanco; sustituye al `InkWell`),
  las filas (`ShelfRow`) y la cuadrícula de búsqueda son más grandes, y el botón Reproducir del cartel toma el foco al abrir.
  Sin "mantener pulsado" con el mando: la tecla **Menú** (≡) abre las opciones de una carátula. También sirve al teatro sin conexión.
- **Ficha de película** (`DetailScreen`): cabecera más baja y contenido a ≤ 900 dp de ancho para ver Reproducir sin bajar; Reproducir
  toma el foco al abrir; botones con aro de foco visible (rojo sobre el blanco) y un botón extra "Más opciones" (descargar, otro dispositivo).
- **Reproductor con mando** (`player_controls.dart`, `main.dart`): con los controles ocultos, **OK** pausa/reanuda, **◀ ▶** saltan 10 s
  (se acumulan: −30 s…; manteniendo pulsado siguen) y **▲ ▼** abren los controles con el foco en el botón de pausa. Con los controles
  abiertos las flechas mueven el foco entre botones (volver, −10 s, pausa, +10 s, velocidad, Ver juntos, pistas) y OK pulsa; sin
  actividad se ocultan a los 6 s y el foco vuelve al reproductor. Teclas multimedia (play/pausa, adelantar, retroceder) en cualquier
  plataforma. El botón "Saltar intro / Siguiente episodio" va dentro de los controles en TV: **▼** con los controles ocultos lo enfoca
  y OK lo pulsa. En TV no hay volumen en pantalla (el del mando) ni imagen en imagen. Menú de pistas: el foco empieza en la opción elegida.
- **Ajustes** (`settings.dart`): en TV la lista es una columna centrada (≤ 900 dp) y cada fila lleva aro blanco al enfocarla; el
  interruptor no es una parada de foco aparte (OK sobre la fila lo cambia); el selector de descargas simultáneas muestra aro en el
  segmento enfocado; se oculta "Sin restricción de batería". Los diálogos de confirmación empiezan con el foco en **Cancelar** y el de
  actualización en su botón principal. El teclado de PIN empieza en el **5** y se mueve con las flechas (las cifras del mando también valen).
- **Volver arriba al enfocar el cartel** (`TvScrollTopOnFocus`, `tv.dart`): en TV, al enfocar Reproducir/Reanudar, "Más información",
  "Ver en otro dispositivo" o "Más opciones" (cartel de Inicio y fichas de película/serie), la pantalla sube hasta el principio, como las
  apps de streaming; así la cabecera se ve y la barra superior no tapa el botón.
- **Entrada de texto con el mando** (`TvTextEntry` en `tv.dart`): envuelve cualquier `TextField` (conexión por IP/PIN, buscadores,
  filtros, nombre de perfil, edición y búsqueda TMDB, búsqueda de Sala). Sin editar es un elemento más del foco (aro blanco; las flechas
  pasan de largo) y **OK** abre el teclado de la TV; al cerrarlo (Atrás o ✓) el foco se queda en el campo. Sin teclado en pantalla,
  ▲/▼ salen del campo, ◀/▶ al llegar al principio/final del texto, y OK lo reabre. Los buscadores que se abren con la lupa empiezan
  ya escribiendo. Fuera de TV no cambia nada.