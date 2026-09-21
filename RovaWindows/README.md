# RovaWindows

Windows companion core for Protocol v2. The runtime deliberately advertises only the operations
implemented in `WindowsCapabilityManifest`; unsupported Mac-only operations are not sent to the
backend as available capabilities.

The project targets Windows 10 22H2+/Windows 11 with .NET 8. The MVP intentionally exposes only
system status, URL opening, running-app listing, and sandbox/computer code execution; application
opening stays hidden until the companion sends a verified application catalogue. It is UI-host agnostic:
a WinUI 3/tray shell can own pairing, token refresh, and lifecycle while reusing
`ProtocolV2Client`, `DeviceSessionClient`, and `WindowsRuntime`. Terminal execution reuses the
existing `executeCode` operation; its optional scope/shell/working-directory fields are backward
compatible with older companions.

Local verification requires a Windows machine with the .NET 8 SDK. This macOS workspace does not
have `dotnet` or the Windows SDK, so a Windows build/test is not claimed here.
