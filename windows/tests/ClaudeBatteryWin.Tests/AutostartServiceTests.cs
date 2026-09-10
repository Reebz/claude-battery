using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U11 launch-at-login tests: enabling writes the HKCU Run value with the canonical (quoted) exe
/// path; disabling removes it; the toggle reflects the value's presence; and a registry write
/// failure surfaces as the actual resulting state so the Settings toggle can snap back (the Mac
/// re-reads status on a thrown register/unregister).
///
/// The Run key is faked in-memory so the write/remove/read behavior is asserted without touching
/// the real HKCU hive, and the exe path is injected so the test does not depend on a Velopack
/// install layout.
/// </summary>
public sealed class AutostartServiceTests
{
    private sealed class FakeRunKey : IRunKey
    {
        public readonly Dictionary<string, string> Values = new();
        public bool ThrowOnWrite;
        public bool ThrowOnDelete;

        public object? GetValue(string name) => Values.TryGetValue(name, out var v) ? v : null;

        public void SetValue(string name, string value)
        {
            if (ThrowOnWrite)
            {
                throw new UnauthorizedAccessException("simulated registry write failure");
            }
            Values[name] = value;
        }

        public void DeleteValue(string name)
        {
            if (ThrowOnDelete)
            {
                throw new UnauthorizedAccessException("simulated registry delete failure");
            }
            Values.Remove(name);
        }
    }

    private const string CanonicalPath = @"C:\Users\u\AppData\Local\ClaudeBatteryWin\current\ClaudeBatteryWin.exe";

    private static AutostartService NewService(FakeRunKey key, string path = CanonicalPath)
        => new(key, () => path);

    [Fact]
    public void Enable_WritesRunValue_WithQuotedCanonicalPath()
    {
        var key = new FakeRunKey();
        var service = NewService(key);

        var enabled = service.SetEnabled(true);

        Assert.True(enabled);
        Assert.True(service.IsEnabled);
        Assert.True(key.Values.ContainsKey(AutostartService.RunValueName));
        // The path is quoted so a path with spaces parses as a single argv[0].
        Assert.Equal($"\"{CanonicalPath}\"", key.Values[AutostartService.RunValueName]);
    }

    [Fact]
    public void Disable_RemovesRunValue()
    {
        var key = new FakeRunKey();
        var service = NewService(key);
        service.SetEnabled(true);
        Assert.True(service.IsEnabled);

        var enabled = service.SetEnabled(false);

        Assert.False(enabled);
        Assert.False(service.IsEnabled);
        Assert.False(key.Values.ContainsKey(AutostartService.RunValueName));
    }

    [Fact]
    public void IsEnabled_ReflectsValuePresence()
    {
        var key = new FakeRunKey();
        var service = NewService(key);

        Assert.False(service.IsEnabled);
        key.Values[AutostartService.RunValueName] = $"\"{CanonicalPath}\"";
        Assert.True(service.IsEnabled);
    }

    [Fact]
    public void Enable_WhenAlreadyEnabled_IsIdempotent()
    {
        var key = new FakeRunKey();
        var service = NewService(key);

        service.SetEnabled(true);
        var second = service.SetEnabled(true);

        Assert.True(second);
        Assert.Single(key.Values);
        Assert.Equal($"\"{CanonicalPath}\"", key.Values[AutostartService.RunValueName]);
    }

    [Fact]
    public void Disable_WhenAlreadyDisabled_IsNoOp()
    {
        var key = new FakeRunKey();
        var service = NewService(key);

        var result = service.SetEnabled(false);

        Assert.False(result);
        Assert.Empty(key.Values);
    }

    [Fact]
    public void Enable_WriteFailure_ReportsActualState_NotRequested()
    {
        var key = new FakeRunKey { ThrowOnWrite = true };
        var service = NewService(key);

        // The write throws internally; SetEnabled swallows it and returns the actual state (still
        // disabled), so the Settings toggle snaps back rather than falsely showing "on".
        var enabled = service.SetEnabled(true);

        Assert.False(enabled);
        Assert.False(service.IsEnabled);
        Assert.Empty(key.Values);
    }

    [Fact]
    public void Disable_DeleteFailure_ReportsActualState_StillEnabled()
    {
        var key = new FakeRunKey();
        var service = NewService(key);
        service.SetEnabled(true);
        key.ThrowOnDelete = true;

        var enabled = service.SetEnabled(false);

        // Delete failed: the value is still there, so the reported state stays enabled.
        Assert.True(enabled);
        Assert.True(service.IsEnabled);
    }

    [Fact]
    public void CanonicalExePath_RewritesVersionedFolder_ToStableCurrent()
    {
        // A path inside a versioned "app-X.Y.Z" folder must be rewritten to the sibling "current"
        // launcher so the persisted Run value survives a Velopack update.
        var versioned = System.IO.Path.Combine(
            @"C:\Users\u\AppData\Local\ClaudeBatteryWin", "app-1.0.0", "ClaudeBatteryWin.exe");

        var key = new FakeRunKey();
        var service = new AutostartService(key, () => AutostartService.CanonicalExePathFor(versioned));
        service.SetEnabled(true);

        var expected = System.IO.Path.Combine(
            @"C:\Users\u\AppData\Local\ClaudeBatteryWin", "current", "ClaudeBatteryWin.exe");
        Assert.Equal($"\"{expected}\"", key.Values[AutostartService.RunValueName]);
    }

    [Fact]
    public void CanonicalExePath_NonVersionedPath_IsUnchanged()
    {
        Assert.Equal(CanonicalPath, AutostartService.CanonicalExePathFor(CanonicalPath));
    }
}
