#!/usr/bin/env python3
"""Cross-platform dependency checker for DeerFlow."""

from __future__ import annotations

import shutil
import subprocess
import sys
from typing import Optional


def run_command(command: list[str]) -> Optional[str]:
    """Run a command and return trimmed stdout, or None on failure."""
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True, shell=False)
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout.strip() or result.stderr.strip()


def parse_node_major(version_text: str) -> Optional[int]:
    version = version_text.strip()
    if version.startswith("v"):
        version = version[1:]
    major_str = version.split(".", 1)[0]
    if not major_str.isdigit():
        return None
    return int(major_str)


def main() -> int:
    print("==========================================")
    print("  Checking Required Dependencies")
    print("==========================================")
    print()

    failed = False

    print("Checking Node.js...")
    node_path = shutil.which("node")
    if node_path:
        node_version = run_command(["node", "-v"])
        if node_version:
            major = parse_node_major(node_version)
            if major is not None and major >= 22:
                print(f"  ✓ Node.js {node_version.lstrip('v')} (>= 22 required)")
            else:
                print(
                    f"  ✗ Node.js {node_version.lstrip('v')} found, but version 22+ is required"
                )
                print("    Install from: https://nodejs.org/")
                failed = True
        else:
            print("  ✗ Unable to determine Node.js version")
            print("    Install from: https://nodejs.org/")
            failed = True
    else:
        print("  ✗ Node.js not found (version 22+ required)")
        print("    Install from: https://nodejs.org/")
        failed = True

    print()
    print("Checking pnpm...")
    if shutil.which("pnpm"):
        pnpm_version = run_command(["pnpm", "-v"])
        if pnpm_version:
            print(f"  ✓ pnpm {pnpm_version}")
        else:
            print("  ✗ Unable to determine pnpm version")
            failed = True
    else:
        print("  ✗ pnpm not found")
        print("    Install: npm install -g pnpm")
        print("    Or visit: https://pnpm.io/installation")
        failed = True

    print()
    print("Checking uv...")
    if shutil.which("uv"):
        uv_version_text = run_command(["uv", "--version"])
        if uv_version_text:
            uv_version = uv_version_text.split()[-1]
            print(f"  ✓ uv {uv_version}")
        else:
            print("  ✗ Unable to determine uv version")
            failed = True
    else:
        print("  ✗ uv not found")
        print("    Visit the official installation guide for your platform:")
        print("    https://docs.astral.sh/uv/getting-started/installation/")
        failed = True

    print()
    print("Checking nginx (or a stack that provides it)...")
    if shutil.which("nginx"):
        nginx_version_text = run_command(["nginx", "-v"])
        if nginx_version_text and "/" in nginx_version_text:
            nginx_version = nginx_version_text.split("/", 1)[1]
            print(f"  ✓ nginx {nginx_version}")
        else:
            print("  ✓ nginx (version unknown)")
    elif (sbin := (shutil.which("singularity") or shutil.which("apptainer"))):
        sver = run_command([sbin, "--version"])
        line = (sver.splitlines()[0] if sver else sbin)[:100]
        print(f"  ✓ {line}")
        print(
            "    Host nginx not required: `make singularity-start` runs nginx in the deerflow-nginx instance."
        )
    elif shutil.which("docker"):
        dver = run_command(["docker", "--version"])
        line = dver or "docker"
        print(f"  ✓ {line}")
        print(
            "    Host nginx not required: `make docker-start` runs nginx in the compose stack."
        )
    else:
        print("  ✗ nginx not found, and neither Singularity/Apptainer nor Docker is on PATH")
        print("    Local dev: install nginx — macOS: brew install nginx; Ubuntu: sudo apt install nginx")
        print("    Or use Singularity: install Apptainer/Singularity, then make singularity-init && make singularity-start")
        print("    Or use Docker: install Docker, then make docker-init && make docker-start")
        print("    nginx download: https://nginx.org/en/download.html")
        failed = True

    print()
    if not failed:
        print("==========================================")
        print("  ✓ All dependencies are installed!")
        print("==========================================")
        print()
        print("You can now run:")
        print("  make install  - Install project dependencies")
        print("  make config   - Generate local config files")
        print("  make dev      - Start development server (host nginx + processes)")
        print("  make start    - Start production server (host nginx + processes)")
        print("  make singularity-init / singularity-start  - Singularity stack (nginx in instance)")
        return 0

    print("==========================================")
    print("  ✗ Some dependencies are missing")
    print("==========================================")
    print()
    print("Please install the missing tools and run 'make check' again.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
