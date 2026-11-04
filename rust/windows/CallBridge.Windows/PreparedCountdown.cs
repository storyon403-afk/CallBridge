// 倒计时只决定是否允许触发；准备/播放的实际状态始终由 Rust Session 持有。
namespace CallBridge.Windows;

internal enum CountdownDecision { Pending, Wait, Play }
internal static class PreparedCountdown
{
    internal static CountdownDecision Decide(double now, double deadline, bool foreground, bool authorized)
    {
        if (!authorized) return CountdownDecision.Wait;
        if (now < deadline) return CountdownDecision.Pending;
        return foreground || now - deadline > 1 ? CountdownDecision.Wait : CountdownDecision.Play;
    }
}
