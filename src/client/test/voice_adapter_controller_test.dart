import 'package:flutter_test/flutter_test.dart';
import 'package:sts_chat_client/voice/voice_interaction_controller.dart';

void main() {
  group('VoiceInteractionController', () {
    test('dispatches one final recognition result through the existing turn callback', () async {
      final recognizer = FakeSpeechRecognizer();
      final synthesizer = FakeSpeechSynthesizer();
      final transcripts = <String>[];
      final states = <VoiceInteractionSnapshot>[];
      final controller = VoiceInteractionController(
        recognizer: recognizer,
        synthesizer: synthesizer,
        onFinalTranscript: (text) async => transcripts.add(text),
        onStateChanged: states.add,
      );

      await controller.beginListening();
      recognizer.emit('partial answer', isFinal: false);
      recognizer.emit('final answer', isFinal: true);
      recognizer.emit('duplicate final answer', isFinal: true);
      await flushMicrotasks();

      expect(transcripts, ['final answer']);
      expect(recognizer.stopCalls, 1);
      expect(states.last.state, VoiceInteractionState.thinking);
    });

    test('speaks completed answers and cancels speaking before a new turn', () async {
      final recognizer = FakeSpeechRecognizer();
      final synthesizer = FakeSpeechSynthesizer();
      final states = <VoiceInteractionSnapshot>[];
      final controller = VoiceInteractionController(
        recognizer: recognizer,
        synthesizer: synthesizer,
        onFinalTranscript: (_) async {},
        onStateChanged: states.add,
      );

      await controller.speakAnswer('Hello from the assistant', language: 'en-US');
      expect(synthesizer.spoken, [('Hello from the assistant', 'en-US')]);
      expect(states.last.state, VoiceInteractionState.speaking);

      await controller.beginListening();

      expect(synthesizer.stopCalls, 1);
      expect(states.last.state, VoiceInteractionState.listening);
    });

    test('reports authorization and TTS failures without platform hardware', () async {
      final deniedRecognizer = FakeSpeechRecognizer(availability: SpeechRecognitionAvailability.authorizationDenied);
      final synthesizer = FakeSpeechSynthesizer(throwWhenSpeaking: true);
      final states = <VoiceInteractionSnapshot>[];
      final controller = VoiceInteractionController(
        recognizer: deniedRecognizer,
        synthesizer: synthesizer,
        onFinalTranscript: (_) async {},
        onStateChanged: states.add,
      );

      await controller.beginListening();
      expect(states.last.state, VoiceInteractionState.error);
      expect(states.last.error, contains('授权失败'));

      await controller.speakAnswer('测试播放', language: 'zh-CN');
      expect(states.last.state, VoiceInteractionState.error);
      expect(states.last.error, contains('语音播放失败'));
    });
  });
}

Future<void> flushMicrotasks() => Future<void>.delayed(Duration.zero);

class FakeSpeechRecognizer implements SpeechRecognizer {
  FakeSpeechRecognizer({this.availability = SpeechRecognitionAvailability.ready});

  final SpeechRecognitionAvailability availability;
  void Function(SpeechRecognitionResult result)? _onResult;
  @override
  bool isListening = false;
  int stopCalls = 0;

  @override
  Future<void> cancel() async {
    isListening = false;
  }

  void emit(String text, {required bool isFinal}) {
    _onResult?.call(SpeechRecognitionResult(transcript: text, isFinal: isFinal));
  }

  @override
  Future<SpeechRecognitionAvailability> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  }) async => availability;

  @override
  Future<void> start({required void Function(SpeechRecognitionResult result) onResult}) async {
    _onResult = onResult;
    isListening = true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    isListening = false;
  }
}

class FakeSpeechSynthesizer implements SpeechSynthesizer {
  FakeSpeechSynthesizer({this.throwWhenSpeaking = false});

  final bool throwWhenSpeaking;
  final spoken = <(String, String)>[];
  int stopCalls = 0;
  void Function()? _onStart;

  @override
  Future<void> initialize({
    required void Function() onStart,
    required void Function() onComplete,
    required void Function(String message) onError,
  }) async {
    _onStart = onStart;
  }

  @override
  Future<void> speak(String text, {required String language}) async {
    _onStart?.call();
    if (throwWhenSpeaking) throw StateError('speaker unavailable');
    spoken.add((text, language));
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}