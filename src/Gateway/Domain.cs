using Microsoft.EntityFrameworkCore;

namespace Gateway;

public sealed class GatewayDbContext(DbContextOptions<GatewayDbContext> options) : DbContext(options)
{
    public DbSet<Device> Devices => Set<Device>();
    public DbSet<Pairing> Pairings => Set<Pairing>();

    protected override void OnModelCreating(ModelBuilder builder)
    {
        builder.Entity<Device>().HasIndex(x => x.DeviceId).IsUnique();
        builder.Entity<Pairing>().HasIndex(x => x.Code).IsUnique();
    }
}

public sealed class Device
{
    public int Id { get; set; }
    public required string DeviceId { get; set; }
    public required string DisplayName { get; set; }
    public required string Platform { get; set; }
    public DateTimeOffset PairedAt { get; set; }
    public DateTimeOffset? RevokedAt { get; set; }
}

public sealed class Pairing
{
    public int Id { get; set; }
    public required string PairingId { get; set; }
    public required string Code { get; set; }
    public required string DisplayName { get; set; }
    public required string Platform { get; set; }
    public DateTimeOffset ExpiresAt { get; set; }
    public DateTimeOffset? ApprovedAt { get; set; }
    public DateTimeOffset? ClaimedAt { get; set; }
    public string? DeviceId { get; set; }
}

public sealed record CreatePairingRequest(string DisplayName, string Platform);
public sealed record ApprovePairingRequest(string? FriendlyName);
public sealed record ClaimPairingRequest(string Code);
public sealed record PairingResponse(string PairingId, string Code, DateTimeOffset ExpiresAt, bool Approved);
public sealed record DeviceCredentialResponse(string DeviceId, string AccessToken, DateTimeOffset ExpiresAt);
public sealed record DeviceResponse(string DeviceId, string DisplayName, string Platform, DateTimeOffset PairedAt, bool Revoked);
public sealed record RealtimeTokenResponse(string Url, string Room, string Token, DateTimeOffset ExpiresAt);
public sealed record PublicVoiceConfiguration(string WakeWord, string DefaultLanguage, string ChineseVoice, string EnglishVoice, int MaxConcurrentSessions);
public sealed record ComponentHealth(string Status, string Detail);
public sealed record SystemHealth(string Status, IReadOnlyDictionary<string, ComponentHealth> Components);
