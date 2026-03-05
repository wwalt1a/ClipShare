import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clipshare/app/data/enums/forward_way.dart';
import 'package:clipshare/app/data/enums/connection_mode.dart';
import 'package:clipshare/app/data/enums/forward_msg_type.dart';
import 'package:clipshare/app/data/enums/module.dart';
import 'package:clipshare/app/data/enums/msg_type.dart';
import 'package:clipshare/app/data/enums/translation_key.dart';
import 'package:clipshare/app/data/enums/transport_protocol.dart';
import 'package:clipshare/app/data/models/dev_info.dart';
import 'package:clipshare/app/data/models/dev_socket.dart';
import 'package:clipshare/app/data/models/message_data.dart';
import 'package:clipshare/app/data/models/version.dart';
import 'package:clipshare/app/data/repository/entity/tables/app_info.dart';
import 'package:clipshare/app/data/repository/entity/tables/history.dart';
import 'package:clipshare/app/modules/history_module/history_controller.dart';
import 'package:clipshare/app/handlers/dev_pairing_handler.dart';
import 'package:clipshare/app/handlers/socket/forward_socket_client.dart';
import 'package:clipshare/app/handlers/socket/secure_socket_client.dart';
import 'package:clipshare/app/handlers/socket/secure_socket_server.dart';
import 'package:clipshare/app/handlers/sync/abstract_data_sender.dart';
import 'package:clipshare/app/handlers/sync/file_sync_handler.dart';
import 'package:clipshare/app/handlers/sync/missing_data_sync_handler.dart';
import 'package:clipshare/app/services/history_sync_progress_service.dart';
import 'package:clipshare/app/utils/notify_util.dart';
import 'package:clipshare/app/utils/task_runner.dart';
import 'package:clipshare/app/listeners/dev_alive_listener.dart';
import 'package:clipshare/app/listeners/discover_listener.dart';
import 'package:clipshare/app/listeners/forward_status_listener.dart';
import 'package:clipshare/app/listeners/screen_opened_listener.dart';
import 'package:clipshare/app/services/clipboard_source_service.dart';
import 'package:clipshare/app/services/config_service.dart';
import 'package:clipshare/app/services/db_service.dart';
import 'package:clipshare/app/services/device_service.dart';
import 'package:clipshare/app/services/transport/connection_registry_service.dart';
import 'package:clipshare/app/utils/constants.dart';
import 'package:clipshare/app/utils/crypto.dart';
import 'package:clipshare/app/utils/extensions/device_extension.dart';
import 'package:clipshare/app/utils/extensions/number_extension.dart';
import 'package:clipshare/app/utils/extensions/platform_extension.dart';
import 'package:clipshare/app/utils/extensions/string_extension.dart';
import 'package:clipshare/app/utils/extensions/time_extension.dart';
import 'package:clipshare/app/utils/global.dart';
import 'package:clipshare/app/utils/log.dart';
import 'package:clipshare/app/services/transport/server_sync_service.dart';
import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class SocketService extends GetxService with ScreenOpenedObserver, DataSender {
  final appConfig = Get.find<ConfigService>();
  final connRegService = Get.find<ConnectionRegistryService>();
  final dbService = Get.find<DbService>();
  static const String tag = "SocketService";
  Timer? _heartbeatTimer;
  Timer? _forwardClientHeartbeatTimer;
  DateTime? _lastForwardServerPingTime;

  // devId => DevSocket
  final Map<String, DevSocket> _devSockets = {};
  late SecureSocketServer _server;
  ForwardSocketClient? _forwardClient;

  bool get forwardServerConnected => _forwardClient != null;

  //临时记录连接配对自定义ip设备记录
  final Set<String> ipSetTemp = {};
  final Set<String> _connectingAddress = {};
  final Map<int, FileSyncHandler> _forwardFiles = {};
  Map<String, Future> broadcastProcessChain = {};
  bool _pairing = false;
  int? _pairingNotifyId;
  static bool _isInit = false;
  bool screenOpened = true;
  Future? autoCloseConnTimer;
  bool _autoConnForwardServer = true;

  String? get forwardServerHost {
    if (!appConfig.enableForward || appConfig.forwardWay != ForwardWay.server) return null;
    return appConfig.forwardServer!.host;
  }

  int? get forwardServerPort {
    if (!appConfig.enableForward || appConfig.forwardWay != ForwardWay.server) return null;
    return appConfig.forwardServer!.port.toInt();
  }

  List<RawDatagramSocket> multicasts = [];

  //正在通知的设备，用于防抖，devId => (notifyId,isDisconnected)
  //时常为 2s，如果 2s 内，该 map 有 key 且 id 仍然为发起通知时创建的 id 则允许通知，否则取消通知
  final _devNotifyIdMap = <String, bool>{};
  Timer? _devNotifyTimer;

  //通知防抖时长
  static final _debounceTime = 1500.ms;

  //region dev registry
  final DeviceConnectionRegistry _registry;

  List<DevAliveListener> get _devAliveListeners => _registry.devAliveListeners;

  List<DiscoverListener> get _discoverListeners => _registry.discoverListeners;

  List<ForwardStatusListener> get _forwardStatusListener => _registry.forwardStatusListener;

  //endregion

  SocketService(this._registry);

  Future<SocketService> init() async {
    if (_isInit) throw Exception("已初始化");
    // 初始化，创建socket监听
    _runSocketServer();
    //连接中转服务器
    await connectForwardServer();
    startDiscoveryDevices();
    startHeartbeatTest();
    ScreenOpenedListener.inst.register(this);
    _isInit = true;
    return this;
  }

  @override
  void onClose() {
    super.onClose();
    ScreenOpenedListener.inst.remove(this);
  }

  ///判断设备是否在线
  bool isOnline(String devId, bool requiredPaired) {
    var online = _devSockets.containsKey(devId);
    var isPaired = false;
    if (online) {
      isPaired = _devSockets[devId]!.isPaired;
    }
    if (!requiredPaired) return online;
    return online && isPaired;
  }

  ///监听广播
  Future<void> _startListenMulticast() async {
    //关闭原本的监听
    for (var multicast in multicasts) {
      multicast.close();
    }
    //重新监听
    multicasts = await _getSockets(Constants.multicastGroup, appConfig.port);
    for (var multicast in multicasts) {
      multicast.listen((event) {
        final datagram = multicast.receive();
        if (datagram == null) {
          return;
        }
        var data = CryptoUtil.base64DecodeStr(utf8.decode(datagram.data));
        Map<String, dynamic> json = jsonDecode(data);
        var msg = MessageData.fromJson(json);
        var dev = msg.send;
        //是本机跳过
        if (dev.guid == appConfig.devInfo.guid) {
          return;
        }
        switch (msg.key) {
          case MsgType.broadcastInfo:
            var devId = dev.guid;
            String ip = datagram.address.address;
            var port = msg.data["port"];
            String address = "$ip:$port";
            Future.delayed(5.s, () {
              broadcastProcessChain.remove(devId);
              _connectingAddress.remove(address);
            });
            var inChain = broadcastProcessChain.containsKey(devId);
            var connecting = _connectingAddress.contains(address);
            if (!inChain && !connecting) {
              _connectingAddress.add(address);
              broadcastProcessChain[devId] = _onBroadcastInfoReceived(msg, datagram);
            }
            break;
          default:
        }
      });
    }
  }

  ///接收广播设备信息
  Future<void> _onBroadcastInfoReceived(
    MessageData msg,
    Datagram datagram,
  ) async {
    DevInfo dev = msg.send;
    //设备已连接，跳过
    if (_devSockets.keys.contains(dev.guid)) {
      return;
    }

    var device = await dbService.deviceDao.getById(dev.guid, appConfig.userId);
    var isPaired = device != null && device.isPaired;
    //未配对且不允许被发现，结束
    if (!appConfig.allowDiscover && !isPaired) {
      return;
    }
    //建立连接
    String ip = datagram.address.address;
    var port = msg.data["port"];
    Log.debug(tag, "${dev.name} ip: $ip，port $port");
    ipSetTemp.add("$ip:$port");
    return _connectFromBroadcast(dev, ip, msg.data["port"]);
  }

  ///从广播，建立 socket 链接
  Future _connectFromBroadcast(DevInfo dev, String ip, int port) {
    //已在broadcastProcessChain中添加互斥
    return SecureSocketClient.connect(
      ip: ip,
      port: port,
      prime1: appConfig.prime1,
      prime2: appConfig.prime2,
      dhAesKey: appConfig.dhAesKey,
      onConnected: (client) async {
        Log.debug(tag, '已连接到服务器');
        //本地是否已配对
        var localDevice = await dbService.deviceDao.getById(dev.guid, appConfig.userId);
        var localIsPaired = localDevice?.isPaired ?? false;
        var pairedStatusData = MessageData(
          userId: appConfig.userId,
          send: appConfig.devInfo,
          key: MsgType.pairedStatus,
          data: {
            "isPaired": localIsPaired,
            "minVersionName": appConfig.minVersion.name,
            "minVersionCode": appConfig.minVersion.code,
            "versionName": appConfig.version.name,
            "versionCode": appConfig.version.code,
          },
        );
        //告诉服务器配对状态
        client.send(pairedStatusData.toJson());
      },
      onMessage: (client, json) {
        var msg = MessageData.fromJson(json);
        _onSocketReceived(client, msg);
      },
      onDone: (SecureSocketClient client) {
        Log.debug(tag, "从广播连接，服务端连接关闭");
        _onDevDisconnected(dev.guid);
      },
      onError: (error, client) {
        Log.debug(tag, '从广播连接，发生错误: $error');
        _onDevDisconnected(dev.guid);
      },
    );
  }

  ///运行服务端 socket 监听消息同步
  void _runSocketServer() async {
    _server = await SecureSocketServer.bind(
      ip: '0.0.0.0',
      port: appConfig.port,
      onConnected: (ip, port) {
        Log.debug(
          tag,
          "新连接来自 ip:$ip port:$port",
        );
      },
      onMessage: (client, json) {
        var msg = MessageData.fromJson(json);
        _onSocketReceived(client, msg);
      },
      onError: (err) {
        Log.error(tag, "服务端内客户端连接，出现错误：$err");
      },
      onClientError: (e, ip, port, client) {
        //此处端口不是客户端的服务端口，是客户端的socket进程端口
        Log.error(tag, "client 出现错误 $ip $port $e");
        final keys = _devSockets.keys;
        for (var id in keys) {
          var skt = _devSockets[id]!;
          if (skt.socket.ip == ip) {
            _onDevDisconnected(id);
            break;
          }
        }
      },
      onClientDone: (ip, port, client) {
        //此处端口不是客户端的服务端口，是客户端的socket进程端口
        Log.error(tag, "client done $ip $port");
        final keys = _devSockets.keys;
        for (var id in keys) {
          var skt = _devSockets[id]!;
          Log.error(
            tag,
            "client done skt ${skt.socket.ip} ${skt.socket.port}",
          );
          if (skt.socket.ip == ip) {
            _onDevDisconnected(id);
            break;
          }
        }
      },
      onDone: () {
        Log.debug(tag, "服务端连接关闭");
        final keys = _devSockets.keys;
        for (var id in keys) {
          _onDevDisconnected(id);
        }
      },
      cancelOnError: false,
    );
    Log.debug(
      tag,
      '服务端已启动，监听所有网络接口 ${_server.ip} ${_server.port}',
    );
  }

  ///连接中转服务器
  Future<void> connectForwardServer([bool startDiscovery = false]) async {
    if (_forwardClient != null) {
      disConnectForwardServer();
    }
    if (appConfig.forwardWay != ForwardWay.server) {
      Log.debug(tag, "connectForwardServer forward way is ${appConfig.forwardWay.name}");
      return;
    }
    //屏幕关闭且 设置了自动断连 且 定时器已到期 则不连接
    if (!screenOpened && appConfig.autoCloseConnAfterScreenOff && autoCloseConnTimer == null) {
      return;
    }
    if (appConfig.currentNetWorkType.value == ConnectivityResult.none) {
      if (_autoConnForwardServer) {
        Log.debug(tag, "中转连接取消重连(无网络)");
      }
      _autoConnForwardServer = false;
      return;
    }
    if (!appConfig.enableForward) return;
    if (forwardServerHost == null || forwardServerPort == null) return;
    if (_forwardClient != null) return;
    _updateForwardConnectingStatus();
    try {
      _forwardClient = await ForwardSocketClient.connect(
        ip: forwardServerHost!,
        port: forwardServerPort!,
        onMessage: (self, data) {
          Log.debug(tag, "forwardClient onMessage $data");
          _onForwardServerReceived(jsonDecode(data));
        },
        onDone: (self) {
          _forwardClient = null;
          _updateForwardDisConnectedStatus();
          _stopJudgeForwardClientAlive();
          Log.debug(tag, "forwardClient done");
          if (_autoConnForwardServer) {
            Log.debug(tag, "尝试重连中转");
            Future.delayed(
              1000.ms,
              () => connectForwardServer(true),
            );
          }
        },
        onError: (ex, self) {
          Log.debug(tag, "forwardClient onError $ex");
        },
        onConnected: (self) {
          _autoConnForwardServer = true;
          Log.debug(tag, "forwardClient onConnected");
          _updateForwardConnectedStatus();
          _startJudgeForwardClientAlivePeriod();
          //中转服务器连接成功后发送本机信息
          final connData = ForwardSocketClient.baseMsg
            ..addAll({
              "connType": ForwardConnType.base.name,
            });
          final key = appConfig.forwardServer?.key;
          if (key != null) {
            connData["key"] = key;
          }
          self.send(connData);
          // 连接成功后拉取服务器新内容
          _pullFromServer();
          if (startDiscovery) {
            Future.delayed(1.s, () async {
              final list = await _forwardDiscovering();
              //发现中转设备
              TaskRunner<void>(
                initialTasks: list,
                onFinish: () async {},
                concurrency: 50,
              );
            });
          }
        },
      );
    } catch (e) {
      _updateForwardDisConnectedStatus();
      Log.debug(tag, "connect forward server failed $e");
      if (_autoConnForwardServer) {
        Log.debug(tag, "尝试重连中转");
        Future.delayed(
          1000.ms,
          () => connectForwardServer(true),
        );
      }
    }
  }

  ///断开中转服务器
  Future<void> disConnectForwardServer() async {
    if (_forwardClient == null) {
      return;
    }
    Log.debug(tag, "disConnectForwardServer");
    _autoConnForwardServer = false;
    await _forwardClient?.close();
    _forwardClient = null;
    _updateForwardDisConnectedStatus();
    _disconnectForwardSockets();
  }

  //region Update server status
  void _updateForwardConnectingStatus() {
    for (var listener in _forwardStatusListener) {
      listener.onForwardServerConnecting();
    }
  }

  void _updateForwardConnectedStatus() {
    for (var listener in _forwardStatusListener) {
      listener.onForwardServerConnected();
    }
  }

  void _updateForwardDisConnectedStatus() {
    for (var listener in _forwardStatusListener) {
      listener.onForwardServerDisconnected();
    }
  }

  //endregion

  ///断开所有通过中转服务器的连接
  void _disconnectForwardSockets() {
    final keys = _devSockets.keys.toList();
    for (var devId in keys) {
      var skt = _devSockets[devId];
      if (skt == null || !skt.socket.isForwardMode) continue;
      _onDevDisconnected(devId, autoReconnect: true);
      skt.socket.destroy();
    }
  }

  Future<void> _onForwardServerReceived(Map<String, dynamic> data) async {
    final type = ForwardMsgType.getValue(data["type"]);
    switch (type) {
      case ForwardMsgType.ping:
        _lastForwardServerPingTime = DateTime.now();
        break;
      case ForwardMsgType.fileSyncNotAllowed:
        Global.showTipsDialog(
          context: Get.context!,
          text: TranslationKey.forwardServerNotAllowedSendFile.tr,
          title: TranslationKey.sendFailed.tr,
        );
        break;
      case ForwardMsgType.check:
        void disableForwardServerAfterDelay() {
          Future.delayed(500.ms, () {
            if (_forwardClient != null) return;
            appConfig.setEnableForward(false);
          });
        }
        if (!data.containsKey("result")) {
          Global.showTipsDialog(
            context: Get.context!,
            text: "${TranslationKey.forwardServerUnknownResult.tr}:\n ${data.toString()}",
            title: TranslationKey.forwardServerConnectFailed.tr,
          );
          disableForwardServerAfterDelay();
          return;
        }
        final result = data["result"];
        if (result == "success") {
          return;
        }
        disableForwardServerAfterDelay();
        Global.showTipsDialog(
          context: Get.context!,
          text: result,
          title: TranslationKey.forwardServerConnectFailed.tr,
        );
        break;
      case ForwardMsgType.requestConnect:
        final targetId = data["sender"];
        manualConnectByForward(targetId);
        break;
      case ForwardMsgType.sendFile:
        final targetId = data["sender"];
        final size = data["size"].toString().toInt();
        final fileName = data["fileName"];
        final fileId = data["fileId"].toString().toInt();
        final userId = data["userId"].toString().toInt();
        //连接中转接收文件
        try {
          await FileSyncHandler.receiveFile(
            isForward: true,
            ip: forwardServerHost!,
            port: forwardServerPort!,
            size: size,
            fileName: fileName,
            devId: targetId,
            userId: userId,
            fileId: fileId,
            context: Get.context!,
            targetId: targetId,
          );
        } catch (err, stack) {
          Log.debug(
            tag,
            "receive file failed from forward"
            "$err $stack",
          );
        }
        break;
      case ForwardMsgType.fileReceiverConnected:
        //接收方已连接，开始发送
        final fileId = data["fileId"].toString().toInt();
        if (_forwardFiles.containsKey(fileId)) {
          _forwardFiles[fileId]!.onForwardReceiverConnected();
        } else {
          Log.warn(tag, "fileReceiverConnected but not fileId in waiting list");
        }
        break;
      default:
    }
  }

  ///socket 监听消息处理
  Future<void> _onSocketReceived(
    SecureSocketClient client,
    MessageData msg,
  ) async {
    DevInfo dev = msg.send;
    Log.debug(tag, "${dev.name} ${msg.key}");
    var address = ipSetTemp.firstWhereOrNull((ip) => ip.split(":")[0] == client.ip);
    switch (msg.key) {
      case MsgType.ping:
        var skt = _devSockets[dev.guid];
        if (_devSockets.containsKey(dev.guid)) {
          skt!.updatePingTime();
          if (msg.data.containsKey("result")) {
            dev.sendData(MsgType.pingResult, {}, false);
          }
        }
        break;

      case MsgType.pingResult:
        var skt = _devSockets[dev.guid];
        if (_devSockets.containsKey(dev.guid)) {
          skt!.updatePingTime();
        }
        break;

      ///客户端连接
      case MsgType.connect:
        final isSocket = _registry.getProtocol(dev.guid)?.isSocket ?? true;
        if (!isSocket) {
          Log.warn(tag, "已通过其他协议连接: ${dev.guid}");
          return;
        }
        assert(() {
          ///忽略指定设备的连接
          if (dev.guid == "1f480ae18e8f79af8c78b304c1c9be3d") {
            client.close();
          }
          return true;
        }());
        var device = await dbService.deviceDao.getById(dev.guid, appConfig.userId);
        var isPaired = device != null && device.isPaired;
        //未配对且不允许被发现，关闭链接
        if (!appConfig.allowDiscover && !isPaired) {
          client.destroy();
          return;
        }
        //设备是自身
        if (dev.guid == appConfig.device.guid) {
          client.destroy();
          return;
        }
        if (_devSockets.containsKey(dev.guid)) {
          //已经链接，跳过
          break;
        }
        //本地是否已配对
        var localDevice = await dbService.deviceDao.getById(dev.guid, appConfig.userId);
        var localIsPaired = localDevice?.isPaired ?? false;
        var pairedStatusData = MessageData(
          userId: appConfig.userId,
          send: appConfig.devInfo,
          key: MsgType.pairedStatus,
          data: {
            "isPaired": localIsPaired,
            "minVersionName": appConfig.minVersion.name,
            "minVersionCode": appConfig.minVersion.code,
            "versionName": appConfig.version.name,
            "versionCode": appConfig.version.code,
          },
        );
        //告诉客户端配对状态
        client.send(pairedStatusData.toJson());
        break;

      case MsgType.pairedStatus:
        _makeSurePaired(client, dev, msg);
        break;

      ///主动断开连接
      case MsgType.disConnect:
        _onDevDisconnected(dev.guid, autoReconnect: false);
        client.destroy();
        break;

      ///忘记设备
      case MsgType.forgetDev:
        onDevForget(dev, appConfig.userId);
        break;

      ///单条数据同步
      case MsgType.ackSync:
      case MsgType.sync:
        _onSyncMsg(msg);
        break;

      ///批量数据同步
      case MsgType.missingData:
        var copyMsg = MessageData.fromJson(msg.toJson());
        var data = msg.data["data"] as Map<dynamic, dynamic>;
        copyMsg.data = data.cast<String, dynamic>();
        final total = msg.data["total"];
        int seq = msg.data["seq"];
        final syncProgressService = Get.find<HistorySyncProgressService>();
        syncProgressService.addProgress(copyMsg.send.guid, copyMsg.data, seq, total);
        _onSyncMsg(copyMsg);
        break;

      ///请求批量同步
      case MsgType.reqMissingData:
        var syncedAppIds = ((msg.data["appIds"] ?? []) as List<dynamic>).cast<String>();
        MissingDataSyncHandler.sendMissingData(dev, appConfig.device.guid, syncedAppIds);
        break;
      case MsgType.reqAppInfo:
        final appId = msg.data["appId"];
        final sourceService = Get.find<ClipboardSourceService>();
        final appInfo = sourceService.appInfos.firstWhereOrNull((item) => item.devId == appConfig.device.guid && appId == item.appId);
        if (appInfo == null) {
          break;
        }
        dev.sendData(MsgType.appInfo, appInfo.toJson());
        break;
      case MsgType.appInfo:
        final appInfo = AppInfo.fromJson(msg.data);
        final sourceService = Get.find<ClipboardSourceService>();
        sourceService.addOrUpdate(appInfo);
        break;

      ///请求配对我方，生成四位配对码
      case MsgType.reqPairing:
        final random = Random();
        int code = 100000 + random.nextInt(900000);
        DevPairingHandler.addCode(dev.guid, CryptoUtil.toMD5(code));
        //发送通知
        _pairingNotifyId = await NotifyUtil.notify(
          content: "${TranslationKey.newParingRequest.tr}: $code",
          key: "dev-pairing-${dev.guid}",
        );
        if (_pairing) {
          Get.back();
        }
        _pairing = true;
        showDialog(
          context: Get.context!,
          builder: (BuildContext context) {
            return AlertDialog(
              title: Text(TranslationKey.paringRequest.tr),
              content: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(TranslationKey.pairingCodeDialogContent.trParams({"devName": dev.name})),
                    const SizedBox(
                      height: 10,
                    ),
                    Text(
                      code.toString().split("").join("  "),
                      style: const TextStyle(fontSize: 30),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () {
                    cancelPairing(dev);
                  },
                  child: Text(TranslationKey.cancelCurrentPairing.tr),
                ),
              ],
            );
          },
        );
        break;

      ///请求配对我方，验证配对码
      case MsgType.pairing:
        String code = msg.data["code"];
        //验证配对码
        var verify = DevPairingHandler.verify(dev.guid, code);
        _onDevPaired(dev, msg.userId, verify, address);
        //返回配对结果
        dev.sendData(MsgType.paired, {"result": verify}, false);
        ipSetTemp.removeWhere((v) {
          return v == address;
        });
        break;

      ///获取配对结果
      case MsgType.paired:
        bool result = msg.data["result"];
        _onDevPaired(dev, msg.userId, result, address);
        ipSetTemp.removeWhere((v) => v == address);
        if (_pairing = true) {
          Get.back();
          _pairing = false;
        }
        // 配对成功后，发起方将同步密码发送给对方
        if (result) {
          final pwd = await appConfig.setSyncPassword(
            appConfig.hasSyncPassword ? appConfig.syncPassword : null,
          );
          dev.sendData(MsgType.syncKey, {"key": pwd}, false);
        }
        break;

      /// 接收对方发来的同步密码（配对完成后由发起方发送）
      case MsgType.syncKey:
        final receivedKey = msg.data["key"] as String?;
        if (receivedKey != null && receivedKey.isNotEmpty) {
          // 仅当本机尚无密码时接受，防止多设备已有密码时被覆盖
          if (!appConfig.hasSyncPassword) {
            await appConfig.setSyncPassword(receivedKey);
          }
        }
        break;

      ///取消配对
      case MsgType.cancelPairing:
        DevPairingHandler.removeCode(dev.guid);
        if (_pairing) {
          Get.back();
        }
        _onCancelPairing(dev);
        break;

      ///文件同步
      case MsgType.file:
        String ip = client.ip;
        int port = msg.data["port"];
        int size = msg.data["size"];
        String fileName = msg.data["fileName"];
        int fileId = msg.data["fileId"];
        try {
          await FileSyncHandler.receiveFile(
            ip: ip,
            port: port,
            size: size,
            fileName: fileName,
            devId: msg.send.guid,
            userId: msg.userId,
            fileId: fileId,
            context: Get.context!,
          );
        } catch (err, stack) {
          Log.debug(
            tag,
            "receive file failed. ip:$ip, port: $port, size: $size, fileName: $fileName. "
            "$err $stack",
          );
        }
        break;
      default:
    }
  }

  void cancelPairing(DevInfo dev) {
    if (!_pairing) return;
    DevPairingHandler.removeCode(dev.guid);
    Get.back();
    dev.sendData(MsgType.cancelPairing, {}, false);
    if (_pairingNotifyId != null) {
      NotifyUtil.cancel("dev-pairing-${dev.guid}", _pairingNotifyId!);
    }
    _pairing = false;
    _pairingNotifyId = null;
  }

  ///数据同步处理
  void _onSyncMsg(MessageData msg) {
    Module module = Module.getValue(msg.data["module"]);
    Log.debug(tag, "module ${module.moduleName}");
    //筛选某个模块的同步处理器
    var lst = getListeners(module);
    for (var listener in lst) {
      switch (msg.key) {
        case MsgType.sync:
        case MsgType.missingData:
          dbService.execSequentially(() => listener.onSync(msg));
          break;
        case MsgType.ackSync:
          dbService.execSequentially(() => listener.ackSync(msg));
          break;
        default:
          break;
      }
    }
  }

  //是否正在设备发现
  var _discovering = false;

  bool get discovering => _discovering;
  TaskRunner? _taskRunner;

  ///发现设备
  void startDiscoveryDevices({
    bool restart = false,
    bool scan = true,
    bool manual = false,
  }) async {
    if (_discovering) {
      Log.debug(tag, "正在发现设备");
      return;
    }
    if (appConfig.currentNetWorkType.value == ConnectivityResult.none) {
      Log.debug(tag, "无网络");
      return;
    }
    _discovering = true;
    for (var listener in _discoverListeners) {
      listener.onDiscoverStart();
    }
    Log.debug(tag, "开始发现设备");
    //重新更新广播监听
    try {
      if (!appConfig.onlyForwardMode) {
        await _startListenMulticast();
      }
    } catch (err, stack) {
      Log.error(tag, "error: $e, $stack");
    }
    List<Future<void> Function()> tasks = [];
    if (appConfig.onlyForwardMode) {
      tasks = []; //测试屏蔽发现用
    } else {
      //先发现自添加设备
      tasks.addAll(await _pairedDiscovering());
    }
    appConfig.deviceDiscoveryStatus.value = TranslationKey.deviceDiscoveryStatusViaPaired.tr;
    //尝试连接中转服务器
    if (_forwardClient == null) {
      await connectForwardServer();
    }
    final isMobileNetwork = appConfig.currentNetWorkType.value == ConnectivityResult.mobile;
    //并行处理
    TaskRunner<void>(
      initialTasks: tasks,
      onFinish: () {
        if (PlatformExt.isMobile && isMobileNetwork) {
          tasks = [];
        } else if (scan) {
          //广播发现
          tasks.addAll(_multicastDiscovering());
        } else {
          tasks = [];
        }
        appConfig.deviceDiscoveryStatus.value = TranslationKey.deviceDiscoveryStatusViaBroadcast.tr;
        _taskRunner = TaskRunner<void>(
          initialTasks: tasks,
          onFinish: () async {
            appConfig.deviceDiscoveryStatus.value = TranslationKey.deviceDiscoveryStatusViaScan.tr;
            if (appConfig.onlyForwardMode) {
              tasks = []; //测试屏蔽发现用
            } else {
              if (PlatformExt.isMobile && isMobileNetwork) {
                tasks = [];
              } else if (scan) {
                //发现子网设备
                tasks = await _subNetDiscovering(manual);
              } else {
                tasks = [];
              }
            }
            _taskRunner = TaskRunner<void>(
              initialTasks: tasks,
              onFinish: () async {
                appConfig.deviceDiscoveryStatus.value = TranslationKey.deviceDiscoveryStatusViaForward.tr;
                if (scan) {
                  //发现中转设备
                  tasks = await _forwardDiscovering();
                } else {
                  tasks = [];
                }
                _taskRunner = TaskRunner<void>(
                  initialTasks: tasks,
                  onFinish: () async {
                    appConfig.deviceDiscoveryStatus.value = null;
                    _taskRunner = null;
                    _discovering = false;
                    for (var listener in _discoverListeners) {
                      listener.onDiscoverFinished();
                    }
                  },
                  concurrency: 50,
                );
              },
              concurrency: 50,
            );
          },
          concurrency: 1,
        );
      },
      concurrency: 50,
    );
  }

  ///停止发现设备
  Future<void> stopDiscoveryDevices([bool restart = false]) async {
    appConfig.deviceDiscoveryStatus.value = null;
    Log.debug(tag, "停止发现设备");
    _taskRunner?.stop();
    _taskRunner = null;
    _discovering = false;
    if (!restart) {
      for (var listener in _discoverListeners) {
        listener.onDiscoverFinished();
      }
    }
  }

  ///重新发现设备
  void restartDiscoveryDevices() async {
    Log.debug(tag, "重新开始发现设备");
    await stopDiscoveryDevices(true);
    startDiscoveryDevices(restart: true);
  }

  ///组播发现设备
  List<Future<void> Function()> _multicastDiscovering() {
    List<Future<void> Function()> tasks = List.empty(growable: true);
    for (var ms in const [100, 500, 2000, 5000]) {
      f() {
        return Future.delayed(ms.ms, () {
          // 广播本机socket信息
          Map<String, dynamic> map = {"port": _server.port};
          sendMulticastMsg(MsgType.broadcastInfo, map);
        });
      }

      tasks.add(() => f());
    }
    return tasks;
  }

  ///发现子网设备
  Future<List<Future<void> Function()>> _subNetDiscovering(bool manual) async {
    List<Future<void> Function()> tasks = List.empty(growable: true);
    //自动设备发现但是设置了仅手动触发
    if (!manual && appConfig.onlyManualDiscoverySubNet) {
      return tasks;
    }
    var interfaces = (await NetworkInterface.list()).where((itf) => !appConfig.noDiscoveryIfs.contains(itf.name));
    var expendAddress = interfaces.map((itf) => itf.addresses).expand((ip) => ip);
    var ips = expendAddress.where((ip) => ip.type == InternetAddressType.IPv4).map((address) => address.address).toList();
    for (var ip in ips) {
      //生成所有 ip
      final ipList = List.generate(255, (i) => '${ip.split('.').take(3).join('.')}.$i').where((genIp) => genIp != ip).toList();
      //对每个ip尝试连接
      for (var genIp in ipList) {
        tasks.add(() => manualConnect(genIp));
      }
    }
    return tasks;
  }

  ///发现已配对设备
  Future<List<Future<void> Function()>> _pairedDiscovering() async {
    List<Future<void> Function()> tasks = List.empty(growable: true);
    var lst = await dbService.deviceDao.getAllDevices(appConfig.userId);
    var devices = lst.where((dev) => dev.address != null).toList();
    final isWifi = appConfig.currentNetWorkType.value == ConnectivityResult.wifi;

    //region 查找中转服务的ip
    String? forwardIp;
    //存在且不为ipv4时才查询
    if (forwardServerHost != null) {
      //如果是域名就进行查询对应ip
      if (!forwardServerHost!.isIPv4) {
        try {
          final addresses = await InternetAddress.lookup(forwardServerHost!);
          for (var address in addresses) {
            if (address.type != InternetAddressType.IPv4) {
              continue;
            }
            forwardIp = address.address;
          }
        } catch (_) {}
      } else {
        forwardIp = forwardServerHost;
      }
    }
    //endregion

    for (var dev in devices) {
      if (!dev.address!.contains(":")) {
        //如果先前通过存储服务连接，会解析失败，直接跳过
        continue;
      }
      var [ip, port] = dev.address!.split(":");
      //检测当前网络环境，以下条件直接直接连接中转，而不是走完整设备发现流程
      //1. 不是 WiFi 且为移动设备
      //2. 不是 WiFi 且地址为中转地址
      if (!isWifi) {
        if (PlatformExt.isMobile || forwardIp == ip) {
          print("connect by forward ${dev.name}(${dev.guid})");
          tasks.add(() => manualConnectByForward(dev.guid));
          continue;
        }
      }
      tasks.add(() => manualConnect(ip, port: int.parse(port)));
    }
    return tasks;
  }

  ///中转连接
  Future<List<Future<void> Function()>> _forwardDiscovering() async {
    List<Future<void> Function()> tasks = List.empty(growable: true);
    if (_forwardClient == null) return tasks;
    if (appConfig.forwardWay != ForwardWay.server) {
      Log.debug(tag, "_forwardDiscovering forward way is ${appConfig.forwardWay.name}");
      return tasks;
    }
    var lst = await dbService.deviceDao.getAllDevices(appConfig.userId);
    var offlineList = lst.where((dev) => !_devSockets.keys.contains(dev.guid));
    for (var dev in offlineList) {
      if (forwardServerHost == null || forwardServerPort == null) continue;
      tasks.add(() => manualConnectByForward(dev.guid));
    }
    return tasks;
  }

  ///检查是否已经掉线，如果掉线则移除
  Future<bool> testIsOnline(String devId) async {
    if (!_devSockets.containsKey(devId)) return false;
    var skt = _devSockets[devId]!;
    //发送一个ping事件，但是要求对方给回复
    await skt.dev.sendData(MsgType.ping, {
      "result": null,
    }, false);
    Log.debug(tag, "testIsOnline: send ping result");
    //等待2000ms
    final waitTime = 2000.ms;
    await Future.delayed(waitTime);
    Log.debug(tag, "testIsOnline: waitTime finished");
    //等待过程中已经掉线
    if (!_devSockets.containsKey(devId)) {
      Log.debug(tag, "testIsOnline: offline in waitTime");
      _onDevDisconnected(devId);
      return false;
    }
    skt = _devSockets[devId]!;
    //检查上次ping的时间是否在误差范围内，如果不在这个范围说明可能已经掉线
    final online = skt.lastPingTime.isWithinRange(waitTime);
    final now = DateTime.now();
    final offsetMs = now.difference(skt.lastPingTime).inMilliseconds;
    Log.debug(tag, "testIsOnline: isWithinRange $online, offset $offsetMs ms");
    if (!online) {
      _onDevDisconnected(devId);
    }
    return online;
  }

  ///中转连接设备
  Future<bool> manualConnectByForward(String devId) async {
    if (await testIsOnline(devId)) {
      Log.debug(tag, "dev($devId) online, cancel connect by forward");
      return false;
    }
    Log.debug(tag, "connecting $devId");
    if (appConfig.forwardWay != ForwardWay.server) {
      Log.debug(tag, "manualConnectByForward forward way is ${appConfig.forwardWay.name}");
      return false;
    }
    return manualConnect(
      forwardServerHost!,
      port: forwardServerPort,
      forward: true,
      targetDevId: devId,
      onErr: (err) {
        Log.debug(tag, '$devId 中转连接，发生错误:$err');
        _onDevDisconnected(devId);
        return false;
      },
    );
  }

  ///手动连接 ip
  Future<bool> manualConnect(
    String ip, {
    int? port,
    Function? onErr,
    Map<String, dynamic> data = const {},
    bool forward = false,
    String? targetDevId,
  }) {
    port = port ?? Constants.port;
    String address = "$ip:$port:$targetDevId";
    if (_connectingAddress.contains(address)) {
      //已经在连接中，返回true
      return Future.value(true);
    }
    _connectingAddress.add(address);
    Future.delayed(5.s, () {
      _connectingAddress.remove(address);
    });
    return SecureSocketClient.connect(
      ip: ip,
      port: port,
      prime1: appConfig.prime1,
      prime2: appConfig.prime2,
      dhAesKey: appConfig.dhAesKey,
      targetDevId: forward ? targetDevId : null,
      selfDevId: forward ? appConfig.device.guid : null,
      connectionMode: forward ? ConnectionMode.forward : ConnectionMode.direct,
      onConnected: (SecureSocketClient client) {
        //外部终止连接
        if (data.containsKey('stop') && data['stop'] == true) {
          client.destroy();
          return;
        }
        ipSetTemp.add("$ip:$port");
        //发送本机信息给对方
        MessageData msg = MessageData(
          userId: appConfig.userId,
          send: appConfig.devInfo,
          key: MsgType.connect,
          data: data,
          recv: null,
        );
        client.send(msg.toJson());
      },
      onMessage: (client, json) {
        var msg = MessageData.fromJson(json);
        _onSocketReceived(client, msg);
      },
      onDone: (SecureSocketClient client) {
        Log.debug(tag, "${forward ? '中转' : '手动'}连接关闭");
        if (forward) {
          _onDevDisconnected(targetDevId!);
        } else {
          for (var devId in _devSockets.keys.toList()) {
            var skt = _devSockets[devId]!.socket;
            if (skt.ip == ip && skt.port == port) {
              _onDevDisconnected(devId);
            }
          }
        }
      },
      onError: (error, client) {
        Log.error(tag, '${forward ? '中转' : '手动'}连接发生错误: $error $ip $port');
        if (forward) {
          _onDevDisconnected(targetDevId!);
        } else {
          for (var devId in _devSockets.keys.toList()) {
            var skt = _devSockets[devId]!.socket;
            if (skt.ip == ip && skt.port == port) {
              _onDevDisconnected(devId);
            }
          }
        }
      },
    ).then((v) => true).catchError((err) {
      onErr?.call(err);
      return false;
    });
  }

  void _makeSurePaired(
    SecureSocketClient client,
    DevInfo dev,
    MessageData msg,
  ) async {
    //已连接，结束
    if (_devSockets.containsKey(dev.guid)) {
      return;
    }
    //本地是否存在该设备
    var localDevice = await dbService.deviceDao.getById(dev.guid, appConfig.userId);
    bool paired = false;
    if (localDevice != null) {
      var localIsPaired = localDevice.isPaired;
      var remoteIsPaired = msg.data["isPaired"];
      //双方配对信息一致
      if (remoteIsPaired && localIsPaired) {
        paired = true;
        Log.debug(tag, "${dev.name} has paired");
      } else {
        //有一方已取消配对或未配对
        //忘记设备
        onDevForget(dev, appConfig.userId);
        dbService.deviceDao.updateDevice(localDevice..isPaired = false);
        Log.debug(tag, "${dev.name} not paired");
      }
    }
    //告诉客户端配对状态
    var pairedStatusData = MessageData(
      userId: appConfig.userId,
      send: appConfig.devInfo,
      key: MsgType.pairedStatus,
      data: {
        "isPaired": paired,
        "minVersionName": appConfig.minVersion.name,
        "minVersionCode": appConfig.minVersion.code,
        "versionName": appConfig.version.name,
        "versionCode": appConfig.version.code,
      },
    );
    client.send(pairedStatusData.toJson());
    var minName = msg.data["minVersionName"];
    var minCode = msg.data["minVersionCode"];
    var versionName = msg.data["versionName"];
    var versionCode = msg.data["versionCode"];
    var minVersion = AppVersion(minName, minCode);
    var version = AppVersion(versionName, versionCode);
    Log.debug(tag, "minVersion $minVersion version $version");
    //添加到本地
    if (_devSockets.containsKey(dev.guid)) {
      _devSockets[dev.guid]!.isPaired = paired;
      _devSockets[dev.guid]!.minVersion = minVersion;
      _devSockets[dev.guid]!.version = version;
    } else {
      var ds = DevSocket(
        dev: dev,
        socket: client,
        isPaired: paired,
        minVersion: minVersion,
        version: version,
      );
      _devSockets[dev.guid] = ds;
    }
    await _onDevConnected(dev, client, minVersion, version);
    if (paired) {
      //已配对，请求所有缺失数据
      reqMissingData();
      // 如果使用转发服务器，从云端拉取离线期间的剪贴板记录
      if (client.isForwardMode) {
        _pullFromServer();
      }
    }
  }

  ///判断某个设备使用使用中转
  bool isUseForward(String guid) {
    if (!_devSockets.containsKey(guid)) return false;
    return _devSockets[guid]!.socket.isForwardMode;
  }

  Future<void> reqMissingData([String? devId]) async {
    final sourceService = Get.find<ClipboardSourceService>();
    if (devId != null) {
      final devSkt = _devSockets[devId];
      if (devSkt == null) {
        return;
      }
      final allAppInfos = sourceService.appInfos;
      final ownedAppIds = allAppInfos.where((item) => item.devId == devId).map((item) => item.appId).toList();
      await devSkt.dev.sendData(MsgType.reqMissingData, {
        "appIds": ownedAppIds,
      });
    } else {
      if (!appConfig.autoSyncMissingData) {
        return;
      }
      final devs = _devSockets.values.where((dev) => dev.isPaired).map(((item) => item.dev)).toList();
      final allAppInfos = sourceService.appInfos;
      for (var dev in devs) {
        final ownedAppIds = allAppInfos.where((item) => item.devId == dev.guid).map((item) => item.appId).toList();
        await dev.sendData(MsgType.reqMissingData, {
          "appIds": ownedAppIds,
        });
      }
    }
  }

  ///设备连接成功
  Future<void> _onDevConnected(
    DevInfo dev,
    SecureSocketClient client,
    AppVersion minVersion,
    AppVersion version,
  ) async {
    showDevConnectedNotification(dev.guid);
    final ip = client.ip;
    final port = client.isForwardMode ? forwardServerPort : client.port;

    //更新连接地址
    final address = "$ip:$port";
    await dbService.deviceDao.updateDeviceAddress(dev.guid, appConfig.userId, address);
    _devSockets[dev.guid]!.updatePingTime();
    //添加到注册服务
    _registry.addDevice(dev, client.isForwardMode ? TransportProtocol.server : TransportProtocol.direct);
    broadcastProcessChain.remove(dev.guid);
    for (var listener in _devAliveListeners) {
      try {
        await listener.onConnected(
          dev,
          minVersion,
          version,
          client.isForwardMode ? TransportProtocol.server : TransportProtocol.direct,
        );
      } catch (e, t) {
        Log.debug(tag, "$e $t");
      }
    }
  }

  ///断开所有连接
  void disConnectAllConnections([bool onlyNotPaired = false]) {
    Log.debug(tag, "开始断开所有连接 仅未配对：$onlyNotPaired");
    if (!onlyNotPaired) {
      disConnectForwardServer();
    }
    var skts = _devSockets.values.toList();
    for (var devSkt in skts) {
      if (onlyNotPaired && devSkt.isPaired) {
        continue;
      }
      disconnectDevice(devSkt.dev, true);
    }
  }

  ///主动断开设备连接
  bool disconnectDevice(DevInfo dev, bool backSend) {
    var id = dev.guid;
    if (!_devSockets.containsKey(id)) {
      return false;
    }
    if (backSend) {
      dev.sendData(MsgType.disConnect, {});
    }
    _onDevDisconnected(id, autoReconnect: false);
    _devSockets[id]?.socket.destroy();
    return true;
  }

  ///设备配对成功
  void _onDevPaired(DevInfo dev, int uid, bool result, String? address) {
    Log.debug(tag, "${dev.name} paired，address：$address");
    _devSockets[dev.guid]?.isPaired = true;
    for (var listener in _devAliveListeners) {
      try {
        listener.onPaired(dev, uid, result, address);
      } catch (e, t) {
        Log.debug(tag, "$e $t");
      }
    }
  }

  ///设备取消配对
  void _onCancelPairing(DevInfo dev) {
    Log.debug(tag, "${dev.name} cancelPairing");
    if (_pairingNotifyId != null) {
      NotifyUtil.cancel("dev-pairing-${dev.guid}", _pairingNotifyId!);
    }
    _pairing = false;
    _pairingNotifyId = null;
    for (var listener in _devAliveListeners) {
      try {
        listener.onCancelPairing(dev);
      } catch (e, t) {
        Log.debug(tag, "$e $t");
      }
    }
  }

  ///设备配对成功
  void onDevForget(DevInfo dev, int uid) {
    Log.debug(tag, "${dev.name} forget");
    _devSockets[dev.guid]?.isPaired = false;
    for (var listener in _devAliveListeners) {
      try {
        listener.onForget(dev, uid);
      } catch (e, t) {
        Log.debug(tag, "$e $t");
      }
    }
  }

  //region 心跳相关
  ///开始所有设备的心跳测试
  void startHeartbeatTest() {
    //先停止
    stopHeartbeatTest();
    //首次直接发送
    DataSender.sendData2All(MsgType.ping, {}, false);
    // judgeDeviceHeartbeatTimeout();
    var interval = appConfig.heartbeatInterval;
    if (interval <= 0) return;
    //更新timer
    _heartbeatTimer = Timer.periodic(interval.s, (timer) {
      if (_devSockets.isEmpty) return;
      Log.debug(tag, "send ping");
      // judgeDeviceHeartbeatTimeout();
      DataSender.sendData2All(MsgType.ping, {}, false);
    });
  }

  ///停止所有设备的心跳测试
  void stopHeartbeatTest() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  ///定时判断中转服务连接存活状态
  void _startJudgeForwardClientAlivePeriod() {
    //先停止
    if (_forwardClientHeartbeatTimer != null) {
      _stopJudgeForwardClientAlive();
    }
    //更新timer
    _forwardClientHeartbeatTimer = Timer.periodic(35.s, (timer) {
      var disconnected = false;
      if (_lastForwardServerPingTime == null) {
        disconnected = true;
      } else {
        final now = DateTime.now();
        if (now.difference(_lastForwardServerPingTime!).inSeconds >= 35) {
          disconnected = true;
        }
      }
      Log.debug(tag, "startJudgeForwardClientAlivePeriod disconnected: $disconnected");
      if (!disconnected) return;
      _forwardClient?.destroy();
    });
  }

  ///停止定时判断中转服务连接存活状态
  void _stopJudgeForwardClientAlive() {
    _forwardClientHeartbeatTimer?.cancel();
    _forwardClientHeartbeatTimer = null;
  }

  ///判断设备心跳是否超时
  void judgeDeviceHeartbeatTimeout() {
    //手机在息屏后无法发送网络数据
    var interval = appConfig.heartbeatInterval * 1.3;
    final now = DateTime.now();
    var skts = _devSockets.values.toList();
    for (var ds in skts) {
      final diff = now.difference(ds.lastPingTime);
      if (diff.inSeconds > interval) {
        //心跳超时
        Log.debug(tag, "judgeDeviceHeartbeatTimeout ${ds.dev.guid}");
        disconnectDevice(ds.dev, true);
        showDevDisConnectNotification(ds.dev.guid);
      }
    }
  }

  @override
  void onScreenOpened() {
    screenOpened = true;
    if (_forwardClient == null) {
      connectForwardServer();
    }
    startDiscoveryDevices(scan: appConfig.enableAutoSyncOnScreenOpened);
    startHeartbeatTest();
    Log.debug(tag, "屏幕打开");
    autoCloseConnTimer = null;
  }

  @override
  void onScreenClosed() {
    super.onScreenClosed();
    Log.debug(tag, "屏幕关闭");
    screenOpened = false;
    if (!appConfig.autoCloseConnAfterScreenOff) {
      return;
    }
    const minutes = 2;
    Log.debug(tag, "屏幕关闭，开启定时器，$minutes分钟后关闭连接");
    WakelockPlus.toggle(enable: true);
    //开启定时器，到时间自动断开连接
    autoCloseConnTimer = Future.delayed(minutes.min, () {
      WakelockPlus.toggle(enable: false);
      if (autoCloseConnTimer == null) {
        Log.debug(tag, "延迟执行已取消");
        return;
      }
      Log.debug(tag, "屏幕关闭时间已到，断开所有连接和心跳测试");
      autoCloseConnTimer = null;
      disConnectAllConnections();
      stopHeartbeatTest();
      _stopJudgeForwardClientAlive();
    });
    // Log.debug(tag, "定时器激活状态: ${autoCloseConnTimer?.isActive}");
  }

  //endregion
  ///设备断开连接
  void _onDevDisconnected(
    String devId, {
    bool autoReconnect = true,
  }) {
    if (!_devSockets.containsKey(devId)) {
      return;
    }
    Log.debug(tag, "$devId 断开连接");
    final ds = _devSockets[devId];
    if (ds != null && ds.isPaired && autoReconnect) {
      showDevDisConnectNotification(ds.dev.guid);
    }
    //移除socket
    _devSockets.remove(devId);
    //从注册服务移除设备
    _registry.removeDevice(devId);
    if (ds != null && ds.socket.isForwardMode) {
      final host = appConfig.forwardServer!.host;
      final port = appConfig.forwardServer!.port;
      final address = "$host:$port:$devId";
      _connectingAddress.remove(address);
    }
    for (var listener in _devAliveListeners) {
      try {
        listener.onDisconnected(devId);
      } catch (e, t) {
        Log.debug(tag, "$e $t");
      }
    }
    if (ds != null && autoReconnect) {
      _attemptReconnect(ds);
    }
  }

  ///设备连接后发起通知
  void showDevConnectedNotification(String devId) {
    if (!appConfig.notifyOnDevConn) {
      return;
    }
    if (!(_devSockets[devId]?.isPaired ?? false)) {
      //未配对的不理会
      return;
    }
    _devNotifyTimer?.cancel();
    //如果短时间内断开并重连，就同时取消通知
    if (_devNotifyIdMap[devId] == true) {
      _devNotifyIdMap.remove(devId);
      return;
    }
    _devNotifyIdMap[devId] = false;
    _devNotifyTimer = Timer(_debounceTime, () async {
      _devNotifyIdMap.remove(devId);
      final devService = Get.find<DeviceService>();
      final key = "dev-conn-$devId";
      NotifyUtil.cancelAll(key);
      final notifyId = await NotifyUtil.notify(
        key: key,
        content: TranslationKey.devConnectedNotifyContent.trParams({
          "devName": devService.getName(devId),
        }),
      );
      if (notifyId != null) {
        Future.delayed(2.s, () {
          NotifyUtil.cancel(key, notifyId);
        });
      }
    });
  }

  ///设备断开后发起通知
  void showDevDisConnectNotification(String devId) {
    if (!appConfig.notifyOnDevDisconn) {
      return;
    }
    if (!(_devSockets[devId]?.isPaired ?? false)) {
      //未配对的不理会
      return;
    }
    _devNotifyTimer?.cancel();
    _devNotifyIdMap[devId] = true;
    _devNotifyTimer = Timer(_debounceTime, () async {
      _devNotifyIdMap.remove(devId);
      final devService = Get.find<DeviceService>();
      final key = "dev-disconn-$devId";
      NotifyUtil.cancelAll(key);
      final notifyId = await NotifyUtil.notify(
        key: key,
        content: TranslationKey.devDisconnectNotifyContent.trParams({
          "devName": devService.getName(devId),
        }),
      );
      if (notifyId != null) {
        Future.delayed(2.s, () {
          NotifyUtil.cancel(key, notifyId);
        });
      }
    });
  }

  ///重连设备，由于对向设备的连接可能持续持有一小段时间（视心跳时间而定）
  ///会在一定时间内持续尝试重连，此处默认 3 分钟
  void _attemptReconnect(DevSocket devSkt) async {    final startTime = DateTime.now();
    var endTime = DateTime.now();
    var diffMinutes = endTime.difference(startTime).inMinutes;
    final ip = devSkt.socket.ip;
    final port = devSkt.socket.port;
    final String devNameAddr = "${devSkt.dev.name}($ip:$port)";
    //三分钟内持续尝试
    while (diffMinutes < 3) {
      //延迟2s
      await Future.delayed(2.s);
      if (_devSockets.containsKey(devSkt.dev.guid)) {
        Log.debug(tag, "重连成功 $devNameAddr");
        //已经成功连接，停止重连
        return;
      }
      Log.debug(tag, "尝试重连 ${devSkt.dev.name}");
      try {
        if (devSkt.socket.isForwardMode) {
          if (_forwardClient != null) {
            await manualConnectByForward(devSkt.dev.guid);
          } else {
            Log.warn(tag, "中转连接已关闭");
            break;
          }
        } else {
          await manualConnect(ip, port: port);
        }
      } catch (err) {
        Log.warn(tag, "attempt reconnect error: $err");
      }
      endTime = DateTime.now();
      diffMinutes = endTime.difference(startTime).inMinutes;
    }
    Log.debug(tag, "重连失败 $devNameAddr");
  }

  ///中转服务器连接成功后拉取服务器端新内容并写入本地数据库
  void _pullFromServer() {
    if (!Get.isRegistered<ServerSyncService>()) return;
    final serverSync = Get.find<ServerSyncService>();
    serverSync.pullNewItems().then((items) async {
      if (items.isEmpty) return;
      final historyController = Get.find<HistoryController>();
      for (final item in items) {
        try {
          String content;
          int size;
          if (item.isImage) {
            // 下载图片字节并保存到本地文件
            final bytes = await serverSync.downloadImage(item.fileId);
            if (bytes == null) continue;
            final fileName = "${item.fileId}.png";
            final dirPath = Platform.isAndroid
                ? (appConfig.saveToPictures
                    ? "${Constants.androidPicturesPath}/${Constants.appName}"
                    : appConfig.androidPrivatePicturesPath)
                : appConfig.fileStorePath;
            final filePath = "$dirPath/$fileName";
            final file = File(filePath);
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes);
            content = file.path.normalizePath;
            size = bytes.length;
          } else {
            content = item.decryptedContent ?? "";
            size = content.length;
          }
          final history = History(
            id: appConfig.snowflake.nextId(),
            uid: appConfig.userId,
            devId: item.devId,
            time: item.createdAt.toLocal().toString(),
            content: content,
            type: item.isImage ? "Image" : "Text",
            size: size,
            serverItemId: item.id,
            serverExpireAt: item.expireAt?.toIso8601String(),
          );
          historyController.addData(history, false);
        } catch (e) {
          Log.error(tag, "pullFromServer item error: $e");
        }
      }
    }).catchError((e) { Log.error(tag, "pullFromServer error: $e"); });
  }

  ///向兼容的设备发送消息
  @override
  Future<void> sendData(
    DevInfo? dev,
    MsgType key,
    Map<String, dynamic> data, [
    bool onlyPaired = true,
  ]) async {
    Iterable<DevSocket> list = [];
    //向所有设备发送消息
    if (dev == null) {
      list = onlyPaired ? _devSockets.values.where((dev) => dev.isPaired) : _devSockets.values;
      //筛选兼容版本的设备
      list = list.where(
        (dev) => dev.version != null && dev.version! >= appConfig.minVersion,
      );
    } else {
      //向指定设备发送消息
      DevSocket? skt = _devSockets[dev.guid];
      if (skt == null) {
        Log.debug(tag, "${dev.name} 设备未连接，发送失败");
        return;
      }
      if (skt.version == null) {
        Log.debug(tag, "${dev.name} 设备无版本号信息，尚未准备好");
        return;
      }
      if (skt.version! < appConfig.minVersion) {
        Log.debug(tag, "${dev.name} 与当前设备版本不兼容");
        return;
      }
      list = [skt];
    }
    //批量发送
    for (var skt in list) {
      MessageData msg = MessageData(
        userId: appConfig.userId,
        send: appConfig.devInfo,
        key: key,
        data: data,
        recv: null,
      );
      Log.debug(tag, skt.dev.name);
      await skt.socket.send(msg.toJson());
    }
  }

  /// 发送组播消息
  void sendMulticastMsg(
    MsgType key,
    Map<String, dynamic> data, [
    DevInfo? recv,
  ]) async {
    MessageData msg = MessageData(
      userId: appConfig.userId,
      send: appConfig.devInfo,
      key: key,
      data: data,
      recv: recv,
    );
    try {
      var b64Data = CryptoUtil.base64EncodeStr("${msg.toJsonStr()}\n");
      var multicasts = await _getSockets(Constants.multicastGroup);
      for (var multicast in multicasts) {
        multicast.send(
          utf8.encode(b64Data),
          InternetAddress(Constants.multicastGroup),
          appConfig.port,
        );
        multicast.close();
      }
    } catch (e, stacktrace) {
      Log.debug(tag, "$e $stacktrace");
    }
  }

  Future<List<RawDatagramSocket>> _getSockets(
    String multicastGroup, [
    int port = 0,
  ]) async {
    final interfaces = (await NetworkInterface.list()).where((itf) => !appConfig.noDiscoveryIfs.contains(itf.name));
    final sockets = <RawDatagramSocket>[];
    for (final interface in interfaces) {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
      socket.joinMulticast(InternetAddress(multicastGroup), interface);
      sockets.add(socket);
    }
    return sockets;
  }

  ///添加中转文件发送记录
  void addSendFileRecordByForward(FileSyncHandler fileSyncer, int fileId) {
    if (_forwardFiles.containsKey(fileId)) {
      throw Exception("The file is already in the sending list: $fileId");
    }
    _forwardFiles[fileId] = fileSyncer;
  }

  ///移除中转文件发送记录
  void removeSendFileRecordByForward(
    FileSyncHandler fileSyncer,
    int fileId,
    String? targetDevId,
  ) {
    _forwardFiles.remove(fileId);
    if (targetDevId != null) {
      _forwardClient?.send({
        "type": ForwardMsgType.cancelSendFile.name,
        "targetId": targetDevId,
      });
    }
  }
}
