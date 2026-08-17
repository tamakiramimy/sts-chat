import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';

import 'voice_interaction_controller.dart';

void main() => runApp(const StsChatApp());

String initialGatewayUrl() {
  const configuredUrl = String.fromEnvironment('GATEWAY_URL');
  if (configuredUrl.isNotEmpty) return configuredUrl;
  return 'http://localhost:8080';
}

enum AssistantState { idle, listening, thinking, speaking, error }

class StsChatApp extends StatelessWidget {
  const StsChatApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'sts-chat',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xff6b5cff), useMaterial3: true),
        home: const VoiceHomePage(),
      );
}

class VoiceHomePage extends StatefulWidget {
  const VoiceHomePage({super.key});

  @override
  State<VoiceHomePage> createState() => _VoiceHomePageState();
}

class _VoiceHomePageState extends State<VoiceHomePage> {
  final _gateway = GatewayClient();
  final _endpointController = TextEditingController(text: initialGatewayUrl());
  final _questionController = TextEditingController();
  final _messages = <ChatMessage>[];
  late final VoiceInteractionController _voice;
  VoiceSession? _session;
  AssistantState _state = AssistantState.idle;
  String _wakeWord = 'sts-chat';
  String _activityDetail = '正在连接语音服务…';
  String? _error;
  bool _continuousConversation = false;
  bool _restartScheduled = false;

  @override
  void initState() {
    super.initState();
    _voice = VoiceInteractionController(onFinalTranscript: _sendVoiceTranscript)..addListener(_handleVoiceState);
    _restoreAndConnect();
  }

  Future<void> _restoreAndConnect() async {
    final credential = await _gateway.loadCredential();
    if (credential == null) {
      if (!mounted) return;
      setState(() => _activityDetail = '未完成设备配对。请点击右上角图标，输入管理员配对密钥后连接服务。');
      return;
    }
    try {
      await _connect(credential);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = AssistantState.error;
        _error = '语音服务连接失败：$error';
        _activityDetail = '已保存的设备凭证不可用，请重新完成设备配对。';
      });
    }
  }

  Future<void> _pairDemoDevice() async {
    final secretController = TextEditingController();
    final adminSecret = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('家长设备配对'),
        content: TextField(
          controller: secretController,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'ADMIN_SETUP_SECRET'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, secretController.text.trim()), child: const Text('配对')),
        ],
      ),
    );
    secretController.dispose();
    if (adminSecret == null || adminSecret.isEmpty) return;
    setState(() {
      _error = null;
      _state = AssistantState.thinking;
    });
    try {
      final platform = kIsWeb ? 'web' : defaultTargetPlatform.name;
      final credential = await _gateway.pairLocalDevice(
        _endpointController.text,
        adminSecret,
            'sts-chat $platform',
        platform,
      );
      await _connect(credential);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = AssistantState.error;
        _error = '配对失败：无法连接 ${_endpointController.text.trim()}。请确认“服务器连接”地址后重试。';
        _activityDetail = '配对请求未到达 Gateway：$error';
      });
    }
  }

  Future<void> _connect(DeviceCredential credential) async {
    if (mounted) {
      setState(() {
        _state = AssistantState.thinking;
        _activityDetail = '正在获取语音配置并连接 Agent…';
        _error = null;
      });
    }
    final config = await _gateway.getConfiguration(_endpointController.text, credential.token);
    final realtime = await _gateway.getRealtimeToken(_endpointController.text, credential.token);
    final session = VoiceSession();
    await session.connect(realtime.url, realtime.token, onEvent: _handleAgentEvent);
    if (!mounted) return;
    setState(() {
      _session = session;
      _wakeWord = config.wakeWord;
      _state = AssistantState.idle;
      _activityDetail = '已连接，点击圆形按钮开始说话。';
      _error = null;
    });
  }

  Future<void> _startListening() async {
    if (_voice.isListening) {
      _continuousConversation = false;
      await _voice.cancelListening();
      if (!mounted) return;
      setState(() {
        _state = AssistantState.idle;
        _activityDetail = '持续对话已暂停。点击圆形按钮可继续。';
      });
      return;
    }
    _continuousConversation = true;
    await _beginListening();
  }

  Future<void> _beginListening() async {
    if (_session == null) {
      _continuousConversation = false;
      setState(() {
        _state = AssistantState.error;
        _error = '语音服务尚未连接，请先点击右上角图标完成设备配对。';
        _activityDetail = '未连接到 Agent，当前语音不会发送到后台。';
      });
      return;
    }
    setState(() {
      _error = null;
      _activityDetail = '正在启动麦克风和语音识别…';
    });
    if (!kIsWeb) {
      final permission = await Permission.microphone.request();
      if (!permission.isGranted) {
        setState(() => _error = '需要麦克风权限才能听到问题。');
        return;
      }
    }
    await _voice.startListening();
  }

  Future<void> _ask() async {
    final text = _questionController.text.trim();
    if (text.isEmpty) return;
    if (_session == null) {
      setState(() {
        _state = AssistantState.error;
        _error = '语音服务尚未连接，请先完成设备配对。';
        _activityDetail = '未连接到 Agent，无法发送问题。';
      });
      return;
    }
    _continuousConversation = true;
    _questionController.clear();
    await _voice.stopSpeaking();
    await _sendTurn(text);
  }

  Future<void> _sendVoiceTranscript(String text) => _sendTurn(text);

  Future<void> _sendTurn(String text) async {
    if (_session == null) throw StateError('Voice session is not connected.');
    setState(() {
      _messages.add(ChatMessage.child(text));
      _state = AssistantState.thinking;
      _activityDetail = '文本已发送，正在等待 Agent 接收问题…';
      _error = null;
    });
    await _session!.sendTurn(text);
  }

  void _handleVoiceState() {
    if (!mounted) return;
    switch (_voice.phase) {
      case VoiceInteractionPhase.idle:
        setState(() {
          _state = AssistantState.idle;
          _activityDetail = _continuousConversation ? '本轮结束，正在准备继续监听…' : '等待下一次语音或文字输入。';
        });
        _scheduleListeningRestart();
      case VoiceInteractionPhase.listening:
        setState(() {
          _state = AssistantState.listening;
          _activityDetail = _voice.transcript.isEmpty ? '麦克风已开启，正在等待你说话…' : '正在实时转写你的语音。';
        });
      case VoiceInteractionPhase.thinking:
        setState(() {
          _state = AssistantState.thinking;
          _activityDetail = '语音已识别，正在发送问题给 Agent…';
        });
      case VoiceInteractionPhase.speaking:
        setState(() {
          _state = AssistantState.speaking;
          _activityDetail = '已收到回答，正在通过扬声器播放。';
        });
      case VoiceInteractionPhase.error:
      case VoiceInteractionPhase.unavailable:
        setState(() {
          _state = AssistantState.error;
          _error = _voice.errorMessage;
          _activityDetail = '语音处理未完成，请查看错误提示后重试。';
        });
        _continuousConversation = false;
    }
  }

  void _handleAgentEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    switch (event['type']) {
      case 'agent_state':
        final state = AssistantState.values.byName(event['state'] as String);
        setState(() {
          _state = state;
          _activityDetail = switch (state) {
            AssistantState.idle => 'Agent 已就绪，等待新的问题。',
            AssistantState.listening => 'Agent 已停止当前回答，等待新的输入。',
            AssistantState.thinking => 'Agent 正在理解问题并生成回答…',
            AssistantState.speaking => 'Agent 已完成回答，正在准备本地播报。',
            AssistantState.error => 'Agent 报告了处理错误。',
          };
        });
      case 'transcript_final':
        setState(() => _activityDetail = 'Agent 已收到文本，正在开始推理…');
        break;
      case 'answer_delta':
        setState(() {
          if (_messages.isEmpty || !_messages.last.isAssistant) {
            _messages.add(ChatMessage.assistant(event['text'] as String));
          } else {
            _messages[_messages.length - 1] = _messages.last.append(event['text'] as String);
          }
          _activityDetail = 'Agent 正在流式生成回答…';
        });
      case 'answer_final':
        setState(() => _activityDetail = 'Agent 已完成回答，正在启动本地播报。');
        unawaited(_voice.speakAnswer(event['text'] as String? ?? ''));
      case 'interrupted':
        unawaited(_voice.stopSpeaking());
        setState(() {
          _state = AssistantState.listening;
          _activityDetail = '当前回答已中断，可以继续说话。';
        });
      case 'error':
        setState(() {
          _state = AssistantState.error;
          _error = event['message'] as String? ?? '发生了错误，请再试一次。';
          _activityDetail = 'Agent 未能完成本次请求。';
        });
        _continuousConversation = false;
    }
  }

  void _scheduleListeningRestart() {
    if (!_continuousConversation || _restartScheduled || _session == null) return;
    _restartScheduled = true;
    unawaited(Future<void>.delayed(const Duration(milliseconds: 350), () async {
      _restartScheduled = false;
      if (!mounted || !_continuousConversation || _session == null || _voice.isListening) return;
      await _beginListening();
    }));
  }

  @override
  void dispose() {
    _endpointController.dispose();
    _questionController.dispose();
    _voice.removeListener(_handleVoiceState);
    unawaited(_voice.close());
    unawaited(_session?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('sts-chat'), actions: [
          IconButton(onPressed: _pairDemoDevice, icon: const Icon(Icons.qr_code_2), tooltip: '设备配对'),
        ]),
        body: SafeArea(
          child: Column(children: [
            if (kIsWeb) const Padding(
              padding: EdgeInsets.all(12),
              child: Text('H5 仅在当前页面前台识别语音；首次使用请允许浏览器访问麦克风。'),
            ),
            Expanded(child: _Conversation(messages: _messages)),
            if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
            _StatusOrb(state: _state, wakeWord: _wakeWord, onTap: _startListening),
            _VoiceActivityPanel(
              state: _state,
              detail: _activityDetail,
              transcript: _voice.transcript,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(children: [
                Expanded(child: TextField(controller: _questionController, onSubmitted: (_) => _ask(), decoration: const InputDecoration(hintText: '也可以打字问我…'))),
                IconButton(onPressed: _ask, icon: const Icon(Icons.send)),
              ]),
            ),
            ExpansionTile(title: const Text('服务器连接'), children: [
              Padding(padding: const EdgeInsets.all(16), child: TextField(controller: _endpointController, decoration: const InputDecoration(labelText: 'Gateway URL'))),
            ]),
          ]),
        ),
      );
}

class _VoiceActivityPanel extends StatelessWidget {
  const _VoiceActivityPanel({required this.state, required this.detail, required this.transcript});

  final AssistantState state;
  final String detail;
  final String transcript;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      AssistantState.idle => Theme.of(context).colorScheme.onSurfaceVariant,
      AssistantState.listening => Colors.green.shade800,
      AssistantState.thinking => Colors.orange.shade800,
      AssistantState.speaking => Colors.purple.shade800,
      AssistantState.error => Theme.of(context).colorScheme.error,
    };
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('语音状态', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(detail, style: TextStyle(color: color)),
            if (state == AssistantState.listening) ...[
              const SizedBox(height: 6),
              Text('实时转写：${transcript.isEmpty ? '等待声音输入…' : transcript}'),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusOrb extends StatelessWidget {
  const _StatusOrb({required this.state, required this.wakeWord, required this.onTap});
  final AssistantState state;
  final String wakeWord;
  final Future<void> Function()? onTap;

  @override
  Widget build(BuildContext context) {
    final labels = {AssistantState.idle: '点一下说话', AssistantState.listening: '点一下暂停', AssistantState.thinking: '让我想想', AssistantState.speaking: '我正在回答', AssistantState.error: '请再试一次'};
    final colors = {AssistantState.idle: Colors.indigo, AssistantState.listening: Colors.green, AssistantState.thinking: Colors.orange, AssistantState.speaking: Colors.purple, AssistantState.error: Colors.red};
    return InkWell(
      onTap: onTap == null ? null : () => unawaited(onTap!()),
      borderRadius: BorderRadius.circular(100),
      child: Container(
        width: 150,
        height: 150,
        alignment: Alignment.center,
        decoration: BoxDecoration(shape: BoxShape.circle, color: colors[state]!.withValues(alpha: .16), border: Border.all(color: colors[state]!, width: 4)),
        child: Padding(padding: const EdgeInsets.all(18), child: Text(labels[state]!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium)),
      ),
    );
  }
}

class _Conversation extends StatelessWidget {
  const _Conversation({required this.messages});
  final List<ChatMessage> messages;

  @override
  Widget build(BuildContext context) => ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: messages.length,
        itemBuilder: (context, index) {
          final item = messages[index];
          return Align(
            alignment: item.isAssistant ? Alignment.centerLeft : Alignment.centerRight,
            child: Card(color: item.isAssistant ? null : Theme.of(context).colorScheme.primaryContainer, child: Padding(padding: const EdgeInsets.all(12), child: Text(item.text))),
          );
        },
      );
}

class ChatMessage {
  const ChatMessage(this.text, this.isAssistant);
  final String text;
  final bool isAssistant;
  factory ChatMessage.child(String text) => ChatMessage(text, false);
  factory ChatMessage.assistant(String text) => ChatMessage(text, true);
  ChatMessage append(String value) => ChatMessage('$text$value', isAssistant);
}

class DeviceCredential {
  const DeviceCredential(this.deviceId, this.token);
  final String deviceId;
  final String token;
}

class VoiceConfig {
  const VoiceConfig(this.wakeWord);
  final String wakeWord;
  factory VoiceConfig.fromJson(Map<String, dynamic> json) => VoiceConfig(json['wakeWord'] as String);
}

class RealtimeCredential {
  const RealtimeCredential(this.url, this.token);
  final String url;
  final String token;
  factory RealtimeCredential.fromJson(Map<String, dynamic> json) => RealtimeCredential(json['url'] as String, json['token'] as String);
}

class GatewayClient {
  static const _storage = FlutterSecureStorage();

  Future<DeviceCredential?> loadCredential() async {
    final token = await _storage.read(key: 'device-token');
    final deviceId = await _storage.read(key: 'device-id');
    return token != null && deviceId != null ? DeviceCredential(deviceId, token) : null;
  }

  Future<DeviceCredential> pairLocalDevice(String endpoint, String adminSecret, String displayName, String platform) async {
    final base = endpoint.trim();
    final adminHeaders = {'Content-Type': 'application/json', 'X-Admin-Secret': adminSecret};
    final created = await http.post(
      Uri.parse('$base/v1/pairings'),
      headers: adminHeaders,
      body: jsonEncode({'displayName': displayName, 'platform': platform}),
    );
    if (created.statusCode != 201) throw StateError('无法创建配对请求（${created.statusCode}）');
    final pairing = jsonDecode(created.body) as Map<String, dynamic>;
    final pairingId = pairing['pairingId'] as String;
    final code = pairing['code'] as String;

    final approved = await http.post(
      Uri.parse('$base/v1/pairings/$pairingId/approve'),
      headers: adminHeaders,
      body: jsonEncode({'friendlyName': displayName}),
    );
    if (approved.statusCode != 200) throw StateError('家长批准失败（${approved.statusCode}）');

    final claimed = await http.post(
      Uri.parse('$base/v1/pairings/$pairingId/claim'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'code': code}),
    );
    if (claimed.statusCode != 200) throw StateError('设备领取凭证失败（${claimed.statusCode}）');
    final value = jsonDecode(claimed.body) as Map<String, dynamic>;
    final credential = DeviceCredential(value['deviceId'] as String, value['accessToken'] as String);
    await _storage.write(key: 'device-id', value: credential.deviceId);
    await _storage.write(key: 'device-token', value: credential.token);
    return credential;
  }

  Future<VoiceConfig> getConfiguration(String endpoint, String token) async {
    final response = await http.get(Uri.parse('${endpoint.trim()}/v1/config'), headers: {'Authorization': 'Bearer $token'});
    if (response.statusCode != 200) throw StateError('无法读取服务器配置。');
    return VoiceConfig.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<RealtimeCredential> getRealtimeToken(String endpoint, String token) async {
    final response = await http.post(Uri.parse('${endpoint.trim()}/v1/realtime/token'), headers: {'Authorization': 'Bearer $token'});
    if (response.statusCode != 200) throw StateError('无法建立语音连接。');
    return RealtimeCredential.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }
}

class VoiceSession {
  final Room _room = Room();
  EventsListener<RoomEvent>? _listener;
  Completer<void>? _agentReady;
  Completer<void>? _agentJoined;
  String? _agentIdentity;

  Future<void> connect(String url, String token, {required void Function(Map<String, dynamic>) onEvent}) async {
    _agentReady = Completer<void>();
    _agentJoined = Completer<void>();
    _agentIdentity = null;
    _listener = _room.createListener();
    _listener!.on<ParticipantConnectedEvent>((event) => _recordAgentIdentity(event.participant.identity));
    _listener!.on<DataReceivedEvent>((event) {
      if (event.topic != 'sts-chat-events') return;
      final value = jsonDecode(utf8.decode(event.data));
      if (value is! Map<String, dynamic>) return;
      if (value['type'] == 'agent_state' && value['state'] == 'idle' && !(_agentReady?.isCompleted ?? true)) {
        _agentReady!.complete();
      }
      onEvent(value);
    });
    await _room.connect(url, token);
    for (final participant in _room.remoteParticipants.values) {
      _recordAgentIdentity(participant.identity);
    }
    await _waitForAgentReady();
  }

  Future<void> sendTurn(String text) {
    final agentIdentity = _agentIdentity;
    if (agentIdentity == null) throw StateError('Voice agent is not connected.');
    return _publishEvent(
      {'type': 'turn.text', 'text': text},
      destinationIdentities: [agentIdentity],
    );
  }

  Future<void> _waitForAgentReady() async {
    final ready = _agentReady;
    final joined = _agentJoined;
    if (ready == null || joined == null) throw StateError('Voice session is not connected.');
    await joined.future.timeout(const Duration(seconds: 30));
    for (var attempt = 0; attempt < 15; attempt++) {
      await _publishEvent({'type': 'session.ready'}, destinationIdentities: [_agentIdentity!]);
      try {
        await ready.future.timeout(const Duration(seconds: 1));
        return;
      } on TimeoutException {
        // A dispatched Agent may still be initializing its room callback.
      }
    }
    throw TimeoutException('Voice agent did not become ready.');
  }

  void _recordAgentIdentity(String identity) {
    if (!identity.startsWith('agent-')) return;
    _agentIdentity ??= identity;
    if (!(_agentJoined?.isCompleted ?? true)) _agentJoined!.complete();
  }

  Future<void> _publishEvent(Map<String, Object> event, {List<String>? destinationIdentities}) => _room.localParticipant?.publishData(
        Uint8List.fromList(utf8.encode(jsonEncode(event))),
        reliable: true,
        destinationIdentities: destinationIdentities,
        topic: 'sts-chat-turns',
      ) ?? Future.value();

  Future<void> dispose() async {
    await _listener?.dispose();
    _agentReady = null;
    _agentJoined = null;
    _agentIdentity = null;
    await _room.disconnect();
  }
}
