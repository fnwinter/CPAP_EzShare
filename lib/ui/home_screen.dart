import 'package:flutter/material.dart';

import '../services/cpap_repository.dart';
import 'format.dart';
import 'night_screen.dart';
import 'settings_screen.dart';
import 'trend_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.repo});
  final CpapRepository repo;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  NightListResult? _result;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final r = await widget.repo.listNights();
    if (!mounted) return;
    setState(() {
      _result = r;
      _loading = false;
    });
  }

  Future<void> _openNight(String folder) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NightScreen(repo: widget.repo, folder: folder),
    ));
    if (mounted) setState(() {}); // 요약 갱신
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('CPAP EzShare'),
        actions: [
          IconButton(
            tooltip: '전체 추세 (STR.edf)',
            icon: const Icon(Icons.insights),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => TrendScreen(repo: widget.repo),
            )),
          ),
          IconButton(
            tooltip: '설정',
            icon: const Icon(Icons.settings),
            onPressed: () async {
              final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
                builder: (_) => SettingsScreen(repo: widget.repo),
              ));
              if (changed == true) _refresh();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _buildBody(r),
      ),
    );
  }

  Widget _buildBody(NightListResult? r) {
    if (r == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        if (_loading) const LinearProgressIndicator(),
        _ConnectionBanner(result: r, baseUrl: widget.repo.settings.baseUrl, onRetry: _refresh),
        if (r.folders.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                Icon(Icons.sd_card_alert_outlined,
                    size: 48, color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 12),
                Text(
                  r.offline
                      ? 'EzShare WiFi 에 연결한 뒤 아래로 당겨 새로고침하세요.'
                      : '${widget.repo.settings.datalogPath} 폴더에 날짜 폴더가 없습니다.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        for (final folder in r.folders) _NightTile(
          folder: folder,
          repo: widget.repo,
          onTap: () => _openNight(folder),
        ),
      ],
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.result, required this.baseUrl, required this.onRetry});
  final NightListResult result;
  final String baseUrl;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!result.offline) {
      return ListTile(
        dense: true,
        leading: Icon(Icons.wifi, color: Colors.green.shade600),
        title: Text('EzShare 연결됨 · $baseUrl'),
        subtitle: Text('${result.folders.length}개 기록'),
      );
    }
    return Card(
      margin: const EdgeInsets.all(12),
      color: scheme.errorContainer,
      child: ListTile(
        leading: Icon(Icons.wifi_off, color: scheme.onErrorContainer),
        title: Text('EzShare 에 연결되지 않음',
            style: TextStyle(color: scheme.onErrorContainer, fontWeight: FontWeight.w600)),
        subtitle: Text(
          '${result.error ?? ''}\n휴대폰 WiFi 를 EzShare(기본 비밀번호 88888888)에 연결하세요. '
          '캐시된 기록만 표시합니다.',
          style: TextStyle(color: scheme.onErrorContainer),
        ),
        trailing: IconButton(
          icon: Icon(Icons.refresh, color: scheme.onErrorContainer),
          onPressed: onRetry,
        ),
        isThreeLine: true,
      ),
    );
  }
}

class _NightTile extends StatelessWidget {
  const _NightTile({required this.folder, required this.repo, required this.onTap});
  final String folder;
  final CpapRepository repo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = repo.summaryFor(folder);
    final date = parseFolderDate(folder);
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: s == null ? scheme.surfaceContainerHighest : ahiColor(s.ahi),
        foregroundColor: Colors.white,
        child: s == null
            ? Icon(Icons.nightlight_outlined, color: scheme.onSurfaceVariant)
            : Text(fmtNum(s.ahi), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
      ),
      title: Text(dateFmt.format(date)),
      subtitle: Text(s == null
          ? '탭하여 분석'
          : '사용 ${fmtHm(Duration(minutes: s.usageMinutes))} · AHI ${fmtNum(s.ahi)}'
              ' · 압력95% ${fmtNum(s.pressure95)} · 누출95% ${fmtNum(s.leak95)}'),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}
