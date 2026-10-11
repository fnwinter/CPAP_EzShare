import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../analysis/models.dart';
import '../services/cpap_repository.dart';
import 'charts.dart';
import 'format.dart';

class NightScreen extends StatefulWidget {
  const NightScreen({super.key, required this.repo, required this.folder});
  final CpapRepository repo;
  final String folder;

  @override
  State<NightScreen> createState() => _NightScreenState();
}

class _NightScreenState extends State<NightScreen> {
  NightReport? _report;
  Object? _error;
  String? _progressMsg;
  double? _progress;

  // BRP 파형
  bool _brpLoading = false;
  DateTime? _flowWindowStart;
  double _flowWindowSec = 60;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _onProgress(String msg, double? f) {
    if (!mounted) return;
    setState(() {
      _progressMsg = msg;
      _progress = f;
    });
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _error = null;
      _report = null;
      _progressMsg = '준비 중…';
      _progress = null;
    });
    try {
      final r = await widget.repo.loadNight(widget.folder,
          onProgress: _onProgress, forceDownload: force);
      if (!mounted) return;
      setState(() => _report = r);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  Future<void> _loadBrp() async {
    final r = _report!;
    final kb = await widget.repo.brpSizeKb(r.folder).catchError((_) => null);
    if (!mounted) return;
    if (kb != null && kb > 2048) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('호흡 파형 다운로드'),
          content: Text('BRP 파일 크기가 약 ${(kb / 1024).toStringAsFixed(1)} MB 입니다. '
              'EzShare WiFi 는 느려서 몇 분 걸릴 수 있습니다. 계속할까요?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('다운로드')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _brpLoading = true);
    try {
      await widget.repo.loadBrp(r, onProgress: _onProgress);
      if (!mounted) return;
      setState(() {
        _flowWindowStart = r.flow!.segments.isEmpty ? null : r.flow!.segments.first.start;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('파형 로드 실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _brpLoading = false);
    }
  }

  void _jumpToEvent(CpapEvent e) {
    if (_report?.flow == null) return;
    setState(() {
      _flowWindowStart = e.time.subtract(Duration(seconds: (_flowWindowSec / 3).round()));
    });
  }

  @override
  Widget build(BuildContext context) {
    final date = parseFolderDate(widget.folder);
    return Scaffold(
      appBar: AppBar(
        title: Text(dateFmt.format(date)),
        actions: [
          IconButton(
            tooltip: '다시 다운로드',
            icon: const Icon(Icons.refresh),
            onPressed: _report == null && _error == null ? null : () => _load(force: true),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
              const SizedBox(height: 12),
              Text('$_error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('다시 시도'),
              ),
            ],
          ),
        ),
      );
    }
    final r = _report;
    if (r == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 220,
                child: LinearProgressIndicator(value: _progress),
              ),
              const SizedBox(height: 12),
              Text(_progressMsg ?? '', textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    if (r.sessions.isEmpty) {
      return const Center(child: Text('이 날짜에는 치료 세션 기록이 없습니다.'));
    }

    final origin = r.firstStart!;
    final end = r.lastEnd!;
    final maxX = end.difference(origin).inMilliseconds / 3600000.0;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
      children: [
        _SummaryCard(report: r),
        const SizedBox(height: 8),
        _EventCountsCard(report: r),
        const SizedBox(height: 8),
        _StatsCard(report: r),
        const SizedBox(height: 8),
        _Section(
          title: '이벤트 타임라인',
          child: EventTimeline(events: r.events, sessions: r.sessions, origin: origin, end: end),
        ),
        for (final key in const ['pressure', 'maskPressure', 'leak', 'respRate', 'tidalVolume',
          'minuteVent', 'flowLimit', 'snore', 'spo2', 'pulse'])
          if (r.series[key] != null && !r.series[key]!.isEmpty)
            _seriesSection(r, key, origin, maxX),
        _buildFlowSection(r),
        const SizedBox(height: 8),
        _EventListCard(report: r, onTap: r.flow != null ? _jumpToEvent : null),
      ],
    );
  }

  Widget _seriesSection(NightReport r, String key, DateTime origin, double maxX) {
    final s = r.series[key]!;
    final stat = r.stat(key);
    final scheme = Theme.of(context).colorScheme;
    final (color, minY, maxY, threshold) = switch (key) {
      'pressure' || 'maskPressure' => (scheme.primary, 0.0, null, null),
      'leak' => (const Color(0xFFE06A00), 0.0, null, largeLeakLpm),
      'respRate' => (const Color(0xFF2F80ED), 0.0, null, null),
      'tidalVolume' => (const Color(0xFF7B4FD6), 0.0, null, null),
      'minuteVent' => (const Color(0xFF00A3A3), 0.0, null, null),
      'flowLimit' => (const Color(0xFF8E6E00), 0.0, 1.0, null),
      'snore' => (const Color(0xFF8E8E93), 0.0, null, null),
      'spo2' => (const Color(0xFFD03030), 80.0, 100.0, 90.0),
      'pulse' => (const Color(0xFFD0306A), null, null, null),
      _ => (scheme.primary, null, null, null),
    };
    double? effMaxY = maxY;
    if (key == 'leak' && stat != null) effMaxY = math.max(stat.max, largeLeakLpm + 6);
    return _Section(
      title: '${s.label}${s.unit.isEmpty ? '' : ' (${s.unit})'}',
      trailing: stat == null
          ? null
          : Text('중앙 ${fmtNum(stat.median)} · 95% ${fmtNum(stat.p95)}',
              style: Theme.of(context).textTheme.bodySmall),
      child: NightLineChart(
        points: downsample(s, origin),
        origin: origin,
        color: color,
        unit: s.unit,
        maxX: maxX,
        minY: minY,
        maxY: effMaxY,
        threshold: threshold,
      ),
    );
  }

  Widget _buildFlowSection(NightReport r) {
    final flow = r.flow;
    if (flow == null) {
      return _Section(
        title: '호흡 유량 파형 (BRP, 25Hz)',
        child: Center(
          child: _brpLoading
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(children: [
                    LinearProgressIndicator(value: _progress),
                    const SizedBox(height: 8),
                    Text(_progressMsg ?? ''),
                  ]),
                )
              : OutlinedButton.icon(
                  onPressed: _loadBrp,
                  icon: const Icon(Icons.show_chart),
                  label: const Text('고해상도 파형 불러오기'),
                ),
        ),
      );
    }
    if (flow.isEmpty || _flowWindowStart == null) {
      return const _Section(title: '호흡 유량 파형', child: Text('파형 데이터가 없습니다.'));
    }
    final first = flow.segments.first.start;
    final last = flow.segments.last.end;
    final totalSec = last.difference(first).inSeconds.toDouble();
    final maxStart = math.max(0.0, totalSec - _flowWindowSec);
    final pos = _flowWindowStart!.difference(first).inSeconds.toDouble().clamp(0.0, maxStart);
    final windowStart = first.add(Duration(seconds: pos.round()));

    return _Section(
      title: '호흡 유량 파형 (L/min)',
      trailing: SegmentedButton<double>(
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 30, label: Text('30초')),
          ButtonSegment(value: 60, label: Text('1분')),
          ButtonSegment(value: 300, label: Text('5분')),
        ],
        selected: {_flowWindowSec},
        onSelectionChanged: (v) => setState(() => _flowWindowSec = v.first),
      ),
      child: Column(
        children: [
          FlowWindowChart(
            flow: flow,
            windowStart: windowStart,
            windowSeconds: _flowWindowSec,
            events: r.events,
          ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() => _flowWindowStart =
                    windowStart.subtract(Duration(seconds: _flowWindowSec.round()))),
              ),
              Expanded(
                child: Slider(
                  value: pos,
                  max: maxStart <= 0 ? 1 : maxStart,
                  label: timeFmt.format(windowStart),
                  divisions: maxStart <= 0 ? null : math.max(1, (maxStart / 10).round()),
                  onChanged: maxStart <= 0
                      ? null
                      : (v) => setState(() => _flowWindowStart = first.add(Duration(seconds: v.round()))),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(() => _flowWindowStart =
                    windowStart.add(Duration(seconds: _flowWindowSec.round()))),
              ),
            ],
          ),
          Text('아래 이벤트 목록을 탭하면 해당 시점의 파형으로 이동합니다.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall)),
                ?trailing,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.report});
  final NightReport report;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final theme = Theme.of(context);
    final ahi = r.ahi;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ahiColor(ahi).withValues(alpha: 0.12),
                border: Border.all(color: ahiColor(ahi), width: 3),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(fmtNum(ahi),
                      style: theme.textTheme.headlineMedium!
                          .copyWith(color: ahiColor(ahi), fontWeight: FontWeight.bold)),
                  Text('AHI', style: theme.textTheme.labelSmall),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ahiLabel(ahi),
                      style: theme.textTheme.titleMedium!.copyWith(color: ahiColor(ahi))),
                  const SizedBox(height: 4),
                  Text('사용 시간  ${fmtDuration(r.usage)}', style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 4),
                  Text(
                    '${timeFmt.format(r.firstStart!)} ~ ${timeFmt.format(r.lastEnd!)}'
                    ' · 세션 ${r.sessions.length}회',
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (r.usageHours < 4)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('⚠ 4시간 미만 사용',
                          style: theme.textTheme.bodySmall!.copyWith(color: Colors.orange.shade800)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EventCountsCard extends StatelessWidget {
  const _EventCountsCard({required this.report});
  final NightReport report;

  @override
  Widget build(BuildContext context) {
    final counts = report.eventCounts;
    final theme = Theme.of(context);
    const shown = [
      EventType.obstructiveApnea,
      EventType.centralApnea,
      EventType.hypopnea,
      EventType.apnea,
      EventType.rera,
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Row(
          children: [
            for (final t in shown)
              Expanded(
                child: Column(
                  children: [
                    Text('${counts[t]}',
                        style: theme.textTheme.titleLarge!
                            .copyWith(color: eventColor(t), fontWeight: FontWeight.bold)),
                    Text(t.code, style: theme.textTheme.labelMedium),
                    Text('${fmtNum(report.indexFor(t))}/h', style: theme.textTheme.bodySmall),
                    Text(t.label,
                        style: theme.textTheme.labelSmall, textAlign: TextAlign.center),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.report});
  final NightReport report;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String, SeriesStats?, String)>[
      ('치료 압력', 'cmH₂O', report.stat('pressure'), 'pressure'),
      ('마스크 압력', 'cmH₂O', report.stat('maskPressure'), 'maskPressure'),
      ('누출', 'L/min', report.stat('leak'), 'leak'),
      ('호흡수', '회/분', report.stat('respRate'), 'respRate'),
      ('일회호흡량', 'mL', report.stat('tidalVolume'), 'tidalVolume'),
      ('분당환기량', 'L/min', report.stat('minuteVent'), 'minuteVent'),
      ('산소포화도', '%', report.stat('spo2'), 'spo2'),
      ('맥박', 'bpm', report.stat('pulse'), 'pulse'),
    ].where((r) => r.$3 != null).toList();
    if (rows.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final head = theme.textTheme.labelMedium!.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final leak = report.stat('leak');
    final largeLeakMinutes = _largeLeakMinutes(report);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Table(
              columnWidths: const {0: FlexColumnWidth(2.2)},
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                TableRow(children: [
                  Text('항목', style: head),
                  Text('중앙값', style: head, textAlign: TextAlign.end),
                  Text('95%', style: head, textAlign: TextAlign.end),
                  Text('최대', style: head, textAlign: TextAlign.end),
                ]),
                for (final (label, unit, s, key) in rows)
                  TableRow(children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Text.rich(TextSpan(children: [
                        TextSpan(text: label),
                        TextSpan(text: ' $unit', style: theme.textTheme.bodySmall),
                      ])),
                    ),
                    Text(fmtNum(s!.median, digits: key == 'tidalVolume' ? 0 : 1),
                        textAlign: TextAlign.end),
                    Text(fmtNum(s.p95, digits: key == 'tidalVolume' ? 0 : 1),
                        textAlign: TextAlign.end,
                        style: key == 'leak' && s.p95 > largeLeakLpm
                            ? const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)
                            : null),
                    Text(
                        key == 'spo2'
                            ? '최저 ${fmtNum(s.min, digits: 0)}'
                            : fmtNum(s.max, digits: key == 'tidalVolume' ? 0 : 1),
                        textAlign: TextAlign.end),
                  ]),
              ],
            ),
            if (leak != null) ...[
              const Divider(height: 20),
              Text(
                leak.p95 > largeLeakLpm
                    ? '⚠ 누출 95% 값이 ${largeLeakLpm.toInt()} L/min 을 넘습니다. 마스크 착용 상태를 확인하세요.'
                    : '✓ 누출 수준 양호 (95% < ${largeLeakLpm.toInt()} L/min)',
                style: theme.textTheme.bodySmall,
              ),
              if (largeLeakMinutes > 0)
                Text('대량 누출 시간: 약 ${largeLeakMinutes.toStringAsFixed(0)}분',
                    style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  static double _largeLeakMinutes(NightReport r) {
    final s = r.series['leak'];
    if (s == null) return 0;
    var sec = 0.0;
    for (final seg in s.segments) {
      if (seg.sampleRate <= 0) continue;
      final n = seg.values.where((v) => v > largeLeakLpm).length;
      sec += n / seg.sampleRate;
    }
    return sec / 60;
  }
}

class _EventListCard extends StatelessWidget {
  const _EventListCard({required this.report, this.onTap});
  final NightReport report;
  final void Function(CpapEvent)? onTap;

  @override
  Widget build(BuildContext context) {
    final events = report.events.where((e) => e.type != EventType.other).toList();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        title: Text('이벤트 목록 (${events.length})'),
        shape: const Border(),
        children: [
          if (events.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('기록된 이벤트가 없습니다.')),
          for (final e in events)
            ListTile(
              dense: true,
              onTap: onTap == null ? null : () => onTap!(e),
              leading: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: eventColor(e.type), shape: BoxShape.circle),
              ),
              title: Text('${timeSecFmt.format(e.time)}  ${e.type.label}'),
              trailing: Text(e.duration > 0 ? '${e.duration.toStringAsFixed(0)}초' : ''),
            ),
        ],
      ),
    );
  }
}
