import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clipshare/app/services/config_service.dart';
import 'package:clipshare/app/utils/log.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

/// 服务器剪贴板同步服务
/// 仅在配置了中转服务器且设置了同步密码时生效
class ServerSyncService extends GetxService {
  static const tag = "ServerSyncService";

  final appConfig = Get.find<ConfigService>();

  bool get _isEnabled =>
      appConfig.forwardServer != null && appConfig.hasSyncPassword;

  String get _groupId => appConfig.syncGroupId;

  // ── 加密 / 解密 ──────────────────────────────────────────

  enc.Encrypter get _encrypter {
    final keyBytes = Uint8List.fromList(appConfig.syncAesKey);
    final key = enc.Key(keyBytes);
    return enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
  }

  enc.IV get _iv {
    final keyBytes = appConfig.syncAesKey;
    return enc.IV(Uint8List.fromList(keyBytes.sublist(0, 16)));
  }

  String _encrypt(String plainText) {
    return _encrypter.encrypt(plainText, iv: _iv).base64;
  }

  String _decrypt(String base64Text) {
    return _encrypter.decrypt64(base64Text, iv: _iv);
  }

  /// 公开的加密方法（供其他服务使用）
  String encrypt(String plainText) {
    return _encrypt(plainText);
  }

  /// 公开的解密方法（供其他服务使用）
  String decrypt(String base64Text) {
    return _decrypt(base64Text);
  }

  // ── 字节加密 / 解密（用于图片） ───────────────────────────

  Uint8List _encryptBytes(Uint8List bytes) {
    final encrypted = _encrypter.encryptBytes(bytes, iv: _iv);
    return encrypted.bytes;
  }

  Uint8List _decryptBytes(Uint8List bytes) {
    final decrypted = _encrypter.decryptBytes(enc.Encrypted(bytes), iv: _iv);
    return Uint8List.fromList(decrypted);
  }

  // ── 新同步路径图片上传/下载（/api/sync/image）─────────────

  String get _syncApiBase {
    final base = appConfig.forwardServer!.apiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isNotEmpty) return base;
    return 'http://${appConfig.forwardServer!.host}';
  }

  /// 上传图片到服务器，返回服务器生成的 fileId；失败返回 null
  Future<String?> uploadImageForSync(String imagePath) async {
    if (!_isEnabled) return null;
    try {
      final file = File(imagePath);
      if (!file.existsSync()) {
        Log.warn(tag, 'uploadImageForSync: 文件不存在 $imagePath');
        return null;
      }
      final rawBytes = await file.readAsBytes();
      final encBytes = _encryptBytes(rawBytes);
      final uri = Uri.parse('$_syncApiBase/api/sync/image');
      final request = http.MultipartRequest('POST', uri)
        ..fields['groupId'] = _groupId
        ..files.add(http.MultipartFile.fromBytes('data', encBytes, filename: 'image.bin'));
      final streamed = await request.send().timeout(const Duration(seconds: 60));
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body);
        if (json['code'] == 200) {
          final fileId = json['data']['fileId'] as String?;
          Log.info(tag, 'uploadImageForSync: 上传成功 fileId=$fileId');
          return fileId;
        }
      }
      Log.warn(tag, 'uploadImageForSync failed: ${resp.statusCode} ${resp.body}');
    } catch (e, s) {
      Log.error(tag, 'uploadImageForSync error: $e', s);
    }
    return null;
  }

  /// 从服务器下载图片并解密，返回原始字节；失败返回 null
  Future<Uint8List?> downloadSyncImage(String fileId) async {
    if (!_isEnabled) return null;
    try {
      final uri = Uri.parse('$_syncApiBase/api/sync/image').replace(
        queryParameters: {'groupId': _groupId, 'fileId': fileId},
      );
      Log.info(tag, 'downloadSyncImage: 请求 $uri');
      final resp = await http.get(uri).timeout(const Duration(seconds: 60));
      if (resp.statusCode == 200) {
        final decrypted = _decryptBytes(resp.bodyBytes);
        Log.info(tag, 'downloadSyncImage: 下载并解密成功 ${decrypted.length} 字节');
        return decrypted;
      }
      Log.warn(tag, 'downloadSyncImage failed: ${resp.statusCode}');
    } catch (e, s) {
      Log.error(tag, 'downloadSyncImage error: $e', s);
    }
    return null;
  }
}

