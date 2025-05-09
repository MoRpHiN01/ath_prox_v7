import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/user_model.dart';
import '../models/session.dart';
import '../services/ble_service.dart';
import '../services/network_discovery_service.dart';
import '../services/session_sync_service.dart';
import '../widgets/app_drawer.dart';
import '../widgets/session_invite_bubble.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final BleService _bleService = BleService();
  final FlutterBlePeripheral _blePeripheral = FlutterBlePeripheral();
  final NetworkDiscoveryService _netDisc = NetworkDiscoveryService();

  late UserModel _user;
  late String _instanceId;
  bool _isAdvertising = false;
  bool _ready = false;

  final Map<String, PeerData> _peers = {};

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    // 1) get permissions
    await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise
    ].request();

    // 2) get user & instanceId
    _user = Provider.of<UserModel>(context, listen: false);
    final prefs = await SharedPreferences.getInstance();
    _instanceId = prefs.getString('instanceId') ?? const Uuid().v4();
    await prefs.setString('instanceId', _instanceId);

    // 3) start discovery & BLE scan
// inside _initialize (or wherever you start discovery):

await _netDisc.start(
  _user.displayName,
  _onNetworkPeer,
  _onNetworkInvite,
  (String responderId, bool accepted) {
    final peer = _peers[responderId];
    if (peer != null) {
      setState(() {
        peer.status = accepted ? 'connected' : 'declined';
      });
    }
  },
);

    _bleService.startScan().listen(
      _onBleResult,
      onError: (e) => Fluttertoast.showToast(msg: 'BLE scan error: $e'),
    );

    setState(() => _ready = true);
  }

  void _onNetworkPeer(String id, String name, String? ip) {
    if (id == _instanceId) return;
    _updatePeer(id, name, ip: ip);
  }

  void _onNetworkInvite(String from, String instanceId, String? ip) {
    _updatePeer(instanceId, from, ip: ip);
    final p = _peers[instanceId];
    if (p != null) _showInvite(p);
  }

  void _onBleResult(ScanResult r) {
    final id = _bleService.extractInstanceId(r);
    if (id == null || id == _instanceId) return;
    final name = _bleService.extractDisplayName(r) ?? 'Unknown';
    final type = _bleService.extractType(r);
    if (type == 'invite') {
      _showInvite(PeerData(id: id, name: name));
    } else {
      _updatePeer(id, name);
    }
  }

  void _updatePeer(String id, String name, {String? ip}) {
    final existing = _peers[id];
    if (existing == null) {
      _peers[id] = PeerData(id: id, name: name, ip: ip);
    } else {
      existing.name = name;
      if (ip != null) existing.ip = ip;
    }
    setState(() {});
  }

  void _showInvite(PeerData peer) {
    showDialog(
      context: context,
      builder: (_) => SessionInviteBubble(
        deviceName: peer.name,
        onAccept: () => _handleResponse(peer, true),
        onDecline: () => _handleResponse(peer, false),
      ),
    );
  }

  void _handleResponse(PeerData peer, bool accepted) {
    setState(() => peer.status = accepted ? 'connected' : 'declined');
    _netDisc.sendInviteResponse(
      _user.displayName,
      _instanceId,
      peer.id,
      peer.ip,
      accepted,
    );
    SessionSyncService.syncSessions([
      Session(
        sessionId: DateTime.now().millisecondsSinceEpoch.toString(),
        deviceId: peer.id,
        deviceName: peer.name,
        startTime: DateTime.now(),
        status:
            accepted ? SessionStatus.accepted : SessionStatus.declined,
      )
    ]);
  }

  Future<void> _advertise() async {
    try {
      final payload = {
        'proto': 'ath-prox-v1',
        'type': 'status',
        'user': _user.displayName,
        'instanceId': _instanceId,
      };
      await _blePeripheral.start(
        advertiseData: AdvertiseData(
          manufacturerId: 0xFF,
          manufacturerData:
              Uint8List.fromList(utf8.encode(jsonEncode(payload))),
        ),
      );
      setState(() => _isAdvertising = true);
    } catch (e) {
      Fluttertoast.showToast(msg: 'Advertise error: $e');
    }
  }

  Future<void> _sendInvite(PeerData peer) async {
    final ok = await _netDisc.sendInvite(
      _user.displayName,
      _instanceId,
      peer.id,
      peer.ip,
    );
    setState(() => peer.status = ok ? 'pending' : 'declined');
  }

  @override
  Widget build(BuildContext ctx) {
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final hasName = _user.displayName.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(hasName
            ? 'Welcome, ${_user.displayName}'
            : 'Set Display Name'),
        actions: [
          IconButton(icon: const Icon(Icons.wifi), onPressed: _advertise)
        ],
      ),
      drawer: AppDrawer(
        onNavigate: (route) =>
            Navigator.of(context).pushReplacementNamed(route),
      ),
      body: hasName
          ? Column(
              children: [
                ElevatedButton(
                  onPressed: _advertise,
                  child:
                      Text(_isAdvertising ? 'Stop Advertising' : 'Start Advertising'),
                ),
                Expanded(
                  child: _peers.isEmpty
                      ? const Center(child: Text('No peers found.'))
                      : ListView(
                          children: _peers.values.map((p) {
                            return ListTile(
                              leading: const CircleAvatar(radius: 8),
                              title: Text(p.name),
                              subtitle: Text('Status: ${p.status}'),
                              trailing: ElevatedButton(
                                onPressed: () => _sendInvite(p),
                                child: const Text('Invite'),
                              ),
                            );
                          }).toList(),
                        ),
                ),
              ],
            )
          : Center(
              child: ElevatedButton(
                onPressed: () =>
                    Navigator.of(context).pushNamed('/profile'),
                child: const Text('Set Display Name'),
              ),
            ),
    );
  }
}

class PeerData {
  final String id;
  String name;
  String status = 'available';
  String? ip;
  PeerData({required this.id, required this.name, this.ip});
}
