using System.Net;
using System.Net.Http.Json;
using Gateway;

namespace Gateway.Tests;

public sealed class GatewayApiTests(GatewayApiFactory factory) : IClassFixture<GatewayApiFactory>
{
    [Fact]
    public async Task Root_returns_service_landing_page()
    {
        var response = await factory.CreateClient().GetAsync("/");
        var content = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("text/html", response.Content.Headers.ContentType?.MediaType);
        Assert.Contains("Gateway 正在运行", content);
        Assert.Contains("/health", content);
        Assert.Contains("/swagger", content);
        Assert.Contains("LiveKit 地址", content);
        Assert.Contains("ws://localhost:7880", content);
    }

    [Fact]
    public async Task Health_is_public_and_reports_gateway()
    {
        var response = await factory.CreateClient().GetAsync("/health");
        var health = await response.Content.ReadFromJsonAsync<SystemHealth>();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("healthy", health!.Components["gateway"].Status);
        Assert.Equal("client-owned", health.Components["asr"].Status);
        Assert.Equal("client-owned", health.Components["tts"].Status);
        Assert.Contains("voiceAgent", health.Components.Keys);
    }

    [Fact]
    public async Task Approved_pairing_can_be_claimed_and_used_for_configuration()
    {
        var client = factory.CreateClient();
        client.DefaultRequestHeaders.Add("X-Admin-Secret", "test-parent-secret");
        var created = await client.PostAsJsonAsync("/v1/pairings", new CreatePairingRequest("Test iPad", "ios"));
        var pairing = await created.Content.ReadFromJsonAsync<PairingResponse>();
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);

        var approved = await client.PostAsJsonAsync($"/v1/pairings/{pairing!.PairingId}/approve", new ApprovePairingRequest(null));
        Assert.Equal(HttpStatusCode.OK, approved.StatusCode);

        client.DefaultRequestHeaders.Remove("X-Admin-Secret");
        var claimed = await client.PostAsJsonAsync($"/v1/pairings/{pairing.PairingId}/claim", new ClaimPairingRequest(pairing.Code));
        var credential = await claimed.Content.ReadFromJsonAsync<DeviceCredentialResponse>();
        Assert.Equal(HttpStatusCode.OK, claimed.StatusCode);

        client.DefaultRequestHeaders.Authorization = new("Bearer", credential!.AccessToken);
        var config = await client.GetAsync("/v1/config");
        Assert.Equal(HttpStatusCode.OK, config.StatusCode);
    }
}
