using Barback.Core;
namespace Barback.Core.Tests;

public class NotificationThrottleTests
{
    private static EventRecord Event(string type, Guid? program = null) => new(DateTimeOffset.UtcNow, type, program, null, "");
    [Fact]
    public void FatalIsCollapsedPerProgramForTenMinutes()
    {
        var now = DateTimeOffset.Parse("2026-10-02T10:00:00Z"); var throttle = new NotificationThrottle(() => now); var a = Guid.NewGuid(); var b = Guid.NewGuid();
        Assert.True(throttle.ShouldNotify(Event("Fatal", a))); Assert.False(throttle.ShouldNotify(Event("Fatal", a))); Assert.True(throttle.ShouldNotify(Event("Fatal", b)));
        now = now.AddMinutes(9.9); Assert.False(throttle.ShouldNotify(Event("Fatal", a)));
        now = now.AddMinutes(0.2); Assert.True(throttle.ShouldNotify(Event("Fatal", a)));
    }
    [Fact]
    public void LogLossAndInterruptedSessionAreAggregatedAcrossPrograms()
    {
        var throttle = new NotificationThrottle(); Assert.True(throttle.ShouldNotify(Event("LogIncomplete", Guid.NewGuid()))); Assert.False(throttle.ShouldNotify(Event("LogIncomplete", Guid.NewGuid())));
        Assert.True(throttle.ShouldNotify(Event("AppInterrupted"))); Assert.False(throttle.ShouldNotify(Event("AppInterrupted")));
    }
    [Theory]
    [InlineData("RunFailed")]
    [InlineData("RunTimeout")]
    [InlineData("CleanupFailed")]
    public void CommandFailuresAndCleanupAlwaysNotify(string type)
    {
        var throttle = new NotificationThrottle(); var id = Guid.NewGuid();
        Assert.True(throttle.ShouldNotify(Event(type, id))); Assert.True(throttle.ShouldNotify(Event(type, id)));
    }
}
