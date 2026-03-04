import 'dart:convert';

class ForwardServerConfig {
  String host;
  int port;
  String? key;
  /// 云端同步 API 地址（可选）。
  /// 填写示例：https://api.yourdomain.com:8888
  /// 留空则自动使用 http://<host>/api/clip（服务端默认 80 端口）
  String apiBaseUrl;

  String get server => "$host:$port";

  String get apiBase {
    final base = apiBaseUrl.trim().trimRight('/');
    if (base.isNotEmpty) return "$base/api/clip";
    return "http://$host/api/clip";
  }

  ForwardServerConfig({
    required this.host,
    required this.port,
    this.key,
    this.apiBaseUrl = "",
  });

  factory ForwardServerConfig.fromJson(Map<String, dynamic> data) {
    String? key = data.containsKey("key")
        ? data["key"] == ""
            ? null
            : data["key"]
        : null;
    return ForwardServerConfig(
      host: data["host"],
      port: data["port"],
      key: key,
      apiBaseUrl: data["apiBaseUrl"] ?? "",
    );
  }

  Map<String, dynamic> toJson() {
    return {
      "host": host,
      "port": port,
      "key": key,
      "apiBaseUrl": apiBaseUrl,
    };
  }

  @override
  String toString() {
    return jsonEncode(toJson());
  }
}
