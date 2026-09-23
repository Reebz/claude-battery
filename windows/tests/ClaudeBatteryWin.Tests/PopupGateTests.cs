using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U6 pure-predicate tests: the navigation allowlist and OAuth-popup gate, the highest-density
/// auth scars (critical patterns #2 and #7). All assertions hit the static
/// <see cref="AuthManager.ShouldAllow"/> / <see cref="AuthManager.AllowsOAuthPopup"/> /
/// <see cref="AuthManager.IsAllowedHost"/> / <see cref="AuthManager.IsLocalizedGoogleAccountsHost"/>
/// - no WebView2, no instance. These encode documented Mac regressions, so they are written
/// test-first per the unit's execution note.
/// </summary>
public sealed class PopupGateTests
{
    // ---- scheme-before-host: about:blank bootstrap (round-9 regression) ------------------------

    [Theory]
    [InlineData("about:blank")]
    [InlineData("about:blank?foo=bar")]
    [InlineData("about:srcdoc")]
    public void ShouldAllow_AllowsAboutBootstrapFrames(string url)
    {
        // The about: scheme MUST be evaluated before the host. about:blank has no host, so a
        // host-first guard silently blocked it and broke Google OAuth (critical pattern #7).
        Assert.True(AuthManager.ShouldAllow(url));
    }

    [Theory]
    [InlineData("about:blank")]
    [InlineData("about:blank?code=live")]
    [InlineData("about:srcdoc")]
    public void AllowsOAuthPopup_AllowsAboutBootstrapFrames(string url)
    {
        Assert.True(AuthManager.AllowsOAuthPopup(url));
    }

    [Theory]
    [InlineData("about:settings")]
    [InlineData("about:config")]
    [InlineData("about:version")]
    public void ShouldAllow_RejectsNonBootstrapAboutUris(string url)
    {
        Assert.False(AuthManager.ShouldAllow(url));
    }

    // ---- exact-domain claude.ai (critical pattern #2) ------------------------------------------

    [Theory]
    [InlineData("https://claude.ai/login")]
    [InlineData("https://claude.ai/")]
    public void ShouldAllow_AcceptsExactClaudeHost(string url)
    {
        Assert.True(AuthManager.ShouldAllow(url));
    }

    [Theory]
    [InlineData("https://evil-claude.ai/login")]
    [InlineData("https://claude.ai.evil.com/login")]
    [InlineData("https://notclaude.ai/")]
    [InlineData("https://accounts.google.com/")] // not allowed in the MAIN frame, only in popups
    public void ShouldAllow_RejectsLookalikeAndThirdPartyHosts(string url)
    {
        Assert.False(AuthManager.ShouldAllow(url));
    }

    [Fact]
    public void ShouldAllow_RejectsEmptyAndGarbage()
    {
        Assert.False(AuthManager.ShouldAllow(""));
        Assert.False(AuthManager.ShouldAllow("   "));
        Assert.False(AuthManager.ShouldAllow("not a url"));
    }

    // ---- popup allowlist: real OAuth provider hosts --------------------------------------------

    [Theory]
    [InlineData("claude.ai")]
    [InlineData("www.claude.ai")]
    [InlineData("accounts.google.com")]
    [InlineData("ssl.gstatic.com")]
    [InlineData("apis.googleapis.com")]
    [InlineData("appleid.apple.com")]
    [InlineData("idmsa.apple.com.icloud.com")] // .icloud.com subdomain
    [InlineData("challenges.cloudflare.com")]   // .challenges.cloudflare.com
    [InlineData("cf-chl-widget.cloudflare.com")]
    public void IsAllowedHost_AcceptsKnownProviderHosts(string host)
    {
        Assert.True(AuthManager.IsAllowedHost(host));
    }

    [Theory]
    [InlineData("evil.googleapis.com.attacker.com")]
    [InlineData("accounts.google.io")]
    [InlineData("evil-claude.ai")]
    [InlineData("claude.ai.evil.com")]
    [InlineData("phishing.com")]
    public void IsAllowedHost_RejectsLookalikeHosts(string host)
    {
        Assert.False(AuthManager.IsAllowedHost(host));
    }

    // ---- localized Google ccTLD hosts (#17/#25) ------------------------------------------------

    [Theory]
    [InlineData("accounts.google.com.tr")]
    [InlineData("accounts.google.co.uk")]
    [InlineData("accounts.google.de")]
    [InlineData("x.accounts.google.com.tr")] // subdomain of an allowed ccTLD host
    public void IsLocalizedGoogleAccountsHost_AcceptsEnumeratedCountryHosts(string host)
    {
        Assert.True(AuthManager.IsLocalizedGoogleAccountsHost(host));
    }

    [Theory]
    [InlineData("evilaccounts.google.com.tr")]   // prefix attack, not a leading-dot subdomain
    [InlineData("accounts.google.com.tr.evil.com")]
    [InlineData("accounts.google.zz")]            // not an enumerated host
    public void IsLocalizedGoogleAccountsHost_RejectsLookalikes(string host)
    {
        Assert.False(AuthManager.IsLocalizedGoogleAccountsHost(host));
    }

    // ---- the popup NavigationStarting gate cancels off-allowlist hosts -------------------------

    [Fact]
    public void PopupGate_CancelsNavigationToNonAllowlistedHost()
    {
        // The popup WebView is wired with AllowsOAuthPopup as its per-navigation gate (the same
        // allowlist), so once the OAuth bootstrap is done it cannot wander to an arbitrary host.
        Func<string, bool> popupGate = AuthManager.AllowsOAuthPopup;

        Assert.True(popupGate("https://accounts.google.com/o/oauth2/auth"));
        Assert.False(popupGate("https://evil.example.com/steal"));
        Assert.False(popupGate("https://claude.ai.evil.com/"));
    }
}
