namespace Gateway;

public sealed class LiveKitOptions
{
    public string PublicUrl { get; init; } = "";
    public string InternalUrl { get; init; } = "http://livekit:7880";
}

public sealed class LlmOptions
{
    public string LocalBaseUrl { get; init; } = "http://llama:8080/v1";
}

public sealed class VoiceOptions
{
    public string WakeWord { get; init; } = "sts-chat";
    public string DefaultLanguage { get; init; } = "auto";
    public string ChineseVoice { get; init; } = "zh_CN-huayan-medium";
    public string EnglishVoice { get; init; } = "en_US-lessac-medium";
}
