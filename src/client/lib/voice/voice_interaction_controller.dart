import 'dart:async';

enum SpeechRecognitionAvailability { ready, authorizationDenied, unavailable }

class SpeechRecognitionResult {
  const SpeechRecognitionResult({required this.transcript, required this.isFinal});

  final String transcript;
  final bool isFinal;
}

abstract interface class SpeechRecognizer {
  bool get isListening;

  Future<SpeechRecognitionAvailability> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
  });

  Future<void> start({required void Function(SpeechRecognitionResult result) onResult});

  Future<void> stop();

  Future<void> cancel();
}

abstract interface class SpeechSynthesizer {
  Future<void> initialize({
    required void Function() onStart,
    required void Function() onComplete,
    required void Function(String message) onError,
  });

  Future<void> speak(String text, {required String language});

  Future<void> stop();
}

enum VoiceInteractionState { idle, listening, thinking, speaking, error }

class VoiceInteractionSnapshot {
  const VoiceInteractionSnapshot(this.state, {this.error});

  final VoiceInteractionState state;
  final String? error;
}

class VoiceInteractionController {
  VoiceInteractionController({
    required SpeechRecognizer recognizer,
    required SpeechSynthesizer synthesizer,
    required Future<void> Function(String transcript) onFinalTranscript,
    required void Function(VoiceInteractionSnapshot snapshot) onStateChanged,
  })  : _recognizer = recognizer,
        _synthesizer = synthesizer,
        _onFinalTranscript = onFinalTranscript,
        _onStateChanged = onStateChanged;

  final SpeechRecognizer _recognizer;
  final SpeechSynthesizer _synthesizer;
  final Future<void> Function(String transcript) _onFinalTranscript;
  final void Function(VoiceInteractionSnapshot snapshot) _onStateChanged;

  bool _recognitionReady = false;
  bool _synthesisReady = false;
  bool _finalTranscriptSent = false;
  VoiceInteractionState _state = VoiceInteractionState.idle;

  bool get isListening => _state == VoiceInteractionState.listening;

  Future<void> initialize() async {
    await _initializeSynthesizer();
    await _initializeRecognizer();
  }

  Future<void> beginListening() async {
    if (!_recognitionReady) {
      await _initializeRecognizer();
    }
    if (!_recognitionReady) return;

    await cancelForNewTurn();
    _finalTranscriptSent = false;
    _publish(VoiceInteractionState.listening);
    try {
      await _recognizer.start(onResult: _handleRecognitionResult);
    } catch (error) {
      _publish(VoiceInteractionState.error, '无法开始语音识别：$error');
    }
  }

  Future<void> stopListening() async {
    if (!_recognizer.isListening) return;
    await _recognizer.stop();
    if (!_finalTranscriptSent) _publish(VoiceInteractionState.idle);
  }

  Future<void> speakAnswer(String answer, {required String language}) async {
    final text = answer.trim();
    if (text.isEmpty) return;
    if (!_synthesisReady) {
      await _initializeSynthesizer();
    }
    if (!_synthesisReady) return;

    if (_recognizer.isListening) await _recognizer.cancel();
    _publish(VoiceInteractionState.speaking);
    try {
      await _synthesizer.speak(text, language: language);
    } catch (error) {
      _publish(VoiceInteractionState.error, '语音播放失败：$error');
    }
  }

  Future<void> cancelForNewTurn() async {
    _finalTranscriptSent = true;
    if (_recognizer.isListening) await _recognizer.cancel();
    if (_synthesisReady) await _synthesizer.stop();
    if (_state == VoiceInteractionState.listening || _state == VoiceInteractionState.speaking) {
      _publish(VoiceInteractionState.idle);
    }
  }

  Future<void> handleInterrupt() => cancelForNewTurn();

  Future<void> _initializeRecognizer() async {
    try {
      final availability = await _recognizer.initialize(
        onError: (message) => _publish(VoiceInteractionState.error, '语音识别失败：$message'),
        onStatus: _handleRecognitionStatus,
      );
      _recognitionReady = availability == SpeechRecognitionAvailability.ready;
      switch (availability) {
        case SpeechRecognitionAvailability.ready:
          return;
        case SpeechRecognitionAvailability.authorizationDenied:
          _publish(VoiceInteractionState.error, '语音识别授权失败。请在系统设置中允许麦克风和语音识别权限。');
        case SpeechRecognitionAvailability.unavailable:
          _publish(VoiceInteractionState.error, '此设备的语音识别不可用。请检查系统语音识别服务。');
      }
    } catch (error) {
      _recognitionReady = false;
      _publish(VoiceInteractionState.error, '初始化语音识别失败：$error');
    }
  }

  Future<void> _initializeSynthesizer() async {
    if (_synthesisReady) return;
    try {
      await _synthesizer.initialize(
        onStart: () => _publish(VoiceInteractionState.speaking),
        onComplete: () {
          if (_state == VoiceInteractionState.speaking) _publish(VoiceInteractionState.idle);
        },
        onError: (message) => _publish(VoiceInteractionState.error, '语音播放失败：$message'),
      );
      _synthesisReady = true;
    } catch (error) {
      _publish(VoiceInteractionState.error, '初始化语音播放失败：$error');
    }
  }

  void _handleRecognitionResult(SpeechRecognitionResult result) {
    if (!result.isFinal || _finalTranscriptSent) return;
    final transcript = result.transcript.trim();
    if (transcript.isEmpty) return;

    _finalTranscriptSent = true;
    unawaited(_submitFinalTranscript(transcript));
  }

  Future<void> _submitFinalTranscript(String transcript) async {
    try {
      await _recognizer.stop();
      _publish(VoiceInteractionState.thinking);
      await _onFinalTranscript(transcript);
    } catch (error) {
      _publish(VoiceInteractionState.error, '无法发送语音问题：$error');
    }
  }

  void _handleRecognitionStatus(String status) {
    if ((status == 'done' || status == 'notListening') && _state == VoiceInteractionState.listening && !_finalTranscriptSent) {
      _publish(VoiceInteractionState.idle);
    }
  }

  void _publish(VoiceInteractionState state, [String? error]) {
    _state = state;
    _onStateChanged(VoiceInteractionSnapshot(state, error: error));
  }
}