import 'dart:async';

import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:uath_desktop/bridge/bridge_hub.dart';
import 'package:uath_desktop/bridge/protocol.dart';
import 'package:uath_desktop/nfc/ndef_text_parser.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.hub,
    required this.onRetryReader,
  });

  final BridgeHub hub;
  final Future<void> Function() onRetryReader;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late BridgeUiState _state;
  StreamSubscription<BridgeUiState>? _sub;
  final _simulateController = TextEditingController();
  var _recovering = false;

  @override
  void initState() {
    super.initState();
    _state = widget.hub.currentUiState;
    _sub = widget.hub.uiStates.listen((next) {
      if (!mounted) {
        return;
      }
      setState(() => _state = next);
    });
  }

  @override
  void dispose() {
    _simulateController.dispose();
    unawaited(_sub?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  Future<void> _retryReader() async {
    if (_recovering) {
      return;
    }
    setState(() => _recovering = true);
    try {
      await widget.onRetryReader();
    } finally {
      if (mounted) {
        setState(() => _recovering = false);
      }
    }
  }

  void _simulateTap() {
    final mrn = normalizeMrn(_simulateController.text);
    if (mrn == null) {
      showToast(
        context: context,
        location: ToastLocation.topRight,
        builder: (context, overlay) {
          return SurfaceCard(
            child: Basic(
              title: const Text('Invalid MRN').semiBold(),
              subtitle: const Text(
                'Enter digits or UATH/PT/{digits}',
              ).muted(),
              trailing: IconButton.ghost(
                icon: const Icon(LucideIcons.x),
                onPressed: overlay.close,
              ),
              trailingAlignment: Alignment.center,
            ),
          );
        },
      );
      return;
    }
    widget.hub.clearReadError();
    widget.hub.emitNfcTap(mrn);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needsRecovery = _state.readerNeedsRecovery;
    final readerLabel = needsRecovery
        ? 'Needs recovery - unplug USB reader, then Retry Reader'
        : _state.reading
            ? 'Reading…'
            : _state.readerConnected
                ? 'Connected - ${_shortReaderName(_state.readerName)}'
                : 'Not detected';
    final emrLabel = !_state.wsListening
        ? (_state.wsError ?? 'WebSocket not listening')
        : _state.connectedTabs > 0
            ? 'Connected (${_state.connectedTabs} tab${_state.connectedTabs == 1 ? '' : 's'})'
            : 'Waiting for EMR login…';
    final lastTap = _state.lastMrn == null
        ? 'None yet'
        : '${_state.lastMrn}${_state.lastTapAt == null ? '' : ' · ${_formatLocal(_state.lastTapAt!)}'}';
    final readError = _state.lastReadError;

    final readerColor = needsRecovery
        ? const Color(0xFFEF4444)
        : _state.reading
            ? theme.colorScheme.primary
            : _state.readerConnected
                ? const Color(0xFF22C55E)
                : const Color(0xFFF59E0B);
    final emrColor = !_state.wsListening
        ? const Color(0xFFEF4444)
        : _state.connectedTabs > 0
            ? const Color(0xFF22C55E)
            : theme.colorScheme.mutedForeground;
    final lastTapColor = theme.colorScheme.primary;
    final errorColor = const Color(0xFFEF4444);

    return Scaffold(
      backgroundColor: theme.colorScheme.background,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    spacing: 12,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(theme.radiusMd),
                        child: Image.asset(
                          'assets/png/uath-logo.png',
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.high,
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('UATH NFC Bridge').h4().semiBold(),
                            const Gap(2),
                            const Text(
                              'Keep this window open while using the staff EMR.',
                            ).small().muted(),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Gap(24),
                  OutlinedContainer(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 16,
                        children: [
                          _StatusRow(
                            label: 'Reader',
                            value: readerLabel,
                            color: readerColor,
                          ),
                          Divider(
                            height: 1,
                            thickness: 1,
                            color: theme.colorScheme.border,
                          ),
                          _StatusRow(
                            label: 'EMR',
                            value: emrLabel,
                            color: emrColor,
                          ),
                          Divider(
                            height: 1,
                            thickness: 1,
                            color: theme.colorScheme.border,
                          ),
                          _StatusRow(
                            label: 'Last Tap',
                            value: lastTap,
                            color: lastTapColor,
                          ),
                          if (readError != null && readError.isNotEmpty) ...[
                            Divider(
                              height: 1,
                              thickness: 1,
                              color: theme.colorScheme.border,
                            ),
                            _StatusRow(
                              label: 'Last Read Error',
                              value: readError,
                              color: errorColor,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (needsRecovery) ...[
                    const Gap(12),
                    OutlineButton(
                      alignment: Alignment.center,
                      onPressed: _recovering ? null : _retryReader,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        spacing: 8,
                        children: [
                          if (_recovering)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            const Icon(LucideIcons.refreshCw, size: 16),
                          Text(_recovering ? 'Recovering…' : 'Retry Reader'),
                        ],
                      ),
                    ),
                  ],
                  const Gap(24),
                  const Text('Simulate Card Tap').small().semiBold(),
                  const Gap(8),
                  TextField(
                    controller: _simulateController,
                    placeholder: const Text('e.g. 2000123 or UATH/PT/2000123'),
                    onSubmitted: (_) => _simulateTap(),
                  ),
                  const Gap(12),
                  PrimaryButton(
                    alignment: Alignment.center,
                    onPressed: _simulateTap,
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      spacing: 8,
                      children: [
                        Icon(LucideIcons.creditCard, size: 16),
                        Text('Simulate Card'),
                      ],
                    ),
                  ),
                  const Gap(28),
                  SelectableText(
                    'WebSocket ${BridgeProtocol.wsUrl}',
                    style: theme.typography.xSmall.copyWith(
                      color: theme.colorScheme.mutedForeground,
                    ),
                  ),
                  const Gap(4),
                  const Text(
                    'Powered by Betacare Health Solutions',
                  ).xSmall().muted(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _shortReaderName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return 'USB reader';
    }
    if (trimmed.length <= 40) {
      return trimmed;
    }
    return '${trimmed.substring(0, 37)}…';
  }

  String _formatLocal(DateTime utc) {
    final local = utc.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    final s = local.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Container(
          width: 10,
          height: 10,
          margin: const EdgeInsets.only(top: 5),
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label).xSmall().muted(),
              const Gap(2),
              Text(value).small().semiBold(),
            ],
          ),
        ),
      ],
    );
  }
}
