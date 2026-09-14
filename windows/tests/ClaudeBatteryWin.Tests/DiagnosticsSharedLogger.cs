using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// The test classes that install their own app-wide diagnostics logger, or that make code emit
/// into whatever logger is installed, share this collection so xUnit never runs them at the same
/// time.
///
/// <c>DiagnosticsLogger.SetShared</c> is one static slot for the whole process. Two classes running
/// in parallel means one class's milestone lands in the other's file, and the test that counts its
/// own records fails for a reason that has nothing to do with the code under test.
/// </summary>
[CollectionDefinition(Name)]
public sealed class DiagnosticsSharedLogger
{
    public const string Name = "diagnostics-shared-logger";
}
