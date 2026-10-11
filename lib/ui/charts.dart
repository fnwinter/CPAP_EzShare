import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../analysis/models.dart';
import 'format.dart';

/// 하룻밤 시간축(origin 기준 시간 단위) 선 그래프.
class NightLineChart extends StatelessWidget {
  const NightLineChart({
    super.key,
    required this.points,
    required this.origin,
    required this.color,
    required this.unit,
    this.minX = 0,
    required this.maxX,
    this.minY,
    this.maxY,
    this.threshold,
    this.height = 150,
  });

  final List<math.Point<double>> points;
  final DateTime origin;
  final Color color;
  final String unit;
  final double minX;
  final double maxX;
  final double? minY;
  final double? maxY;
  final double? threshold;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spots = [
      for (final p in points) p.y.isNaN ? FlSpot.nullSpot : FlSpot(p.x, p.y),
    ];
    final span = maxX - minX;
    final interval = span <= 0
        ? 1.0
        : span <= 3
            ? 0.5
            : span <= 8
                ? 1.0
                : 2.0;
    final labelStyle = TextStyle(fontSize: 10, color: scheme.onSurfaceVariant);

    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minX: minX,
          maxX: maxX <= minX ? minX + 1 : maxX,
          minY: minY,
          maxY: maxY,
          clipData: const FlClipData.all(),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              color: color,
              barWidth: 1.4,
              isCurved: false,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(show: true, color: color.withValues(alpha: 0.12)),
            ),
          ],
          extraLinesData: threshold == null
              ? null
              : ExtraLinesData(horizontalLines: [
                  HorizontalLine(
                    y: threshold!,
                    color: Colors.red.withValues(alpha: 0.6),
                    strokeWidth: 1,
                    dashArray: [4, 4],
                  ),
                ]),
          gridData: FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: scheme.outlineVariant.withValues(alpha: 0.5), strokeWidth: 0.6),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                getTitlesWidget: (v, meta) {
                  if (v == meta.max || v == meta.min) return const SizedBox.shrink();
                  return Text(meta.formattedValue, style: labelStyle);
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: interval,
                reservedSize: 20,
                getTitlesWidget: (v, meta) {
                  if (v == meta.max && v != meta.min) return const SizedBox.shrink();
                  final t = origin.add(Duration(milliseconds: (v * 3600000).round()));
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(timeFmt.format(t), style: labelStyle),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => scheme.inverseSurface,
              getTooltipItems: (spots) => spots.map((s) {
                final t = origin.add(Duration(milliseconds: (s.x * 3600000).round()));
                return LineTooltipItem(
                  '${timeFmt.format(t)}\n${s.y.toStringAsFixed(1)} $unit',
                  TextStyle(color: scheme.onInverseSurface, fontSize: 12),
                );
              }).toList(),
            ),
          ),
        ),
        duration: Duration.zero,
      ),
    );
  }
}

/// 이벤트 종류별 발생 위치를 한 줄씩 표시하는 타임라인.
class EventTimeline extends StatelessWidget {
  const EventTimeline({
    super.key,
    required this.events,
    required this.sessions,
    required this.origin,
    required this.end,
  });

  final List<CpapEvent> events;
  final List<SessionInfo> sessions;
  final DateTime origin;
  final DateTime end;

  static const types = [
    EventType.obstructiveApnea,
    EventType.centralApnea,
    EventType.hypopnea,
    EventType.apnea,
    EventType.rera,
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final t in types)
          SizedBox(
            height: 22,
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text(t.code,
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w600, color: eventColor(t))),
                ),
                Expanded(
                  child: CustomPaint(
                    painter: _TimelinePainter(
                      events: events.where((e) => e.type == t).toList(),
                      sessions: sessions,
                      origin: origin,
                      end: end,
                      color: eventColor(t),
                      background: scheme.surfaceContainerHighest,
                    ),
                    size: Size.infinite,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.events,
    required this.sessions,
    required this.origin,
    required this.end,
    required this.color,
    required this.background,
  });

  final List<CpapEvent> events;
  final List<SessionInfo> sessions;
  final DateTime origin;
  final DateTime end;
  final Color color;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final total = end.difference(origin).inMilliseconds;
    if (total <= 0) return;
    double x(DateTime t) => t.difference(origin).inMilliseconds / total * size.width;
    final bg = Paint()..color = background;
    for (final s in sessions) {
      canvas.drawRect(
          Rect.fromLTRB(x(s.start), 4, x(s.end), size.height - 4), bg);
    }
    final p = Paint()..color = color;
    for (final e in events) {
      final x0 = x(e.time);
      final w = math.max(1.5, e.duration * 1000 / total * size.width);
      canvas.drawRect(Rect.fromLTWH(x0, 2, w, size.height - 4), p);
    }
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter old) =>
      old.events != events || old.color != color || old.background != background;
}

/// 고해상도 유량 파형 뷰어 (지정한 시간 창만 표시).
class FlowWindowChart extends StatelessWidget {
  const FlowWindowChart({
    super.key,
    required this.flow,
    required this.windowStart,
    required this.windowSeconds,
    required this.events,
    this.height = 200,
  });

  final TimeSeries flow;
  final DateTime windowStart;
  final double windowSeconds;
  final List<CpapEvent> events;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final windowEnd =
        windowStart.add(Duration(milliseconds: (windowSeconds * 1000).round()));
    final spots = <FlSpot>[];
    for (final seg in flow.segments) {
      if (seg.end.isBefore(windowStart) || seg.start.isAfter(windowEnd)) continue;
      final i0 = math.max(0,
          (windowStart.difference(seg.start).inMilliseconds / 1000 * seg.sampleRate).floor());
      final i1 = math.min(seg.values.length,
          (windowEnd.difference(seg.start).inMilliseconds / 1000 * seg.sampleRate).ceil());
      final step = math.max(1, ((i1 - i0) / 1500).ceil());
      for (var i = i0; i < i1; i += step) {
        final t = seg.timeAt(i).difference(windowStart).inMilliseconds / 1000;
        spots.add(FlSpot(t, seg.values[i].toDouble()));
      }
      spots.add(FlSpot.nullSpot);
    }
    if (spots.isNotEmpty && spots.last == FlSpot.nullSpot) spots.removeLast();

    final labelStyle = TextStyle(fontSize: 10, color: scheme.onSurfaceVariant);
    final inWindow = events.where((e) =>
        e.time.isAfter(windowStart.subtract(const Duration(seconds: 60))) &&
        e.time.isBefore(windowEnd));

    return SizedBox(
      height: height,
      child: spots.isEmpty
          ? Center(child: Text('이 구간에는 파형 데이터가 없습니다', style: labelStyle))
          : LineChart(
              LineChartData(
                minX: 0,
                maxX: windowSeconds,
                clipData: const FlClipData.all(),
                rangeAnnotations: RangeAnnotations(
                  verticalRangeAnnotations: [
                    for (final e in inWindow)
                      VerticalRangeAnnotation(
                        x1: math.max(0, e.time.difference(windowStart).inMilliseconds / 1000),
                        x2: math.min(windowSeconds,
                            e.time.difference(windowStart).inMilliseconds / 1000 + math.max(e.duration, 1)),
                        color: eventColor(e.type).withValues(alpha: 0.18),
                      ),
                  ],
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    color: scheme.primary,
                    barWidth: 1,
                    dotData: const FlDotData(show: false),
                  ),
                ],
                gridData: FlGridData(
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (v) => FlLine(
                    color: v == 0
                        ? scheme.outline
                        : scheme.outlineVariant.withValues(alpha: 0.4),
                    strokeWidth: v == 0 ? 0.8 : 0.5,
                  ),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 36,
                      getTitlesWidget: (v, meta) => (v == meta.max || v == meta.min)
                          ? const SizedBox.shrink()
                          : Text(meta.formattedValue, style: labelStyle),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 20,
                      interval: windowSeconds / 4,
                      getTitlesWidget: (v, meta) {
                        final t = windowStart.add(Duration(milliseconds: (v * 1000).round()));
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(timeSecFmt.format(t), style: labelStyle),
                        );
                      },
                    ),
                  ),
                ),
                lineTouchData: const LineTouchData(enabled: false),
              ),
              duration: Duration.zero,
            ),
    );
  }
}
