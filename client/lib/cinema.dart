import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared/shared.dart' show UserProfile;

import 'api.dart';
import 'profiles.dart' show AvatarCircle;
import 'remote.dart' show PartyMember;

// ===========================================================================
//  Sala de cine: una pantalla con la portada horizontal de lo que se ve y, debajo, filas
//  de butacas. Cada persona de la sala ocupa una butaca con la foto de su perfil.
// ===========================================================================

const _gold = Color(0xFFFFD54F);
const _seatTop = Color(0xFF8E1A22);
const _seatBottom = Color(0xFF4B0B12);
const _cushion = Color(0xFF38070D);
const _speakGreen =
    Color(0xFF4CFF8A); // aro de quien está hablando en el chat de voz

/// Cuántas butacas lleva cada fila (de la más cercana a la pantalla a la del fondo). Si hay
/// más gente que butacas se añaden filas.
List<int> _rows(int people, bool compact) {
  final c = compact ? [4, 5] : [5, 6, 7];
  while (c.fold<int>(0, (a, b) => a + b) < people) {
    c.add(c.last + 1);
  }
  return c;
}

class _Slot {
  _Slot(this.row, this.idx, this.norm);
  final int row, idx;

  /// -1 (extremo izquierdo) .. 1 (extremo derecho) dentro de su fila.
  final double norm;
}

class CinemaHall extends StatelessWidget {
  const CinemaHall({
    super.key,
    required this.api,
    required this.members,
    this.myId,
    this.hostId,
    this.backdropUrl,
    this.title,
    this.playing = false,
    this.waiting = false,
    this.empty = false,
    this.compact = false,
    this.fitHeight,
    this.speaking = const {},
  });

  final Api? api;
  final List<PartyMember> members;

  /// Mi dispositivo (se marca con un aro dorado) y quien creó la sala (lleva una estrella).
  final String? myId, hostId;
  final String? backdropUrl, title;
  final bool playing;

  /// Vestíbulo: la función aún no empezó (pantalla atenuada y etiqueta "Esperando").
  final bool waiting;

  /// Sin función: pantalla apagada y butacas vacías.
  final bool empty;

  /// Solo las butacas, sin pantalla (para la hoja del reproductor).
  final bool compact;

  /// Altura disponible para toda la sala (pantalla + butacas). Si se indica, la sala se
  /// ajusta para verse ENTERA en esa altura, sin desplazarse (TV, tablet, escritorio). Si es
  /// null, la pantalla ocupa todo el ancho y la sala crece hacia abajo (móvil).
  final double? fitHeight;

  /// Ids de dispositivo de quienes están hablando ahora (chat de voz del vestíbulo): su
  /// butaca se ilumina.
  final Set<String> speaking;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth.isFinite ? c.maxWidth : 360.0;
      final counts = _rows(members.length, compact);
      // Butacas: se rellenan desde la fila central hacia fuera y, en cada fila, del centro a
      // los lados, para que la gente se siente junta y no se muevan al entrar otra persona.
      final slots = <_Slot>[
        for (var r = 0; r < counts.length; r++)
          for (var i = 0; i < counts[r]; i++)
            _Slot(
                r,
                i,
                counts[r] == 1
                    ? 0
                    : (i - (counts[r] - 1) / 2) / ((counts[r] - 1) / 2)),
      ]..sort((a, b) {
          double pr(_Slot s) => (s.row - 1).abs() + (s.row < 1 ? 0.5 : 0);
          final c1 = pr(a).compareTo(pr(b));
          if (c1 != 0) return c1;
          final c2 = a.norm.abs().compareTo(b.norm.abs());
          return c2 != 0 ? c2 : a.norm.compareTo(b.norm);
        });
      final bySlot = <int, PartyMember>{};
      for (var i = 0; i < members.length && i < slots.length; i++) {
        bySlot[slots[i].row * 100 + slots[i].idx] = members[i];
      }
      final maxN = counts.last;
      final fit = (!compact && fitHeight != null && fitHeight!.isFinite)
          ? fitHeight
          : null;
      // Tamaño de butaca que cabe a lo ancho (en modo ajustado puede crecer más: TV).
      var base = (((w - 32) / maxN) - 8)
          .clamp(24.0, fit != null ? 72.0 : 54.0)
          .toDouble();
      // Ancho de la pantalla: todo el ancho menos los márgenes de las cortinas.
      var stageW = w - 68;
      if (fit != null) {
        // Se reparte la altura entre la pantalla (16:9) y las filas de butacas.
        final nRows = counts.length;
        var rowsFactor =
            0.0; // altura de las filas = base * rowsFactor + separaciones fijas
        for (var r = 0; r < nRows; r++) {
          final f = nRows == 1 ? 1.0 : 0.78 + 0.22 * r / (nRows - 1);
          rowsFactor += f * 1.12 + 0.42;
        }
        // Márgenes fijos: sobre la pantalla (14), bajo ella (26), final (4) y 6 por fila.
        final avail = fit - 14 - 26 - 4 - 6.0 * nRows;
        final baseW = base;
        base = math.min(baseW, avail * 0.42 / rowsFactor);
        stageW = math.min(stageW, (avail - base * rowsFactor) * 16 / 9);
        // Si la pantalla topa con el ancho, lo que sobra de altura son butacas más grandes.
        base = math.min(baseW, (avail - stageW * 9 / 16) / rowsFactor);
        base = base.clamp(16.0, 72.0).toDouble();
        stageW = math.max(stageW, 120.0);
      }

      final seats = Column(mainAxisSize: MainAxisSize.min, children: [
        for (var r = 0; r < counts.length; r++) ...[
          _row(r, counts, base, bySlot),
          SizedBox(height: base * 0.42 + 6),
        ],
      ]);

      if (compact)
        return Padding(padding: const EdgeInsets.only(top: 8), child: seats);

      return Container(
        height: fit,
        decoration: const BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF07070B), Color(0xFF12060A)])),
        child: Stack(children: [
          // Cortinas a los lados de la pantalla.
          Positioned(
              left: 0, top: 0, bottom: 0, width: 22, child: _curtain(true)),
          Positioned(
              right: 0, top: 0, bottom: 0, width: 22, child: _curtain(false)),
          Column(mainAxisSize: MainAxisSize.min, children: [
            _stage(stageW),
            // Haz de luz del proyector cayendo sobre las butacas.
            Stack(children: [
              Positioned.fill(
                  child: CustomPaint(painter: _BeamPainter(on: !empty))),
              Padding(
                  padding: const EdgeInsets.only(top: 26, bottom: 4),
                  child: seats),
            ]),
          ]),
        ]),
      );
    });
  }

  Widget _curtain(bool left) => DecoratedBox(
      decoration: BoxDecoration(
          gradient: LinearGradient(
              begin: left ? Alignment.centerLeft : Alignment.centerRight,
              end: left ? Alignment.centerRight : Alignment.centerLeft,
              colors: const [Color(0xFF6E0F17), Color(0x006E0F17)])));

  Widget _row(
      int r, List<int> counts, double base, Map<int, PartyMember> bySlot) {
    final n = counts[r];
    final f = counts.length == 1 ? 1.0 : 0.78 + 0.22 * r / (counts.length - 1);
    final size = compact ? base : base * f;
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      for (var i = 0; i < n; i++)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Transform.translate(
            // Las filas se curvan alrededor de la pantalla: los extremos quedan más arriba.
            offset: () {
              final norm = n == 1 ? 0.0 : (i - (n - 1) / 2) / ((n - 1) / 2);
              return Offset(0, -size * 0.34 * norm * norm);
            }(),
            child: _Seat(
              size: size,
              member: bySlot[r * 100 + i],
              api: api,
              me: bySlot[r * 100 + i]?.id == myId && myId != null,
              host: bySlot[r * 100 + i]?.id == hostId && hostId != null,
              speaking: bySlot[r * 100 + i] != null &&
                  speaking.contains(bySlot[r * 100 + i]!.id),
            ),
          ),
        ),
    ]);
  }

  Widget _stage(double stageW) {
    final on = !empty;
    final titleSize = (stageW / 38).clamp(15.0, 26.0).toDouble();
    final tagSize = (stageW / 56).clamp(11.0, 16.0).toDouble();
    final placeholder = const DecoratedBox(
        decoration: BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1A1A22), Color(0xFF0C0C11)])));
    Widget face;
    if (empty) {
      face = Stack(fit: StackFit.expand, children: [
        placeholder,
        const Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.movie_filter_outlined, color: Colors.white24, size: 34),
          SizedBox(height: 8),
          Text('Sin función',
              style: TextStyle(
                  color: Colors.white38,
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
        ])),
      ]);
    } else {
      final url = backdropUrl;
      face = Stack(fit: StackFit.expand, children: [
        placeholder,
        if (url != null && api != null)
          Image.network(url,
              headers: api!.authHeaders,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => const SizedBox()),
        if (waiting) const ColoredBox(color: Color(0x66000000)),
        // Degradado para que se lea el título sobre cualquier portada.
        const DecoratedBox(
            decoration: BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.45, 1],
                    colors: [Color(0x00000000), Color(0xCC000000)]))),
        Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: Row(children: [
              Expanded(
                  child: Text(title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: titleSize,
                          fontWeight: FontWeight.w700,
                          color: Colors.white))),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.circle,
                      size: tagSize * 0.75,
                      color: waiting
                          ? Colors.amber
                          : playing
                              ? const Color(0xFFE50914)
                              : Colors.white54),
                  const SizedBox(width: 5),
                  Text(
                      waiting
                          ? 'Esperando'
                          : (playing ? 'En curso' : 'En pausa'),
                      style:
                          TextStyle(fontSize: tagSize, color: Colors.white70)),
                ]),
              ),
            ])),
      ]);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Center(
        child: SizedBox(
          width: stageW,
          child: Transform(
            alignment: Alignment.bottomCenter,
            // Un poco de perspectiva: la parte de arriba de la pantalla queda más lejos.
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0013)
              ..rotateX(-0.12),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white24, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                        color: on
                            ? const Color(0x55FFFFFF)
                            : const Color(0x14FFFFFF),
                        blurRadius: on ? 46 : 20,
                        spreadRadius: on ? 1 : 0),
                  ],
                ),
                child: ClipRRect(
                    borderRadius: BorderRadius.circular(7), child: face),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BeamPainter extends CustomPainter {
  _BeamPainter({required this.on});
  final bool on;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * 0.16, 0)
      ..lineTo(size.width * 0.84, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(on ? 0x26FFFFFF : 0x0AFFFFFF), const Color(0x00FFFFFF)],
      ).createShader(Offset.zero & size);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_BeamPainter old) => old.on != on;
}

/// Una butaca. Vacía se ve apagada; ocupada lleva la foto de perfil de quien se sienta.
class _Seat extends StatelessWidget {
  const _Seat({
    required this.size,
    required this.member,
    required this.api,
    required this.me,
    required this.host,
    this.speaking = false,
  });

  final double size;
  final PartyMember? member;
  final Api? api;
  final bool me, host;

  /// Está hablando ahora mismo (chat de voz).
  final bool speaking;

  @override
  Widget build(BuildContext context) {
    final m = member;
    final h = size * 1.12;
    final radius = size * 0.29;
    final body = SizedBox(
      width: size,
      height: h,
      child: Stack(clipBehavior: Clip.none, children: [
        // Respaldo.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [_seatTop, _seatBottom]),
              borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(size * 0.42),
                  topRight: Radius.circular(size * 0.42),
                  bottomLeft: Radius.circular(size * 0.14),
                  bottomRight: Radius.circular(size * 0.14)),
              boxShadow: const [
                BoxShadow(
                    color: Colors.black54, blurRadius: 6, offset: Offset(0, 3))
              ],
            ),
          ),
        ),
        // Apoyabrazos.
        Positioned(
            left: -size * 0.07,
            bottom: size * 0.04,
            width: size * 0.12,
            height: size * 0.5,
            child: _arm()),
        Positioned(
            right: -size * 0.07,
            bottom: size * 0.04,
            width: size * 0.12,
            height: size * 0.5,
            child: _arm()),
        // Cojín.
        Positioned(
          left: size * 0.07,
          right: size * 0.07,
          bottom: 0,
          height: size * 0.36,
          child: DecoratedBox(
              decoration: BoxDecoration(
                  color: _cushion,
                  borderRadius: BorderRadius.circular(size * 0.12))),
        ),
        if (m != null) ...[
          Positioned(
            top: size * 0.1,
            left: 0,
            right: 0,
            child: Center(child: _avatar(m, radius)),
          ),
          if (host)
            Positioned(
                top: size * 0.02,
                right: size * 0.0,
                child:
                    Icon(Icons.star_rounded, size: size * 0.28, color: _gold)),
          Positioned(
            left: 2,
            right: 2,
            bottom: size * 0.05,
            child: Text(me ? 'Tú' : m.label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: math.max(8, size * 0.19),
                    fontWeight: me ? FontWeight.w700 : FontWeight.w500,
                    color: speaking
                        ? _speakGreen
                        : (me ? _gold : Colors.white70))),
          ),
        ],
      ]),
    );
    return Opacity(opacity: m == null ? 0.42 : 1, child: body);
  }

  Widget _arm() => DecoratedBox(
      decoration: BoxDecoration(
          color: const Color(0xFF2A0509),
          borderRadius: BorderRadius.circular(size * 0.06)));

  Widget _avatar(PartyMember m, double radius) {
    final profile = m.profile ?? UserProfile(m.label);
    final ring = radius * 2 + 7;
    return SizedBox(
      width: ring,
      height: ring,
      child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            // Aro del avatar: verde y con brillo mientras habla.
            AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.all(1.5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color:
                        speaking ? _speakGreen : (me ? _gold : Colors.white30),
                    width: speaking ? 2.4 : (me ? 2 : 1.2)),
                boxShadow: speaking
                    ? const [
                        BoxShadow(
                            color: Color(0xAA4CFF8A),
                            blurRadius: 16,
                            spreadRadius: 3)
                      ]
                    : const [],
              ),
              child: AvatarCircle(api: api, profile: profile, radius: radius),
            ),
            if (m.buffering)
              Positioned.fill(
                child: Container(
                  decoration: const BoxDecoration(
                      shape: BoxShape.circle, color: Color(0x88000000)),
                  padding: const EdgeInsets.all(8),
                  child: const CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                ),
              ),
            // Insignia de micrófono: solo para quien tiene el chat de voz activado.
            if (m.voice)
              Positioned(
                  right: -3, bottom: -3, child: _micBadge(m.muted, radius)),
          ]),
    );
  }

  Widget _micBadge(bool muted, double radius) {
    final d = math.max(14.0, radius * 0.8);
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: muted ? const Color(0xFFD32F2F) : const Color(0xFF1B5E20),
          border: Border.all(color: Colors.black54, width: 1)),
      child: Icon(muted ? Icons.mic_off_rounded : Icons.mic_rounded,
          size: d * 0.66, color: Colors.white),
    );
  }
}
