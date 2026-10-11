import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../analysis/models.dart';

final dateFmt = DateFormat('yyyy.MM.dd (E)', 'ko');
final shortDateFmt = DateFormat('M/d', 'ko');
final timeFmt = DateFormat('HH:mm');
final timeSecFmt = DateFormat('HH:mm:ss');

String fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  return '$h시간 ${m.toString().padLeft(2, '0')}분';
}

String fmtHm(Duration d) =>
    '${d.inHours}:${d.inMinutes.remainder(60).toString().padLeft(2, '0')}';

String fmtNum(double? v, {int digits = 1}) =>
    v == null ? '-' : v.toStringAsFixed(digits);

/// AHI 중증도 색상: <5 정상, <15 경도, <30 중등도, ≥30 중증
Color ahiColor(double? ahi) {
  if (ahi == null) return Colors.grey;
  if (ahi < 5) return const Color(0xFF2E9E5B);
  if (ahi < 15) return const Color(0xFFE0A100);
  if (ahi < 30) return const Color(0xFFE06A00);
  return const Color(0xFFD03030);
}

String ahiLabel(double? ahi) {
  if (ahi == null) return '-';
  if (ahi < 5) return '정상 범위';
  if (ahi < 15) return '경도';
  if (ahi < 30) return '중등도';
  return '중증';
}

/// ResMed 기준 대량 누출 임계값
const largeLeakLpm = 24.0;

Color eventColor(EventType t) => switch (t) {
      EventType.obstructiveApnea => const Color(0xFF7B4FD6),
      EventType.centralApnea => const Color(0xFF2F80ED),
      EventType.hypopnea => const Color(0xFFE0A100),
      EventType.apnea => const Color(0xFF8E8E93),
      EventType.rera => const Color(0xFF27AE60),
      EventType.csr => const Color(0xFF00A3A3),
      EventType.other => const Color(0xFFB0B0B0),
    };

DateTime parseFolderDate(String folder) {
  if (folder.length < 8) return DateTime(1970);
  return DateTime(
    int.tryParse(folder.substring(0, 4)) ?? 1970,
    int.tryParse(folder.substring(4, 6)) ?? 1,
    int.tryParse(folder.substring(6, 8)) ?? 1,
  );
}
