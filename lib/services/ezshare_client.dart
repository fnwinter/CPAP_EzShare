import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// EzShare 웹 목록의 항목 (파일 또는 디렉터리).
class EzEntry {
  const EzEntry({
    required this.name,
    required this.path,
    required this.isDir,
    this.sizeKb,
    this.url,
  });

  final String name;

  /// SD 카드 내 경로 (백슬래시 구분, 드라이브 문자 제외). 예: `DATALOG\20260111`
  final String path;
  final bool isDir;
  final int? sizeKb;

  /// 다운로드 URL (파일인 경우).
  final Uri? url;

  @override
  String toString() => '${isDir ? 'DIR ' : ''}$path${sizeKb != null ? ' (${sizeKb}KB)' : ''}';
}

class EzShareException implements Exception {
  EzShareException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// EzShare WiFi SD 카드 (`http://ezshare.card`) 접근 클라이언트.
///
/// EzShare 는 `dir?dir=A:\경로` 로 HTML 디렉터리 목록을,
/// `download?file=경로` 로 파일을 제공한다.
class EzShareClient {
  EzShareClient({required String baseUrl, http.Client? client})
      : baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  static const listTimeout = Duration(seconds: 10);

  Uri dirUri(String path) {
    final p = path.replaceAll('/', r'\');
    // EzShare 가 스스로 만드는 링크와 같은 형식: dir?dir=A:%5CDATALOG%5C20260111
    return Uri.parse('$baseUrl/dir?dir=A:${Uri.encodeComponent('\\$p')}');
  }

  Uri downloadUri(String path) {
    final p = path.replaceAll('/', r'\');
    return Uri.parse('$baseUrl/download?file=${Uri.encodeComponent(p)}');
  }

  /// [path] 디렉터리 목록. 예: `listDir('DATALOG')`
  Future<List<EzEntry>> listDir(String path) async {
    final http.Response res;
    try {
      res = await _client.get(dirUri(path)).timeout(listTimeout);
    } on TimeoutException {
      throw EzShareException('EzShare 응답 시간 초과 ($baseUrl). WiFi 연결을 확인하세요.');
    } on SocketException catch (e) {
      throw EzShareException('EzShare 에 연결할 수 없습니다 ($baseUrl): ${e.message}');
    } on http.ClientException catch (e) {
      throw EzShareException('EzShare 에 연결할 수 없습니다 ($baseUrl): ${e.message}');
    }
    if (res.statusCode != 200) {
      throw EzShareException('목록 요청 실패: HTTP ${res.statusCode}');
    }
    return parseListing(res.body, path, baseUrl);
  }

  /// EzShare HTML 디렉터리 목록 파싱.
  ///
  /// 각 줄은 대략 다음 형태이다:
  /// ```
  /// 2026- 1-11   22:30:15    &lt;DIR&gt;   <a href="dir?dir=A:%5CDATALOG%5C20260111"> 20260111</a>
  /// 2026- 1-11   22:30:15        1234KB  <a href="http://ezshare.card/download?file=DATALOG%5C...%5CX.edf"> X.edf</a>
  /// ```
  static List<EzEntry> parseListing(String html, String parentPath, String baseUrl) {
    final entries = <EzEntry>[];
    final seen = <String>{};
    final linkRe = RegExp(r'''<a\s+[^>]*href\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a>''',
        caseSensitive: false, dotAll: true);
    final sizeRe = RegExp(r'(\d+)\s*KB', caseSensitive: false);
    final parent = parentPath.replaceAll('/', r'\').replaceAll(RegExp(r'^\\+|\\+$'), '');

    for (final line in html.split(RegExp(r'\r?\n|<br\s*/?>', caseSensitive: false))) {
      for (final m in linkRe.allMatches(line)) {
        final href = _decodeEntities(m.group(1)!.trim());
        final name = _decodeEntities(m.group(2)!.replaceAll(RegExp(r'<[^>]*>'), '')).trim();
        if (name.isEmpty || name == '.' || name == '..') continue;
        final lowerHref = href.toLowerCase();
        final isDir = lowerHref.contains('dir?dir=');
        final isFile = lowerHref.contains('download?file=');
        if (!isDir && !isFile) continue;
        final path = parent.isEmpty ? name : '$parent\\$name';
        if (!seen.add(path)) continue;

        // 링크 앞부분(날짜/크기 영역)에서 크기 추출
        final before = line.substring(0, m.start);
        final sizeMatch = sizeRe.allMatches(before).lastOrNull;
        entries.add(EzEntry(
          name: name,
          path: path,
          isDir: isDir,
          sizeKb: isFile && sizeMatch != null ? int.tryParse(sizeMatch.group(1)!) : null,
          url: isFile ? _resolve(baseUrl, href) : null,
        ));
      }
    }
    return entries;
  }

  static Uri _resolve(String baseUrl, String href) {
    // EzShare 는 경로에 백슬래시를 그대로 쓰는 경우가 있어 먼저 인코딩한다.
    final cleaned = href.replaceAll(r'\', '%5C').replaceAll(' ', '%20');
    final base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/');
    return base.resolve(cleaned);
  }

  static String _decodeEntities(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');

  /// 파일 다운로드. [onProgress] 는 (받은 바이트, 전체 바이트 또는 null).
  Future<Uint8List> download(Uri url, {void Function(int, int?)? onProgress}) async {
    final req = http.Request('GET', url);
    final http.StreamedResponse res;
    try {
      res = await _client.send(req).timeout(listTimeout);
    } on TimeoutException {
      throw EzShareException('다운로드 응답 시간 초과: $url');
    } on SocketException catch (e) {
      throw EzShareException('다운로드 실패: ${e.message}');
    } on http.ClientException catch (e) {
      throw EzShareException('다운로드 실패: ${e.message}');
    }
    if (res.statusCode != 200) {
      throw EzShareException('다운로드 실패: HTTP ${res.statusCode} ($url)');
    }
    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
      builder.add(chunk);
      received += chunk.length;
      onProgress?.call(received, res.contentLength);
    }
    return builder.takeBytes();
  }

  void close() => _client.close();
}

/// 다운로드한 파일을 앱 문서 폴더에 캐시한다.
/// 같은 경로의 파일 크기가 목록의 KB 값과 같으면 다시 받지 않는다.
class FileCache {
  FileCache._(this.root);

  final Directory root;

  static Future<FileCache> open() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}ezshare_cache');
    await dir.create(recursive: true);
    return FileCache._(dir);
  }

  File fileFor(String sdPath) =>
      File('${root.path}/${sdPath.replaceAll(r'\', '/')}');

  Future<Uint8List?> get(EzEntry entry) async {
    final f = fileFor(entry.path);
    if (!await f.exists()) return null;
    final len = await f.length();
    if (len == 0) return null;
    if (entry.sizeKb != null) {
      // EzShare 는 KB 단위(반올림/올림 방식이 펌웨어마다 다름)로 표시
      final kb = len / 1024;
      if ((kb - entry.sizeKb!).abs() > 1.01) return null;
    }
    return f.readAsBytes();
  }

  Future<void> put(String sdPath, Uint8List bytes) async {
    final f = fileFor(sdPath);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
  }

  /// 오프라인일 때 사용: 캐시에 있는 [dirPath] 하위 항목.
  Future<List<EzEntry>> list(String dirPath) async {
    final dir = Directory('${root.path}/${dirPath.replaceAll(r'\', '/')}');
    if (!await dir.exists()) return [];
    final parent = dirPath.replaceAll('/', r'\');
    final out = <EzEntry>[];
    await for (final e in dir.list()) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final isDir = e is Directory;
      out.add(EzEntry(
        name: name,
        path: '$parent\\$name',
        isDir: isDir,
        sizeKb: isDir ? null : ((await (e as File).length()) / 1024).ceil(),
      ));
    }
    return out;
  }

  Future<int> totalBytes() async {
    var total = 0;
    await for (final e in root.list(recursive: true)) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  Future<void> clear() async {
    if (await root.exists()) await root.delete(recursive: true);
    await root.create(recursive: true);
  }
}
