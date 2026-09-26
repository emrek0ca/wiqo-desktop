#!/bin/bash
# One command for the companion contract: reference vectors, the Mac (Swift) and Windows (C#)
# implementations against them, and the Mac/Windows operation parity report.
# Usage: contracts/companion/check.sh [--write]   (--write regenerates vectors.json/operations.json)
set -euo pipefail
cd "$(dirname "$0")/../.."
DIR=contracts/companion
BUILD="${TMPDIR:-/tmp}/wiqo-companion-contract"
mkdir -p "$BUILD"

if [[ "${1:-}" == "--write" ]]; then node "$DIR/generate-vectors.mjs"; else node "$DIR/generate-vectors.mjs" --check; fi

xcrun swiftc -O -o "$BUILD/contract-swift" RovaShared/*.swift "$DIR/swift/main.swift"
"$BUILD/contract-swift" "$DIR/vectors.json" "$DIR/operations.json" ${1:-}

DOTNET="${DOTNET:-$(command -v dotnet || echo "$HOME/.dotnet/dotnet")}"
DOTNET_CLI_TELEMETRY_OPTOUT=1 "$DOTNET" test RovaWindows/Tests/RovaWindows.Tests.csproj -p:EnableWindowsTargeting=true --nologo -v q | tail -1

node "$DIR/parity-report.mjs"
