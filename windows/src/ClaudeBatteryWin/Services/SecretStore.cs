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
/// a truncated/garbage file. <see cref="Load"/> never throws on these; it reports
/// <see cref="SecretLoadResult.Corrupt"/> (or <see cref="SecretLoadResult.Missing"/> when there is no
/// blob at all), and the caller (<see cref="AccountStore"/>) deletes the blob, drops the account, and
/// flags a re-auth. The app must never crash because a secret would not decrypt.
/// </para>
///
/// <para>
/// <b>Read-failure policy.</b> A blob that exists but cannot be READ (a sharing violation while an
/// antivirus, backup, or sync agent holds the file, or a momentary permissions hiccup) is NOT
/// corrupt: the bytes are fine, they are just unavailable right now. <see cref="Load"/> retries the
/// read a few times and then reports <see cref="SecretLoadResult.Unreadable"/>, which the caller
/// treats as "skip this launch, keep the account for next time" - never delete, never drop. Before
/// this split a single transient read error at startup permanently signed the user out.
/// </para>
///
/// <para>
/// <b>Save-failure policy.</b> <see cref="Save"/> wraps every disk and DPAPI failure in
/// <see cref="AccountPersistenceException"/> so callers can show "could not save sign-in data"
/// instead of faulting an unobserved task and leaving the login window spinning.
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
    /// <exception cref="AccountPersistenceException">
    /// The folder could not be created, DPAPI refused to protect the payload, or the blob could not
    /// be written or moved into place (disk full, read-only redirected profile, a file occupying the
    /// folder path, an antivirus holding the temp file). The original error is the inner exception.
    /// Nothing is left half-written: the target blob is untouched until the final move.
    /// </exception>
    public void Save(Guid accountId, AccountSecret secret)
    {
        try
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
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or CryptographicException)
        {
            DebugLog("Failed to save secret blob");
            throw new AccountPersistenceException("Could not save the account's sign-in data.", ex);
        }
    }

    /// <summary>Number of read attempts <see cref="Load"/> makes before reporting Unreadable.</summary>
    private const int ReadAttempts = 3;

    /// <summary>Pause between read attempts. A scanner's sharing violation usually clears well within this.</summary>
    private static readonly TimeSpan ReadRetryDelay = TimeSpan.FromMilliseconds(100);

    /// <summary>
    /// Load and decrypt an account's secrets, reporting WHY when that is not possible so the caller
    /// can tell a blob that is gone for good from one that is merely locked right now.
    /// </summary>
    /// <returns>
    /// <list type="bullet">
    /// <item><see cref="SecretLoadResult.Loaded"/>: <paramref name="secret"/> is set.</item>
    /// <item><see cref="SecretLoadResult.Missing"/>: no blob file exists for this id.</item>
    /// <item><see cref="SecretLoadResult.Corrupt"/>: the blob exists but DPAPI would not decrypt it
    /// (corrupt bytes, copied profile, SID change), the cleartext is not valid JSON, or it carries no
    /// session key. The data is unusable; the caller should drop the account.</item>
    /// <item><see cref="SecretLoadResult.Unreadable"/>: the blob exists but could not be read after
    /// <see cref="ReadAttempts"/> tries (sharing violation, access denied). The data may be fine; the
    /// caller must NOT delete it.</item>
    /// </list>
    /// Never throws for any of these.
    /// </returns>
    public SecretLoadResult Load(Guid accountId, out AccountSecret? secret)
    {
        secret = null;
        var path = BlobPath(accountId);
        if (!File.Exists(path))
        {
            return SecretLoadResult.Missing;
        }

        byte[] protectedBytes;
        try
        {
            protectedBytes = ReadAllBytesWithRetry(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // The file is there but locked or inaccessible right now. Not corrupt: leave it alone so
            // the next launch can try again.
            DebugLog("Secret blob unreadable after retries (deferred, not dropped)");
            return SecretLoadResult.Unreadable;
        }

        try
        {
            var json = ProtectedData.Unprotect(protectedBytes, Entropy, DataProtectionScope.CurrentUser);
            var parsed = JsonSerializer.Deserialize<AccountSecret>(json, SecretJsonOptions);
            if (parsed is null || string.IsNullOrEmpty(parsed.SessionKey))
            {
                return SecretLoadResult.Corrupt;
            }

            secret = parsed;
            return SecretLoadResult.Loaded;
        }
        catch (CryptographicException)
        {
            // Corrupt blob, copied profile, or SID change: not a crash, a re-auth.
            return SecretLoadResult.Corrupt;
        }
        catch (JsonException)
        {
            // Decrypted fine but the cleartext is malformed: same handling, never crash.
            return SecretLoadResult.Corrupt;
        }
    }

    /// <summary>
    /// <see cref="Load"/> collapsed to a bool: <c>true</c> only for <see cref="SecretLoadResult.Loaded"/>.
    /// Kept for callers that do not need to tell the failure kinds apart.
    /// </summary>
    public bool TryLoad(Guid accountId, out AccountSecret? secret) =>
        Load(accountId, out secret) == SecretLoadResult.Loaded;

    /// <summary>
    /// Read a file, retrying a transient I/O failure up to <see cref="ReadAttempts"/> times with a
    /// short pause. The last failure propagates so the caller can classify it. Shared with
    /// <see cref="AccountStore"/>, which gives accounts.json the same treatment as a blob: a scanner
    /// holding the metadata file open at launch must not read as "no accounts".
    /// </summary>
    internal static byte[] ReadAllBytesWithRetry(string path)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                return File.ReadAllBytes(path);
            }
            catch (Exception ex) when (attempt < ReadAttempts && (ex is IOException or UnauthorizedAccessException))
            {
                Thread.Sleep(ReadRetryDelay);
            }
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
/// Outcome of <see cref="SecretStore.Load"/>. The split between <see cref="Corrupt"/> and
/// <see cref="Unreadable"/> is the whole point: only the first means the data is gone.
/// </summary>
public enum SecretLoadResult
{
    /// The blob was read and decrypted; the secret is available.
    Loaded,

    /// No blob file exists for this account id.
    Missing,

    /// The blob exists but its contents are unusable (DPAPI refused it, malformed cleartext, no
    /// session key). Safe to delete; the account needs a re-auth.
    Corrupt,

    /// The blob exists but could not be read right now (locked by another process, access denied).
    /// Its contents may be fine. Must NOT be deleted; retry on a later launch.
    Unreadable,
}

/// <summary>
/// Thrown by <see cref="SecretStore.Save"/> when an account's sign-in data could not be written to
/// disk. Carries the original disk or DPAPI error as <see cref="Exception.InnerException"/>. The
/// sign-in flows catch this to show a "could not save" message instead of a generic connection error
/// (or, worse, a silently faulted task).
/// </summary>
public sealed class AccountPersistenceException : Exception
{
    public AccountPersistenceException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
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
