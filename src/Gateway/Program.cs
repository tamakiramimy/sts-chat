using System.Net;
using System.Security.Claims;
using Gateway;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);
var tokenService = new TokenService(builder.Configuration);

builder.Services.Configure<LiveKitOptions>(builder.Configuration.GetSection("LiveKit"));
builder.Services.Configure<LlmOptions>(builder.Configuration.GetSection("Llm"));
builder.Services.Configure<VoiceOptions>(builder.Configuration.GetSection("Voice"));
builder.Services.AddDbContext<GatewayDbContext>(options =>
    options.UseSqlite(builder.Configuration.GetConnectionString("Gateway") ?? "Data Source=data/gateway.db"));
builder.Services.AddSingleton(tokenService);
builder.Services.AddHttpClient("probe", client => client.Timeout = TimeSpan.FromSeconds(2));
builder.Services.AddHttpClient("livekit", client => client.Timeout = TimeSpan.FromSeconds(4));
builder.Services.AddScoped<HealthService>();
builder.Services.AddScoped<LiveKitDispatchService>();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();
var allowedOrigins = (builder.Configuration["CORS_ALLOWED_ORIGINS"] ?? "")
    .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
builder.Services.AddCors(options => options.AddPolicy("Client", policy =>
{
    if (allowedOrigins.Length > 0)
        policy.WithOrigins(allowedOrigins).AllowAnyHeader().AllowAnyMethod();
}));

builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = "sts-chat-gateway",
            ValidateAudience = true,
            ValidAudience = "sts-chat-clients",
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            IssuerSigningKey = tokenService.SigningKey,
            ClockSkew = TimeSpan.FromMinutes(1)
        };
        options.Events = new JwtBearerEvents
        {
            OnTokenValidated = async context =>
            {
                var deviceId = context.Principal?.FindFirstValue("device_id");
                var db = context.HttpContext.RequestServices.GetRequiredService<GatewayDbContext>();
                if (string.IsNullOrWhiteSpace(deviceId) || !await db.Devices.AnyAsync(x => x.DeviceId == deviceId && x.RevokedAt == null, context.HttpContext.RequestAborted))
                    context.Fail("The device is revoked or unknown.");
            }
        };
    });
builder.Services.AddAuthorization();

var app = builder.Build();
await using (var scope = app.Services.CreateAsyncScope())
{
    var db = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
    await db.Database.EnsureCreatedAsync();
}

app.UseHttpsRedirection();
app.UseCors("Client");
app.UseAuthentication();
app.UseAuthorization();
app.UseSwagger();
app.UseSwaggerUI();

app.MapGet("/", (HttpRequest request, IConfiguration configuration) =>
{
    var hostName = request.Host.Host;
    var h5Url = configuration["Client:PublicUrl"]
        ?? $"{request.Scheme}://{hostName}:3000";
    var liveKitUrl = configuration["LiveKit:PublicUrl"]
        ?? configuration["LIVEKIT_URL"]
        ?? $"ws://{hostName}:7880";

    var html = $$"""
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>sts-chat</title>
          <style>
            :root { color-scheme: light dark; font-family: system-ui, -apple-system, sans-serif; }
            body { max-width: 720px; margin: 64px auto; padding: 0 24px; line-height: 1.6; }
            .card { padding: 24px; border: 1px solid #8885; border-radius: 16px; }
            a { display: inline-block; margin: 6px 16px 6px 0; }
            code { padding: 2px 6px; border-radius: 6px; background: #8882; word-break: break-all; }
          </style>
        </head>
        <body>
          <main class="card">
            <h1>sts-chat</h1>
            <p>Gateway 正在运行。</p>
            <p>
              <a href="{{WebUtility.HtmlEncode(h5Url)}}">打开 H5 客户端</a>
              <a href="/health">查看健康状态</a>
              <a href="/swagger">打开 API 文档</a>
            </p>
            <p>LiveKit 地址：<code>{{WebUtility.HtmlEncode(liveKitUrl)}}</code></p>
            <p><small>LiveKit 是 WebSocket/WebRTC 服务，需要由客户端 SDK 连接，不能作为普通网页打开。</small></p>
          </main>
        </body>
        </html>
        """;

    return Results.Content(html, "text/html; charset=utf-8");
}).AllowAnonymous().ExcludeFromDescription();

app.MapGet("/health", async (HealthService health, CancellationToken cancellationToken) =>
    Results.Ok(await health.CheckAsync(cancellationToken))).AllowAnonymous();

app.MapPost("/v1/pairings", async (CreatePairingRequest request, GatewayDbContext db, HttpContext context, IConfiguration configuration, CancellationToken cancellationToken) =>
{
    if (AdminAuthorization.Validate(context, configuration) is { } failure) return failure;
    if (string.IsNullOrWhiteSpace(request.DisplayName) || string.IsNullOrWhiteSpace(request.Platform))
        return Results.ValidationProblem(new Dictionary<string, string[]> { ["request"] = ["DisplayName and Platform are required."] });

    var pairing = new Pairing
    {
        PairingId = Guid.NewGuid().ToString("N"),
        Code = Random.Shared.Next(0, 1_000_000).ToString("D6"),
        DisplayName = request.DisplayName.Trim(),
        Platform = request.Platform.Trim().ToLowerInvariant(),
        ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(10)
    };
    db.Pairings.Add(pairing);
    await db.SaveChangesAsync(cancellationToken);
    return Results.Created($"/v1/pairings/{pairing.PairingId}", new PairingResponse(pairing.PairingId, pairing.Code, pairing.ExpiresAt, false));
});

app.MapPost("/v1/pairings/{pairingId}/approve", async (string pairingId, ApprovePairingRequest request, GatewayDbContext db, HttpContext context, IConfiguration configuration, CancellationToken cancellationToken) =>
{
    if (AdminAuthorization.Validate(context, configuration) is { } failure) return failure;
    var pairing = await db.Pairings.SingleOrDefaultAsync(x => x.PairingId == pairingId, cancellationToken);
    if (pairing is null || pairing.ExpiresAt <= DateTimeOffset.UtcNow) return Results.NotFound();
    pairing.ApprovedAt ??= DateTimeOffset.UtcNow;
    if (!string.IsNullOrWhiteSpace(request.FriendlyName)) pairing.DisplayName = request.FriendlyName.Trim();
    await db.SaveChangesAsync(cancellationToken);
    return Results.Ok(new PairingResponse(pairing.PairingId, pairing.Code, pairing.ExpiresAt, true));
});

app.MapPost("/v1/pairings/{pairingId}/claim", async (string pairingId, ClaimPairingRequest request, GatewayDbContext db, TokenService tokens, CancellationToken cancellationToken) =>
{
    var pairing = await db.Pairings.SingleOrDefaultAsync(x => x.PairingId == pairingId, cancellationToken);
    if (pairing is null || pairing.ExpiresAt <= DateTimeOffset.UtcNow || pairing.ApprovedAt is null || pairing.ClaimedAt is not null || request.Code != pairing.Code)
        return Results.Unauthorized();

    var deviceId = Guid.NewGuid().ToString("N");
    db.Devices.Add(new Device { DeviceId = deviceId, DisplayName = pairing.DisplayName, Platform = pairing.Platform, PairedAt = DateTimeOffset.UtcNow });
    pairing.DeviceId = deviceId;
    pairing.ClaimedAt = DateTimeOffset.UtcNow;
    await db.SaveChangesAsync(cancellationToken);
    return Results.Ok(tokens.IssueDeviceToken(deviceId));
});

var deviceApi = app.MapGroup("/v1").RequireAuthorization();
deviceApi.MapGet("/config", (IConfiguration configuration) => Results.Ok(new PublicVoiceConfiguration(
    configuration["DEFAULT_WAKE_WORD"] ?? configuration["Voice:WakeWord"] ?? "sts-chat",
    configuration["Voice:DefaultLanguage"] ?? "auto",
    configuration["Voice:ChineseVoice"] ?? "zh_CN-huayan-medium",
    configuration["Voice:EnglishVoice"] ?? "en_US-lessac-medium",
    1)));

deviceApi.MapPost("/realtime/token", async (ClaimsPrincipal principal, TokenService tokens, IConfiguration configuration, LiveKitDispatchService dispatch, CancellationToken cancellationToken) =>
{
    var deviceId = principal.FindFirstValue("device_id");
    if (string.IsNullOrWhiteSpace(deviceId)) return Results.Unauthorized();
    try
    {
        var credential = tokens.IssueLiveKitToken(deviceId, configuration["LiveKit:PublicUrl"] ?? configuration["LIVEKIT_URL"] ?? "");
        await dispatch.EnsureAgentDispatchAsync(credential.Room, cancellationToken);
        return Results.Ok(credential);
    }
    catch (InvalidOperationException exception)
    {
        return Results.Problem(exception.Message, statusCode: StatusCodes.Status503ServiceUnavailable);
    }
    catch (HttpRequestException)
    {
        return Results.Problem("LiveKit room or agent dispatch is unavailable.", statusCode: StatusCodes.Status503ServiceUnavailable);
    }
});

var adminApi = app.MapGroup("/v1/admin");
adminApi.MapGet("/devices", async (GatewayDbContext db, HttpContext context, IConfiguration configuration, CancellationToken cancellationToken) =>
{
    if (AdminAuthorization.Validate(context, configuration) is { } failure) return failure;
    var devices = await db.Devices.OrderByDescending(x => x.PairedAt).Select(x => new DeviceResponse(x.DeviceId, x.DisplayName, x.Platform, x.PairedAt, x.RevokedAt != null)).ToListAsync(cancellationToken);
    return Results.Ok(devices);
});
adminApi.MapDelete("/devices/{deviceId}", async (string deviceId, GatewayDbContext db, HttpContext context, IConfiguration configuration, CancellationToken cancellationToken) =>
{
    if (AdminAuthorization.Validate(context, configuration) is { } failure) return failure;
    var device = await db.Devices.SingleOrDefaultAsync(x => x.DeviceId == deviceId, cancellationToken);
    if (device is null) return Results.NotFound();
    device.RevokedAt = DateTimeOffset.UtcNow;
    await db.SaveChangesAsync(cancellationToken);
    return Results.NoContent();
});

app.Run();

public partial class Program;
