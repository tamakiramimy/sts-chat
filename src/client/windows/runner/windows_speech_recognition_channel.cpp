#include "windows_speech_recognition_channel.h"

#include <flutter/event_stream_handler.h>
#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.SpeechRecognition.h>

#include <utility>

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::EventSink;
using flutter::MethodCall;
using flutter::MethodResult;
using flutter::StreamHandler;
using flutter::StreamHandlerError;
using winrt::Windows::Media::SpeechRecognition::SpeechRecognitionResultStatus;
using winrt::Windows::Media::SpeechRecognition::SpeechRecognitionScenario;
using winrt::Windows::Media::SpeechRecognition::SpeechRecognitionTopicConstraint;
using winrt::Windows::Media::SpeechRecognition::SpeechRecognizer;

namespace {

class SpeechRecognitionStreamHandler final : public StreamHandler<EncodableValue> {
 public:
  explicit SpeechRecognitionStreamHandler(
      std::unique_ptr<EventSink<EncodableValue>>* event_sink)
      : event_sink_(event_sink) {}

 protected:
  std::unique_ptr<StreamHandlerError<EncodableValue>> OnListenInternal(
      const EncodableValue*,
      std::unique_ptr<EventSink<EncodableValue>>&& events) override {
    *event_sink_ = std::move(events);
    return nullptr;
  }

  std::unique_ptr<StreamHandlerError<EncodableValue>> OnCancelInternal(
      const EncodableValue*) override {
    event_sink_->reset();
    return nullptr;
  }

 private:
  std::unique_ptr<EventSink<EncodableValue>>* event_sink_;
};

}  // namespace

struct WindowsSpeechRecognitionChannel::Impl {
  SpeechRecognizer recognizer{nullptr};
  bool initialized = false;
};

WindowsSpeechRecognitionChannel::WindowsSpeechRecognitionChannel(
    flutter::BinaryMessenger* messenger)
    : impl_(std::make_unique<Impl>()) {
  method_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "sts_chat/speech_recognition",
      &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [this](const MethodCall<EncodableValue>& call,
             std::unique_ptr<MethodResult<EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });

  event_channel_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger, "sts_chat/speech_recognition/events",
      &flutter::StandardMethodCodec::GetInstance());
  event_channel_->SetStreamHandler(
      std::make_unique<SpeechRecognitionStreamHandler>(&event_sink_));
}

WindowsSpeechRecognitionChannel::~WindowsSpeechRecognitionChannel() {
  StopRecognition();
  event_channel_->SetStreamHandler(nullptr);
}

void WindowsSpeechRecognitionChannel::HandleMethodCall(
    const MethodCall<EncodableValue>& call,
    std::unique_ptr<MethodResult<EncodableValue>> result) {
  if (call.method_name() == "initialize") {
    result->Success(EncodableValue(InitializeRecognizer()));
    return;
  }
  if (call.method_name() == "start") {
    if (!InitializeRecognizer()) {
      result->Error("unavailable", "Windows speech recognition is unavailable.");
      return;
    }
    StartRecognition();
    result->Success();
    return;
  }
  if (call.method_name() == "stop" || call.method_name() == "cancel") {
    StopRecognition();
    result->Success();
    return;
  }
  result->NotImplemented();
}

bool WindowsSpeechRecognitionChannel::InitializeRecognizer() {
  if (impl_->initialized) return true;
  try {
    impl_->recognizer = SpeechRecognizer();
    impl_->recognizer.Constraints().Append(SpeechRecognitionTopicConstraint(
        SpeechRecognitionScenario::Dictation, L"sts-chat-dictation"));
    impl_->initialized = true;
    return true;
  } catch (const winrt::hresult_error&) {
    impl_->recognizer = nullptr;
    return false;
  }
}

void WindowsSpeechRecognitionChannel::StartRecognition() {
  auto recognize = [this]() -> winrt::fire_and_forget {
    try {
      const auto compilation = co_await impl_->recognizer.CompileConstraintsAsync();
      if (compilation.Status() != SpeechRecognitionResultStatus::Success) {
        EmitError("Windows could not prepare speech recognition.");
        EmitDone();
        co_return;
      }

      const auto recognition = co_await impl_->recognizer.RecognizeAsync();
      if (recognition.Status() == SpeechRecognitionResultStatus::Success) {
        EmitResult(winrt::to_string(recognition.Text()));
      } else {
        EmitError("Windows speech recognition did not return a result.");
      }
    } catch (const winrt::hresult_error&) {
      EmitError("Windows speech recognition failed.");
    }
    EmitDone();
  };
  recognize();
}

void WindowsSpeechRecognitionChannel::StopRecognition() {
  if (impl_->recognizer) {
    impl_->recognizer.Close();
    impl_->recognizer = nullptr;
    impl_->initialized = false;
  }
}

void WindowsSpeechRecognitionChannel::EmitResult(const std::string& text) {
  if (!event_sink_) return;
  EncodableMap event;
  event[EncodableValue("type")] = EncodableValue("result");
  event[EncodableValue("text")] = EncodableValue(text);
  event[EncodableValue("final")] = EncodableValue(true);
  event_sink_->Success(EncodableValue(event));
}

void WindowsSpeechRecognitionChannel::EmitError(const std::string& message) {
  if (!event_sink_) return;
  EncodableMap event;
  event[EncodableValue("type")] = EncodableValue("error");
  event[EncodableValue("message")] = EncodableValue(message);
  event_sink_->Success(EncodableValue(event));
}

void WindowsSpeechRecognitionChannel::EmitDone() {
  if (!event_sink_) return;
  EncodableMap event;
  event[EncodableValue("type")] = EncodableValue("done");
  event_sink_->Success(EncodableValue(event));
}