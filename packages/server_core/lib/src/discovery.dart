import 'dart:convert';
import 'dart:io';

import 'package:shared/shared.dart';

/// Responde a los broadcasts UDP de los clientes con nombre y puerto HTTP.
Future<RawDatagramSocket> startDiscovery(String name, int httpPort,
    {bool Function()? open}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort,
      reuseAddress: true);
  socket.listen((e) {
    if (e != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d != null && utf8.decode(d.data, allowMalformed: true) == discoveryRequest) {
      // La respuesta se arma en cada petición: así refleja si ahora se pide PIN o no.
      final reply = utf8.encode(jsonEncode(
          ServerInfo(name, httpPort, '0.1.0', open: open?.call() ?? false).toJson()));
      socket.send(reply, d.address, d.port);
    }
  });
  print('Descubrimiento UDP activo en el puerto $discoveryPort');
  return socket;
}