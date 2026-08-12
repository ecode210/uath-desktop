import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_pcsc/flutter_pcsc.dart';
import 'package:uath_desktop/bridge/bridge_hub.dart';
import 'package:uath_desktop/nfc/ndef_text_parser.dart';

/// Production NFC poller for ACR122U-style readers (NTAG NDEF Text MRNs).
///
/// Design goals for a hard-to-update desktop binary:
/// - UI never blocks on PC/SC (work runs in a dedicated isolate).
/// - Stalls are detected via heartbeats; isolate restarts are **capped**.
/// - After repeated stalls we stop respawning (avoids zombie FFI threads) and
///   ask the operator to unplug the reader, then use Retry Reader.
/// - Verbose APDU logs only in debug builds.
class NfcReaderService {
  NfcReaderService(this.hub);

  final BridgeHub hub;

  static const _heartbeatTimeout = Duration(seconds: 7);
  static const _maxConsecutiveRestarts = 3;
  static const _watchdogPeriod = Duration(seconds: 2);

  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _controlPort;
  var _running = false;
  String? _errorShownForUid;
  DateTime _lastHeartbeat = DateTime.now();
  Timer? _watchdog;
  var _restarting = false;
  var _consecutiveRestarts = 0;
  var _awaitingManualRecover = false;

  Future<void> start() async {
    if (_running) {
      return;
    }
    _running = true;
    _awaitingManualRecover = false;
    _consecutiveRestarts = 0;
    hub.setReaderNeedsRecovery(false);
    _lastHeartbeat = DateTime.now();
    await _spawnIsolate();
    _watchdog?.cancel();
    _watchdog = Timer.periodic(_watchdogPeriod, (_) {
      unawaited(_watchdogTick());
    });
  }

  Future<void> stop() async {
    _running = false;
    _watchdog?.cancel();
    _watchdog = null;
    _awaitingManualRecover = false;
    hub.setReaderNeedsRecovery(false);
    hub.setReading(false);
    await _tearDownIsolate();
  }

  /// Operator-triggered recovery after the reader was wedged.
  Future<void> recover() async {
    if (!_running || _restarting) {
      return;
    }
    _awaitingManualRecover = false;
    _consecutiveRestarts = 0;
    hub.setReaderNeedsRecovery(false);
    hub.clearReadError();
    hub.setReaderStatus(connected: false, name: '');
    _restarting = true;
    try {
      await _tearDownIsolate();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!_running) {
        return;
      }
      _lastHeartbeat = DateTime.now();
      await _spawnIsolate();
      _logMain('NFC: manual recover - reader isolate started');
    } finally {
      _restarting = false;
    }
  }

  Future<void> _spawnIsolate() async {
    final receive = ReceivePort();
    _receivePort = receive;
    _isolate = await Isolate.spawn(
      _nfcIsolateMain,
      receive.sendPort,
      debugName: 'nfc-pcsc',
      errorsAreFatal: false,
    );
    receive.listen(_onIsolateMessage, onError: (Object error, StackTrace stack) {
      _logMain('NFC isolate port error: $error\n$stack');
      hub.setReaderStatus(connected: false, name: '');
    });
  }

  Future<void> _tearDownIsolate() async {
    try {
      _controlPort?.send(const <String, Object?>{'cmd': 'stop'});
    } catch (_) {}
    // Brief grace for releaseContext; kill cannot interrupt native FFI.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    try {
      _receivePort?.close();
    } catch (_) {}
    try {
      _isolate?.kill(priority: Isolate.immediate);
    } catch (_) {}
    _receivePort = null;
    _isolate = null;
    _controlPort = null;
  }

  Future<void> _watchdogTick() async {
    if (!_running || _restarting || _awaitingManualRecover) {
      return;
    }
    final silent = DateTime.now().difference(_lastHeartbeat);
    if (silent < _heartbeatTimeout) {
      return;
    }
    await _handleStall(silent);
  }

  Future<void> _handleStall(Duration silent) async {
    _restarting = true;
    try {
      _consecutiveRestarts++;
      _logMain(
        'NFC: stall detected (${silent.inMilliseconds}ms quiet, '
        'restart $_consecutiveRestarts/$_maxConsecutiveRestarts)',
      );

      hub.setReading(false);
      hub.setReaderStatus(connected: false, name: '');

      await _tearDownIsolate();

      if (_consecutiveRestarts > _maxConsecutiveRestarts) {
        _enterManualRecovery(
          'NFC reader is stuck. Unplug the USB reader, wait 3 seconds, '
          'plug it back in, then press Retry Reader. '
          'Quit any other NFC software (e.g. NFC Tools).',
        );
        return;
      }

      final backoffMs = math.min(8000, 400 * (1 << (_consecutiveRestarts - 1)));
      hub.setReadError(
        'NFC reader stalled - recovering (attempt $_consecutiveRestarts of '
        '$_maxConsecutiveRestarts). Keep the card off the pad for a moment.',
      );
      await Future<void>.delayed(Duration(milliseconds: backoffMs));
      if (!_running || _awaitingManualRecover) {
        return;
      }
      _lastHeartbeat = DateTime.now();
      await _spawnIsolate();
    } finally {
      _restarting = false;
    }
  }

  void _enterManualRecovery(String message) {
    _awaitingManualRecover = true;
    hub.setReaderNeedsRecovery(true);
    hub.setReadError(message);
    hub.setReaderStatus(connected: false, name: '');
    hub.setReading(false);
    _logMain('NFC: entered manual recovery - waiting for Retry Reader');
  }

  void _onIsolateMessage(dynamic message) {
    if (message is SendPort) {
      _controlPort = message;
      return;
    }
    if (message is! Map) {
      return;
    }
    final type = message['type'] as String?;
    _lastHeartbeat = DateTime.now();

    // Sustained healthy heartbeats after a restart clear the strike counter.
    if (type == 'heartbeat' && _consecutiveRestarts > 0) {
      final n = message['n'];
      if (n is int && n >= 8) {
        _consecutiveRestarts = 0;
        if (_awaitingManualRecover) {
          _awaitingManualRecover = false;
          hub.setReaderNeedsRecovery(false);
        }
      }
    }

    switch (type) {
      case 'reader':
        hub.setReaderStatus(
          connected: message['connected'] as bool? ?? false,
          name: message['name'] as String? ?? '',
        );
      case 'reading':
        hub.setReading(message['value'] as bool? ?? false);
      case 'tap':
        final mrn = message['mrn'] as String?;
        if (mrn != null && mrn.isNotEmpty) {
          _errorShownForUid = null;
          _consecutiveRestarts = 0;
          _awaitingManualRecover = false;
          hub.setReaderNeedsRecovery(false);
          hub.clearReadError();
          hub.emitNfcTap(mrn);
        }
      case 'read_error':
        final error = (message['message'] as String?)?.trim() ?? '';
        final uid = (message['uid'] as String?)?.trim();
        final key = (uid != null && uid.isNotEmpty) ? uid : error;
        if (error.isEmpty) {
          break;
        }
        if (key == _errorShownForUid) {
          break;
        }
        _errorShownForUid = key;
        hub.setReadError(error);
      case 'card_absent':
        _errorShownForUid = null;
      case 'log':
        _logMain(message['message'] as String? ?? '');
      case 'heartbeat':
        break;
    }
  }

  void _logMain(String message) {
    if (kDebugMode && message.isNotEmpty) {
      debugPrint(message);
    }
  }
}

@pragma('vm:entry-point')
void _nfcIsolateMain(SendPort toMain) {
  final fromMain = ReceivePort();
  toMain.send(fromMain.sendPort);

  var running = true;
  fromMain.listen((message) {
    if (message is Map && message['cmd'] == 'stop') {
      running = false;
    }
  });

  unawaited(_nfcIsolateLoop(toMain, () => running));
}

void _log(SendPort toMain, String message) {
  // Main isolate filters to debug builds.
  toMain.send(<String, Object?>{'type': 'log', 'message': message});
}

Future<void> _nfcIsolateLoop(SendPort toMain, bool Function() isRunning) async {
  String? lastUid;
  DateTime? lastEmitAt;
  var awaitingRemoval = false;
  var idleLogCounter = 0;
  var pollCount = 0;
  int? context;
  var pollsOnContext = 0;
  DateTime? removalWaitStarted;

  Future<void> releaseContext() async {
    final ctx = context;
    context = null;
    pollsOnContext = 0;
    if (ctx == null) {
      return;
    }
    try {
      await Pcsc.releaseContext(ctx);
    } catch (_) {}
  }

  while (isRunning()) {
    pollCount++;
    toMain.send(<String, Object?>{
      'type': 'heartbeat',
      'n': pollCount,
    });

    try {
      if (context == null || pollsOnContext >= 40) {
        await releaseContext();
        context = await Pcsc.establishContext(PcscSCope.user);
      }
      pollsOnContext++;

      // After a read, wait briefly with no PC/SC calls so the ACR122 settles
      // before the next cardConnect (presence check).
      if (awaitingRemoval && removalWaitStarted != null) {
        final waited = DateTime.now().difference(removalWaitStarted);
        if (waited < const Duration(milliseconds: 900)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          continue;
        }
      }

      final result = await _pollOnce(
        toMain,
        context: context!,
        awaitingRemoval: awaitingRemoval,
        idleLogCounter: idleLogCounter,
      );
      idleLogCounter = result.nextIdleLogCounter;

      if (!result.noCard && !result.stillPresent) {
        await releaseContext();
      }

      toMain.send(<String, Object?>{
        'type': 'reader',
        'connected': result.connected,
        'name': result.readerName ?? '',
      });

      if (result.noCard) {
        if (awaitingRemoval) {
          _log(toMain, 'NFC: card removed');
          awaitingRemoval = false;
          removalWaitStarted = null;
          lastUid = null;
          toMain.send(const <String, Object?>{'type': 'card_absent'});
          await releaseContext();
        }
        await Future<void>.delayed(result.delay);
        continue;
      }

      if (result.stillPresent) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
        continue;
      }

      awaitingRemoval = true;
      removalWaitStarted = DateTime.now();

      if (result.mrn != null) {
        final uid = result.uid;
        final now = DateTime.now();
        final lastAt = lastEmitAt;
        final recent = lastAt != null &&
            now.difference(lastAt) < const Duration(seconds: 2) &&
            lastUid == uid;
        if (!recent) {
          lastUid = uid;
          lastEmitAt = now;
          toMain.send(<String, Object?>{'type': 'tap', 'mrn': result.mrn});
        }
      } else if (result.error != null) {
        toMain.send(<String, Object?>{
          'type': 'read_error',
          'message': result.error,
          'uid': result.uid,
        });
        lastUid = result.uid ?? lastUid;
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
    } catch (error, stack) {
      _log(toMain, 'NFC poll error: $error\n$stack');
      awaitingRemoval = false;
      removalWaitStarted = null;
      await releaseContext();
      toMain.send(const <String, Object?>{
        'type': 'reader',
        'connected': false,
        'name': '',
      });
      toMain.send(<String, Object?>{
        'type': 'read_error',
        'message':
            'The NFC reader stopped responding. Unplug it, wait a few seconds, '
            'plug it back in, then press Retry Reader if shown. '
            'Keep this app open alone (quit other NFC tools).',
        'uid': 'reader-fault',
      });
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  await releaseContext();
}

class _PollResult {
  const _PollResult({
    required this.connected,
    required this.nextIdleLogCounter,
    this.readerName,
    this.uid,
    this.mrn,
    this.error,
    this.noCard = false,
    this.stillPresent = false,
    this.delay = const Duration(milliseconds: 450),
  });

  final bool connected;
  final String? readerName;
  final String? uid;
  final String? mrn;
  final String? error;
  final bool noCard;
  final bool stillPresent;
  final Duration delay;
  final int nextIdleLogCounter;
}

Future<_PollResult> _pollOnce(
  SendPort toMain, {
  required int context,
  required bool awaitingRemoval,
  required int idleLogCounter,
}) async {
  final readers = await Pcsc.listReaders(context);
  if (readers.isEmpty) {
    return _PollResult(
      connected: false,
      readerName: '',
      noCard: true,
      delay: const Duration(seconds: 2),
      nextIdleLogCounter: idleLogCounter,
    );
  }

  final reader = readers.first;

  CardStruct? card;
  try {
    card = await Pcsc.cardConnect(
      context,
      reader,
      PcscShare.shared,
      PcscProtocol.any,
    );
  } catch (error) {
    final next = idleLogCounter + 1;
    if (kDebugMode && (next == 1 || next % 20 == 0)) {
      _log(toMain, 'NFC: idle (no card) - $error');
    }
    return _PollResult(
      connected: true,
      readerName: reader,
      noCard: true,
      nextIdleLogCounter: next,
    );
  }

  if (awaitingRemoval) {
    try {
      await Pcsc.cardDisconnect(card.hCard, PcscDisposition.leaveCard);
    } catch (_) {}
    return _PollResult(
      connected: true,
      readerName: reader,
      stillPresent: true,
      nextIdleLogCounter: 0,
    );
  }

  toMain.send(const <String, Object?>{'type': 'reading', 'value': true});
  try {
    _log(toMain, 'NFC: card present on "$reader"');

    String? uid;
    String? mrn;
    String? error;
    List<int> lastMemory = const [];

    for (var attempt = 1; attempt <= _maxFullReadAttempts; attempt++) {
      try {
        if (attempt > 1) {
          _log(toMain, 'NFC: retrying full read ($attempt/$_maxFullReadAttempts)');
          await _cycleRfField(card, toMain);
          await Future<void>.delayed(Duration(milliseconds: 80 * attempt));
        }

        uid = await _readUid(card);
        _log(toMain, 'NFC: UID=${uid ?? "(failed)"} (attempt $attempt)');

        if (uid == null) {
          error =
              'The reader detected a card but could not read its ID. '
              'Center the card on the pad and hold still until Reading finishes.';
          continue;
        }

        final memory = await _readUserMemory(card, toMain);
        lastMemory = memory.bytes;
        _log(
          toMain,
          'NFC: user memory ${memory.bytes.length} bytes '
          '(pagesOk=${memory.pagesOk}, pagesFailed=${memory.pagesFailed}, '
          'attempt=$attempt) '
          'hex=${_hexPreview(memory.bytes)} '
          'ascii=${_asciiPreview(memory.bytes)}',
        );

        if (memory.bytes.isEmpty) {
          error = memory.pagesFailed > 0
              ? 'The reader could not read this card’s memory. '
                  'Hold the card still on the center of the pad.'
              : 'No data was read from the card. Keep it on the reader until '
                  'Reading finishes, then try again.';
          continue;
        }

        mrn = parseMrnFromNtagUserMemory(memory.bytes);
        if (mrn != null) {
          _log(toMain, 'NFC: parsed MRN=$mrn');
          error = null;
          break;
        }

        final ascii = _asciiPreview(memory.bytes);
        final incomplete = _ndefPayloadIncomplete(memory.bytes);
        error = incomplete
            ? 'Card read was incomplete (hold still on the pad). Retrying…'
            : ascii.isEmpty
                ? 'Card memory was read, but it is empty or not NDEF Text. '
                    'Write an NDEF Text record with the patient MRN '
                    '(e.g. UATH/PT/2000003).'
                : 'Card was read, but no hospital MRN was found '
                    '("$ascii"). Write an NDEF Text record like '
                    'UATH/PT/2000003.';
        _log(
          toMain,
          incomplete
              ? 'NFC: incomplete NDEF on attempt $attempt - will retry'
              : 'NFC: MRN parse failed for uid=$uid attempt=$attempt',
        );

        if (!incomplete && memory.pagesFailed == 0) {
          break;
        }
      } catch (attemptError, stack) {
        _log(toMain, 'NFC: read attempt $attempt failed: $attemptError\n$stack');
        error = _userMessageForException(attemptError);
      }
    }

    if (mrn == null && error != null && error.contains('Retrying')) {
      final ascii = _asciiPreview(lastMemory);
      error = ascii.isEmpty
          ? 'Could not finish reading the card. Hold it still on the pad and try again.'
          : 'Could not finish reading the card ("$ascii"). '
              'Hold it still on the center of the pad and try again.';
    }

    return _PollResult(
      connected: true,
      readerName: reader,
      uid: uid,
      mrn: mrn,
      error: error,
      delay: const Duration(milliseconds: 300),
      nextIdleLogCounter: 0,
    );
  } catch (errorObj, stack) {
    _log(toMain, 'NFC: read exception: $errorObj\n$stack');
    return _PollResult(
      connected: true,
      readerName: reader,
      error: _userMessageForException(errorObj),
      nextIdleLogCounter: 0,
    );
  } finally {
    toMain.send(const <String, Object?>{'type': 'reading', 'value': false});
    await _safeDisconnectAfterApdu(card, toMain);
  }
}

Future<void> _cycleRfField(CardStruct card, SendPort toMain) async {
  try {
    await Pcsc.transmit(card, [0xFF, 0x00, 0x00, 0x00, 0x04, 0xD4, 0x32, 0x01, 0x00]);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await Pcsc.transmit(card, [0xFF, 0x00, 0x00, 0x00, 0x04, 0xD4, 0x32, 0x01, 0x01]);
  } catch (error) {
    _log(toMain, 'NFC: RF cycle skipped: $error');
  }
}

Future<void> _safeDisconnectAfterApdu(CardStruct card, SendPort toMain) async {
  await _cycleRfField(card, toMain);
  try {
    await Pcsc.cardDisconnect(card.hCard, PcscDisposition.resetCard);
  } catch (error) {
    _log(toMain, 'NFC: reset disconnect failed, trying leave: $error');
    try {
      await Pcsc.cardDisconnect(card.hCard, PcscDisposition.leaveCard);
    } catch (leaveError) {
      _log(toMain, 'NFC: disconnect failed: $leaveError');
    }
  }
}

const _maxFullReadAttempts = 3;
const _maxPageAttempts = 5;

String _userMessageForException(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('sharing') ||
      text.contains('exclusive') ||
      text.contains('access') ||
      text.contains('busy')) {
    return 'The NFC reader is busy or locked by another app. '
        'Quit NFC Tools (and any other NFC software), then press Retry Reader.';
  }
  if (text.contains('removed') || text.contains('reset')) {
    return 'The card was removed before reading finished. '
        'Place it on the reader and hold still.';
  }
  return 'Card read failed unexpectedly. Unplug the reader, plug it back in, '
      'then press Retry Reader if shown.';
}

class _MemoryRead {
  const _MemoryRead({
    required this.bytes,
    required this.pagesOk,
    required this.pagesFailed,
  });

  final List<int> bytes;
  final int pagesOk;
  final int pagesFailed;
}

Future<List<int>> _transmit(CardStruct card, List<int> command) {
  return Pcsc.transmit(card, command);
}

Future<String?> _readUid(CardStruct card) async {
  for (var attempt = 1; attempt <= 3; attempt++) {
    try {
      final response = await _transmit(card, [0xFF, 0xCA, 0x00, 0x00, 0x00]);
      final data = _unwrapApduData(response);
      if (data != null && data.isNotEmpty) {
        return data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      }
    } catch (_) {}
    await Future<void>.delayed(Duration(milliseconds: 30 * attempt));
  }
  return null;
}

Future<_MemoryRead> _readUserMemory(CardStruct card, SendPort toMain) async {
  final bytes = <int>[];
  var pagesOk = 0;
  var pagesFailed = 0;
  for (var page = 4; page <= 16; page += 4) {
    final chunk = await _readPages(card, page, toMain);
    if (chunk == null || chunk.isEmpty) {
      pagesFailed++;
      _log(toMain, 'NFC: page $page read failed after retries');
      break;
    }
    pagesOk++;
    bytes.addAll(chunk);
    if (chunk.contains(0xFE) && bytes.length > 8) {
      _log(toMain, 'NFC: NDEF terminator found near page $page');
      break;
    }
    if (!_ndefPayloadIncomplete(bytes) &&
        parseMrnFromNtagUserMemory(bytes) != null) {
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return _MemoryRead(bytes: bytes, pagesOk: pagesOk, pagesFailed: pagesFailed);
}

bool _ndefPayloadIncomplete(List<int> bytes) {
  for (var i = 0; i < bytes.length; i++) {
    final type = bytes[i];
    if (type == 0x00) {
      continue;
    }
    if (type == 0xFE) {
      return false;
    }
    if (type != 0x03) {
      if (i + 1 >= bytes.length) {
        return true;
      }
      final len = bytes[i + 1];
      i += 1 + len;
      continue;
    }
    if (i + 1 >= bytes.length) {
      return true;
    }
    var length = bytes[i + 1];
    var header = 2;
    if (length == 0xFF) {
      if (i + 3 >= bytes.length) {
        return true;
      }
      length = (bytes[i + 2] << 8) | bytes[i + 3];
      header = 4;
    }
    final need = i + header + length;
    return bytes.length < need;
  }
  final ascii = _asciiPreview(bytes).toUpperCase();
  if (ascii.contains('UATH/PT') &&
      !RegExp(r'UATH/PT/\d{1,8}').hasMatch(ascii)) {
    return true;
  }
  return false;
}

Future<List<int>?> _readPages(
  CardStruct card,
  int startPage,
  SendPort toMain,
) async {
  final inDataExchange = [
    0xFF,
    0x00,
    0x00,
    0x00,
    0x05,
    0xD4,
    0x40,
    0x01,
    0x30,
    startPage & 0xFF,
  ];
  final through = [
    0xFF,
    0x00,
    0x00,
    0x00,
    0x04,
    0xD4,
    0x42,
    0x30,
    startPage & 0xFF,
  ];

  for (var attempt = 1; attempt <= _maxPageAttempts; attempt++) {
    try {
      final response = await _transmit(card, inDataExchange);
      final data = _unwrapTagPayload(response);
      if (data != null && data.isNotEmpty) {
        _log(
          toMain,
          'NFC: page $startPage InDataExchange '
          '(${data.length}b, try $attempt) ${_hexPreview(data, max: 20)}',
        );
        return data.length > 16 ? data.sublist(0, 16) : data;
      }
      _log(
        toMain,
        'NFC: page $startPage InDataExchange try $attempt empty/bad '
        '${_hexPreview(response, max: 28)}',
      );
    } catch (error) {
      _log(toMain, 'NFC: InDataExchange page $startPage try $attempt: $error');
    }

    if (attempt >= 3) {
      try {
        final response = await _transmit(card, through);
        final data = _unwrapTagPayload(response);
        if (data != null && data.isNotEmpty) {
          _log(
            toMain,
            'NFC: page $startPage InCommunicateThru '
            '(${data.length}b, try $attempt) ${_hexPreview(data, max: 20)}',
          );
          return data.length > 16 ? data.sublist(0, 16) : data;
        }
      } catch (error) {
        _log(
          toMain,
          'NFC: InCommunicateThru page $startPage try $attempt: $error',
        );
      }
    }

    await Future<void>.delayed(Duration(milliseconds: 35 * attempt));
  }

  return null;
}

List<int>? _unwrapTagPayload(List<int> response) {
  if (response.length < 2) {
    return null;
  }
  final sw1 = response[response.length - 2];
  final sw2 = response[response.length - 1];
  if (sw1 != 0x90 || sw2 != 0x00) {
    return null;
  }
  var data = response.sublist(0, response.length - 2);
  if (data.isEmpty) {
    return null;
  }

  if (data[0] == 0xD5) {
    if (data.length < 3) {
      return null;
    }
    final cmd = data[1];
    final status = data[2];
    if (status != 0x00) {
      return null;
    }
    if (cmd != 0x41 && cmd != 0x43) {
      return null;
    }
    data = data.sublist(3);
  }

  if (data.isEmpty) {
    return null;
  }
  if (data.every((b) => b == 0)) {
    return null;
  }
  return data;
}

List<int>? _unwrapApduData(List<int> response) {
  if (response.length < 2) {
    return null;
  }
  final sw1 = response[response.length - 2];
  final sw2 = response[response.length - 1];
  if (sw1 != 0x90 || sw2 != 0x00) {
    return null;
  }
  return response.sublist(0, response.length - 2);
}

String _hexPreview(List<int> bytes, {int max = 48}) {
  if (bytes.isEmpty) {
    return '(empty)';
  }
  final take = bytes.length > max ? bytes.sublist(0, max) : bytes;
  final hex = take.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  return bytes.length > max ? '$hex …' : hex;
}

String _asciiPreview(List<int> bytes, {int max = 64}) {
  final cleaned = bytes
      .where((b) => b >= 32 && b < 127)
      .map((b) => String.fromCharCode(b))
      .join()
      .trim();
  if (cleaned.isEmpty) {
    return '';
  }
  if (cleaned.length <= max) {
    return cleaned;
  }
  return '${cleaned.substring(0, max)}…';
}
