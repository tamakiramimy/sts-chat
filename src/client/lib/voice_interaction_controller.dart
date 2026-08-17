import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

enum VoiceInteractionPhase { idle, listening, thinking, speaking, error, unavailable }

typedef FinalTranscriptHandler = Future<void> Function(String transcript);

abstract interface class SpeechRecognitionService {
  Future<bool> initialize({
    required void Function(String text, bool isFinal) onResult,
    required void Function(String message) onError,
    required VoidCallback onDone,
  });

  Future<void> start({String? localeId});
  Future<void> stop();
  Future<void> cancel();
  Future<void> dispose();
}

abstract interface class SpeechSynthesisService {
  Future<void> speak(String text, {required String language});
  Future<void> stop();
  Future<void> dispose();
}

class VoiceInteractionController extends ChangeNotifier {
  VoiceInteractionController({
    required FinalTranscriptHandler onFinalTranscript,
    SpeechRecognitionService? recognizer,
    SpeechSynthesisService? synthesizer,
  })  : _onFinalTranscript = onFinalTranscript,
        _recognizer = recognizer ?? createSpeechRecognitionService(),
        _synthesizer = synthesizer ?? FlutterTtsSpeechSynthesisService();

  final FinalTranscriptHandler _onFinalTranscript;
  final SpeechRecognitionService _recognizer;
  final SpeechSynthesisService _synthesizer;
  bool _initialized = false;
  bool _finalTranscriptSent = false;

  VoiceInteractionPhase _phase = VoiceInteractionPhase.idle;
  String _transcript = '';
  String? _errorMessage;

  VoiceInteractionPhase get phase => _phase;
  String get transcript => _transcript;
  String? get errorMessage => _errorMessage;
  bool get isListening => _phase == VoiceInteractionPhase.listening;

  Future<void> startListening() async {
    await _synthesizer.stop();
    _errorMessage = null;
    _transcript = '';
    _finalTranscriptSent = false;

    if (!_initialized) {
      final available = await _recognizer.initialize(
        onResult: _onRecognitionResult,
        onError: _onRecognitionError,
        onDone: _onRecognitionDone,
      );
      if (!available) {
        _setPhase(VoiceInteractionPhase.unavailable, '当前设备未提供语音识别服务。');
        return;
      }
      _initialized = true;
    }

    _setPhase(VoiceInteractionPhase.listening);
    try {
      await _recognizer.start(localeId: _preferredRecognitionLocale());
    } catch (_) {
      _setPhase(VoiceInteractionPhase.error, '无法启动语音识别，请检查麦克风和语音识别权限。');
    }
  }

  Future<void> stopListening() => _recognizer.stop();

  Future<void> cancelListening() async {
    await _recognizer.cancel();
    if (_phase == VoiceInteractionPhase.listening) _setPhase(VoiceInteractionPhase.idle);
  }

  Future<void> speakAnswer(String text) async {
    final answer = text.trim();
    if (answer.isEmpty) return;
    _setPhase(VoiceInteractionPhase.speaking);
    try {
      await _synthesizer.speak(answer, language: _speechLanguageFor(answer));
      if (_phase == VoiceInteractionPhase.speaking) _setPhase(VoiceInteractionPhase.idle);
    } catch (_) {
      _setPhase(VoiceInteractionPhase.error, '回答已生成，但无法通过扬声器播放。');
    }
  }

  Future<void> stopSpeaking() async {
    await _synthesizer.stop();
    if (_phase == VoiceInteractionPhase.speaking) _setPhase(VoiceInteractionPhase.idle);
  }

  void _onRecognitionResult(String text, bool isFinal) {
    _transcript = text;
    notifyListeners();
    if (isFinal && text.trim().isNotEmpty && !_finalTranscriptSent) {
      _finalTranscriptSent = true;
      unawaited(_submitFinalTranscript(text.trim()));
    }
  }

  Future<void> _submitFinalTranscript(String text) async {
    _setPhase(VoiceInteractionPhase.thinking);
    try {
      await _onFinalTranscript(text);
    } catch (_) {
      _setPhase(VoiceInteractionPhase.error, '语音已识别，但暂时无法发送问题。');
    }
  }

  void _onRecognitionError(String message) {
    if (_finalTranscriptSent) return;
    _setPhase(VoiceInteractionPhase.error, _displayRecognitionError(message));
  }

  void _onRecognitionDone() {
    if (_phase == VoiceInteractionPhase.listening) _setPhase(VoiceInteractionPhase.idle);
  }

  void _setPhase(VoiceInteractionPhase phase, [String? errorMessage]) {
    _phase = phase;
    _errorMessage = errorMessage;
    notifyListeners();
  }

  Future<void> close() async {
    await _recognizer.dispose();
    await _synthesizer.dispose();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

SpeechRecognitionService createSpeechRecognitionService() {
  if (defaultTargetPlatform == TargetPlatform.windows) return WindowsSpeechRecognitionService();
  return SpeechToTextRecognitionService();
}

class SpeechToTextRecognitionService implements SpeechRecognitionService {
  SpeechToTextRecognitionService({SpeechToText? speech}) : _speech = speech ?? SpeechToText();

  final SpeechToText _speech;
  void Function(String text, bool isFinal)? _onResult;
  void Function(String message)? _onError;
  VoidCallback? _onDone;

  @override
  Future<bool> initialize({
    required void Function(String text, bool isFinal) onResult,
    required void Function(String message) onError,
    required VoidCallback onDone,
  }) async {
    _onResult = onResult;
    _onError = onError;
    _onDone = onDone;
    return _speech.initialize(onError: _handleError, onStatus: _handleStatus);
  }

  @override
  Future<void> start({String? localeId}) => _speech.listen(
        onResult: _handleResult,
        listenOptions: SpeechListenOptions(
          cancelOnError: true,
          partialResults: true,
          listenFor: const Duration(seconds: 20),
          pauseFor: const Duration(seconds: 2),
          localeId: localeId,
        ),
      );

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();

  @override
  Future<void> dispose() => cancel();

  void _handleResult(SpeechRecognitionResult result) => _onResult?.call(result.recognizedWords, result.finalResult);

  void _handleError(SpeechRecognitionError error) => _onError?.call(error.errorMsg);

  void _handleStatus(String status) {
    if (status == 'done' || status == 'notListening') _onDone?.call();
  }
}

class WindowsSpeechRecognitionService implements SpeechRecognitionService {
  static const _methods = MethodChannel('sts_chat/speech_recognition');
  static const _events = EventChannel('sts_chat/speech_recognition/events');
  StreamSubscription<dynamic>? _subscription;
  void Function(String text, bool isFinal)? _onResult;
  void Function(String message)? _onError;
  VoidCallback? _onDone;

  @override
  Future<bool> initialize({
    required void Function(String text, bool isFinal) onResult,
    required void Function(String message) onError,
    required VoidCallback onDone,
  }) async {
    _onResult = onResult;
    _onError = onError;
    _onDone = onDone;
    _subscription ??= _events.receiveBroadcastStream().listen(_onEvent, onError: _onChannelError);
    return await _methods.invokeMethod<bool>('initialize') ?? false;
  }

  @override
  Future<void> start({String? localeId}) => _methods.invokeMethod<void>('start', {'localeId': localeId});

  @override
  Future<void> stop() => _methods.invokeMethod<void>('stop');

  @override
  Future<void> cancel() => _methods.invokeMethod<void>('cancel');

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    await cancel();
  }

  void _onEvent(dynamic event) {
    final value = Map<String, dynamic>.from(event as Map);
    switch (value['type']) {
      case 'result':
        _onResult?.call(value['text'] as String? ?? '', value['final'] as bool? ?? false);
      case 'error':
        _onError?.call(value['message'] as String? ?? 'Windows speech recognition failed.');
      case 'done':
        _onDone?.call();
    }
  }

  void _onChannelError(Object error, StackTrace stackTrace) => _onError?.call('Windows speech recognition is unavailable.');
}

class FlutterTtsSpeechSynthesisService implements SpeechSynthesisService {
  FlutterTtsSpeechSynthesisService({FlutterTts? tts}) : _tts = tts ?? FlutterTts() {
    _tts.setCompletionHandler(_completePlayback);
    _tts.setCancelHandler(_completePlayback);
    _tts.setErrorHandler((_) => _completePlayback(StateError('TTS playback failed.')));
  }

  final FlutterTts _tts;
  Completer<void>? _completion;

  @override
  Future<void> speak(String text, {required String language}) async {
    await stop();
    await _tts.awaitSpeakCompletion(true);
    await _tts.setLanguage(language);
    _completion = Completer<void>();
    final result = await _tts.speak(text);
    if (result != 1) throw StateError('Unable to start TTS playback.');
    await _completion!.future;
  }

  @override
  Future<void> stop() async {
    final completion = _completion;
    _completion = null;
    await _tts.stop();
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  @override
  Future<void> dispose() => stop();

  void _completePlayback([Object? error]) {
    final completion = _completion;
    if (completion == null || completion.isCompleted) return;
    if (error == null) {
      completion.complete();
    } else {
      completion.completeError(error);
    }
  }
}

String _preferredRecognitionLocale() => 'zh-CN';

String _speechLanguageFor(String text) => RegExp(r'[\u4e00-\u9fff]').hasMatch(text) ? 'zh-CN' : 'en-US';

String _displayRecognitionError(String message) {
  final normalized = message.toLowerCase();
  if (normalized.contains('permission') || normalized.contains('not authorized')) {
    return '请在系统设置中允许麦克风和语音识别权限。';
  }
  if (normalized.contains('network')) return '语音识别服务暂时不可用，请检查网络后重试。';
  return '没有听清楚，请再试一次。';
}