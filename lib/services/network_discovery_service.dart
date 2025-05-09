// lib/services/network_discovery_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class NetworkDiscoveryService {
  static const int port = 9999;
  RawDatagramSocket? _socket;
  late String _instanceId;
  late String _displayName;
  Timer? _broadcastTimer;

  /// onFound(peerId, name, ip)
  /// onInvite(from, instanceId, ip)
  /// onResponse(instanceId, accepted)
  /// onEndSession(instanceId)
  Future<void> start(
    String displayName,
    void Function(String peerId, String name, String? ip) onFound,
    void Function(String from, String instanceId, String? ip)? onInvite,
    void Function(String instanceId, bool accepted)? onResponse,
    void Function(String instanceId)? onEndSession,
  ) async {
    _displayName = displayName;
    final prefs = await SharedPreferences.getInstance();
    _instanceId = prefs.getString('instanceId') ?? const Uuid().v4();
    await prefs.setString('instanceId', _instanceId);

    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    _socket!.broadcastEnabled = true;
    _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = _socket!.receive();
      if (dg == null) return;
      try {
        final msg = utf8.decode(dg.data);
        final map = jsonDecode(msg) as Map<String, dynamic>;
        if (map['proto'] != 'ath-prox-v1') return;
        final type = map['type'] as String;
        final srcIp = dg.address.address;

        if (type == 'status') {
          final id = map['instanceId'] as String?;
          final user = map['user'] as String?;
          if (id != null && user != null && id != _instanceId) {
            onFound(id, user, srcIp);
          }
        } else if (type == 'invite' && onInvite != null) {
          final from = map['from'] as String?;
          final instanceId = map['instanceId'] as String?;
          final targetId = map['targetId'] as String?;
          if (from != null && instanceId != null && targetId == _instanceId) {
            onInvite(from, instanceId, srcIp);
          }
        } else if (type == 'response' && onResponse != null) {
          final sourceId = map['instanceId'] as String?;
          final targetId = map['targetId'] as String?;
          final accepted = map['accepted'] as bool? ?? false;
          if (targetId == _instanceId && sourceId != null) {
            onResponse(sourceId, accepted);
          }
        } else if (type == 'end' && onEndSession != null) {
          final sourceId = map['instanceId'] as String?;
          final targetId = map['targetId'] as String?;
          if (targetId == _instanceId && sourceId != null) {
            onEndSession(sourceId);
          }
        }
      } catch (_) {
        // ignore bad JSON
      }
    });

    // broadcast immediately and every 10s
    broadcastStatus();
    _broadcastTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => broadcastStatus(),
    );
  }

  void broadcastStatus() {
    if (_socket == null) return;
    final payload = jsonEncode({
      'proto': 'ath-prox-v1',
      'type': 'status',
      'user': _displayName,
      'instanceId': _instanceId,
    });
    _socket!.send(utf8.encode(payload), InternetAddress('255.255.255.255'), port);
  }

  Future<bool> sendInvite(
    String from,
    String fromId,
    String targetId,
    String? targetIp,
  ) async {
    if (_socket == null || targetIp == null) return false;
    final payload = jsonEncode({
      'proto': 'ath-prox-v1',
      'type': 'invite',
      'from': from,
      'instanceId': fromId,
      'targetId': targetId,
    });
    _socket!.send(utf8.encode(payload), InternetAddress(targetIp), port);
    return true;
  }

  Future<bool> sendInviteResponse(
    String from,
    String fromId,
    String targetId,
    String? targetIp,
    bool accepted,
  ) async {
    if (_socket == null || targetIp == null) return false;
    final payload = jsonEncode({
      'proto': 'ath-prox-v1',
      'type': 'response',
      'from': from,
      'instanceId': fromId,
      'targetId': targetId,
      'accepted': accepted,
    });
    _socket!.send(utf8.encode(payload), InternetAddress(targetIp), port);
    return true;
  }

  Future<bool> sendEndSession(
    String from,
    String fromId,
    String targetId,
    String? targetIp,
  ) async {
    if (_socket == null || targetIp == null) return false;
    final payload = jsonEncode({
      'proto': 'ath-prox-v1',
      'type': 'end',
      'from': from,
      'instanceId': fromId,
      'targetId': targetId,
    });
    _socket!.send(utf8.encode(payload), InternetAddress(targetIp), port);
    return true;
  }

  void stop() {
    _broadcastTimer?.cancel();
    _socket?.close();
    _socket = null;
  }
}
