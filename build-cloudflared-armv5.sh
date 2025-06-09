#!/bin/bash
set -euo pipefail

# Usage:
#   CLOUDFLARED_VERSION=<tag_or_branch> ./build-cloudflared-armv5.sh
#   or
#   ./build-cloudflared-armv5.sh <tag_or_branch>
# If not specified, defaults to latest upstream tag
# Multi-stage Go bootstrap build for ARMv5 toolchain
# 1. Uses Go 1.20.7 binary to bootstrap Go 1.22.6 (amd64)
# 2. Uses Go 1.22.6 to bootstrap the required Go version for ARMv5
# 3. Packages the resulting toolchain for Docker

# Step 0: Get the required cloudflared version and Go version
CLOUDFLARED_REPO_URL="https://github.com/cloudflare/cloudflared.git"
CLOUDFLARED_TMP_DIR="cloudflared-upstream-tmp"

# Allow override of cloudflared version via env or argument (default: latest tag)
if [ $# -ge 1 ]; then
  CLOUDFLARED_VERSION="$1"
elif [ -n "${CLOUDFLARED_VERSION:-}" ]; then
  CLOUDFLARED_VERSION="$CLOUDFLARED_VERSION"
else
  # Discover latest release tag from upstream
  CLOUDFLARED_VERSION="$(git ls-remote --tags --refs $CLOUDFLARED_REPO_URL | awk -F/ '{print $NF}' | sort -V | tail -n1)"
  echo "No version specified. Using latest tag: $CLOUDFLARED_VERSION"
fi

echo "Building for cloudflared version: $CLOUDFLARED_VERSION"

# Step 1: Prepare/clone the cloudflared repo at the desired tag
rm -rf "$CLOUDFLARED_TMP_DIR"
git clone --depth 1 --branch "$CLOUDFLARED_VERSION" "$CLOUDFLARED_REPO_URL" "$CLOUDFLARED_TMP_DIR"

# Parse go.mod for the Go version (e.g., "go 1.24" or "go 1.24.2")
GO_MOD_VERSION_LINE=$(grep '^go ' "$CLOUDFLARED_TMP_DIR/go.mod" | awk '{print $2}')
if [[ "$GO_MOD_VERSION_LINE" =~ ^([0-9]+\.[0-9]+)$ ]]; then
  GO_FULL_VERSION="${BASH_REMATCH[1]}.0"
elif [[ "$GO_MOD_VERSION_LINE" =~ ^([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  GO_FULL_VERSION="${BASH_REMATCH[1]}"
else
  echo "Could not parse Go version from cloudflared upstream go.mod"
  exit 1
fi

GO_VERSION="go${GO_FULL_VERSION}"
GO_SRC_TAG="go${GO_FULL_VERSION}"
GO_TARBALL="go${GO_FULL_VERSION}-armv5.tar.gz"

echo "Detected required Go version: $GO_VERSION"

# --- Stage 0: Download Go 1.20.7 binary as initial bootstrap ---
BOOTSTRAP0_GO_VERSION="go1.20.7"
BOOTSTRAP0_GO_TARBALL="${BOOTSTRAP0_GO_VERSION}.linux-amd64.tar.gz"
BOOTSTRAP0_GO_URL="https://go.dev/dl/${BOOTSTRAP0_GO_TARBALL}"

echo "Step 1: Download Go $BOOTSTRAP0_GO_VERSION bootstrap binary"
rm -rf go-bootstrap0
if [ ! -d "go-bootstrap0" ]; then
  curl -fsSL "$BOOTSTRAP0_GO_URL" -o "$BOOTSTRAP0_GO_TARBALL"
  tar -xzf "$BOOTSTRAP0_GO_TARBALL"
  mv go go-bootstrap0
  rm "$BOOTSTRAP0_GO_TARBALL"
fi

# --- Stage 1: Build Go 1.22.6 from source using Go 1.20.7 ---
STAGE1_GO_VERSION="go1.22.6"
STAGE1_GO_SRC_DIR="go-src-stage1"
rm -rf "$STAGE1_GO_SRC_DIR"
git clone --depth 1 --branch "$STAGE1_GO_VERSION" https://go.googlesource.com/go "$STAGE1_GO_SRC_DIR"

echo "Step 2: Build Go $STAGE1_GO_VERSION for amd64 using bootstrap0"
export GOROOT_BOOTSTRAP="$(pwd)/go-bootstrap0"
export PATH="$GOROOT_BOOTSTRAP/bin:$PATH"
cd "$STAGE1_GO_SRC_DIR/src"
GOOS=linux GOARCH=amd64 ./make.bash
cd ../..

# --- Stage 2: Build Go $GO_VERSION for ARMv5 using Go 1.22.6 (stage1) ---
GO_SRC_DIR="go-src"
rm -rf "$GO_SRC_DIR"
git clone https://go.googlesource.com/go "$GO_SRC_DIR"
cd "$GO_SRC_DIR"
git fetch --all --tags

if git rev-parse "$GO_SRC_TAG" >/dev/null 2>&1; then
  git checkout "$GO_SRC_TAG"
else
  GO_SRC_TAG_MINOR=$(echo "$GO_FULL_VERSION" | awk -F. '{print "go"$1"."$2}')
  if git rev-parse "$GO_SRC_TAG_MINOR" >/dev/null 2>&1; then
    git checkout "$GO_SRC_TAG_MINOR"
  else
    echo "Warning: Tag $GO_SRC_TAG or $GO_SRC_TAG_MINOR not found, falling back to $GO_VERSION"
    git checkout "$GO_VERSION"
  fi
fi

echo "Step 3: Build Go $GO_VERSION for linux/arm (ARMv5) using stage1 Go"
export GOROOT_BOOTSTRAP="$(pwd)/../$STAGE1_GO_SRC_DIR"
export PATH="$GOROOT_BOOTSTRAP/bin:$PATH"
cd src
GOOS=linux GOARCH=arm GOARM=5 ./make.bash
cd ..

cd ..
echo "Step 4: Package built Go toolchain"
rm -f "$GO_TARBALL"
tar czf "$GO_TARBALL" go-src

echo "Go toolchain build complete: $GO_TARBALL"

echo "Toolchain tarball ready: $(realpath "$GO_TARBALL")"
echo "You can now use this tarball in your Docker build."