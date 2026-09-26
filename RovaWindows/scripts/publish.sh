#!/bin/bash
# Self-contained single-file Wiqo.exe for x64 and ARM64 (no .NET install needed on the PC).
# Works on macOS/Linux (EnableWindowsTargeting) and Windows. Output: RovaWindows/dist/<rid>/Wiqo.exe
set -euo pipefail
cd "$(dirname "$0")/.."
DOTNET="${DOTNET:-$(command -v dotnet || echo "$HOME/.dotnet/dotnet")}"
for rid in win-x64 win-arm64; do
  DOTNET_CLI_TELEMETRY_OPTOUT=1 "$DOTNET" publish App/RovaWindows.App.csproj -c Release -r "$rid" --self-contained true \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true \
    -p:EnableWindowsTargeting=true -p:DebugType=none -o "dist/$rid" --nologo -v q
  echo "dist/$rid/Wiqo.exe ($(du -h "dist/$rid/Wiqo.exe" | cut -f1))"
done
