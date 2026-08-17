using Gateway;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Gateway.Tests;

public sealed class GatewayApiFactory : WebApplicationFactory<Program>
{
    private readonly InMemoryDatabaseRoot _databaseRoot = new();

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.UseSetting("ADMIN_SETUP_SECRET", "test-parent-secret");
        builder.UseSetting("JWT_SECRET", "test-jwt-secret-that-is-long-enough-for-hmac");
        builder.UseSetting("LIVEKIT_API_KEY", "test-key");
        builder.UseSetting("LIVEKIT_API_SECRET", "test-livekit-secret");
        builder.ConfigureServices(services =>
        {
            services.RemoveAll<DbContextOptions<GatewayDbContext>>();
            services.AddDbContext<GatewayDbContext>(options =>
                options.UseInMemoryDatabase("gateway-tests", _databaseRoot));
        });
    }
}
