using System.IO;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U5 secret-storage tests. DPAPI <see cref="System.Security.Cryptography.ProtectedData"/> is a
/// real Windows API; these run on the CI Windows host (the suite never runs on macOS). They prove
/// the round-trip recovers the exact secret and that a corrupted blob is reported as a decrypt
/// failure (not an exception), which is what lets the AccountStore drop-and-reauth instead of
/// crashing.
/// </summary>
public sealed class SecretStoreTests : IDisposable
{
    private readonly string _dir;
    private readonly SecretStore _store;

    public SecretStoreTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "cbw-secret-tests", Guid.NewGuid().ToString("N"));
        _store = new SecretStore(_dir);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_dir))
            {
                Directory.Delete(_dir, recursive: true);
            }
            else if (File.Exists(_dir))
            {
                // The save-failure test occupies the directory path with a FILE.
                File.Delete(_dir);
            }
        }
        catch (IOException)
        {
            // Best-effort temp cleanup.
        }
    }

    [Fact]
    public void RoundTrip_RecoversExactSecret()
    {
        var id = Guid.NewGuid();
        var secret = new AccountSecret
        {
            SessionKey = "sk-ant-sid01-abc123_def-456",
            AllCookieHeader = "sessionKey=sk-ant-sid01-abc123_def-456; __cf_bm=rotating-value; activitySessionId=xyz",
        };

        _store.Save(id, secret);
        var ok = _store.TryLoad(id, out var loaded);

        Assert.True(ok);
        Assert.NotNull(loaded);
        Assert.Equal(secret.SessionKey, loaded!.SessionKey);
        Assert.Equal(secret.AllCookieHeader, loaded.AllCookieHeader);
    }

    [Fact]
    public void RoundTrip_PreservesNullCookieHeader()
    {
        var id = Guid.NewGuid();
        var secret = new AccountSecret { SessionKey = "sk-only", AllCookieHeader = null };

        _store.Save(id, secret);
        var ok = _store.TryLoad(id, out var loaded);

        Assert.True(ok);
        Assert.NotNull(loaded);
        Assert.Equal("sk-only", loaded!.SessionKey);
        Assert.Null(loaded.AllCookieHeader);
    }

    [Fact]
    public void TryLoad_MissingBlob_ReturnsFalse_NoThrow()
    {
        var ok = _store.TryLoad(Guid.NewGuid(), out var loaded);

        Assert.False(ok);
        Assert.Null(loaded);
    }

    [Fact]
    public void TryLoad_CorruptBlob_ReturnsFalse_NoThrow()
    {
        var id = Guid.NewGuid();
        _store.Save(id, new AccountSecret { SessionKey = "sk-real" });

        // Corrupt the encrypted blob on disk: DPAPI Unprotect must reject it, and TryLoad must
        // translate that into false rather than letting the CryptographicException escape.
        File.WriteAllBytes(_store.BlobPath(id), new byte[] { 0x00, 0x01, 0x02, 0x03, 0x04, 0x05 });

        var ok = _store.TryLoad(id, out var loaded);

        Assert.False(ok);
        Assert.Null(loaded);
    }

    [Fact]
    public void Save_OverwritesExistingBlob()
    {
        var id = Guid.NewGuid();
        _store.Save(id, new AccountSecret { SessionKey = "first" });
        _store.Save(id, new AccountSecret { SessionKey = "second" });

        var ok = _store.TryLoad(id, out var loaded);

        Assert.True(ok);
        Assert.Equal("second", loaded!.SessionKey);
    }

    [Fact]
    public void Delete_RemovesBlob_AndIsIdempotent()
    {
        var id = Guid.NewGuid();
        _store.Save(id, new AccountSecret { SessionKey = "sk" });
        Assert.True(File.Exists(_store.BlobPath(id)));

        _store.Delete(id);
        Assert.False(File.Exists(_store.BlobPath(id)));

        // Second delete must not throw.
        _store.Delete(id);
        Assert.False(_store.TryLoad(id, out _));
    }

    // ---- Load tri-state: the caller must be able to tell "gone" from "locked right now" ----

    [Fact]
    public void Load_MissingBlob_ReturnsMissing()
    {
        var result = _store.Load(Guid.NewGuid(), out var loaded);

        Assert.Equal(SecretLoadResult.Missing, result);
        Assert.Null(loaded);
    }

    [Fact]
    public void Load_CorruptBlob_ReturnsCorrupt()
    {
        var id = Guid.NewGuid();
        _store.Save(id, new AccountSecret { SessionKey = "sk-real" });
        File.WriteAllBytes(_store.BlobPath(id), new byte[] { 0x00, 0x01, 0x02, 0x03, 0x04, 0x05 });

        var result = _store.Load(id, out var loaded);

        Assert.Equal(SecretLoadResult.Corrupt, result);
        Assert.Null(loaded);
    }

    [Fact]
    public void Load_LockedBlob_ReturnsUnreadable_NotCorrupt_AndLeavesFile()
    {
        var id = Guid.NewGuid();
        _store.Save(id, new AccountSecret { SessionKey = "sk-locked" });
        var path = _store.BlobPath(id);

        // Hold the blob open with no sharing (an antivirus / backup agent mid-scan). ReadAllBytes
        // then fails with a sharing violation on Windows, which is where this suite runs.
        using (new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            var result = _store.Load(id, out var loaded);

            Assert.Equal(SecretLoadResult.Unreadable, result);
            Assert.Null(loaded);
        }

        // Once the lock is gone the same blob loads normally - it was never corrupt.
        Assert.Equal(SecretLoadResult.Loaded, _store.Load(id, out var recovered));
        Assert.Equal("sk-locked", recovered!.SessionKey);
        Assert.True(File.Exists(path));
    }

    // ---- Save wraps disk/DPAPI failures in a typed exception, never a bare fault ----

    [Fact]
    public void Save_DirectoryPathOccupiedByFile_ThrowsAccountPersistenceException()
    {
        // Occupy the store's directory path with a FILE so Directory.CreateDirectory fails.
        Directory.CreateDirectory(Path.GetDirectoryName(_dir)!);
        File.WriteAllText(_dir, "not a directory");
        var store = new SecretStore(_dir);

        var ex = Assert.Throws<AccountPersistenceException>(
            () => store.Save(Guid.NewGuid(), new AccountSecret { SessionKey = "sk" }));

        Assert.NotNull(ex.InnerException);
        Assert.True(ex.InnerException is IOException or UnauthorizedAccessException);
    }
}
