import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:uath_desktop/bridge/bridge_hub.dart';
import 'package:uath_desktop/bridge/ws_server.dart';
import 'package:uath_desktop/nfc/nfc_reader_service.dart';
import 'package:uath_desktop/ui/home_page.dart';

const _accent = Color(0xFF0FA858);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final hub = BridgeHub();
  final server = BridgeWsServer(hub);
  final reader = NfcReaderService(hub);
  final services = BridgeServices(hub: hub, server: server, reader: reader);

  try {
    await server.start();
  } catch (error, stack) {
    if (kDebugMode) {
      debugPrint('Failed to start WebSocket server: $error\n$stack');
    }
    // BridgeWsServer keeps retrying bind in the background.
  }

  runApp(UathDesktopApp(services: services));

  // Start PC/SC after the first frame so a blocked reader never prevents paint.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(reader.start());
  });
}

/// Owns long-lived bridge services and tears them down on app exit.
class BridgeServices {
  BridgeServices({
    required this.hub,
    required this.server,
    required this.reader,
  });

  final BridgeHub hub;
  final BridgeWsServer server;
  final NfcReaderService reader;

  var _disposed = false;

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    try {
      await reader.stop();
    } catch (_) {}
    try {
      await server.stop();
    } catch (_) {}
    try {
      await hub.dispose();
    } catch (_) {}
  }
}

class UathDesktopApp extends StatefulWidget {
  const UathDesktopApp({super.key, required this.services});

  final BridgeServices services;

  @override
  State<UathDesktopApp> createState() => _UathDesktopAppState();
}

class _UathDesktopAppState extends State<UathDesktopApp> {
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await widget.services.dispose();
        return AppExitResponse.exit;
      },
      onDetach: () {
        unawaited(widget.services.dispose());
      },
    );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    unawaited(widget.services.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShadcnApp(
      title: 'UATH NFC Bridge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorSchemes.lightNeutral.recolor(_accent),
        radius: 0.75,
        scaling: 1,
        density: Density.defaultDensity,
        typography: const Typography.geist(),
      ),
      themeMode: ThemeMode.light,
      home: HomePage(
        hub: widget.services.hub,
        onRetryReader: () => widget.services.reader.recover(),
      ),
    );
  }
}
