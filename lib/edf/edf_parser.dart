import 'dart:convert';
import 'dart:typed_data';

/// EDF / EDF+ 파일 하나에 들어있는 신호 채널.
class EdfSignal {
  EdfSignal({
    required this.label,
    required this.transducer,
    required this.physicalDimension,
    required this.physicalMin,
    required this.physicalMax,
    required this.digitalMin,
    required this.digitalMax,
    required this.samplesPerRecord,
    required this.recordDuration,
  });

  final String label;
  final String transducer;
  final String physicalDimension;
  final double physicalMin;
  final double physicalMax;
  final int digitalMin;
  final int digitalMax;
  final int samplesPerRecord;
  final double recordDuration;

  /// 물리 단위로 변환된 샘플 값. 어노테이션 채널은 비어 있음.
  Float32List values = Float32List(0);

  bool get isAnnotation => label == 'EDF Annotations';

  /// 초당 샘플 수 (Hz).
  double get sampleRate =>
      recordDuration > 0 ? samplesPerRecord / recordDuration : 0;

  double get _gain => digitalMax == digitalMin
      ? 1
      : (physicalMax - physicalMin) / (digitalMax - digitalMin);

  double toPhysical(int digital) =>
      (digital - digitalMin) * _gain + physicalMin;

  @override
  String toString() =>
      'EdfSignal($label, ${values.length} samples @ ${sampleRate}Hz, $physicalDimension)';
}

/// EDF+ TAL(Time-stamped Annotation List) 항목.
class EdfAnnotation {
  const EdfAnnotation(this.onset, this.duration, this.text);

  /// 파일 시작 기준 초.
  final double onset;
  final double? duration;
  final String text;

  @override
  String toString() => 'EdfAnnotation(+$onset, $duration, $text)';
}

class EdfFile {
  EdfFile({
    required this.version,
    required this.patient,
    required this.recording,
    required this.start,
    required this.reserved,
    required this.numRecords,
    required this.recordDuration,
    required this.signals,
    required this.annotations,
  });

  final String version;
  final String patient;
  final String recording;
  final DateTime start;
  final String reserved;
  final int numRecords;
  final double recordDuration;
  final List<EdfSignal> signals;
  final List<EdfAnnotation> annotations;

  bool get isEdfPlus => reserved.startsWith('EDF+');

  Duration get duration =>
      Duration(milliseconds: (numRecords * recordDuration * 1000).round());

  DateTime get end => start.add(duration);

  /// 라벨이 [prefix] 로 시작하는 첫 신호 (대소문자 무시).
  EdfSignal? signal(String prefix) {
    final p = prefix.toLowerCase();
    for (final s in signals) {
      if (s.label.toLowerCase().startsWith(p)) return s;
    }
    return null;
  }
}

class EdfFormatException implements Exception {
  EdfFormatException(this.message);
  final String message;
  @override
  String toString() => 'EdfFormatException: $message';
}

/// ResMed AirSense 가 SD 카드에 기록하는 EDF/EDF+ 파일 파서.
class EdfParser {
  /// [signalFilter] 가 주어지면 해당 라벨의 신호만 샘플을 디코딩한다
  /// (헤더는 항상 전부 읽음). 큰 BRP 파일에서 메모리를 아낄 때 사용.
  static EdfFile parse(Uint8List bytes, {bool Function(String label)? signalFilter}) {
    if (bytes.length < 256) {
      throw EdfFormatException('파일이 너무 작습니다 (${bytes.length} bytes)');
    }
    var pos = 0;
    String field(int len) {
      if (pos + len > bytes.length) {
        throw EdfFormatException('헤더가 잘렸습니다');
      }
      final s = latin1.decode(bytes.sublist(pos, pos + len)).trim();
      pos += len;
      return s;
    }

    final version = field(8);
    final patient = field(80);
    final recording = field(80);
    final startDate = field(8);
    final startTime = field(8);
    final headerBytes = int.tryParse(field(8)) ?? 0;
    final reserved = field(44);
    var numRecords = int.tryParse(field(8)) ?? -1;
    final recordDuration = double.tryParse(field(8)) ?? 1;
    final ns = int.tryParse(field(4)) ?? 0;
    if (ns <= 0 || ns > 512) {
      throw EdfFormatException('신호 개수가 잘못되었습니다: $ns');
    }

    List<String> fields(int len) => List.generate(ns, (_) => field(len));
    final labels = fields(16);
    final transducers = fields(80);
    final dims = fields(8);
    final physMin = fields(8).map(_toDouble).toList();
    final physMax = fields(8).map(_toDouble).toList();
    final digMin = fields(8).map((s) => int.tryParse(s) ?? -32768).toList();
    final digMax = fields(8).map((s) => int.tryParse(s) ?? 32767).toList();
    fields(80); // prefiltering
    final spr = fields(8).map((s) => int.tryParse(s) ?? 0).toList();
    fields(32); // reserved

    final signals = List.generate(
      ns,
      (i) => EdfSignal(
        label: labels[i],
        transducer: transducers[i],
        physicalDimension: dims[i],
        physicalMin: physMin[i],
        physicalMax: physMax[i],
        digitalMin: digMin[i],
        digitalMax: digMax[i],
        samplesPerRecord: spr[i],
        recordDuration: recordDuration,
      ),
    );

    final dataStart = headerBytes > 0 ? headerBytes : 256 + ns * 256;
    final samplesPerRecordTotal = spr.fold<int>(0, (a, b) => a + b);
    final recordBytes = samplesPerRecordTotal * 2;
    if (recordBytes <= 0) {
      throw EdfFormatException('레코드 크기가 0 입니다');
    }
    final available = (bytes.length - dataStart) ~/ recordBytes;
    // 기록 중인 파일은 numRecords 가 -1 일 수 있고, 잘린 파일은 헤더보다 짧을 수 있다.
    if (numRecords < 0 || numRecords > available) numRecords = available;
    if (numRecords < 0) numRecords = 0;

    final data = ByteData.sublistView(bytes);
    final annotations = <EdfAnnotation>[];

    // 신호별 출력 버퍼 준비
    final decode = List<bool>.generate(ns, (i) {
      if (signals[i].isAnnotation) return false;
      return signalFilter == null || signalFilter(signals[i].label);
    });
    for (var i = 0; i < ns; i++) {
      if (decode[i]) signals[i].values = Float32List(spr[i] * numRecords);
    }

    // 레코드 내 각 신호의 바이트 오프셋
    final offsets = List<int>.filled(ns, 0);
    for (var i = 1; i < ns; i++) {
      offsets[i] = offsets[i - 1] + spr[i - 1] * 2;
    }

    for (var r = 0; r < numRecords; r++) {
      final recStart = dataStart + r * recordBytes;
      for (var i = 0; i < ns; i++) {
        final sigStart = recStart + offsets[i];
        if (signals[i].isAnnotation) {
          _parseTal(bytes, sigStart, spr[i] * 2, annotations);
          continue;
        }
        if (!decode[i]) continue;
        final sig = signals[i];
        final out = sig.values;
        final base = r * spr[i];
        final gain = sig._gain;
        final dMin = sig.digitalMin;
        final pMin = sig.physicalMin;
        for (var k = 0; k < spr[i]; k++) {
          final d = data.getInt16(sigStart + k * 2, Endian.little);
          out[base + k] = (d - dMin) * gain + pMin;
        }
      }
    }

    return EdfFile(
      version: version,
      patient: patient,
      recording: recording,
      start: _parseStart(startDate, startTime),
      reserved: reserved,
      numRecords: numRecords,
      recordDuration: recordDuration,
      signals: signals,
      annotations: annotations,
    );
  }

  static double _toDouble(String s) => double.tryParse(s) ?? 0;

  static DateTime _parseStart(String date, String time) {
    final d = date.split('.').map((s) => int.tryParse(s.trim()) ?? 0).toList();
    final t = time.split('.').map((s) => int.tryParse(s.trim()) ?? 0).toList();
    if (d.length < 3 || t.length < 3) return DateTime(1985);
    // EDF 규격: yy 85~99 → 19yy, 00~84 → 20yy
    final year = d[2] >= 85 ? 1900 + d[2] : 2000 + d[2];
    return DateTime(year, d[1], d[0], t[0], t[1], t[2]);
  }

  /// EDF+ TAL 파싱: `+onset[\x15duration]\x14text\x14...\x14\x00`
  static void _parseTal(
      Uint8List bytes, int start, int length, List<EdfAnnotation> out) {
    final end = (start + length).clamp(0, bytes.length);
    var i = start;
    while (i < end) {
      // 다음 TAL 끝(\x00) 찾기
      var j = i;
      while (j < end && bytes[j] != 0) {
        j++;
      }
      if (j > i) {
        final tal = utf8.decode(bytes.sublist(i, j), allowMalformed: true);
        final parts = tal.split('\x14');
        if (parts.isNotEmpty) {
          final head = parts[0].split('\x15');
          final onset = double.tryParse(head[0]);
          final dur = head.length > 1 ? double.tryParse(head[1]) : null;
          if (onset != null) {
            for (var k = 1; k < parts.length; k++) {
              final text = parts[k].trim();
              // 첫 번째 빈 텍스트는 레코드 시간 기록용(timekeeping) TAL
              if (text.isNotEmpty) out.add(EdfAnnotation(onset, dur, text));
            }
          }
        }
      }
      i = j + 1;
    }
  }
}
