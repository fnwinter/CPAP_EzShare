import 'package:cpap_ezshare/analysis/airsense_analyzer.dart';
import 'package:cpap_ezshare/analysis/models.dart';
import 'package:cpap_ezshare/edf/edf_parser.dart';
import 'package:cpap_ezshare/services/ezshare_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'edf_test_utils.dart';

void main() {
  // 2시간 세션, PLD 0.5Hz (60초 레코드 × 30 샘플)
  final sessionStart = DateTime(2026, 1, 11, 23, 0, 0);
  const records = 120; // 120분
  const spr = 30;
  final n = records * spr;

  final pld = buildEdf(
    start: sessionStart,
    recordDuration: 60,
    numRecords: records,
    signals: [
      TestSignal('MaskPress.2s', 'cmH2O', -5, 30, spr,
          List.generate(n, (i) => 8 + (i % 10) * 0.2)), // 8.0 ~ 9.8
      TestSignal('Press.2s', 'cmH2O', -5, 30, spr, List.filled(n, 9.0)),
      TestSignal('Leak.2s', 'L/s', 0, 2, spr,
          List.generate(n, (i) => i < n * 0.9 ? 0.1 : 0.5)), // 6 L/min, 마지막 10% 30 L/min
      TestSignal('RespRate.2s', 'bpm', 0, 60, spr, List.filled(n, 15.0)),
      TestSignal('TidVol.2s', 'L', 0, 4, spr, List.filled(n, 0.45)),
    ],
  );

  final eve = buildEdf(
    start: sessionStart,
    recordDuration: 0,
    numRecords: 1,
    signals: [],
    annotationBytes: 400,
    annotationTals: [
      timekeeping(0) +
          tal(5, 'Recording starts') +
          tal(600, 'Obstructive Apnea', duration: 12) +
          tal(1200, 'Hypopnea', duration: 15) +
          tal(1800, 'Hypopnea', duration: 20) +
          tal(2400, 'Central Apnea', duration: 11) +
          tal(3000, 'Arousal', duration: 6),
    ],
  );

  test('EDF 헤더/신호 파싱', () {
    final edf = EdfParser.parse(pld);
    expect(edf.start, sessionStart);
    expect(edf.numRecords, records);
    expect(edf.duration, const Duration(hours: 2));
    final mp = edf.signal('MaskPress')!;
    expect(mp.sampleRate, closeTo(0.5, 1e-9));
    expect(mp.values.length, n);
    expect(mp.values[3], closeTo(8.6, 0.01));
    // 'Press' 접두어가 MaskPress 를 잡지 않아야 함
    expect(edf.signal('Press')!.label, 'Press.2s');
  });

  test('EDF+ 어노테이션 파싱', () {
    final edf = EdfParser.parse(eve);
    expect(edf.isEdfPlus, isTrue);
    expect(edf.annotations.map((a) => a.text),
        ['Recording starts', 'Obstructive Apnea', 'Hypopnea', 'Hypopnea', 'Central Apnea', 'Arousal']);
    expect(edf.annotations[1].onset, 600);
    expect(edf.annotations[1].duration, 12);
  });

  test('잘린 파일 / numRecords=-1 처리', () {
    final truncated = pld.sublist(0, pld.length - 61 * 2 * 30); // 마지막 일부 손실
    final edf = EdfParser.parse(truncated);
    expect(edf.numRecords, lessThan(records));
  });

  test('하룻밤 분석: 사용시간, AHI, 통계, 단위 변환', () {
    final r = AirSenseAnalyzer.analyzeNight('20260111', {
      '20260111_230000_PLD.edf': pld,
      '20260111_230000_EVE.edf': eve,
    });
    expect(r.sessions, hasLength(1));
    expect(r.usage, const Duration(hours: 2));
    final c = r.eventCounts;
    expect(c[EventType.obstructiveApnea], 1);
    expect(c[EventType.hypopnea], 2);
    expect(c[EventType.centralApnea], 1);
    expect(c[EventType.rera], 1);
    expect(c[EventType.other], 0, reason: 'Recording starts 는 제외');
    expect(r.ahi, closeTo(4 / 2, 1e-9)); // (OA+H+H+CA)/2h
    expect(r.events.first.time, sessionStart.add(const Duration(seconds: 600)));

    final leak = r.stat('leak')!;
    expect(leak.median, closeTo(6, 0.1)); // 0.1 L/s → 6 L/min
    expect(leak.p95, closeTo(30, 0.1));
    expect(r.stat('tidalVolume')!.median, closeTo(450, 1)); // L → mL
    expect(r.stat('pressure')!.median, closeTo(9, 0.01));
    expect(r.toSummary().usageMinutes, 120);
  });

  test('다운샘플링은 세션 사이를 끊는다', () {
    final pld2 = buildEdf(
      start: sessionStart.add(const Duration(hours: 3)),
      recordDuration: 60,
      numRecords: 10,
      signals: [TestSignal('Press.2s', 'cmH2O', -5, 30, spr, List.filled(300, 10.0))],
    );
    final r = AirSenseAnalyzer.analyzeNight('20260111', {
      '20260111_230000_PLD.edf': pld,
      '20260112_020000_PLD.edf': pld2,
    });
    expect(r.sessions, hasLength(2));
    expect(r.usage, const Duration(hours: 2, minutes: 10));
    final pts = downsample(r.series['pressure']!, r.firstStart!, maxPoints: 200);
    expect(pts.where((p) => p.y.isNaN), hasLength(1));
    expect(pts.last.x, greaterThan(3));
  });

  test('STR.edf 일별 요약', () {
    // 하루 1레코드 (86400초). 3일 중 둘째 날은 미사용
    final str = buildEdf(
      start: DateTime(2026, 1, 10, 12),
      recordDuration: 86400,
      numRecords: 3,
      signals: [
        TestSignal('Duration', 'min', 0, 1440, 1, [420, 0, 300]),
        TestSignal('AHI', '', 0, 100, 1, [3.2, -1, 7.5], digMin: -32768),
        TestSignal('Leak.95', 'L/s', 0, 2, 1, [0.3, 0, 0.5]),
        TestSignal('MaskPress.95', 'cmH2O', 0, 30, 1, [10.5, 0, 11]),
      ],
    );
    final days = AirSenseAnalyzer.parseStr(str);
    expect(days, hasLength(2));
    expect(days[0].date, DateTime(2026, 1, 10));
    expect(days[0].usageHours, closeTo(7, 0.01));
    expect(days[0].ahi, closeTo(3.2, 0.01));
    expect(days[0].leak95, closeTo(18, 0.05));
    expect(days[1].date, DateTime(2026, 1, 12));
    expect(days[1].pressure95, closeTo(11, 0.01));
  });

  test('파일명 해석', () {
    expect(AirSenseAnalyzer.fileKind('20260111_230000_BRP.edf'), 'BRP');
    expect(AirSenseAnalyzer.fileKind('STR.edf'), isNull);
    expect(AirSenseAnalyzer.timeFromName('20260111_230512_PLD.edf'),
        DateTime(2026, 1, 11, 23, 5, 12));
  });

  group('EzShare 목록 파싱', () {
    const html = '''
<html><head><title>ez Share</title></head><body>
<h1>Directory Index of A:\\DATALOG\\</h1><pre>
2026- 1-12   10:20:30         &lt;DIR&gt;   <a href="dir?dir=A:%5CDATALOG%5C."> .</a>
2026- 1-12   10:20:30         &lt;DIR&gt;   <a href="dir?dir=A:%5CDATALOG%5C.."> ..</a>
2026- 1-11   22:58:02         &lt;DIR&gt;   <a href="dir?dir=A:%5CDATALOG%5C20260111"> 20260111</a>
2026- 1-12   23:01:44         &lt;DIR&gt;   <a href="dir?dir=A:%5CDATALOG%5C20260112"> 20260112</a>
2026- 1-12   07:01:44          1234KB  <a href="http://ezshare.card/download?file=DATALOG%5C20260112%5C20260112_230144_BRP.edf"> 20260112_230144_BRP.edf</a>
2026- 1-12   07:01:44            12KB  <a href="download?file=DATALOG\\20260112\\20260112_230144_EVE.edf"> 20260112_230144_EVE.edf</a>
</pre></body></html>''';

    test('디렉터리와 파일 구분, 크기, URL', () {
      final entries = EzShareClient.parseListing(html, 'DATALOG', 'http://ezshare.card');
      expect(entries.map((e) => e.name),
          ['20260111', '20260112', '20260112_230144_BRP.edf', '20260112_230144_EVE.edf']);
      final dir = entries[0];
      expect(dir.isDir, isTrue);
      expect(dir.path, r'DATALOG\20260111');
      final brp = entries[2];
      expect(brp.isDir, isFalse);
      expect(brp.sizeKb, 1234);
      expect(brp.url.toString(),
          'http://ezshare.card/download?file=DATALOG%5C20260112%5C20260112_230144_BRP.edf');
      final eveEntry = entries[3];
      expect(eveEntry.sizeKb, 12);
      expect(eveEntry.url.toString(),
          'http://ezshare.card/download?file=DATALOG%5C20260112%5C20260112_230144_EVE.edf');
    });

    test('목록 요청 URL', () {
      final c = EzShareClient(baseUrl: 'http://ezshare.card/');
      expect(c.dirUri(r'DATALOG\20260111').toString(),
          'http://ezshare.card/dir?dir=A:%5CDATALOG%5C20260111');
      expect(c.dirUri('').toString(), 'http://ezshare.card/dir?dir=A:%5C');
      expect(c.downloadUri(r'STR.edf').toString(), 'http://ezshare.card/download?file=STR.edf');
    });
  });
}
