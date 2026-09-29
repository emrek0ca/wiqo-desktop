using System.Runtime.InteropServices;
using System.Windows.Automation;
using RovaWindows.Native;

namespace RovaWindows.Operations;

/// Task-scoped desktop control through Windows UI Automation and documented SendInput APIs.
/// Observations are bounded and semantic; screenshots remain a separate capability.
public sealed class WindowsDesktopControlAdapter : IDesktopControlAdapter
{
    private sealed record TargetState(string Ref, AutomationElement Element, System.Windows.Rect Bounds, string Name, string Role, bool Secure, string[] Actions);
    private sealed record SessionState(
        string TaskId, string SnapshotId, string? PreviousSnapshotId, int Generation, TargetState[] Targets,
        TargetState[] AddedTargets, TargetState[] ChangedTargets, string[] RemovedTargetRefs,
        string Fingerprint, NativeMethods.Point? ExpectedCursor, DateTimeOffset UpdatedAt,
        string? ApplicationName, string? ApplicationIdentifier, string? WindowTitle);
    private sealed record StepEvidence(int Index, string Action, string? TargetRef, bool Ok, bool Changed, bool Verified, object? Before, object? After, string? ErrorCode);

    private readonly object gate = new();
    private readonly Dictionary<string, SessionState> sessions = new(StringComparer.Ordinal);
    private readonly Dictionary<string, int> generations = new(StringComparer.Ordinal);
    private const int TargetLimit = 80;
    private const int TraversalLimit = 1_500;
    private static readonly TimeSpan SessionLifetime = TimeSpan.FromMinutes(15);

    public Outcome Execute(ComputerDesktopPayload payload, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (payload.Action == "cancel")
        {
            lock (gate) { sessions.Remove(payload.TaskId); generations.Remove(payload.TaskId); }
            AgentCursorOverlay.Hide();
            return Data(payload, null, [], changed: false, verified: true);
        }
        if (payload.Action == "observe") return Observe(payload, false, true, null, cancellationToken);
        if (payload.Action == "runSteps") return RunSteps(payload, cancellationToken);

        SessionState session;
        lock (gate)
        {
            if (!sessions.TryGetValue(payload.TaskId, out session!))
                return Outcome.Fail("DESKTOP_OBSERVATION_REQUIRED", "Önce masaüstünü gözlemleyip güncel hedefleri alın.");
            if (DateTimeOffset.UtcNow - session.UpdatedAt > SessionLifetime)
            {
                sessions.Remove(payload.TaskId);
                generations.Remove(payload.TaskId);
                return Outcome.Fail("DESKTOP_SESSION_EXPIRED", "Masaüstü görevi zaman aşımına uğradı; yeniden izin verip gözlemleyin.", "permission");
            }
        }
        if (payload.SnapshotId is not null && !string.Equals(payload.SnapshotId, session.SnapshotId, StringComparison.Ordinal))
            return Outcome.Fail("DESKTOP_STALE_OBSERVATION", "Masaüstü görünümü değişti; işlemden önce yeniden gözlemleyin.");
        if (WasInterrupted(session))
        {
            lock (gate) sessions.Remove(payload.TaskId);
            AgentCursorOverlay.Hide();
            return Outcome.Fail("DESKTOP_USER_INTERRUPTED", "Kullanıcı fareyi devraldığı için masaüstü görevi güvenle durduruldu.", "permission");
        }

        cancellationToken.ThrowIfCancellationRequested();
        var error = payload.Action switch
        {
            "move" => ResolvePoint(payload, session, out var movePoint) ? Move(movePoint) : MissingTarget(),
            "click" or "doubleClick" or "rightClick" => ClickAction(payload, session),
            "scroll" => ScrollAction(payload, session),
            "dragDrop" => DragAction(payload, session),
            "type" => TypeAction(payload, session),
            "hotkey" => Hotkey(payload.Keys ?? []),
            "wait" => Wait(payload.Amount ?? 250, cancellationToken),
            _ => new WireError("DESKTOP_ACTION_UNSUPPORTED", "Bu masaüstü eylemi desteklenmiyor.", "validation")
        };
        if (error is not null) return new Outcome(error.Message, null, error);
        Thread.Sleep(180);
        return Observe(payload, true, true, session.Fingerprint, cancellationToken);
    }

    private Outcome RunSteps(ComputerDesktopPayload payload, CancellationToken cancellationToken)
    {
        if (payload.Steps is not { Length: >= 1 and <= 8 }) return Outcome.Fail("DESKTOP_STEPS_INVALID", "Toplu masaüstü görevi 1-8 güvenli adım içermelidir.", "validation");
        var evidence = new List<StepEvidence>();
        foreach (var (step, index) in payload.Steps.Select((value, index) => (value, index)))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var before = CurrentSession(payload.TaskId);
            var nested = new ComputerDesktopPayload(
                payload.TaskId, step.Action, step.Action == "observe" ? null : before?.SnapshotId,
                step.TargetRef, step.SourceRef, step.DestinationRef, step.NormalizedX, step.NormalizedY,
                step.Direction, step.Amount, step.Text, step.Keys, true);
            var outcome = Execute(nested, cancellationToken);
            var after = CurrentSession(payload.TaskId);
            evidence.Add(new StepEvidence(
                index, step.Action, step.TargetRef ?? step.SourceRef, outcome.Error is null,
                before?.Fingerprint != after?.Fingerprint, outcome.Error is null && after is not null,
                State(before), State(after), outcome.Error?.Code));
            if (outcome.Error is not null)
                return Data(payload, after, evidence, verified: false) with { Error = outcome.Error, Message = outcome.Error.Message };
        }
        var current = CurrentSession(payload.TaskId);
        return Data(payload, current, evidence, verified: evidence.All(item => item.Verified));
    }

    private SessionState? CurrentSession(string taskId)
    {
        lock (gate) return sessions.TryGetValue(taskId, out var value) ? value : null;
    }

    private static object? State(SessionState? session) => session is null ? null : new { identifier = session.ApplicationIdentifier, title = session.WindowTitle, version = session.Generation };

    private Outcome Observe(ComputerDesktopPayload payload, bool changed, bool verified, string? previousFingerprint, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var foreground = NativeMethods.GetForegroundWindow();
        if (foreground == IntPtr.Zero) return Outcome.Fail("DESKTOP_APP_UNAVAILABLE", "Ön plandaki uygulama belirlenemedi.");

        AutomationElement root;
        try { root = AutomationElement.FromHandle(foreground); }
        catch (ElementNotAvailableException) { return Outcome.Fail("DESKTOP_APP_UNAVAILABLE", "Ön plandaki uygulamanın erişilebilirlik ağacı kullanılamıyor."); }

        SessionState? previous = null;
        var generation = 1;
        lock (gate)
        {
            sessions.TryGetValue(payload.TaskId, out previous);
            generation = generations.TryGetValue(payload.TaskId, out var current) ? current + 1 : 1;
            generations[payload.TaskId] = generation;
        }
        var snapshotId = Guid.NewGuid().ToString("D").ToLowerInvariant();
        var queue = new Queue<AutomationElement>();
        queue.Enqueue(root);
        var visited = 0;
        var targets = new List<TargetState>();
        var signatureCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        while (queue.Count > 0 && visited < TraversalLimit && targets.Count < TargetLimit)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var element = queue.Dequeue();
            visited++;
            try
            {
                var bounds = element.Current.BoundingRectangle;
                var enabled = element.Current.IsEnabled;
                var role = element.Current.ControlType?.ProgrammaticName?.Replace("ControlType.", "", StringComparison.Ordinal) ?? "control";
                var secure = element.Current.IsPassword;
                var name = secure ? "Güvenli alan" : (element.Current.Name ?? "").Trim();
                var actions = Actions(element, bounds, secure);
                if (enabled && !bounds.IsEmpty && bounds.Width > 1 && bounds.Height > 1 && actions.Length > 0)
                {
                    var boundedName = name.Length == 0 ? role : name[..Math.Min(name.Length, 160)];
                    var normalizedRole = role.ToLowerInvariant();
                    var signature = $"{normalizedRole}|{NormalizeTargetText(boundedName)}|{string.Join(",", actions)}";
                    var occurrence = signatureCounts.TryGetValue(signature, out var count) ? count + 1 : 1;
                    signatureCounts[signature] = occurrence;
                    var reference = $"d-{ShortHash($"{signature}|{occurrence}")}";
                    targets.Add(new TargetState(reference, element, bounds, boundedName, normalizedRole, secure, actions));
                }
                var walker = TreeWalker.ControlViewWalker;
                for (var child = walker.GetFirstChild(element); child is not null; child = walker.GetNextSibling(child)) queue.Enqueue(child);
            }
            catch (ElementNotAvailableException) { }
            catch (InvalidOperationException) { }
        }

        NativeMethods.GetWindowThreadProcessId(foreground, out var processId);
        var process = processId == 0 ? null : System.Diagnostics.Process.GetProcessById((int)processId);
        var appName = process?.ProcessName;
        var appIdentifier = Safe(() => process?.MainModule?.FileName);
        var windowTitle = Safe(() => root.Current.Name);
        var fingerprint = string.Join('|', new[] { appName ?? "", windowTitle ?? "" }.Concat(targets.Select(target => $"{target.Role}:{target.Name}:{target.Bounds.X:0}:{target.Bounds.Y:0}")));
        var oldTargets = (previous?.Targets ?? []).ToDictionary(target => target.Ref, StringComparer.Ordinal);
        var newTargets = targets.ToDictionary(target => target.Ref, StringComparer.Ordinal);
        var addedTargets = targets.Where(target => !oldTargets.ContainsKey(target.Ref)).ToArray();
        var changedTargets = targets.Where(target => oldTargets.TryGetValue(target.Ref, out var old) && !SameTarget(old, target)).ToArray();
        var removedTargetRefs = oldTargets.Keys.Where(reference => !newTargets.ContainsKey(reference)).Order(StringComparer.Ordinal).ToArray();
        NativeMethods.Point? cursor = NativeMethods.GetCursorPos(out var currentCursor) ? currentCursor : null;
        var session = new SessionState(payload.TaskId, snapshotId, previous?.SnapshotId, generation, targets.ToArray(), addedTargets, changedTargets, removedTargetRefs, fingerprint, cursor, DateTimeOffset.UtcNow, appName, appIdentifier, windowTitle);
        lock (gate)
        {
            foreach (var expired in sessions.Values.Where(item => DateTimeOffset.UtcNow - item.UpdatedAt > SessionLifetime).Select(item => item.TaskId).ToArray())
            {
                sessions.Remove(expired);
                generations.Remove(expired);
            }
            sessions[payload.TaskId] = session;
        }
        var didChange = previousFingerprint is not null ? !string.Equals(previousFingerprint, fingerprint, StringComparison.Ordinal) : changed;
        return Data(payload, session, [], didChange || addedTargets.Length > 0 || changedTargets.Length > 0 || removedTargetRefs.Length > 0, verified);
    }

    private static Outcome Data(ComputerDesktopPayload payload, SessionState? session, IReadOnlyList<StepEvidence> evidence, bool changed = false, bool verified = true)
    {
        var left = NativeMethods.GetSystemMetrics(NativeMethods.SmXVirtualScreen);
        var top = NativeMethods.GetSystemMetrics(NativeMethods.SmYVirtualScreen);
        var width = Math.Max(1, NativeMethods.GetSystemMetrics(NativeMethods.SmCxVirtualScreen));
        var height = Math.Max(1, NativeMethods.GetSystemMetrics(NativeMethods.SmCyVirtualScreen));
        NativeMethods.GetCursorPos(out var cursor);
        var value = new
        {
            taskId = payload.TaskId,
            action = payload.Action,
            snapshotId = session?.SnapshotId,
            previousSnapshotId = session?.PreviousSnapshotId,
            applicationName = session?.ApplicationName,
            applicationIdentifier = session?.ApplicationIdentifier,
            windowTitle = session?.WindowTitle,
            cursorX = (cursor.X - left) / (double)width,
            cursorY = (cursor.Y - top) / (double)height,
            targets = PublicTargets(session?.Targets ?? [], left, top, width, height),
            addedTargets = PublicTargets(session?.AddedTargets ?? [], left, top, width, height),
            changedTargets = PublicTargets(session?.ChangedTargets ?? [], left, top, width, height),
            removedTargetRefs = session?.RemovedTargetRefs ?? [],
            evidence,
            accessGranted = true,
            changed,
            verified
        };
        return Outcome.WithData("computerDesktop", value, "Masaüstü eylemi uygulandı ve durum yeniden gözlemlendi.");
    }

    private static object[] PublicTargets(IEnumerable<TargetState> targets, int left, int top, int width, int height) =>
        targets.Select(target => (object)new
            {
                @ref = target.Ref,
                role = target.Role,
                name = target.Name,
                frame = new { x = (target.Bounds.X - left) / width, y = (target.Bounds.Y - top) / height, width = target.Bounds.Width / width, height = target.Bounds.Height / height },
                actions = target.Actions,
                enabled = true,
                secure = target.Secure
            }).ToArray();

    private static bool SameTarget(TargetState left, TargetState right) =>
        left.Name == right.Name && left.Role == right.Role && left.Secure == right.Secure
        && left.Actions.SequenceEqual(right.Actions, StringComparer.Ordinal)
        && Math.Abs(left.Bounds.X - right.Bounds.X) < 1 && Math.Abs(left.Bounds.Y - right.Bounds.Y) < 1
        && Math.Abs(left.Bounds.Width - right.Bounds.Width) < 1 && Math.Abs(left.Bounds.Height - right.Bounds.Height) < 1;

    private static string NormalizeTargetText(string value) => string.Join(' ', value.Trim().ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    private static string ShortHash(string value)
    {
        uint hash = 2166136261;
        foreach (var character in System.Text.Encoding.UTF8.GetBytes(value)) { hash ^= character; hash *= 16777619; }
        return hash.ToString("x8");
    }

    private static string[] Actions(AutomationElement element, System.Windows.Rect bounds, bool secure)
    {
        var controlType = element.Current.ControlType;
        var editable = element.TryGetCurrentPattern(ValuePattern.Pattern, out _) || controlType == ControlType.Edit || controlType == ControlType.Document || controlType == ControlType.ComboBox;
        var actionable = editable
            || element.TryGetCurrentPattern(InvokePattern.Pattern, out _)
            || element.TryGetCurrentPattern(SelectionItemPattern.Pattern, out _)
            || element.TryGetCurrentPattern(TogglePattern.Pattern, out _)
            || element.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out _);
        var draggable = controlType == ControlType.ListItem || controlType == ControlType.TreeItem || controlType == ControlType.DataItem;
        if (bounds.IsEmpty || (!actionable && !draggable)) return [];
        var actions = new List<string> { "move", "click", "double_click", "right_click" };
        if (draggable) actions.Add("drag_drop");
        if (!secure && editable) actions.Add("type");
        return actions.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();
    }

    private static bool ResolvePoint(ComputerDesktopPayload payload, SessionState session, out NativeMethods.Point point)
    {
        if (payload.TargetRef is not null && session.Targets.FirstOrDefault(target => target.Ref == payload.TargetRef) is { } target)
        {
            point = new NativeMethods.Point { X = (int)Math.Round(target.Bounds.X + target.Bounds.Width / 2), Y = (int)Math.Round(target.Bounds.Y + target.Bounds.Height / 2) };
            return true;
        }
        if (payload.NormalizedX is { } x && payload.NormalizedY is { } y)
        {
            var left = NativeMethods.GetSystemMetrics(NativeMethods.SmXVirtualScreen);
            var top = NativeMethods.GetSystemMetrics(NativeMethods.SmYVirtualScreen);
            point = new NativeMethods.Point { X = left + (int)Math.Round(x * NativeMethods.GetSystemMetrics(NativeMethods.SmCxVirtualScreen)), Y = top + (int)Math.Round(y * NativeMethods.GetSystemMetrics(NativeMethods.SmCyVirtualScreen)) };
            return true;
        }
        point = default;
        return false;
    }

    private static WireError? ClickAction(ComputerDesktopPayload payload, SessionState session)
    {
        if (!ResolvePoint(payload, session, out var point)) return MissingTarget();
        if (payload.TargetRef is not null && session.Targets.FirstOrDefault(target => target.Ref == payload.TargetRef) is { } target && Sensitive(target))
            return new WireError("DESKTOP_SENSITIVE_ACTION_BLOCKED", "Bu hassas eylem genel masaüstü izniyle çalıştırılamaz.", "permission");
        if (Move(point) is { } moveError) return moveError;
        var (down, up) = payload.Action == "rightClick"
            ? (NativeMethods.MouseEventFRightDown, NativeMethods.MouseEventFRightUp)
            : (NativeMethods.MouseEventFLeftDown, NativeMethods.MouseEventFLeftUp);
        var count = payload.Action == "doubleClick" ? 2 : 1;
        for (var i = 0; i < count; i++)
        {
            if (!SendMouse(down) || !SendMouse(up)) return InputUnavailable();
            Thread.Sleep(70);
        }
        return null;
    }

    private static WireError? ScrollAction(ComputerDesktopPayload payload, SessionState session)
    {
        if (payload.TargetRef is not null && ResolvePoint(payload, session, out var point) && Move(point) is { } moveError) return moveError;
        var delta = (payload.Direction == "up" ? 120 : -120) * (payload.Amount ?? 2);
        return SendMouse(NativeMethods.MouseEventFWheel, unchecked((uint)delta)) ? null : InputUnavailable();
    }

    private static WireError? DragAction(ComputerDesktopPayload payload, SessionState session)
    {
        var source = session.Targets.FirstOrDefault(target => target.Ref == payload.SourceRef);
        var destination = session.Targets.FirstOrDefault(target => target.Ref == payload.DestinationRef);
        if (source is null || destination is null) return MissingTarget();
        var from = new NativeMethods.Point { X = (int)(source.Bounds.X + source.Bounds.Width / 2), Y = (int)(source.Bounds.Y + source.Bounds.Height / 2) };
        var to = new NativeMethods.Point { X = (int)(destination.Bounds.X + destination.Bounds.Width / 2), Y = (int)(destination.Bounds.Y + destination.Bounds.Height / 2) };
        if (Move(from) is { } moveError) return moveError;
        if (!SendMouse(NativeMethods.MouseEventFLeftDown)) return InputUnavailable();
        for (var step = 1; step <= 14; step++)
        {
            var x = from.X + (to.X - from.X) * step / 14;
            var y = from.Y + (to.Y - from.Y) * step / 14;
            if (!NativeMethods.SetCursorPos(x, y))
            {
                _ = SendMouse(NativeMethods.MouseEventFLeftUp);
                return InputUnavailable();
            }
            Thread.Sleep(18);
        }
        return SendMouse(NativeMethods.MouseEventFLeftUp) ? null : InputUnavailable();
    }

    private static WireError? TypeAction(ComputerDesktopPayload payload, SessionState session)
    {
        var target = session.Targets.FirstOrDefault(item => item.Ref == payload.TargetRef);
        if (target is null) return MissingTarget();
        if (target.Secure) return new WireError("DESKTOP_SECURE_FIELD_BLOCKED", "Parola ve güvenli metin alanları modele kapalıdır; bu alanı kendiniz doldurun.", "permission");
        try
        {
            target.Element.SetFocus();
            if (target.Element.TryGetCurrentPattern(ValuePattern.Pattern, out var raw) && raw is ValuePattern pattern && !pattern.Current.IsReadOnly)
            {
                pattern.SetValue(payload.Text ?? "");
                return null;
            }
            return TypeWithKeyboard(payload.Text ?? "");
        }
        catch (ElementNotAvailableException) { return MissingTarget(); }
        catch (InvalidOperationException) { return TypeWithKeyboard(payload.Text ?? ""); }
    }

    private static WireError? Hotkey(string[] keys)
    {
        var virtualKeys = new Dictionary<string, ushort>(StringComparer.OrdinalIgnoreCase)
        {
            ["command"] = 0x11, ["control"] = 0x11, ["option"] = 0x12, ["alt"] = 0x12, ["shift"] = 0x10,
            ["a"] = 0x41, ["c"] = 0x43, ["v"] = 0x56, ["x"] = 0x58, ["z"] = 0x5A, ["f"] = 0x46,
            ["enter"] = 0x0D, ["escape"] = 0x1B, ["tab"] = 0x09, ["arrowleft"] = 0x25, ["arrowup"] = 0x26, ["arrowright"] = 0x27, ["arrowdown"] = 0x28
        };
        if (keys.Length == 0 || keys.Any(key => !virtualKeys.ContainsKey(key))) return new WireError("DESKTOP_HOTKEY_BLOCKED", "Bu klavye kısayolu güvenli izin listesinde değil.", "permission");
        var values = keys.Select(key => virtualKeys[key]).ToArray();
        var inputs = values.Select(KeyDown).Concat(values.Reverse().Select(KeyUp)).ToArray();
        return NativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<NativeMethods.Input>()) == (uint)inputs.Length ? null : InputUnavailable();
    }

    private static NativeMethods.Input KeyDown(ushort key) => new() { Type = NativeMethods.InputKeyboard, Union = new NativeMethods.InputUnion { Keyboard = new NativeMethods.KeyboardInput { VirtualKey = key } } };
    private static NativeMethods.Input KeyUp(ushort key) => new() { Type = NativeMethods.InputKeyboard, Union = new NativeMethods.InputUnion { Keyboard = new NativeMethods.KeyboardInput { VirtualKey = key, Flags = NativeMethods.KeyEventFKeyUp } } };

    private static WireError? Move(NativeMethods.Point point)
    {
        if (!NativeMethods.GetCursorPos(out var start)) start = point;
        for (var step = 1; step <= 10; step++)
        {
            if (!NativeMethods.SetCursorPos(start.X + (point.X - start.X) * step / 10, start.Y + (point.Y - start.Y) * step / 10)) return InputUnavailable();
            Thread.Sleep(12);
        }
        if (!NativeMethods.GetCursorPos(out var observed) || Math.Abs(observed.X - point.X) > 3 || Math.Abs(observed.Y - point.Y) > 3) return InputUnavailable();
        AgentCursorOverlay.Show(point.X, point.Y);
        return null;
    }

    private static WireError? TypeWithKeyboard(string text)
    {
        var selectAll = new[] { KeyDown(0x11), KeyDown(0x41), KeyUp(0x41), KeyUp(0x11) };
        if (NativeMethods.SendInput((uint)selectAll.Length, selectAll, Marshal.SizeOf<NativeMethods.Input>()) != (uint)selectAll.Length) return InputUnavailable();
        var inputs = text.SelectMany(character => new[] { UnicodeKey(character, false), UnicodeKey(character, true) }).ToArray();
        if (inputs.Length == 0) return null;
        return NativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<NativeMethods.Input>()) == (uint)inputs.Length
            ? null
            : new WireError("DESKTOP_TYPE_FAILED", "Metin hedef alana güvenli biçimde yazılamadı.");
    }

    private static NativeMethods.Input UnicodeKey(char character, bool keyUp) => new()
    {
        Type = NativeMethods.InputKeyboard,
        Union = new NativeMethods.InputUnion
        {
            Keyboard = new NativeMethods.KeyboardInput
            {
                ScanCode = character,
                Flags = NativeMethods.KeyEventFUnicode | (keyUp ? NativeMethods.KeyEventFKeyUp : 0)
            }
        }
    };

    private static WireError? Wait(int milliseconds, CancellationToken cancellationToken)
    {
        cancellationToken.WaitHandle.WaitOne(milliseconds);
        cancellationToken.ThrowIfCancellationRequested();
        return null;
    }

    private static bool SendMouse(uint flags, uint data = 0)
    {
        var input = new NativeMethods.Input { Type = NativeMethods.InputMouse, Union = new NativeMethods.InputUnion { Mouse = new NativeMethods.MouseInput { Flags = flags, Data = data } } };
        return NativeMethods.SendInput(1, [input], Marshal.SizeOf<NativeMethods.Input>()) == 1;
    }

    private static bool WasInterrupted(SessionState state)
    {
        if (state.ExpectedCursor is not { } expected || !NativeMethods.GetCursorPos(out var current)) return false;
        var dx = current.X - expected.X;
        var dy = current.Y - expected.Y;
        return Math.Sqrt(dx * dx + dy * dy) > 120;
    }

    private static bool Sensitive(TargetState target)
    {
        if (target.Secure) return true;
        var text = target.Name.ToLowerInvariant();
        string[] blocked = ["delete", "erase", "remove", "sil", "kaldır", "purchase", "buy", "pay", "satın al", "öde", "send", "gönder", "transfer", "install", "uninstall"];
        return blocked.Any(text.Contains);
    }

    private static WireError MissingTarget() => new("DESKTOP_TARGET_NOT_FOUND", "Hedef güncel masaüstü görünümünde bulunamadı.");
    private static WireError InputUnavailable() => new("DESKTOP_INPUT_UNAVAILABLE", "İşletim sistemi giriş eylemini kabul etmedi.");
    private static string? Safe(Func<string?> value) { try { return value(); } catch { return null; } }

    public void Dispose()
    {
        lock (gate)
        {
            sessions.Clear();
            generations.Clear();
        }
        AgentCursorOverlay.Hide();
    }
}

internal static class AgentCursorOverlay
{
    private static readonly object Gate = new();
    private static CursorForm? form;
    private static Thread? thread;

    public static void Show(int x, int y)
    {
        EnsureStarted();
        var current = form;
        if (current is null || current.IsDisposed) return;
        current.BeginInvoke(new Action(() => current.ShowAt(x, y)));
    }

    public static void Hide()
    {
        var current = form;
        if (current is null || current.IsDisposed) return;
        current.BeginInvoke(new Action(current.HideNow));
    }

    private static void EnsureStarted()
    {
        lock (Gate)
        {
            if (thread?.IsAlive == true) return;
            using var ready = new ManualResetEventSlim();
            thread = new Thread(() =>
            {
                form = new CursorForm();
                ready.Set();
                System.Windows.Forms.Application.Run(form);
            }) { IsBackground = true, Name = "Wiqo desktop cursor overlay" };
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
            ready.Wait(TimeSpan.FromSeconds(2));
        }
    }

    private sealed class CursorForm : System.Windows.Forms.Form
    {
        private readonly System.Windows.Forms.Timer hideTimer = new() { Interval = 1_400 };

        protected override bool ShowWithoutActivation => true;
        protected override System.Windows.Forms.CreateParams CreateParams
        {
            get
            {
                const int wsExTransparent = 0x20;
                const int wsExToolWindow = 0x80;
                const int wsExNoActivate = 0x08000000;
                var value = base.CreateParams;
                value.ExStyle |= wsExTransparent | wsExToolWindow | wsExNoActivate;
                return value;
            }
        }

        public CursorForm()
        {
            FormBorderStyle = System.Windows.Forms.FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            Size = new System.Drawing.Size(30, 30);
            BackColor = System.Drawing.Color.Magenta;
            TransparencyKey = System.Drawing.Color.Magenta;
            hideTimer.Tick += (_, _) => HideNow();
        }

        internal void ShowAt(int x, int y)
        {
            hideTimer.Stop();
            Location = new System.Drawing.Point(x - 15, y - 15);
            Show();
            Invalidate();
            hideTimer.Start();
        }

        internal void HideNow()
        {
            hideTimer.Stop();
            Hide();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) hideTimer.Dispose();
            base.Dispose(disposing);
        }

        protected override void OnPaint(System.Windows.Forms.PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            using var fill = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(70, 139, 92, 246));
            using var pen = new System.Drawing.Pen(System.Drawing.Color.FromArgb(139, 92, 246), 2);
            e.Graphics.FillEllipse(fill, 2, 2, 26, 26);
            e.Graphics.DrawEllipse(pen, 5, 5, 20, 20);
        }
    }
}
