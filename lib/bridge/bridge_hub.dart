import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uath_desktop/bridge/protocol.dart';

class ConnectedTab {
  ConnectedTab({
    required this.tabId,
    required this.staffId,
    required this.staffName,
    required this.socket,
  }) : registeredAt = DateTime.now().toUtc(),
       lastFocusedAt = DateTime.now().toUtc();

  final String tabId;
  final String staffId;
  final String staffName;
  final WebSocketChannel socket;
  final DateTime registeredAt;
  DateTime lastFocusedAt;
}

class BridgeUiState {
  const BridgeUiState({
    required this.wsListening,
    required this.readerConnected,
    required this.readerName,
    required this.connectedTabs,
    required this.reading,
    required this.readerNeedsRecovery,
    this.wsError,
    this.lastMrn,
    this.lastTapAt,
    this.lastReadError,
  });

  final bool wsListening;
  final String? wsError;
  final bool readerConnected;
  final String readerName;
  final int connectedTabs;
  final bool reading;
  final bool readerNeedsRecovery;
  final String? lastMrn;
  final DateTime? lastTapAt;
  final String? lastReadError;

  BridgeUiState copyWith({
    bool? wsListening,
    String? wsError,
    bool clearWsError = false,
    bool? readerConnected,
    String? readerName,
    int? connectedTabs,
    bool? reading,
    bool? readerNeedsRecovery,
    String? lastMrn,
    DateTime? lastTapAt,
    String? lastReadError,
    bool clearLastReadError = false,
  }) {
    return BridgeUiState(
      wsListening: wsListening ?? this.wsListening,
      wsError: clearWsError ? null : (wsError ?? this.wsError),
      readerConnected: readerConnected ?? this.readerConnected,
      readerName: readerName ?? this.readerName,
      connectedTabs: connectedTabs ?? this.connectedTabs,
      reading: reading ?? this.reading,
      readerNeedsRecovery: readerNeedsRecovery ?? this.readerNeedsRecovery,
      lastMrn: lastMrn ?? this.lastMrn,
      lastTapAt: lastTapAt ?? this.lastTapAt,
      lastReadError:
          clearLastReadError ? null : (lastReadError ?? this.lastReadError),
    );
  }
}

/// Routes NFC taps to the focused EMR tab and broadcasts connection status.
class BridgeHub {
  final Map<String, ConnectedTab> _tabs = {};
  final _uiController = StreamController<BridgeUiState>.broadcast();

  var _wsListening = false;
  String? _wsError;
  var _readerConnected = false;
  var _readerName = '';
  var _reading = false;
  var _readerNeedsRecovery = false;
  String? _lastMrn;
  DateTime? _lastTapAt;
  String? _lastReadError;

  Stream<BridgeUiState> get uiStates => _uiController.stream;

  BridgeUiState get currentUiState => BridgeUiState(
        wsListening: _wsListening,
        wsError: _wsError,
        readerConnected: _readerConnected,
        readerName: _readerName,
        connectedTabs: _tabs.length,
        reading: _reading,
        readerNeedsRecovery: _readerNeedsRecovery,
        lastMrn: _lastMrn,
        lastTapAt: _lastTapAt,
        lastReadError: _lastReadError,
      );

  void setWsListening(bool listening, {String? error}) {
    _wsListening = listening;
    _wsError = error;
    _emitUi();
  }

  void setReaderStatus({required bool connected, String name = ''}) {
    _readerConnected = connected;
    _readerName = name;
    _broadcastStatus();
    _emitUi();
  }

  void setReading(bool reading) {
    _reading = reading;
    _emitUi();
  }

  void setReaderNeedsRecovery(bool needsRecovery) {
    if (_readerNeedsRecovery == needsRecovery) {
      return;
    }
    _readerNeedsRecovery = needsRecovery;
    _emitUi();
  }

  void setReadError(String message) {
    _lastReadError = message.trim();
    _emitUi();
  }

  void clearReadError() {
    if (_lastReadError == null) {
      return;
    }
    _lastReadError = null;
    _emitUi();
  }

  void handleSocket(WebSocketChannel socket) {
    late final StreamSubscription sub;
    String? tabId;

    sub = socket.stream.listen(
      (data) {
        if (data is! String) {
          return;
        }
        try {
          final map = jsonDecode(data) as Map<String, dynamic>;
          final type = map['type'] as String?;
          switch (type) {
            case MessageType.register:
              final id = (map['tabId'] as String?)?.trim() ?? '';
              final staffId = (map['staffId'] as String?)?.trim() ?? '';
              final staffName = (map['staffName'] as String?)?.trim() ?? '';
              if (id.isEmpty || staffId.isEmpty) {
                _send(socket, {
                  'type': MessageType.registerRejected,
                  'reason': 'not_authenticated',
                });
                unawaited(socket.sink.close());
                return;
              }
              tabId = id;
              _tabs[id] = ConnectedTab(
                tabId: id,
                staffId: staffId,
                staffName: staffName,
                socket: socket,
              );
              _send(socket, {
                'type': MessageType.registered,
                'readerConnected': _readerConnected,
                'readerName': _readerName,
                'connectedTabs': _tabs.length,
              });
              _broadcastStatus();
              _emitUi();
            case MessageType.focus:
              final id = (map['tabId'] as String?)?.trim() ?? tabId;
              if (id == null) {
                return;
              }
              final tab = _tabs[id];
              if (tab != null) {
                tab.lastFocusedAt = DateTime.now().toUtc();
              }
            case MessageType.ping:
              final id = (map['tabId'] as String?)?.trim() ?? tabId;
              if (id != null && _tabs.containsKey(id)) {
                _send(socket, {
                  'type': MessageType.status,
                  'connectedTabs': _tabs.length,
                  'readerConnected': _readerConnected,
                  'readerName': _readerName,
                });
              }
          }
        } catch (_) {
          // ignore malformed client messages
        }
      },
      onDone: () {
        _removeTab(tabId, socket);
        unawaited(sub.cancel());
      },
      onError: (_) {
        _removeTab(tabId, socket);
        unawaited(sub.cancel());
      },
      cancelOnError: true,
    );
  }

  void emitNfcTap(String mrn) {
    final normalized = mrn.trim();
    if (normalized.isEmpty) {
      return;
    }
    final readAt = DateTime.now().toUtc();
    _lastMrn = normalized;
    _lastTapAt = readAt;
    _lastReadError = null;
    _emitUi();

    final target = _focusedTab();
    if (target == null) {
      return;
    }
    _send(target.socket, {
      'type': MessageType.nfcTap,
      'mrn': normalized,
      'readAt': readAt.toIso8601String(),
    });
  }

  ConnectedTab? _focusedTab() {
    if (_tabs.isEmpty) {
      return null;
    }
    final cutoff = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    ConnectedTab? best;
    for (final tab in _tabs.values) {
      if (tab.lastFocusedAt.isBefore(cutoff)) {
        continue;
      }
      if (best == null || tab.lastFocusedAt.isAfter(best.lastFocusedAt)) {
        best = tab;
      }
    }
    if (best != null) {
      return best;
    }
    // Fallback: most recently registered.
    final sorted = _tabs.values.toList()
      ..sort((a, b) => b.registeredAt.compareTo(a.registeredAt));
    return sorted.first;
  }

  void _removeTab(String? tabId, WebSocketChannel socket) {
    if (tabId != null && _tabs[tabId]?.socket == socket) {
      _tabs.remove(tabId);
    } else {
      _tabs.removeWhere((_, tab) => tab.socket == socket);
    }
    _broadcastStatus();
    _emitUi();
  }

  void _broadcastStatus() {
    final payload = {
      'type': MessageType.status,
      'connectedTabs': _tabs.length,
      'readerConnected': _readerConnected,
      'readerName': _readerName,
    };
    for (final tab in _tabs.values) {
      _send(tab.socket, payload);
    }
  }

  void _send(WebSocketChannel socket, Map<String, dynamic> payload) {
    try {
      socket.sink.add(jsonEncode(payload));
    } catch (_) {}
  }

  void _emitUi() {
    if (!_uiController.isClosed) {
      _uiController.add(currentUiState);
    }
  }

  Future<void> dispose() async {
    await _uiController.close();
    for (final tab in _tabs.values) {
      try {
        await tab.socket.sink.close();
      } catch (_) {}
    }
    _tabs.clear();
  }
}
