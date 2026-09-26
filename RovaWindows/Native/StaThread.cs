namespace RovaWindows.Native;

/// Runs a call on a fresh single-threaded apartment thread. The shell (SHFileOperation, the
/// Recycle Bin) and the clipboard expect STA; thread-pool threads are MTA.
internal static class StaThread
{
    internal static T Run<T>(Func<T> work)
    {
        T result = default!;
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try { result = work(); }
            catch (Exception error) { failure = error; }
        }) { IsBackground = true, Name = "Wiqo STA" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
        return result;
    }
}
