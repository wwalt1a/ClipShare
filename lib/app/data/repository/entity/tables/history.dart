import 'dart:convert';

import 'package:floor/floor.dart';

@Entity(
  indices: [
    Index(value: ['devId'], unique: false),
    Index(value: ['devId', "source"], unique: false),
  ]
)
class History implements Comparable {
  ///本地id
  @PrimaryKey(autoGenerate: true)
  int id;

  ///用户id（uuid）
  int uid;

  ///时间
  String time;

  ///剪贴板内容
  String content;

  ///内容类型
  String type;

  ///设备id
  String devId;

  ///是否置顶
  bool top = false;

  ///是否同步
  bool sync = false;

  ///内容大小、长度
  late int size;

  ///更新时间
  String? updateTime;

  ///来源
  String? source;

  ///服务器图片到期时间（ISO8601字符串），仅图片类型在中转模式下有值
  String? serverExpireAt;

  ///服务器端条目 ID，用于删除时同步到服务器
  String? serverItemId;

  History({
    required this.id,
    required this.uid,
    required this.time,
    required this.content,
    required this.type,
    required this.devId,
    required this.size,
    this.top = false,
    this.sync = false,
    this.updateTime,
    this.source,
    this.serverExpireAt,
    this.serverItemId,
  });

  @override
  int compareTo(other) {
    // 首先按照 top 属性排序
    if (top && !other.top) {
      return 1;
    } else if (!top && other.top) {
      return -1;
    } else {
      // 如果 top 属性相同，则按照 id 降序
      return id.compareTo(other.id);
    }
  }

  History.empty({
    this.id = 0,
    this.uid = 0,
    this.time = "",
    this.content = "",
    this.type = "",
    this.devId = "",
    this.top = false,
    this.sync = false,
    this.size = 0,
    this.updateTime,
    this.source,
    this.serverExpireAt,
    this.serverItemId,
  });

  static History fromJson(Map<String, dynamic> map) {
    var id = map["id"];
    var uid = map["uid"];
    var time = map["time"];
    var content = map["content"];
    var type = map["type"];
    var devId = map["devId"];
    var top = map["top"];
    var sync = map["sync"];
    var size = map["size"];
    return History(
      id: id,
      uid: uid,
      time: time,
      content: content,
      type: type,
      devId: devId,
      size: size,
      top: top,
      sync: sync,
      updateTime: map.containsKey("updateTime") ? map["updateTime"] : null,
      source: map.containsKey("source") ? map["source"] : null,
      serverExpireAt: map.containsKey("serverExpireAt") ? map["serverExpireAt"] : null,
      serverItemId: map.containsKey("serverItemId") ? map["serverItemId"] : null,
    );
  }

  static List<History> fromJsonList(List<dynamic> jsonList) {
    List<History> res = List.empty(growable: true);
    for (var map in jsonList) {
      res.add(History.fromJson(map));
    }
    return res;
  }

  Map<String, dynamic> toJson() {
    return {
      "id": id,
      "uid": uid,
      "time": time,
      "content": content,
      "type": type,
      "devId": devId,
      "top": top,
      "sync": sync,
      "size": size,
      "updateTime": updateTime,
      "source": source,
    };
  }

  @override
  String toString() {
    return jsonEncode(toJson());
  }

  History copy() {
    return fromJson(toJson());
  }

  @override
  int get hashCode => id.hashCode;

  @override
  bool operator ==(Object other) {
    if (other is History) {
      return id == other.id;
    }
    return false;
  }
}
