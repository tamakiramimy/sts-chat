import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sts_chat_client/voice_interaction_controller.dart';

void main() {
  group('VoiceInteractionController', () {
    test('submits each final transcript once', () async {
      final recognizer = FakeRecognizer();
      final synthesizer = FakeSynthesizer();
      final submitted = <String>[];
      final controller = VoiceInteractionController(
        recognizer: recognizer,
        synthesizer: synthesizer,
        onFinalTranscript: (text) async => submitted.add(text),
      );

      await controller.startListening();
      recognizer.emitResult('今天天气怎么样', true);
      recognizer.emitResult('今天天气怎么样', true);
      await Future<void>.delayed(Duration.zero);

      expect(submitted, ['今天天气怎么样']);
      expect(controller.phase, VoiceInteractionPhase.thinking);
      await controller.close();
    });

    test('maps microphone permission errors to an actionable message', () async {
      final recognizer = FakeRecognizer();
      final controller = VoiceInteractionController(
        recognizer: recognizer,
        synthesizer: FakeSynthesizer(),
        onFinalTranscript: (_) async {},
      );

      await controller.startListening();
      recognizer.emitError('permission denied');

      expect(controller.phase, VoiceInteractionPhase.error);
      expect(controller.errorMessage, '请在系统设置中允许麦克风和语音识别权限。');
      await controller.close();
    });

    test('speaks Chinese answers and stops playback before a new turn', () async {
      final recognizer = FakeRecognizer();
      final synthesizer = FakeSynthesizer();
      final controller = VoiceInteractionController(
        recognizer: recognizer,
        synthesizer: synthesizer,
        onFinalTranscript: (_) async {},
      );

      await controller.speakAnswer('你好，我可以帮你解答问题。');
      await controller.startListening();

      expect(synthesizer.spoken, ['你好，我可以帮你解答问题。']);
      expect(synthesizer.languages, ['zh-CN']);
      expect(synthesizer.stopCalls, greaterThanOrEqualTo(1));
      expect(controller.phase, VoiceInteractionPhase.listening);
      await controller.close();
    });

    test('reports an unavailable recognizer without entering a fake listening state', () async {
      final controller = VoiceInteractionController(
        recognizer: FakeRecognizer(available: false),
        synthesizer: FakeSynthesizer(),
        onFinalTranscript: (_) async {},
      );

      await controller.startListening();

      expect(controller.phase, VoiceInteractionPhase.unavailable);
      expect(controller.errorMessage, '当前设备未提供语音识别服务。');
      await controller.close();
    });
  });
}

class FakeRecognizer implements SpeechRecognitionService {
  FakeRecognizer({this.available = true});

  final bool available;
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
    return available;
  }

  @override
  Future<void> start({String? localeId}) async {}

  @override
  Future<void> stop() async => _onDone?.call();

  @override
  Future<void> cancel() async => _onDone?.call();

  @override
  Future<void> dispose() async {}

  void emitResult(String text, bool isFinal) => _onResult?.call(text, isFinal);
  void emitError(String message) => _onError?.call(message);
}

class FakeSynthesizer implements SpeechSynthesisService {
  final spoken = <String>[];
  final languages = <String>[];
  int stopCalls = 0;

  @override
  Future<void> speak(String text, {required String language}) async {
    spoken.add(text);
    languages.add(language);
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> dispose() async {}
}