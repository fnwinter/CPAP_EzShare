import 'dart:io';

import 'package:flutter/services.dart';

/// EzShare WiFi 는 인터넷이 없어서 Android 가 모바일 데이터로 트래픽을 보낼 수 있다.
/// 앱 프로세스를 WiFi 네트워크에 바인딩해 EzShare(ezshare.card) 로 요청이 가도록 한다.
class NetworkBinder {
  static const _channel = MethodChannel('cpap_ezshare/network');

  static Future<bool> bindToWifi() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('bindWifi') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> unbind() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('unbind');
    } on Object {
      // 무시
    }
  }
}
