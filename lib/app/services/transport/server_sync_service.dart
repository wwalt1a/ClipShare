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

  // 上次拉取时间（从 config 持久化读取）
  DateTime get _lastPullTime {
    final timestamp = appConfig.lastServerPullTime;
    Log.info(tag, "_lastPullTime getter: 从配置读取 timestamp=$timestamp");
    if (timestamp == null || timestamp == 0) {
      Log.info(tag, "_lastPullTime getter: 返回初始时间 (epoch 0)");
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
    final result = DateTime.fromMillisecondsSinceEpoch(timestamp);
    Log.info(tag, "_lastPullTime getter: 返回时间 ${result.toLocal()} ($timestamp)");
    return result;
  }

  // 设置上次拉取时间（持久化到 config）
  Future<void> _setLastPullTime(DateTime time) async {
    Log.info(tag, "_setLastPullTime: 保存拉取时间 ${time.toLocal()} (${time.millisecondsSinceEpoch})");
    await appConfig.setLastServerPullTime(time.millisecondsSinceEpoch);
    Log.info(tag, "_setLastPullTime: 验证保存结果 ${appConfig.lastServerPullTime}");
  }

  /// 重置拉取时间，用于强制拉取所有记录
  void resetPullTime() {
    appConfig.setLastServerPullTime(0);
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

  /// 公开的加密方法（供其他服务使用）
  String encrypt(String plainText) {
    return _encrypt(plainText);
  }

  /// 公开的解密方法（供其他服务使用）
  String decrypt(String base64Text) {
    return _decrypt(base64Text);
  }

  // ── 推送文本 ─────────────────────────────────────────────

  Future<String?> pushText(History history, List<String> tags) async {
    if (!_isEnabled) {
      Log.warn(tag, "pushText: 云端同步未启用 (forwardServer=${appConfig.forwardServer != null}, hasSyncPassword=${appConfig.hasSyncPassword})");
      return null;
    }
    try {
      Log.info(tag, "pushText: 开始推送文本, historyId=${history.id}, tags=$tags, tagCount=${tags.length}");
      final encrypted = _encrypt(history.content);
      final tagsStr = tags.join(',');
      Log.info(tag, "pushText: 标签字符串='$tagsStr'");
      final body = jsonEncode({
        "groupId": _groupId,
        "devId": appConfig.device.guid,
        "content": encrypted,
        "tags": tagsStr, // 标签以逗号分隔
      });
      final uri = Uri.parse("$_apiBase/push/text");
      Log.info(tag, "pushText: 请求 $uri, groupId=$_groupId, devId=${appConfig.device.guid}, body长度=${body.length}");
      final resp = await http
          .post(
            uri,
            headers: {"Content-Type": "application/json"},
            body: body,
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body);
        if (json["code"] == 200 && json["data"] != null) {
          final serverId = json["data"]["id"] as String?;
          Log.info(tag, "pushText 成功: serverItemId=$serverId");
          return serverId;
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
  Future<Map<String, dynamic>?> pushImage(String imagePath, List<String> tags) async {
    if (!_isEnabled) {
      Log.warn(tag, "pushImage: 云端同步未启用 (forwardServer=${appConfig.forwardServer != null}, hasSyncPassword=${appConfig.hasSyncPassword})");
      return null;
    }
    try {
      Log.info(tag, "pushImage: 开始推送图片, imagePath=$imagePath, tags=$tags, tagCount=${tags.length}");
      final file = File(imagePath);
      if (!file.existsSync()) {
        Log.warn(tag, "pushImage: 文件不存在 $imagePath");
        return null;
      }

      final rawBytes = await file.readAsBytes();
      Log.info(tag, "pushImage: 读取图片 ${rawBytes.length} 字节");
      // 将图片原始字节加密后再上传
      final encBytes = _encryptBytes(rawBytes);
      Log.info(tag, "pushImage: 加密后 ${encBytes.length} 字节");

      final tagsStr = tags.join(',');
      Log.info(tag, "pushImage: 标签字符串='$tagsStr'");
      final uri = Uri.parse("$_apiBase/push/image");
      Log.info(tag, "pushImage: 请求 $uri, groupId=$_groupId, devId=${appConfig.device.guid}");
      final request = http.MultipartRequest("POST", uri)
        ..fields["groupId"] = _groupId
        ..fields["devId"] = appConfig.device.guid
        ..fields["tags"] = tagsStr // 标签以逗号分隔
        ..files.add(
          http.MultipartFile.fromBytes("data", encBytes, filename: "image.bin"),
        );

      final streamed = await request.send().timeout(const Duration(seconds: 30));
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body);
        if (json["code"] == 200) {
          Log.info(tag, "pushImage 成功: ${json["data"]}");
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
      Log.info(tag, "pullNewItems: _lastPullTime=${_lastPullTime.toLocal()}, since=$since");
      final uri = Uri.parse("$_apiBase/pull").replace(
        queryParameters: {"groupId": _groupId, "since": since},
      );
      Log.info(tag, "pullNewItems: 请求 $uri, groupId=$_groupId, devId=${appConfig.device.guid}");
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
      // 无论是否有新记录，都更新拉取时间，避免重复拉取
      await _setLastPullTime(DateTime.now());
      if (items.isNotEmpty) {
        Log.info(tag, "pullNewItems: 成功解析 ${items.length} 条记录");
      } else {
        Log.info(tag, "pullNewItems: 无新记录，已更新拉取时间");
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
  final List<String> tags; // 标签列表
  String? decryptedContent;

  ServerClipItem({
    required this.id,
    required this.devId,
    required this.type,
    required this.content,
    required this.fileId,
    required this.createdAt,
    this.expireAt,
    this.tags = const [],
    this.decryptedContent,
  });

  factory ServerClipItem.fromJson(Map<String, dynamic> json) {
    // 解析标签，支持逗号分隔的字符串或数组
    List<String> parseTags(dynamic tagsData) {
      if (tagsData == null) return [];
      if (tagsData is String) {
        if (tagsData.isEmpty) return [];
        return tagsData.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      }
      if (tagsData is List) {
        return tagsData.map((e) => e.toString()).toList();
      }
      return [];
    }

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
      tags: parseTags(json["Tags"]),
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
