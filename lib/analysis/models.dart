import 'dart:math' as math;
import 'dart:typed_data';

/// ResMed 이벤트 종류.
enum EventType {
  obstructiveApnea('OA', '폐쇄성 무호흡', true),
  centralApnea('CA', '중추성 무호흡', true),
  hypopnea('H', '저호흡', true),
  apnea('UA', '미분류 무호흡', true),
  rera('RERA', '호흡노력 각성', false),
  csr('CSR', '체인-스토크스 호흡', false),
  other('기타', '기타', false);

  const EventType(this.code, this.label, this.countsForAhi);
  final String code;
  final String label;
  final bool countsForAhi;

  static EventType fromAnnotation(String text) {
    final t = text.toLowerCase().trim();
    if (t.contains('obstructive')) return obstructiveApnea;
    if (t.contains('central')) return centralApnea;
    if (t.contains('hypopnea')) return hypopnea;
    if (t.contains('apnea') || t.contains('apnoea')) return apnea;
    if (t.contains('arousal') || t.contains('rera')) return rera;
    if (t.contains('csr') || t.contains('cheyne')) return csr;
    return other;
  }
}

class CpapEvent {
  const CpapEvent(this.type, this.time, this.duration, this.text);
  final EventType type;
  final DateTime time;
  final double duration; // 초
  final String text;
}

/// 일정 간격으로 샘플링된 연속 구간.
class Segment {
  Segment(this.start, this.sampleRate, this.values);
  final DateTime start;
  final double sampleRate; // Hz
  final Float32List values;

  DateTime get end => start.add(Duration(
      microseconds: (values.length / sampleRate * 1e6).round()));

  DateTime timeAt(int i) =>
      start.add(Duration(microseconds: (i / sampleRate * 1e6).round()));
}

/// 한 신호의 여러 세션 구간 묶음.
class TimeSeries {
  TimeSeries({required this.key, required this.label, required this.unit})
      : segments = [];

  final String key;
  final String label;
  final String unit;
  final List<Segment> segments;

  bool get isEmpty => segments.every((s) => s.values.isEmpty);

  Iterable<double> get allValues sync* {
    for (final s in segments) {
      yield* s.values;
    }
  }

  SeriesStats? stats({double? validMin, double? validMax}) =>
      SeriesStats.from(allValues, validMin: validMin, validMax: validMax);
}

class SeriesStats {
  const SeriesStats({
    required this.median,
    required this.p95,
    required this.max,
    required this.min,
    required this.mean,
    required this.count,
  });

  final double median;
  final double p95;
  final double max;
  final double min;
  final double mean;
  final int count;

  static SeriesStats? from(Iterable<double> values,
      {double? validMin, double? validMax}) {
    final v = values
        .where((x) =>
            x.isFinite &&
            (validMin == null || x >= validMin) &&
            (validMax == null || x <= validMax))
        .toList()
      ..sort();
    if (v.isEmpty) return null;
    double pct(double p) {
      final idx = (p * (v.length - 1));
      final lo = idx.floor(), hi = idx.ceil();
      return v[lo] + (v[hi] - v[lo]) * (idx - lo);
    }

    final sum = v.fold<double>(0, (a, b) => a + b);
    return SeriesStats(
      median: pct(0.5),
      p95: pct(0.95),
      max: v.last,
      min: v.first,
      mean: sum / v.length,
      count: v.length,
    );
  }
}

class SessionInfo {
  const SessionInfo(this.start, this.end);
  final DateTime start;
  final DateTime end;
  Duration get duration => end.difference(start);
}

/// 하룻밤(DATALOG/YYYYMMDD 폴더) 분석 결과.
class NightReport {
  NightReport({
    required this.folder,
    required this.date,
    required this.sessions,
    required this.events,
    required this.series,
  });

  final String folder;
  final DateTime date;
  final List<SessionInfo> sessions;
  final List<CpapEvent> events;

  /// key: pressure, maskPressure, eprPressure, leak, respRate, tidalVolume,
  /// minuteVent, snore, flowLimit, spo2, pulse
  final Map<String, TimeSeries> series;

  /// BRP 파일(25Hz 유량/압력) — 사용자가 요청했을 때만 로드.
  TimeSeries? flow;
  TimeSeries? flowPressure;

  Duration get usage =>
      sessions.fold(Duration.zero, (a, s) => a + s.duration);

  double get usageHours => usage.inSeconds / 3600.0;

  Map<EventType, int> get eventCounts {
    final m = {for (final t in EventType.values) t: 0};
    for (final e in events) {
      m[e.type] = m[e.type]! + 1;
    }
    return m;
  }

  double? indexFor(EventType t) =>
      usageHours > 0 ? eventCounts[t]! / usageHours : null;

  /// AHI = (OA + CA + H + UA) / 사용시간
  double? get ahi {
    if (usageHours <= 0) return null;
    final n = events.where((e) => e.type.countsForAhi).length;
    return n / usageHours;
  }

  DateTime? get firstStart => sessions.isEmpty
      ? null
      : sessions.map((s) => s.start).reduce((a, b) => a.isBefore(b) ? a : b);

  DateTime? get lastEnd => sessions.isEmpty
      ? null
      : sessions.map((s) => s.end).reduce((a, b) => a.isAfter(b) ? a : b);

  SeriesStats? stat(String key) {
    final s = series[key];
    if (s == null) return null;
    switch (key) {
      case 'spo2':
        return s.stats(validMin: 50, validMax: 100);
      case 'pulse':
        return s.stats(validMin: 20, validMax: 250);
      case 'leak':
      case 'respRate':
      case 'tidalVolume':
      case 'minuteVent':
        return s.stats(validMin: 0);
      default:
        return s.stats();
    }
  }

  /// 목록 화면용 요약 (JSON 저장 가능).
  NightSummary toSummary() => NightSummary(
        folder: folder,
        usageMinutes: usage.inMinutes,
        ahi: ahi,
        pressure95: stat('pressure')?.p95 ?? stat('maskPressure')?.p95,
        leak95: stat('leak')?.p95,
        sessions: sessions.length,
      );
}

class NightSummary {
  const NightSummary({
    required this.folder,
    required this.usageMinutes,
    required this.ahi,
    required this.pressure95,
    required this.leak95,
    required this.sessions,
  });

  final String folder;
  final int usageMinutes;
  final double? ahi;
  final double? pressure95;
  final double? leak95;
  final int sessions;

  Map<String, dynamic> toJson() => {
        'folder': folder,
        'usageMinutes': usageMinutes,
        'ahi': ahi,
        'pressure95': pressure95,
        'leak95': leak95,
        'sessions': sessions,
      };

  factory NightSummary.fromJson(Map<String, dynamic> j) => NightSummary(
        folder: j['folder'] as String,
        usageMinutes: (j['usageMinutes'] as num).toInt(),
        ahi: (j['ahi'] as num?)?.toDouble(),
        pressure95: (j['pressure95'] as num?)?.toDouble(),
        leak95: (j['leak95'] as num?)?.toDouble(),
        sessions: (j['sessions'] as num?)?.toInt() ?? 0,
      );
}

/// STR.edf 의 하루치 요약.
class DailyStat {
  DailyStat(this.date, this.values);
  final DateTime date;
  final Map<String, double> values;

  double? get usageHours {
    final d = values['duration'];
    return d == null ? null : d / 60.0;
  }

  double? get ahi => values['ahi'];
  double? get leak95 => values['leak95'];
  double? get pressure95 => values['pressure95'];
  double? get pressure50 => values['pressure50'];
}

/// 차트 표시용 다운샘플링 (버킷 평균, NaN 제외).
List<math.Point<double>> downsample(TimeSeries s, DateTime origin, {int maxPoints = 800}) {
  final total = s.segments.fold<int>(0, (a, b) => a + b.values.length);
  if (total == 0) return const [];
  final step = math.max(1, (total / maxPoints).ceil());
  final pts = <math.Point<double>>[];
  for (final seg in s.segments) {
    for (var i = 0; i < seg.values.length; i += step) {
      var sum = 0.0;
      var n = 0;
      final end = math.min(seg.values.length, i + step);
      for (var k = i; k < end; k++) {
        final v = seg.values[k];
        if (v.isFinite) {
          sum += v;
          n++;
        }
      }
      if (n == 0) continue;
      final t = seg.timeAt(i + (end - i) ~/ 2);
      pts.add(math.Point(
          t.difference(origin).inMilliseconds / 3600000.0, sum / n));
    }
    // 세션 사이 공백은 NaN 으로 표시해 선을 끊는다.
    if (pts.isNotEmpty && !pts.last.y.isNaN) {
      pts.add(math.Point(pts.last.x, double.nan));
    }
  }
  if (pts.isNotEmpty && pts.last.y.isNaN) pts.removeLast();
  return pts;
}
