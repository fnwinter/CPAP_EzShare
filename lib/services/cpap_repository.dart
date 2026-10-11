import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../analysis/airsense_analyzer.dart';
import '../analysis/models.dart';
import 'ezshare_client.dart';
import 'network_binder.dart';

class AppSettings {
  const AppSettings({required this.baseUrl, required this.datalogPath});

  static const defaultBaseUrl = 'http://ezshare.card';
  static const defaultDatalogPath = 'DATALOG';

  final String baseUrl;

  /// SD 카드 내 DATALOG 경로 (드라이브 문자 제외)
  final String datalogPath;

  /// STR.edf 가 있는 SD 카드 루트 (DATALOG 의 상위 폴더)
  String get rootPath {
    final parts = datalogPath.split(RegExp(r'[\\/]+')).where((s) => s.isNotEmpty).toList();
    if (parts.isNotEmpty) parts.removeLast();
    return parts.join(r'\');
  }

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    var baseUrl = p.getString('baseUrl') ?? defaultBaseUrl;
    // 이전 버전의 기본 주소가 저장돼 있으면 새 기본 주소로 바꾼다.
    if (baseUrl == 'http://192.168.4.1') baseUrl = defaultBaseUrl;
    return AppSettings(
      baseUrl: baseUrl,
      datalogPath: p.getString('datalogPath') ?? defaultDatalogPath,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('baseUrl', baseUrl);
    await p.setString('datalogPath', datalogPath);
  }
}

class NightListResult {
  const NightListResult(this.folders, {required this.offline, this.error});
  final List<String> folders; // 최신순
  final bool offline;
  final String? error;
}

typedef ProgressCallback = void Function(String message, double? fraction);

class CpapRepository {
  CpapRepository._(this.settings, this._cache, this._summaries);

  AppSettings settings;
  final FileCache _cache;
  final Map<String, NightSummary> _summaries;
  late EzShareClient _client = EzShareClient(baseUrl: settings.baseUrl);

  /// 폴더별 파일 목록 (네트워크 목록 결과 메모)
  final Map<String, List<EzEntry>> _listing = {};

  static Future<CpapRepository> create() async {
    final settings = await AppSettings.load();
    final cache = await FileCache.open();
    final summaries = <String, NightSummary>{};
    try {
      final f = File('${cache.root.path}/summaries.json');
      if (await f.exists()) {
        final list = jsonDecode(await f.readAsString()) as List;
        for (final j in list) {
          final s = NightSummary.fromJson(j as Map<String, dynamic>);
          summaries[s.folder] = s;
        }
      }
    } on Object {
      // 손상된 요약 파일은 무시
    }
    return CpapRepository._(settings, cache, summaries);
  }

  Future<void> updateSettings(AppSettings s) async {
    settings = s;
    await s.save();
    _client.close();
    _client = EzShareClient(baseUrl: s.baseUrl);
    _listing.clear();
  }

  NightSummary? summaryFor(String folder) => _summaries[folder];

  Future<void> _saveSummary(NightSummary s) async {
    _summaries[s.folder] = s;
    final f = File('${_cache.root.path}/summaries.json');
    await f.writeAsString(jsonEncode(_summaries.values.map((e) => e.toJson()).toList()));
  }

  static final _folderRe = RegExp(r'^\d{8}$');

  /// DATALOG 아래 날짜 폴더 목록. 연결 실패 시 캐시된 폴더를 반환.
  Future<NightListResult> listNights() async {
    await NetworkBinder.bindToWifi();
    try {
      final entries = await _client.listDir(settings.datalogPath);
      final folders = entries
          .where((e) => e.isDir && _folderRe.hasMatch(e.name))
          .map((e) => e.name)
          .toList()
        ..sort((a, b) => b.compareTo(a));
      return NightListResult(folders, offline: false);
    } on EzShareException catch (e) {
      final cached = await _cache.list(settings.datalogPath);
      final folders = cached
          .where((e) => e.isDir && _folderRe.hasMatch(e.name))
          .map((e) => e.name)
          .toList()
        ..sort((a, b) => b.compareTo(a));
      return NightListResult(folders, offline: true, error: e.message);
    }
  }

  String _folderPath(String folder) => '${settings.datalogPath}\\$folder';

  Future<List<EzEntry>> _listFolder(String folder, {bool forceNetwork = false}) async {
    if (!forceNetwork && _listing.containsKey(folder)) return _listing[folder]!;
    try {
      final entries = await _client.listDir(_folderPath(folder));
      _listing[folder] = entries;
      return entries;
    } on EzShareException {
      final cached = await _cache.list(_folderPath(folder));
      if (cached.isEmpty) rethrow;
      return cached;
    }
  }

  Future<Map<String, Uint8List>> _fetchAll(
    List<EzEntry> entries,
    ProgressCallback? onProgress, {
    bool forceDownload = false,
  }) async {
    final out = <String, Uint8List>{};
    final totalKb = entries.fold<int>(0, (a, e) => a + (e.sizeKb ?? 0));
    var doneKb = 0;
    for (final e in entries) {
      Uint8List? bytes = forceDownload ? null : await _cache.get(e);
      if (bytes == null) {
        final url = e.url ?? _client.downloadUri(e.path);
        bytes = await _client.download(url, onProgress: (rec, _) {
          onProgress?.call(
            '${e.name} 다운로드 중… ${(rec / 1024).toStringAsFixed(0)} KB',
            totalKb > 0 ? ((doneKb + rec / 1024) / totalKb).clamp(0.0, 1.0) : null,
          );
        });
        await _cache.put(e.path, bytes);
      }
      doneKb += e.sizeKb ?? 0;
      out[e.name] = bytes;
    }
    return out;
  }

  /// 하룻밤 데이터 다운로드 + 분석 (BRP 제외).
  Future<NightReport> loadNight(String folder,
      {ProgressCallback? onProgress, bool forceDownload = false}) async {
    await NetworkBinder.bindToWifi();
    onProgress?.call('파일 목록 가져오는 중…', null);
    final entries = await _listFolder(folder, forceNetwork: forceDownload);
    final wanted = entries
        .where((e) => !e.isDir && const {'PLD', 'EVE', 'SAD', 'CSL'}
            .contains(AirSenseAnalyzer.fileKind(e.name)))
        .toList();
    if (wanted.isEmpty) {
      throw EzShareException('$folder 폴더에 분석할 EDF 파일(PLD/EVE/SAD)이 없습니다.');
    }
    final files = await _fetchAll(wanted, onProgress, forceDownload: forceDownload);
    onProgress?.call('분석 중…', null);
    final report = await Isolate.run(() => AirSenseAnalyzer.analyzeNight(folder, files));
    await _saveSummary(report.toSummary());
    return report;
  }

  /// BRP (고해상도 유량 파형) 크기 합계 (KB). 목록에 크기가 없으면 null.
  Future<int?> brpSizeKb(String folder) async {
    final entries = await _listFolder(folder);
    final brp = entries.where((e) => AirSenseAnalyzer.fileKind(e.name) == 'BRP');
    if (brp.isEmpty) return 0;
    if (brp.any((e) => e.sizeKb == null)) return null;
    return brp.fold<int>(0, (a, e) => a + e.sizeKb!);
  }

  Future<void> loadBrp(NightReport report, {ProgressCallback? onProgress}) async {
    await NetworkBinder.bindToWifi();
    final entries = await _listFolder(report.folder);
    final brp = entries.where((e) => AirSenseAnalyzer.fileKind(e.name) == 'BRP').toList();
    if (brp.isEmpty) throw EzShareException('BRP 파일이 없습니다.');
    final files = await _fetchAll(brp, onProgress);
    onProgress?.call('파형 분석 중…', null);
    final r = await Isolate.run(() => AirSenseAnalyzer.parseBrp(files));
    report.flow = r.flow;
    report.flowPressure = r.pressure;
  }

  /// SD 카드 루트의 STR.edf (전체 기간 일별 요약).
  Future<List<DailyStat>> loadDailyStats({ProgressCallback? onProgress}) async {
    await NetworkBinder.bindToWifi();
    final root = settings.rootPath;
    final strPath = root.isEmpty ? 'STR.edf' : '$root\\STR.edf';
    EzEntry entry;
    try {
      onProgress?.call('STR.edf 찾는 중…', null);
      final entries = await _client.listDir(root);
      entry = entries.firstWhere(
        (e) => !e.isDir && e.name.toUpperCase() == 'STR.EDF',
        orElse: () => throw EzShareException('SD 카드 루트에 STR.edf 가 없습니다.'),
      );
    } on EzShareException {
      // 오프라인: 캐시된 파일 사용
      final f = _cache.fileFor(strPath);
      if (!await f.exists()) rethrow;
      entry = EzEntry(name: 'STR.edf', path: strPath, isDir: false,
          sizeKb: ((await f.length()) / 1024).ceil());
    }
    final files = await _fetchAll([entry], onProgress);
    onProgress?.call('분석 중…', null);
    final bytes = files.values.first;
    return Isolate.run(() => AirSenseAnalyzer.parseStr(bytes));
  }

  Future<int> cacheBytes() => _cache.totalBytes();

  Future<void> clearCache() async {
    await _cache.clear();
    _summaries.clear();
    _listing.clear();
  }
}
