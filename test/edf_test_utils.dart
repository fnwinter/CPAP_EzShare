import 'dart:convert';
import 'dart:typed_data';

/// 테스트용 EDF/EDF+ 파일 생성기.
class TestSignal {
  TestSignal(this.label, this.dim, this.physMin, this.physMax, this.samplesPerRecord,
      this.samples, {this.digMin = -32768, this.digMax = 32767});
  final String label;
  final String dim;
  final double physMin, physMax;
  final int digMin, digMax;
  final int samplesPerRecord;

  /// 물리 값 (전체 레코드)
  final List<double> samples;
}

String _pad(String s, int n) => s.length >= n ? s.substring(0, n) : s.padRight(n);

Uint8List buildEdf({
  required DateTime start,
  required double recordDuration,
  required int numRecords,
  required List<TestSignal> signals,
  List<String>? annotationTals, // 레코드별 TAL 문자열 (EDF+)
  int annotationBytes = 120,
}) {
  final allSignals = [...signals];
  final hasAnn = annotationTals != null;
  final ns = allSignals.length + (hasAnn ? 1 : 0);
  final b = BytesBuilder();
  void w(String s, int n) => b.add(latin1.encode(_pad(s, n)));

  String two(int v) => v.toString().padLeft(2, '0');
  w('0', 8);
  w('X X X X', 80);
  w('Startdate X X X X', 80);
  w('${two(start.day)}.${two(start.month)}.${two(start.year % 100)}', 8);
  w('${two(start.hour)}.${two(start.minute)}.${two(start.second)}', 8);
  w('${256 + ns * 256}', 8);
  w(hasAnn ? 'EDF+C' : '', 44);
  w('$numRecords', 8);
  w('$recordDuration', 8);
  w('$ns', 4);

  final labels = [...allSignals.map((s) => s.label), if (hasAnn) 'EDF Annotations'];
  final spr = [...allSignals.map((s) => s.samplesPerRecord), if (hasAnn) annotationBytes ~/ 2];
  for (final l in labels) {
    w(l, 16);
  }
  for (var i = 0; i < ns; i++) {
    w('', 80);
  }
  for (final s in allSignals) {
    w(s.dim, 8);
  }
  if (hasAnn) w('', 8);
  for (final s in allSignals) {
    w('${s.physMin}', 8);
  }
  if (hasAnn) w('-1', 8);
  for (final s in allSignals) {
    w('${s.physMax}', 8);
  }
  if (hasAnn) w('1', 8);
  for (final s in allSignals) {
    w('${s.digMin}', 8);
  }
  if (hasAnn) w('-32768', 8);
  for (final s in allSignals) {
    w('${s.digMax}', 8);
  }
  if (hasAnn) w('32767', 8);
  for (var i = 0; i < ns; i++) {
    w('', 80);
  }
  for (final n in spr) {
    w('$n', 8);
  }
  for (var i = 0; i < ns; i++) {
    w('', 32);
  }

  for (var r = 0; r < numRecords; r++) {
    for (final s in allSignals) {
      final bd = ByteData(s.samplesPerRecord * 2);
      final gain = (s.physMax - s.physMin) / (s.digMax - s.digMin);
      for (var k = 0; k < s.samplesPerRecord; k++) {
        final v = s.samples[r * s.samplesPerRecord + k];
        final d = ((v - s.physMin) / gain + s.digMin).round().clamp(s.digMin, s.digMax);
        bd.setInt16(k * 2, d, Endian.little);
      }
      b.add(bd.buffer.asUint8List());
    }
    if (hasAnn) {
      final tal = utf8.encode(annotationTals[r]);
      final buf = Uint8List(annotationBytes);
      buf.setRange(0, tal.length, tal);
      b.add(buf);
    }
  }
  return b.takeBytes();
}

/// `+onset\x15dur\x14text\x14\x00` 형식 TAL.
String tal(double onset, String text, {double? duration}) =>
    '+$onset${duration != null ? '\x15$duration' : ''}\x14$text\x14\x00';

String timekeeping(double onset) => '+$onset\x14\x14\x00';
