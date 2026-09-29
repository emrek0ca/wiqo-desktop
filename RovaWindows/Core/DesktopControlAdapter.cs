namespace RovaWindows;

/// Optional Windows desktop automation seam. The core runtime stays headless and testable;
/// the WPF companion supplies the UI Automation implementation only when it is available.
public interface IDesktopControlAdapter : IDisposable
{
    Outcome Execute(ComputerDesktopPayload payload, CancellationToken cancellationToken);
}
