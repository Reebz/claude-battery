using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// At-rest secret storage for account credentials, using Windows DPAPI
/// (<see cref="ProtectedData"/>, <see cref="DataProtectionScope.CurrentUser"/>).
///
/// This is the Windows analog of the Mac Keychain. It encrypts the two per-account secrets
/// (<c>sessionKey</c> and the full <c>.claude.ai</c> cookie header) to a per-account file under
/// <c>%APPDATA%</c>. The non-secret account metadata (email, org id, nickname, thresholds) is
/// persisted separately by <see cref="AccountStore"/> in plaintext JSON; only the credentials
/// pass through here.
///
/// Threat-model boundary (from the plan): DPAPI CurrentUser protects against other local users
/// and offline disk theft. It does NOT protect against malware running as the same user (the same
/// limitation as the Mac Keychain). It is an at-rest upgrade over the Mac's plaintext UserDefaults,
/// not anti-malware protection.
///
/// <para>
/// <b>optionalEntropy is obfuscation, not a secret.</b> It is a fixed per-app constant compiled
/// into the binary, so it adds no cryptographic secrecy. Its only purpose is to scope these blobs
/// to this app so a blob produced by another CurrentUser-scoped DPAPI consumer cannot be decrypted
/// here by accident, and vice versa.
/// </para>
///
/// <para>
/// <b>Decrypt-failure policy.</b> A blob can fail to decrypt for benign reasons that are not data
/// corruption in the malicious sense: a profile copied to another machine, a Windows SID change, or
/// a truncated/garbage file. <see cref="TryLoad"/> never throws on these; it returns <c>false</c>,
/// and the caller (<see cref="AccountStore"/>) deletes the blob, drops the account, and flags a
/// re-auth. The app must never crash because a secret would not decrypt.
/// </para>
/// </summary>
public sealed class SecretStore
{
    /// <summary>
    /// Fixed per-app entropy. NOT a secret (it ships in the binary); see the type remarks. The
    /// bytes are an arbitrary stable constant tied to the bundle identifier so the scoping survives
    /// across app versions. Changing these bytes invalidates every existing blob.
    /// </summary>
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("com.reebz.claudebattery.dpapi.v1");

    private readonly string _directory;

    /// <param name="directory">
    /// Folder that holds the per-account secret blobs. Defaults to
    /// <c>%APPDATA%\ClaudeBatteryWin\secrets</c>. Tests inject a temp folder. The directory is
    /// created lazily on first save.
    /// </param>
    public SecretStore(string? directory = null)
    {
        _directory = directory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "ClaudeBatteryWin",
            "secrets");
    }

    /// <summary>The on-disk path for one account's secret blob.</summary>
    public string BlobPath(Guid accountId) => Path.Combine(_directory, accountId.ToString("N") + ".dpapi");

    /// <summary>
    /// Encrypt and persist an account's secrets. The cleartext is JSON over the two fields, then
    /// DPAPI-protected. Overwrites any existing blob for this account id atomically (write to a
    /// temp file, then move into place) so a crash mid-write cannot leave a half-written blob that
    /// would later read as "corrupt" and drop the account.
    /// </summary>
    public void Save(Guid accountId, AccountSecret secret)
    {
        Directory.CreateDirectory(_directory);

        var json = JsonSerializer.SerializeToUtf8Bytes(secret, SecretJsonOptions);
        var protectedBytes = ProtectedData.Protect(json, Entropy, DataProtectionScope.CurrentUser);

        var target = BlobPath(accountId);
        var temp = target + ".tmp";
        File.WriteAllBytes(temp, protectedBytes);
        // Move is atomic within the same volume; overwrite to replace any prior blob.
        File.Move(temp, target, overwrite: true);
    }

    /// <summary>
    /// Attempt to load and decrypt an account's secrets.
    /// </summary>
    /// <returns>
    /// <c>true</c> with <paramref name="secret"/> set when the blob exists and decrypts; otherwise
    /// <c>false</c> with <paramref name="secret"/> null. A missing file, a DPAPI decrypt failure
    /// (corrupt blob, copied profile, SID change), or a JSON parse failure all return <c>false</c>
    /// without throwing. The caller decides what a <c>false</c> means for the account.
    /// </returns>
    public bool TryLoad(Guid accountId, out AccountSecret? secret)
    {
        secret = null;
        var path = BlobPath(accountId);
        if (!File.Exists(path))
        {
            return false;
        }

        try
        {
            var protectedBytes = File.ReadAllBytes(path);
            var json = ProtectedData.Unprotect(protectedBytes, Entropy, DataProtectionScope.CurrentUser);
            var parsed = JsonSerializer.Deserialize<AccountSecret>(json, SecretJsonOptions);
            if (parsed is null || string.IsNullOrEmpty(parsed.SessionKey))
            {
                return false;
            }

            secret = parsed;
            return true;
        }
        catch (CryptographicException)
        {
            // Corrupt blob, copied profile, or SID change: not a crash, a re-auth.
            return false;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            // Unreadable file or malformed cleartext: same handling, never crash.
            return false;
        }
    }

    /// <summary>
    /// Delete an account's secret blob. Idempotent; a missing file is not an error. Called when an
    /// account is removed and as part of dropping an account whose blob would not decrypt.
    /// </summary>
    public void Delete(Guid accountId)
    {
        var path = BlobPath(accountId);
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Best-effort; a locked/already-removed file must not crash the app.
            DebugLog("Failed to delete secret blob (ignored)");
        }
    }

    [Conditional("DEBUG")]
    private static void DebugLog(string message) => Debug.WriteLine($"[SecretStore] {message}");

    /// Shared so serialize and deserialize stay symmetric.
    private static readonly JsonSerializerOptions SecretJsonOptions = new()
    {
        IncludeFields = false,
    };
}

/// <summary>
/// The cleartext secret payload that DPAPI protects. Held in memory as cleartext (the
/// <see cref="Account"/> model carries the same values); only the on-disk form is encrypted.
/// </summary>
public sealed record AccountSecret
{
    /// The HttpOnly <c>sessionKey</c> cookie value.
    public required string SessionKey { get; init; }

    /// Full <c>.claude.ai</c> Cookie header ("name=value; ..."), or null when none was captured.
    public string? AllCookieHeader { get; init; }
}
