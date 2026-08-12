import 'dart:convert';
import 'dart:typed_data';

import 'package:ndef/ndef.dart' as ndef;

/// Extract MRN text from NTAG215 user memory (NDEF TLV starting at page 4).
String? parseMrnFromNtagUserMemory(List<int> userBytes) {
  final ndefBytes = _extractNdefPayload(userBytes);
  if (ndefBytes == null || ndefBytes.isEmpty) {
    // Fallback: treat raw ASCII as the payload (some writers skip TLV).
    return normalizeMrn(_asciiSnippet(userBytes));
  }

  try {
    final records = ndef.decodeRawNdefMessage(Uint8List.fromList(ndefBytes));
    for (final record in records) {
      if (record is ndef.TextRecord) {
        final text = record.text?.trim();
        final mrn = normalizeMrn(text);
        if (mrn != null) {
          return mrn;
        }
      }
    }
  } catch (_) {
    // Fall through to ASCII scrape.
  }

  return normalizeMrn(_asciiSnippet(ndefBytes));
}

/// Accepts `UATH/PT/{digits}` or bare 1-8 digits.
String? normalizeMrn(String? raw) {
  if (raw == null) {
    return null;
  }
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final upper = trimmed.toUpperCase();
  final full = RegExp(r'^UATH/PT/(\d{1,8})$').firstMatch(upper);
  if (full != null) {
    return 'UATH/PT/${full.group(1)}';
  }
  final digits = RegExp(r'^(\d{1,8})$').firstMatch(trimmed);
  if (digits != null) {
    return 'UATH/PT/${digits.group(1)}';
  }
  // NFC Tools sometimes appends language noise; scrape UATH/PT/…
  final embedded = RegExp(r'UATH/PT/\d{1,8}', caseSensitive: false).firstMatch(upper);
  if (embedded != null) {
    return embedded.group(0)!.toUpperCase();
  }
  return null;
}

List<int>? _extractNdefPayload(List<int> bytes) {
  for (var i = 0; i < bytes.length; i++) {
    final type = bytes[i];
    if (type == 0x00) {
      continue; // NULL TLV
    }
    if (type == 0xFE) {
      return null; // terminator without NDEF
    }
    if (type != 0x03) {
      // Skip unknown TLV
      if (i + 1 >= bytes.length) {
        return null;
      }
      final len = bytes[i + 1];
      i += 1 + len;
      continue;
    }
    if (i + 1 >= bytes.length) {
      return null;
    }
    var length = bytes[i + 1];
    var headerSize = 2;
    if (length == 0xFF) {
      if (i + 3 >= bytes.length) {
        return null;
      }
      length = (bytes[i + 2] << 8) | bytes[i + 3];
      headerSize = 4;
    }
    final start = i + headerSize;
    final end = start + length;
    if (end > bytes.length) {
      return bytes.sublist(start);
    }
    return bytes.sublist(start, end);
  }
  return null;
}

String _asciiSnippet(List<int> bytes) {
  final cleaned = bytes.where((b) => b >= 32 && b < 127).toList();
  return utf8.decode(cleaned, allowMalformed: true).trim();
}
