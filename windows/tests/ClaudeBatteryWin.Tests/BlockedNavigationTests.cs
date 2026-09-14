using System.IO;
using System.Net;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U10: a blocked single sign-on redirect says what happened and offers a way through (R49), and the
/// host it blocked is recorded, by name only, for a bug report (R50).
///
/// Before this the window cancelled the hop silently. A user at a company that uses its own identity
/// provider saw the page stop, with no message, no explanation, and no reason to think the manual
/// paste under Settings would work.
/// </summary>
public sealed class BlockedNavigationTests : IDisposable
{
    private readonly string _root;
    private readonly CookieContainer _jar = new();

    public BlockedNavigationTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "cbw-blocked-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_root);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_root))
            {
                Directory.Delete(_root, recursive: true);
            }
        }
        catch (IOException)
        {
        }
    }

    private (AuthManager Manager, FakeLoginWebView WebView) NewManager()
    {
        var store = new AccountStore(
            _jar, new SecretStore(Path.Combine(_root, "secrets")), Path.Combine(_root, "accounts.json"));
        var web = new FakeLoginWebView();
        var manager = new AuthManager(
            new FakeClaudeApi(), store, new FakeLoginWebViewFactory(web), new FakeOrgPicker());
        return (manager, web);
    }

    // --- The message ---------------------------------------------------------------------------

    [Fact]
    public void BlockedIdentityProvider_ShowsTheSingleSignOnMessage()
    {
        var (manager, web) = NewManager();
        manager.PresentLogin();

        var allowed = web.RaiseNavigationStarting("https://acme.okta.com/app/sso?state=LEAKEDSTATE");

        Assert.False(allowed); // blocked, not merely recorded
        Assert.Equal(LoginStateKind.Error, manager.LoginState.Kind);
        Assert.Equal(AuthManager.SsoBlockedMessage, manager.LoginState.Message);
    }

    [Fact]
    public void TheMessage_NamesTheWayThroughAndNeverTheHost()
    {
        var message = AuthManager.SsoBlockedMessage;

        Assert.Equal(
            "This sign-in window can't complete single sign-on (SSO). Choose \"Continue with email\" and "
            + "enter the code Claude sends you, or use Sign in manually to paste your cookie header under Settings.",
            message);
        Assert.DoesNotContain("okta", message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ABlockAfterTheSessionWasCaptured_DoesNotReplaceTheInProgressState()
    {
        // A post-sign-in redirect must not turn "finishing sign-in" into an error card with a stale
        // "Try again" underneath a live discovery call.
        var (manager, web) = NewManager();
        manager.PresentLogin();
        web.RaiseCookiesObserved(new[]
        {
            AuthManagerTests.Cookie("sessionKey", "sk-live"),
            AuthManagerTests.Cookie("__cf_bm", "cf"),
        });

        web.RaiseNavigationStarting("https://acme.okta.com/app/sso");

        Assert.NotEqual(LoginStateKind.Error, manager.LoginState.Kind);
    }

    // --- What is recorded ----------------------------------------------------------------------

    [Theory]
    [InlineData("claude.ai", "claude.ai")]
    [InlineData("acme.okta.com", "acme.okta.com")]
    [InlineData("a-b.example.co.uk", "a-b.example.co.uk")]
    [InlineData("", "(invalid)")]
    [InlineData("a..b", "(invalid)")]
    [InlineData(".leading.dot", "(invalid)")]
    [InlineData("trailing.dot.", "(invalid)")]
    [InlineData("user@evil.com", "(invalid)")]
    [InlineData("host/path", "(invalid)")]
    [InlineData("host?query=1", "(invalid)")]
    [InlineData("müller.de", "(invalid)")]
    public void HostForDiagnostics_AcceptsOnlyAPlainDomainName(string host, string expected) =>
        Assert.Equal(expected, AuthManager.HostForDiagnostics(host));

    [Fact]
    public void HostForDiagnostics_RefusesAnOverlongHost() =>
        Assert.Equal("(invalid)", AuthManager.HostForDiagnostics(new string('a', 254)));

    [Fact]
    public void HostForDiagnostics_RefusesAnOverlongLabel() =>
        Assert.Equal("(invalid)", AuthManager.HostForDiagnostics(new string('a', 64) + ".com"));

    [Fact]
    public void ABlockedHop_RecordsTheKindAndTheHostButNotTheUrl()
    {
        var dir = Path.Combine(_root, "logs");
        var logger = new DiagnosticsLogger(settings: null, directoryOverride: dir, enabledOverride: true);
        DiagnosticsLogger.SetShared(logger);
        try
        {
            var (manager, web) = NewManager();
            manager.PresentLogin();

            web.RaiseNavigationStarting("https://acme.okta.com/app/sso?state=LEAKEDSTATE");

            var text = ReadWhileOpen(logger.CurrentSessionFilePath!);
            Assert.Contains("\"kind\":\"main\"", text.Replace(" ", string.Empty), StringComparison.Ordinal);
            Assert.Contains("acme.okta.com", text, StringComparison.Ordinal);
            Assert.DoesNotContain("LEAKEDSTATE", text, StringComparison.Ordinal);
            Assert.DoesNotContain("state=", text, StringComparison.Ordinal);
            Assert.DoesNotContain("/app/sso", text, StringComparison.Ordinal);
        }
        finally
        {
            logger.Dispose();
        }
    }

    [Fact]
    public void TheSameHopRetried_IsRecordedOnce()
    {
        var dir = Path.Combine(_root, "logs-dedup");
        var logger = new DiagnosticsLogger(settings: null, directoryOverride: dir, enabledOverride: true);
        DiagnosticsLogger.SetShared(logger);
        try
        {
            var (manager, web) = NewManager();
            manager.PresentLogin();

            for (var i = 0; i < 50; i++)
            {
                web.RaiseNavigationStarting("https://acme.okta.com/app/sso");
            }

            var lines = ReadWhileOpen(logger.CurrentSessionFilePath!)
                .Split('\n', StringSplitOptions.RemoveEmptyEntries)
                .Where(l => l.Contains("nav-decision", StringComparison.Ordinal))
                .ToList();

            Assert.Single(lines);
        }
        finally
        {
            logger.Dispose();
        }
    }

    [Fact]
    public void ADifferentHost_IsANewRecord()
    {
        var dir = Path.Combine(_root, "logs-two");
        var logger = new DiagnosticsLogger(settings: null, directoryOverride: dir, enabledOverride: true);
        DiagnosticsLogger.SetShared(logger);
        try
        {
            var (manager, web) = NewManager();
            manager.PresentLogin();

            web.RaiseNavigationStarting("https://acme.okta.com/app/sso");
            web.RaiseNavigationStarting("https://login.microsoftonline.com/x");

            var lines = ReadWhileOpen(logger.CurrentSessionFilePath!)
                .Split('\n', StringSplitOptions.RemoveEmptyEntries)
                .Where(l => l.Contains("nav-decision", StringComparison.Ordinal))
                .ToList();

            Assert.Equal(2, lines.Count);
        }
        finally
        {
            logger.Dispose();
        }
    }

    [Fact]
    public void WithLoggingOff_NothingIsRecordedAtAllButTheMessageStillShows()
    {
        var dir = Path.Combine(_root, "logs-off");
        var logger = new DiagnosticsLogger(settings: null, directoryOverride: dir, enabledOverride: false);
        DiagnosticsLogger.SetShared(logger);
        try
        {
            var (manager, web) = NewManager();
            manager.PresentLogin();

            web.RaiseNavigationStarting("https://acme.okta.com/app/sso");

            Assert.False(Directory.Exists(dir));
            Assert.Equal(LoginStateKind.Error, manager.LoginState.Kind);
        }
        finally
        {
            logger.Dispose();
        }
    }

    private static string ReadWhileOpen(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }
}
