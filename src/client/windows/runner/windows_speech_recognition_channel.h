#ifndef RUNNER_WINDOWS_SPEECH_RECOGNITION_CHANNEL_H_
#define RUNNER_WINDOWS_SPEECH_RECOGNITION_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>

#include <memory>

class WindowsSpeechRecognitionChannel {
 public:
  explicit WindowsSpeechRecognitionChannel(flutter::BinaryMessenger* messenger);
  ~WindowsSpeechRecognitionChannel();

  WindowsSpeechRecognitionChannel(const WindowsSpeechRecognitionChannel&) = delete;
  WindowsSpeechRecognitionChannel& operator=(const WindowsSpeechRecognitionChannel&) = delete;

 private:
  using EncodableValue = flutter::EncodableValue;

  void HandleMethodCall(
      const flutter::MethodCall<EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result);
  bool InitializeRecognizer();
  void StartRecognition();
  void StopRecognition();
  void EmitResult(const std::string& text);
  void EmitError(const std::string& message);
  void EmitDone();

  std::unique_ptr<flutter::MethodChannel<EncodableValue>> method_channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> event_sink_;
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_WINDOWS_SPEECH_RECOGNITION_CHANNEL_H_