#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${ROVA_MAC_DERIVED_DATA:-$repo_root/build/DerivedData-Mac}"
lock_dir="${derived_data}.lock"

mkdir -p "$(dirname "$derived_data")"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "Mac derlemesi zaten çalışıyor: $lock_dir" >&2
  exit 1
fi
trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT

xcodebuild \
  -project "$repo_root/Rova.xcodeproj" \
  -scheme RovaMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  build

app_path="$derived_data/Build/Products/Debug/Wiqo.app"
if [[ ! -d "$app_path" ]]; then
  echo "Derleme tamamlandı ancak uygulama bulunamadı: $app_path" >&2
  exit 1
fi
open "$app_path"
echo "Wiqo açıldı: $app_path"
