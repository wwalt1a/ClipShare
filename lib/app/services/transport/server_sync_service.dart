import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clipshare/app/data/repository/entity/tables/history.dart';
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

  String get _apiBase => appConfig.forwardServer!.apiBase;
  String get _groupId => appConfig.syncGroupId;

  // 上次拉取时间（持久化到 config 可做更复杂处理，此处用内存值）
  DateTime _lastPullTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// 重置拉取时间，用于强制拉取所有记录
  void resetPullTime() {
    _lastPullTime = DateTime.fromMillisecondsSinceEpoch(0);
    Log.info(tag, "resetPullTime: 已重置拉取时间");
  }

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

  // ── 推送文本 ─────────────────────────────────────────────

  Future<String?> pushText(History history) async {
    if (!_isEnabled) return null;
    try {
      final encrypted = _encrypt(history.content);
      final body = jsonEncode({
        "groupId": _groupId,
        "devId": appConfig.device.guid,
        "content": encrypted,
      });
      final resp = await http
          .post(
            Uri.parse("$_apiBase/push/text"),
            headers: {"Content-Type": "application/json"},
            body: body,
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body);
        if (json["code"] == 200 && json["data"] != null) {
          return json["data"]["id"] as String?;
        }
      }
      Log.warn(tag, "pushText failed: ${resp.statusCode} ${resp.body}");
    } catch (e, s) {
      Log.error(tag, "pushText error: $e", s);
    }
    return null;
  }

  // ── 推送图片 ─────────────────────────────────────────────

  /// [imagePath] 本地图片文件路径，[imageExpireDays] 服务器保留天数（由服务器决定为30天）
  Future<Map<String, dynamic>?> pushImage(String imagePath) async {
    if (!_isEnabled) return null;
    try {
      final file = File(imagePath);
      if (!file.existsSync()) return null;

      final rawBytes = await file.readAsBytes();
      // 将图片原始字节加密后再上传
      final encBytes = _encryptBytes(rawBytes);

      final request = http.MultipartRequest(
        "POST",
        Uri.parse("$_apiBase/push/image"),
      )
        ..fields["groupId"] = _groupId
        ..fields["devId"] = appConfig.device.guid
        ..files.add(
          http.MultipartFile.fromBytes("data", encBytes, filename: "image.bin"),
        );

      final streamed = await request.send().timeout(const Duration(seconds: 30));
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body);
        if (json["code"] == 200) {
          return json["data"] as Map<String, dynamic>;
        }
      }
      Log.warn(tag, "pushImage failed: ${resp.statusCode} ${resp.body}");
    } catch (e, s) {
      Log.error(tag, "pushImage error: $e", s);
    }
    return null;
  }

  // ── 拉取新条目 ────────────────────────────────────────────

  Future<List<ServerClipItem>> pullNewItems() async {
    if (!_isEnabled) {
      Log.warn(tag, "pullNewItems: 云端同步未启用");
      return [];
    }
    try {
      final since = _lastPullTime.toUtc().toIso8601String();
      final uri = Uri.parse("$_apiBase/pull").replace(
        queryParameters: {"groupId": _groupId, "since": since},
      );
      Log.info(tag, "pullNewItems: 请求 $uri");
      final resp = await http
          .get(uri)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        Log.warn(tag, "pullNewItems failed: ${resp.statusCode} ${resp.body}");
        return [];
      }
      final json = jsonDecode(resp.body);
      if (json["code"] != 200) {
        Log.warn(tag, "pullNewItems: 服务器返回错误 code=${json["code"]}");
        return [];
      }

      final List<dynamic> raw = json["data"] ?? [];
      Log.info(tag, "pullNewItems: 收到 ${raw.length} 条原始记录");
      final items = <ServerClipItem>[];
      for (final item in raw) {
        try {
          final ci = ServerClipItem.fromJson(item);
          // 跳过本机发出的条目，避免回环
          if (ci.devId == appConfig.device.guid) {
            Log.info(tag, "跳过本机条目: ${ci.id}");
            continue;
          }
          // 解密内容
          if (ci.type == "text" && ci.content.isNotEmpty) {
            Log.info(tag, "解密文本条目: ${ci.id}");
            ci.decryptedContent = _decrypt(ci.content);
          }
          items.add(ci);
        } catch (e) {
          Log.warn(tag, "parse item error: $e");
        }
      }
      if (items.isNotEmpty) {
        _lastPullTime = DateTime.now();
        Log.info(tag, "pullNewItems: 成功解析 ${items.length} 条记录");
      }
      return items;
    } catch (e, s) {
      Log.error(tag, "pullNewItems error: $e", s);
      return [];
    }
  }

  // ── 下载加密图片并解密 ─────────────────────────────────────

  Future<Uint8List?> downloadImage(String fileId) async {
    if (!_isEnabled) {
      Log.warn(tag, "downloadImage: 云端同步未启用");
      return null;
    }
    try {
      final uri = Uri.parse("$_apiBase/image").replace(
        queryParameters: {"groupId": _groupId, "fileId": fileId},
      );
      Log.info(tag, "downloadImage: 请求 $uri");
      final resp = await http
          .get(uri)
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) {
        Log.info(tag, "downloadImage: 收到 ${resp.bodyBytes.length} 字节加密数据");
        final decrypted = _decryptBytes(resp.bodyBytes);
        Log.info(tag, "downloadImage: 解密后 ${decrypted.length} 字节");
        return decrypted;
      }
      Log.warn(tag, "downloadImage failed: ${resp.statusCode} ${resp.body}");
    } catch (e, s) {
      Log.error(tag, "downloadImage error: $e", s);
    }
    return null;
  }

  // ── 删除条目 ──────────────────────────────────────────────

  Future<void> deleteItems(List<String> serverIds) async {
    if (!_isEnabled || serverIds.isEmpty) return;
    try {
      final body = jsonEncode({"groupId": _groupId, "ids": serverIds});
      await http
          .delete(
            Uri.parse("$_apiBase/delete"),
            headers: {"Content-Type": "application/json"},
            body: body,
          )
          .timeout(const Duration(seconds: 10));
    } catch (e, s) {
      Log.error(tag, "deleteItems error: $e", s);
    }
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
}

/// 服务器返回的剪贴板条目
class ServerClipItem {
  final String id;
  final String devId;
  final String type;
  final String content;
  final String fileId;
  final DateTime createdAt;
  final DateTime? expireAt;
  String? decryptedContent;

  ServerClipItem({
    required this.id,
    required this.devId,
    required this.type,
    required this.content,
    required this.fileId,
    required this.createdAt,
    this.expireAt,
    this.decryptedContent,
  });

  factory ServerClipItem.fromJson(Map<String, dynamic> json) {
    return ServerClipItem(
      id: json["Id"] ?? "",
      devId: json["DevId"] ?? "",
      type: json["Type"] ?? "text",
      content: json["Content"] ?? "",
      fileId: json["FileId"] ?? "",
      createdAt: DateTime.tryParse(json["CreatedAt"] ?? "") ?? DateTime.now(),
      expireAt: json["ExpireAt"] != null
          ? DateTime.tryParse(json["ExpireAt"])
          : null,
    );
  }

  bool get isImage => type == "image";

  /// 距服务器删除还有多少天（仅图片有效）
  int? get serverDaysLeft {
    if (expireAt == null) return null;
    final diff = expireAt!.difference(DateTime.now()).inDays;
    return diff < 0 ? 0 : diff;
  }
}
