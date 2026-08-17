namespace Gateway;

public sealed class HealthService(IHttpClientFactory clientFactory, IConfiguration configuration, ILogger<HealthService> logger)
{
    public async Task<SystemHealth> CheckAsync(CancellationToken cancellationToken)
    {
        var components = new Dictionary<string, ComponentHealth>
        {
            ["gateway"] = new("healthy", "running"),
            ["asr"] = new("client-owned", "Native device speech recognition"),
            ["tts"] = new("client-owned", "Native device speech synthesis"),
            ["cloudFallback"] = new(string.IsNullOrWhiteSpace(configuration["CLOUD_API_BASE_URL"]) ? "disabled" : "configured", "text-only fallback")
        };

        components["voiceAgent"] = await ProbeAsync(configuration["VoiceAgent:HealthUrl"], cancellationToken);
        components["livekit"] = await ProbeAsync(configuration["LiveKit:InternalUrl"], cancellationToken, acceptNotFound: true);
        components["llm"] = await ProbeAsync($"{configuration["Llm:LocalBaseUrl"]?.TrimEnd('/')}/models", cancellationToken);
        var status = components.Values.Any(x => x.Status == "unhealthy") ? "degraded" : "healthy";
        return new SystemHealth(status, components);
    }

    private async Task<ComponentHealth> ProbeAsync(string? url, CancellationToken cancellationToken, bool acceptNotFound = false)
    {
        if (string.IsNullOrWhiteSpace(url)) return new ComponentHealth("unknown", "not configured");
        try
        {
            var client = clientFactory.CreateClient("probe");
            using var response = await client.GetAsync(url, cancellationToken);
            var reachable = response.IsSuccessStatusCode || (acceptNotFound && response.StatusCode == System.Net.HttpStatusCode.NotFound);
            return new ComponentHealth(reachable ? "healthy" : "unhealthy", $"HTTP {(int)response.StatusCode}");
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException)
        {
            logger.LogWarning("Health probe to {Url} failed: {Message}", url, exception.Message);
            return new ComponentHealth("unhealthy", "unreachable");
        }
    }
}
