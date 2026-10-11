import 'dart:typed_data';

import '../edf/edf_parser.dart';
import 'models.dart';

class _SignalSpec {
  const _SignalSpec(this.prefix, this.key, this.label, this.unit,
      {this.convert});
  final String prefix;
  final String key;
  final String label;
  final String unit;

  /// 원본 단위(physicalDimension) 를 보고 배율을 결정.
  final double Function(String dim)? convert;
}

double _lpsToLpm(String dim) => dim.toLowerCase() == 'l/s' ? 60 : 1;
double _lToMl(String dim) => dim.toLowerCase() == 'l' ? 1000 : 1;

/// ResMed AirSense 10/11 DATALOG 파일 분석기.
///
/// DATALOG/YYYYMMDD 폴더에는 세션마다 다음 파일이 생긴다.
///  - `*_BRP.edf` : 25Hz 유량(Flow)/압력 파형
///  - `*_PLD.edf` : 0.5Hz 압력, 누출, 호흡수, 일회호흡량, 분당환기량, 코골이, 유량제한
///  - `*_SAD.edf` : 1Hz SpO2/맥박 (산소포화도 센서 연결 시)
///  - `*_EVE.edf` : EDF+ 어노테이션 이벤트 (무호흡/저호흡/각성)
///  - `*_CSL.edf` : 체인-스토크스 호흡 구간
class AirSenseAnalyzer {
  static const _pldSpecs = [
    _SignalSpec('MaskPress', 'maskPressure', '마스크 압력', 'cmH₂O'),
    _SignalSpec('Press', 'pressure', '치료 압력', 'cmH₂O'),
    _SignalSpec('EprPress', 'eprPressure', 'EPR 압력', 'cmH₂O'),
    _SignalSpec('Leak', 'leak', '누출', 'L/min', convert: _lpsToLpm),
    _SignalSpec('RespRate', 'respRate', '호흡수', '회/분'),
    _SignalSpec('TidVol', 'tidalVolume', '일회호흡량', 'mL', convert: _lToMl),
    _SignalSpec('MinVent', 'minuteVent', '분당환기량', 'L/min'),
    _SignalSpec('Snore', 'snore', '코골이', ''),
    _SignalSpec('FlowLim', 'flowLimit', '유량 제한', ''),
  ];

  static const _sadSpecs = [
    _SignalSpec('SpO2', 'spo2', '산소포화도', '%'),
    _SignalSpec('Pulse', 'pulse', '맥박', 'bpm'),
  ];

  static const seriesOrder = [
    'pressure',
    'maskPressure',
    'eprPressure',
    'leak',
    'respRate',
    'tidalVolume',
    'minuteVent',
    'snore',
    'flowLimit',
    'spo2',
    'pulse',
  ];

  /// 파일명 끝의 종류 (BRP/PLD/SAD/EVE/CSL). 없으면 null.
  static String? fileKind(String name) {
    final m = RegExp(r'_([A-Za-z]{3})\.edf$', caseSensitive: false).firstMatch(name);
    return m?.group(1)!.toUpperCase();
  }

  /// `20260111_223015_PLD.edf` → 2026-01-11 22:30:15
  static DateTime? timeFromName(String name) {
    final m = RegExp(r'(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})').firstMatch(name);
    if (m == null) return null;
    final v = List.generate(6, (i) => int.parse(m.group(i + 1)!));
    return DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
  }

  static DateTime dateFromFolder(String folder) {
    final m = RegExp(r'(\d{4})(\d{2})(\d{2})').firstMatch(folder);
    if (m == null) return DateTime(1970);
    return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
  }

  /// [files]: 파일명 → 내용. BRP 는 포함하지 않아도 된다.
  static NightReport analyzeNight(String folder, Map<String, Uint8List> files) {
    final series = <String, TimeSeries>{};
    final sessions = <SessionInfo>[];
    final events = <CpapEvent>[];

    void addSignals(EdfFile edf, List<_SignalSpec> specs) {
      for (final spec in specs) {
        final sig = edf.signal(spec.prefix);
        if (sig == null || sig.values.isEmpty) continue;
        final scale = spec.convert?.call(sig.physicalDimension) ?? 1;
        final values = scale == 1
            ? sig.values
            : Float32List.fromList([for (final v in sig.values) v * scale]);
        series
            .putIfAbsent(spec.key,
                () => TimeSeries(key: spec.key, label: spec.label, unit: spec.unit))
            .segments
            .add(Segment(edf.start, sig.sampleRate, values));
      }
    }

    final names = files.keys.toList()..sort();
    final sessionSources = <String, List<SessionInfo>>{'PLD': [], 'BRP': [], 'SAD': []};

    for (final name in names) {
      final kind = fileKind(name);
      if (kind == null || kind == 'BRP') {
        if (kind == 'BRP') {
          // 세션 시간만 헤더에서 얻는다
          final edf = _tryParse(files[name]!, filter: (_) => false);
          if (edf != null) sessionSources['BRP']!.add(SessionInfo(edf.start, edf.end));
        }
        continue;
      }
      final edf = _tryParse(files[name]!);
      if (edf == null) continue;
      switch (kind) {
        case 'PLD':
          addSignals(edf, _pldSpecs);
          sessionSources['PLD']!.add(SessionInfo(edf.start, edf.end));
        case 'SAD':
          addSignals(edf, _sadSpecs);
          sessionSources['SAD']!.add(SessionInfo(edf.start, edf.end));
        case 'EVE':
        case 'CSL':
          for (final a in edf.annotations) {
            final type = EventType.fromAnnotation(a.text);
            final lower = a.text.toLowerCase();
            if (type == EventType.other && lower.contains('recording')) continue;
            events.add(CpapEvent(
              type,
              edf.start.add(Duration(milliseconds: (a.onset * 1000).round())),
              a.duration ?? 0,
              a.text,
            ));
          }
      }
    }

    // 사용시간 기준: PLD > BRP > SAD
    for (final src in ['PLD', 'BRP', 'SAD']) {
      if (sessionSources[src]!.isNotEmpty) {
        sessions.addAll(sessionSources[src]!.where((s) => s.duration > Duration.zero));
        break;
      }
    }
    sessions.sort((a, b) => a.start.compareTo(b.start));
    events.sort((a, b) => a.time.compareTo(b.time));
    for (final s in series.values) {
      s.segments.sort((a, b) => a.start.compareTo(b.start));
    }

    return NightReport(
      folder: folder,
      date: dateFromFolder(folder),
      sessions: sessions,
      events: events,
      series: series,
    );
  }

  /// BRP(25Hz 유량/압력) 파일들을 파싱해 [report] 에 붙인다.
  static ({TimeSeries flow, TimeSeries pressure}) parseBrp(Map<String, Uint8List> files) {
    final flow = TimeSeries(key: 'flow', label: '호흡 유량', unit: 'L/min');
    final press = TimeSeries(key: 'flowPressure', label: '압력(고해상도)', unit: 'cmH₂O');
    final names = files.keys.toList()..sort();
    for (final name in names) {
      final edf = _tryParse(files[name]!,
          filter: (l) => l.toLowerCase().startsWith('flow') || l.toLowerCase().startsWith('press'));
      if (edf == null) continue;
      final f = edf.signal('Flow');
      if (f != null && f.values.isNotEmpty) {
        final scale = _lpsToLpm(f.physicalDimension);
        flow.segments.add(Segment(edf.start, f.sampleRate,
            scale == 1 ? f.values : Float32List.fromList([for (final v in f.values) v * scale])));
      }
      final p = edf.signal('Press');
      if (p != null && p.values.isNotEmpty) {
        press.segments.add(Segment(edf.start, p.sampleRate, p.values));
      }
    }
    return (flow: flow, pressure: press);
  }

  /// STR.edf (하루당 1레코드 요약) 파싱.
  static List<DailyStat> parseStr(Uint8List bytes) {
    final edf = EdfParser.parse(bytes);
    // 요약 키 → STR 신호 라벨 후보 (기종/펌웨어마다 조금씩 다름)
    const keys = <String, List<String>>{
      'duration': ['Duration'],
      'ahi': ['AHI'],
      'oai': ['OAI'],
      'cai': ['CAI'],
      'hi': ['HI'],
      'uai': ['UAI'],
      'leak50': ['Leak.50'],
      'leak95': ['Leak.95', 'Leak.70'],
      'leakMax': ['Leak.Max'],
      'pressure50': ['MaskPress.50', 'TgtPress.50', 'TgtEPAP.50'],
      'pressure95': ['MaskPress.95', 'TgtPress.95', 'TgtIPAP.95'],
      'pressureMax': ['MaskPress.Max', 'TgtPress.Max'],
      'respRate50': ['RespRate.50'],
      'tidVol50': ['TidVol.50'],
      'minVent50': ['MinVent.50'],
      'spo2_50': ['SpO2.50'],
      'csr': ['CSR'],
    };
    final found = <String, EdfSignal>{};
    for (final e in keys.entries) {
      for (final label in e.value) {
        final s = edf.signals.where((s) => s.label.toLowerCase() == label.toLowerCase());
        if (s.isNotEmpty) {
          found[e.key] = s.first;
          break;
        }
      }
    }
    final base = DateTime(edf.start.year, edf.start.month, edf.start.day);
    final out = <DailyStat>[];
    for (var r = 0; r < edf.numRecords; r++) {
      final values = <String, double>{};
      found.forEach((key, sig) {
        if (sig.samplesPerRecord <= 0) return;
        final v = sig.values[r * sig.samplesPerRecord];
        if (!v.isFinite || v < 0) return; // ResMed 는 데이터 없음을 음수로 기록
        var x = v;
        if (key.startsWith('leak')) x *= _lpsToLpm(sig.physicalDimension);
        if (key == 'tidVol50') x *= _lToMl(sig.physicalDimension);
        values[key] = x;
      });
      final dur = values['duration'];
      if (dur == null || dur <= 0) continue;
      out.add(DailyStat(base.add(Duration(days: r)), values));
    }
    return out;
  }

  static EdfFile? _tryParse(Uint8List bytes, {bool Function(String)? filter}) {
    try {
      return EdfParser.parse(bytes, signalFilter: filter);
    } on Object {
      return null;
    }
  }
}
