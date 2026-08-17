using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using Microsoft.IdentityModel.Tokens;

namespace Gateway;

public sealed class TokenService(IConfiguration configuration)
{
    private readonly byte[] _jwtKey = Encoding.UTF8.GetBytes(configuration["JWT_SECRET"] ?? Convert.ToBase64String(RandomNumberGenerator.GetBytes(48)));
    private const string Issuer = "sts-chat-gateway";

    public SymmetricSecurityKey SigningKey => new(_jwtKey);

    public DeviceCredentialResponse IssueDeviceToken(string deviceId)
    {
        var expiresAt = DateTimeOffset.UtcNow.AddDays(30);
        var descriptor = new SecurityTokenDescriptor
        {
            Subject = new ClaimsIdentity([new Claim("device_id", deviceId)]),
            Expires = expiresAt.UtcDateTime,
            Issuer = Issuer,
            Audience = "sts-chat-clients",
            SigningCredentials = new SigningCredentials(SigningKey, SecurityAlgorithms.HmacSha256)
        };
        var handler = new JwtSecurityTokenHandler();
        return new DeviceCredentialResponse(deviceId, handler.WriteToken(handler.CreateToken(descriptor)), expiresAt);
    }

    public RealtimeTokenResponse IssueLiveKitToken(string deviceId, string publicUrl)
    {
        var apiKey = Require("LIVEKIT_API_KEY");
        var apiSecret = Require("LIVEKIT_API_SECRET");
        var room = $"voice-{deviceId}";
        var now = DateTimeOffset.UtcNow;
        var expiresAt = now.AddMinutes(10);
        var header = Base64Url("{\"alg\":\"HS256\",\"typ\":\"JWT\"}");
        var payload = Base64Url($"{{\"iss\":\"{apiKey}\",\"sub\":\"{deviceId}\",\"nbf\":{now.ToUnixTimeSeconds()},\"exp\":{expiresAt.ToUnixTimeSeconds()},\"video\":{{\"roomJoin\":true,\"room\":\"{room}\",\"canPublish\":true,\"canSubscribe\":true,\"canPublishData\":true}}}}");
        using var signer = new HMACSHA256(Encoding.UTF8.GetBytes(apiSecret));
        var signature = Base64Url(signer.ComputeHash(Encoding.UTF8.GetBytes($"{header}.{payload}")));
        return new RealtimeTokenResponse(publicUrl, room, $"{header}.{payload}.{signature}", expiresAt);
    }

    public string IssueLiveKitServiceToken(string room)
    {
        var apiKey = Require("LIVEKIT_API_KEY");
        var apiSecret = Require("LIVEKIT_API_SECRET");
        var now = DateTimeOffset.UtcNow;
        var header = Base64Url("{\"alg\":\"HS256\",\"typ\":\"JWT\"}");
        var payload = Base64Url($"{{\"iss\":\"{apiKey}\",\"sub\":\"gateway\",\"nbf\":{now.ToUnixTimeSeconds()},\"exp\":{now.AddMinutes(2).ToUnixTimeSeconds()},\"video\":{{\"roomCreate\":true,\"roomAdmin\":true,\"room\":\"{room}\"}}}}");
        using var signer = new HMACSHA256(Encoding.UTF8.GetBytes(apiSecret));
        return $"{header}.{payload}.{Base64Url(signer.ComputeHash(Encoding.UTF8.GetBytes($"{header}.{payload}")))}";
    }

    private string Require(string key) => configuration[key] is { Length: > 0 } value
        ? value
        : throw new InvalidOperationException($"Missing required environment variable {key}.");

    private static string Base64Url(string value) => Base64Url(Encoding.UTF8.GetBytes(value));
    private static string Base64Url(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}

public static class AdminAuthorization
{
    public static IResult? Validate(HttpContext context, IConfiguration configuration)
    {
        var expected = configuration["ADMIN_SETUP_SECRET"];
        if (string.IsNullOrWhiteSpace(expected))
            return Results.Problem("ADMIN_SETUP_SECRET is not configured.", statusCode: StatusCodes.Status503ServiceUnavailable);

        if (!context.Request.Headers.TryGetValue("X-Admin-Secret", out var supplied) ||
            !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(expected), Encoding.UTF8.GetBytes(supplied.ToString())))
            return Results.Unauthorized();

        return null;
    }
}
