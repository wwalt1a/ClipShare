import 'dart:convert';

class ForwardServerConfig {
  String host;
  int port;
  String? key;

  String get server => "$host:$port";

  /// HTTP API 默认走 80 端口，不需要用户额外配置
  String get apiBase => "http://$host/api/clip";

  ForwardServerConfig({
    required this.host,
    required this.port,
    this.key,
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
    );
  }

  Map<String, dynamic> toJson() {
    return {
      "host": host,
      "port": port,
      "key": key,
    };
  }

  @override
  String toString() {
    return jsonEncode(toJson());
  }
}
