import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../analysis/models.dart';
import '../services/cpap_repository.dart';
import 'format.dart';

/// STR.edf 기반 일별 추세 화면.
class TrendScreen extends StatefulWidget {
  const TrendScreen({super.key, required this.repo});
  final CpapRepository repo;

  @override
  State<TrendScreen> createState() => _TrendScreenState();
}

class _TrendScreenState extends State<TrendScreen> {
  List<DailyStat>? _days;
  Object? _error;
  String? _msg;
  double? _progress;
  int _range = 30;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _days = null;
    });
    try {
      final d = await widget.repo.loadDailyStats(onProgress: (m, f) {
        if (!mounted) return;
        setState(() {
          _msg = m;
          _progress = f;
        });
      });
      if (mounted) setState(() => _days = d);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('전체 추세'),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('$_error', textAlign: TextAlign.center),
        ),
      );
    }
    final all = _days;
    if (all == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 220, child: LinearProgressIndicator(value: _progress)),
          const SizedBox(height: 12),
          Text(_msg ?? ''),
        ]),
      );
    }
    if (all.isEmpty) return const Center(child: Text('STR.edf 에 사용 기록이 없습니다.'));

    final lastDay = all.last.date;
    final days = _range == 0
        ? all
        : all.where((d) => !d.date.isBefore(lastDay.subtract(Duration(days: _range - 1)))).toList();
    final periodDays = _range == 0
        ? lastDay.difference(all.first.date).inDays + 1
        : _range;

    final usage = days.map((d) => d.usageHours ?? 0).toList();
    final compliant = usage.where((h) => h >= 4).length;
    final ahis = days.map((d) => d.ahi).whereType<double>().toList();
    final avgAhi = ahis.isEmpty ? null : ahis.reduce((a, b) => a + b) / ahis.length;
    final avgUsage = usage.isEmpty ? 0.0 : usage.reduce((a, b) => a + b) / usage.length;
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Center(
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 7, label: Text('7일')),
              ButtonSegment(value: 30, label: Text('30일')),
              ButtonSegment(value: 90, label: Text('90일')),
              ButtonSegment(value: 0, label: Text('전체')),
            ],
            selected: {_range},
            onSelectionChanged: (s) => setState(() => _range = s.first),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(children: [
              _kpi(theme, '평균 AHI', fmtNum(avgAhi), color: ahiColor(avgAhi)),
              _kpi(theme, '평균 사용', fmtHm(Duration(minutes: (avgUsage * 60).round()))),
              _kpi(theme, '4시간 이상',
                  '${(compliant / math.max(1, periodDays) * 100).toStringAsFixed(0)}%',
                  sub: '$compliant/$periodDays일'),
            ]),
          ),
        ),
        _chartCard(theme, 'AHI (회/시간)', days, (d) => d.ahi,
            colorFor: (v) => ahiColor(v), refLine: 5),
        _chartCard(theme, '사용 시간 (시간)', days, (d) => d.usageHours,
            colorFor: (v) => v >= 4 ? theme.colorScheme.primary : Colors.orange, refLine: 4),
        _chartCard(theme, '누출 95% (L/min)', days, (d) => d.leak95,
            colorFor: (v) => v > largeLeakLpm ? Colors.red : const Color(0xFFE06A00),
            refLine: largeLeakLpm),
        _chartCard(theme, '압력 95% (cmH₂O)', days, (d) => d.pressure95,
            colorFor: (_) => theme.colorScheme.tertiary),
      ],
    );
  }

  Widget _kpi(ThemeData theme, String label, String value, {Color? color, String? sub}) {
    return Expanded(
      child: Column(children: [
        Text(value,
            style: theme.textTheme.headlineSmall!
                .copyWith(fontWeight: FontWeight.bold, color: color)),
        Text(label, style: theme.textTheme.labelMedium),
        if (sub != null) Text(sub, style: theme.textTheme.bodySmall),
      ]),
    );
  }

  Widget _chartCard(
    ThemeData theme,
    String title,
    List<DailyStat> days,
    double? Function(DailyStat) value, {
    required Color Function(double) colorFor,
    double? refLine,
  }) {
    if (days.every((d) => value(d) == null)) return const SizedBox.shrink();
    final first = days.first.date;
    final barWidth = days.length > 60 ? 2.0 : days.length > 20 ? 5.0 : 12.0;
    final labelStyle = TextStyle(fontSize: 10, color: theme.colorScheme.onSurfaceVariant);
    final labelEvery = math.max(1, (days.length / 6).ceil());

    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 12),
          SizedBox(
            height: 150,
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceBetween,
                barGroups: [
                  for (final d in days)
                    if (value(d) != null)
                      BarChartGroupData(
                        x: d.date.difference(first).inDays,
                        barRods: [
                          BarChartRodData(
                            toY: value(d)!,
                            color: colorFor(value(d)!),
                            width: barWidth,
                            borderRadius: BorderRadius.circular(barWidth > 4 ? 2 : 0),
                          ),
                        ],
                      ),
                ],
                extraLinesData: refLine == null
                    ? null
                    : ExtraLinesData(horizontalLines: [
                        HorizontalLine(
                          y: refLine,
                          color: theme.colorScheme.outline,
                          strokeWidth: 1,
                          dashArray: [4, 4],
                        ),
                      ]),
                gridData: FlGridData(
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) => FlLine(
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                      strokeWidth: 0.6),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 32,
                      getTitlesWidget: (v, meta) => v == meta.max
                          ? const SizedBox.shrink()
                          : Text(meta.formattedValue, style: labelStyle),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 20,
                      getTitlesWidget: (v, meta) {
                        final i = v.toInt();
                        if (i % labelEvery != 0) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(shortDateFmt.format(first.add(Duration(days: i))),
                              style: labelStyle),
                        );
                      },
                    ),
                  ),
                ),
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) => theme.colorScheme.inverseSurface,
                    getTooltipItem: (group, _, rod, _) => BarTooltipItem(
                      '${shortDateFmt.format(first.add(Duration(days: group.x)))}\n'
                      '${rod.toY.toStringAsFixed(1)}',
                      TextStyle(color: theme.colorScheme.onInverseSurface, fontSize: 12),
                    ),
                  ),
                ),
              ),
              duration: Duration.zero,
            ),
          ),
        ]),
      ),
    );
  }
}
