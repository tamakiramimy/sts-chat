using System.Net.Http.Headers;
using System.Net.Http.Json;

namespace Gateway;

/// <summary>Creates a private room and assigns its one voice agent before a client joins.</summary>
public sealed class LiveKitDispatchService(IHttpClientFactory clients, TokenService tokens, IConfiguration configuration)
{
    public async Task EnsureAgentDispatchAsync(string room, CancellationToken cancellationToken)
    {
        var baseUrl = (configuration["LiveKit:InternalUrl"] ?? "http://livekit:7880").TrimEnd('/');
        var client = clients.CreateClient("livekit");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", tokens.IssueLiveKitServiceToken(room));

        // CreateRoom is idempotent for the requested name; an already existing room
        // returns a conflict, which is safe because the client is reconnecting.
        using var roomResponse = await client.PostAsJsonAsync($"{baseUrl}/twirp/livekit.RoomService/CreateRoom", new { name = room, emptyTimeout = 300 }, cancellationToken);
        if (!roomResponse.IsSuccessStatusCode && roomResponse.StatusCode != System.Net.HttpStatusCode.Conflict)
            roomResponse.EnsureSuccessStatusCode();

        using var dispatchResponse = await client.PostAsJsonAsync($"{baseUrl}/twirp/livekit.AgentDispatchService/CreateDispatch", new { agentName = "sts-chat-agent", room }, cancellationToken);
        if (!dispatchResponse.IsSuccessStatusCode && dispatchResponse.StatusCode != System.Net.HttpStatusCode.Conflict)
            dispatchResponse.EnsureSuccessStatusCode();
    }
}
