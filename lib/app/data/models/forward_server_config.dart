import 'dart:convert';

class ForwardServerConfig {
  String host;
  int port;
  String? key;
  /// HTTP API 端口，默认 80。若通过反代或自定义端口暴露，需与服务端 WEB_PORT 一致
  int apiPort;

  String get server => "$host:$port";

  String get apiBase => "http://$host:$apiPort/api/clip";

  ForwardServerConfig({
    required this.host,
    required this.port,
    this.key,
    this.apiPort = 80,
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
      apiPort: data["apiPort"] ?? 80,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      "host": host,
      "port": port,
      "key": key,
      "apiPort": apiPort,
    };
  }

  @override
  String toString() {
    return jsonEncode(toJson());
  }
}
