# Patched flutter_pcsc platform packages

Upstream `flutter_pcsc_macos` / `flutter_pcsc_windows` set `pluginClass: none`.
Flutter 3.44+ generates invalid native registrant code from that value
(`none.register(...)`), which fails the macOS build.

These copies fix registration:

- macOS: `pluginClass: FlutterPcscMacosPlugin` (existing stub class)
- Windows: drop `pluginClass`; keep FFI `dartPluginClass` only
