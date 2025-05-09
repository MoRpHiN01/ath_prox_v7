// lib/screens/home_screen.dart

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
  Duration _totalSessionDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise
    ].request();

    _user = Provider.of<UserModel>(context, listen: false);
    final prefs = await SharedPreferences.getInstance();
    _instanceId = prefs.getString('instanceId') ?? const Uuid().v4();
    await prefs.setString('instanceId', _instanceId);

    await _netDisc.start(
      _user.displayName,
      _onNetworkPeer,
      _onNetworkInvite,
      _onNetworkResponse,
      _onNetworkEndSession,
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

  void _onNetworkInvite(String from, String id, String? ip) {
    if (id == _instanceId) return;
    _updatePeer(id, from, ip: ip);
    _showInvite(_peers[id]!);
  }

  void _onNetworkResponse(String responderId, bool accepted) {
    final peer = _peers[responderId];
    if (peer == null) return;
    if (accepted) {
      _startPeerSession(peer);
    } else {
      peer.status = 'declined';
    }
    setState(() {});
  }

  void _onNetworkEndSession(String peerId) {
    final peer = _peers[peerId];
    if (peer != null) {
      _endSessionLocal(peer);
      setState(() {});
    }
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
    if (accepted) {
      _startPeerSession(peer);
    } else {
      peer.status = 'declined';
    }
    setState(() {});

    // send response
    _netDisc.sendInviteResponse(
      _user.displayName,
      _instanceId,
      peer.id,
      peer.ip,
      accepted,
    );

    // log start or decline
    SessionSyncService.syncSessions([
      Session(
        sessionId: DateTime.now().millisecondsSinceEpoch.toString(),
        deviceId: peer.id,
        deviceName: peer.name,
        startTime: accepted ? peer.startTime! : DateTime.now(),
        status: accepted ? SessionStatus.accepted : SessionStatus.declined,
      )
    ]);
  }

  void _startPeerSession(PeerData peer) {
    peer.status = 'connected';
    peer.startTime = DateTime.now();
    peer.elapsed = Duration.zero;
    peer.timer?.cancel();
    peer.timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        peer.elapsed = DateTime.now().difference(peer.startTime!);
      });
    });
  }

  Future<void> _sendInvite(PeerData peer) async {
    final ok = await _netDisc.sendInvite(
      _user.displayName,
      _instanceId,
      peer.id,
      peer.ip,
    );
    peer.status = ok ? 'pending' : 'declined';
    setState(() {});
  }

  void _endSession(PeerData peer) {
    // local cleanup & log
    _endSessionLocal(peer);

    // notify other side
    _netDisc.sendEndSession(
      _user.displayName,
      _instanceId,
      peer.id,
      peer.ip,
    );
  }

  void _endSessionLocal(PeerData peer) {
    peer.timer?.cancel();
    final endTime = DateTime.now();
    final duration = peer.startTime != null
        ? endTime.difference(peer.startTime!)
        : Duration.zero;
    _totalSessionDuration += duration;
    SessionSyncService.syncSessions([
      Session(
        sessionId: peer.id + '_' + endTime.millisecondsSinceEpoch.toString(),
        deviceId: peer.id,
        deviceName: peer.name,
        startTime: peer.startTime!,
        endTime: endTime,
        status: SessionStatus.completed,
      )
    ]);
    peer.status = 'available';
    peer.startTime = null;
    peer.elapsed = Duration.zero;
    setState(() {});
  }

  Future<void> _advertise() async {
    final payload = {
      'proto': 'ath-prox-v1',
      'type': 'status',
      'user': _user.displayName,
      'instanceId': _instanceId,
    };
    try {
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

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final hasName = _user.displayName.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title:
            Text(hasName ? 'Welcome, ${_user.displayName}' : 'Set Display Name'),
        actions: [IconButton(icon: const Icon(Icons.wifi), onPressed: _advertise)],
      ),
      drawer:
          AppDrawer(onNavigate: (r) => Navigator.of(context).pushReplacementNamed(r)),
      body: hasName
          ? Column(
              children: [
                ElevatedButton(
                  onPressed: _advertise,
                  child: Text(_isAdvertising ? 'Stop Advertising' : 'Start Advertising'),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child:
                      Text('Total Session Time: ${_formatDuration(_totalSessionDuration)}'),
                ),
                Expanded(
                  child: _peers.isEmpty
                      ? const Center(child: Text('No peers found.'))
                      : ListView(
                          children: _peers.values.map((p) {
                            final isConnected = p.status == 'connected';
                            Color color;
                            switch (p.status) {
                              case 'pending':
                                color = Colors.yellow;
                                break;
                              case 'connected':
                                color = Colors.red;
                                break;
                              default:
                                color = Colors.green;
                            }
                            return ListTile(
                              leading: CircleAvatar(radius: 8, backgroundColor: color),
                              title: Text(p.name),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Status: ${p.status}'),
                                  if (isConnected)
                                    Text('Session Time: ${_formatDuration(p.elapsed)}'),
                                ],
                              ),
                              trailing: ElevatedButton(
                                onPressed: isConnected
                                    ? () => _endSession(p)
                                    : () => _sendInvite(p),
                                child: Text(isConnected ? 'End Session' : 'Invite'),
                              ),
                            );
                          }).toList(),
                        ),
                ),
              ],
            )
          : Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pushNamed('/profile'),
                child: const Text('Set Display Name'),
              ),
            ),
    );
  }
}

class PeerData {
  final String id;
  String name;
  String status;
  String? ip;
  DateTime? startTime;
  Timer? timer;
  Duration elapsed;

  PeerData({
    required this.id,
    required this.name,
    this.ip,
  })  : status = 'available',
        elapsed = Duration.zero;
}
