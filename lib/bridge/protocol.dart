/// Localhost WebSocket protocol shared with uath-staff.
abstract final class BridgeProtocol {
  static const port = 8787;
  static const host = '127.0.0.1';
  static const wsUrl = 'ws://$host:$port';
}

abstract final class MessageType {
  static const register = 'register';
  static const focus = 'focus';
  static const ping = 'ping';
  static const registered = 'registered';
  static const status = 'status';
  static const nfcTap = 'nfc_tap';
  static const registerRejected = 'register_rejected';
}
