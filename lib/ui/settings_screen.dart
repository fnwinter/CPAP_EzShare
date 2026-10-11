import 'package:flutter/material.dart';

import '../services/cpap_repository.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.repo});
  final CpapRepository repo;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _url = TextEditingController(text: widget.repo.settings.baseUrl);
  late final _path = TextEditingController(text: widget.repo.settings.datalogPath);
  int? _cacheBytes;

  @override
  void initState() {
    super.initState();
    widget.repo.cacheBytes().then((b) {
      if (mounted) setState(() => _cacheBytes = b);
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    var url = _url.text.trim();
    if (!url.startsWith('http')) url = 'http://$url';
    final path = _path.text.trim().replaceAll('/', r'\').replaceAll(RegExp(r'^[A-Za-z]:\\?'), '');
    await widget.repo.updateSettings(AppSettings(
      baseUrl: url,
      datalogPath: path.isEmpty ? AppSettings.defaultDatalogPath : path,
    ));
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('설정'),
        actions: [TextButton(onPressed: _save, child: const Text('저장'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'EzShare 주소',
              helperText: '기본값: ${AppSettings.defaultBaseUrl}',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _path,
            decoration: const InputDecoration(
              labelText: 'DATALOG 폴더 경로 (SD 카드 기준)',
              helperText: r'기본값: DATALOG  (예: Data\DATALOG)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.storage),
            title: const Text('다운로드 캐시'),
            subtitle: Text(_cacheBytes == null
                ? '계산 중…'
                : '${(_cacheBytes! / 1024 / 1024).toStringAsFixed(1)} MB'),
            trailing: TextButton(
              onPressed: () async {
                await widget.repo.clearCache();
                final b = await widget.repo.cacheBytes();
                if (mounted) setState(() => _cacheBytes = b);
              },
              child: const Text('비우기'),
            ),
          ),
          const Divider(),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline),
            title: Text('사용 방법'),
            subtitle: Text(
              '1. AirSense 에 EzShare WiFi SD 카드를 꽂습니다.\n'
              '2. 휴대폰 WiFi 를 EzShare 네트워크(기본 비밀번호 88888888)에 연결합니다.\n'
              '   "인터넷 연결 없음" 경고가 나오면 연결 유지를 선택하세요.\n'
              '3. 앱에서 날짜를 선택하면 해당 밤의 데이터를 내려받아 분석합니다.\n\n'
              '이 앱의 분석 결과는 참고용이며 의료적 진단을 대신하지 않습니다.',
            ),
          ),
        ],
      ),
    );
  }
}
