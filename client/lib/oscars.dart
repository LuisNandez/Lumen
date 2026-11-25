import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

const _gold = Color(0xFFD4AF37);
const _goldSoft = Color(0xFFF1D77A);

/// Aviso discreto y elegante de que una película o serie ganó el Óscar.
/// No ocupa espacio si no hay premios. Al tocarlo muestra todas las categorías.
class OscarBanner extends StatelessWidget {
  const OscarBanner(this.info, {super.key});
  final OscarInfo info;

  static String _plural(int n) => n == 1 ? '1 Óscar' : '$n Óscares';

  String get _headline => info.bestPicture
      ? 'GANADORA DEL ÓSCAR A LA MEJOR PELÍCULA'
      : 'GANADORA DE ${_plural(info.wins).toUpperCase()}';

  /// Segunda línea: hasta 3 categorías (sin la de mejor película, que ya va arriba).
  String? get _subline {
    final rest = [for (final c in info.categories) if (!isBestPictureLabel(c)) c];
    if (info.bestPicture && rest.isEmpty) return null;
    if (info.bestPicture) {
      final head = rest.take(2).join(' · ');
      final more = rest.length - 2;
      return more > 0 ? '$head · y $more más' : head;
    }
    final shown = rest.take(3).toList();
    final more = rest.length - shown.length;
    return more > 0 ? '${shown.join(' · ')} · +$more' : shown.join(' · ');
  }

  void _openList(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1B1B),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.emoji_events, color: _gold, size: 22),
                  const SizedBox(width: 10),
                  Text(_plural(info.wins),
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: _goldSoft)),
                ]),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView(shrinkWrap: true, children: [
                    for (final c in info.categories)
                      Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Padding(
                                    padding: EdgeInsets.only(top: 7, right: 12),
                                    child: Icon(Icons.circle,
                                        size: 6, color: _gold)),
                                Expanded(
                                    child: Text(c,
                                        style: const TextStyle(
                                            fontSize: 15, height: 1.3))),
                              ])),
                  ]),
                ),
                const SizedBox(height: 4),
                const Text('Fuente: Wikidata',
                    style: TextStyle(fontSize: 11, color: Colors.white38)),
              ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!info.any) return const SizedBox.shrink();
    final sub = _subline;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeOutCubic,
      builder: (_, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(0, 10 * (1 - t)), child: child)),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Material(
          color: Colors.transparent,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _gold.withOpacity(0.55), width: 1),
              gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [_gold.withOpacity(0.16), _gold.withOpacity(0.03)]),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _openList(context),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                child: Row(children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [_goldSoft, _gold])),
                    child: const Icon(Icons.emoji_events,
                        size: 20, color: Color(0xFF3A2C00)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_headline,
                              style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.3,
                                  color: _goldSoft)),
                          if (sub != null && sub.isNotEmpty)
                            Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text(sub,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 13, color: Colors.white70))),
                        ]),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.white38),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
