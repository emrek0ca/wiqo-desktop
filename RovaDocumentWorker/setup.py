"""Explicit installation into the current user's private application data, never app startup."""
import argparse
import hashlib
import urllib.request
import os
from pathlib import Path
import shutil
import subprocess
import sys


def runtime_root():
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "Wiqo" / "Documents"
    if os.name == "nt":
        return Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local")) / "Wiqo" / "Documents"
    return Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "wiqo" / "documents"


def install_ocr_languages(root):
    # Small, versioned language assets; never change system-wide Tesseract data.
    revision = "87416418657359cb625c412a48b6e1d6d41c29bd"
    hashes = {"tur": "7393381111e1152420fc4092cb44eef4237580d21b92bf30d7d221aad192c6b7",
              "eng": "7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2",
              "osd": "9cf5d576fcc47564f11265841e5ca839001e7e6f38ff7f7aacf46d15a96b00ff"}
    directory = root / "tessdata"
    directory.mkdir(parents=True, exist_ok=True)
    configs = directory / "configs"
    configs.mkdir(exist_ok=True)
    # A private tessdata directory also needs the named output config used by Docling.
    (configs / "tsv").write_text("tessedit_create_tsv 1\n", encoding="ascii")
    for language, digest in hashes.items():
        destination = directory / (language + ".traineddata")
        if destination.exists() and hashlib.sha256(destination.read_bytes()).hexdigest() == digest:
            continue
        with urllib.request.urlopen(f"https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/{revision}/{language}.traineddata", timeout=30) as source:
            data = source.read(16 * 1024 * 1024 + 1)
        if len(data) > 16 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != digest:
            raise OSError("OCR model integrity check failed")
        temporary = destination.with_suffix(".part")
        temporary.write_bytes(data)
        temporary.replace(destination)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--layout", action="store_true", help="Install optional Docling and its local layout models; requires a local Tesseract executable; installs private OCR language data")
    args = parser.parse_args()
    uv = shutil.which("uv")
    if not uv:
        parser.exit(1, "uv is required to install the optional document environment.\n")
    root = runtime_root()
    root.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, UV_PROJECT_ENVIRONMENT=str(root / ".venv"))
    command = [uv, "sync", "--project", str(Path(__file__).parent), "--frozen", "--no-dev", "--python", "3.11"]
    if args.layout:
        command += ["--extra", "layout"]
    subprocess.run(command, env=env, check=True, timeout=600)
    if args.layout:
        install_ocr_languages(root)
        executable = root / ".venv" / ("Scripts/docling-tools.exe" if os.name == "nt" else "bin/docling-tools")
        subprocess.run([str(executable), "models", "download", "layout", "tableformer", "--output-dir", str(root / "models")], check=True, timeout=600)
    print("Document environment ready:", root)


if __name__ == "__main__":
    try:
        main()
    except (subprocess.SubprocessError, OSError):
        sys.exit("Document setup did not complete. Existing native readers remain available.")
