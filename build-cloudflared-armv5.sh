#!/bin/bash
set -euo pipefail

GO_VERSION="go1.22.0"
GO_SRC_DIR="go-src"
GO_TARBALL="go1.22-armv5.tar.gz"
DOCKER_IMAGE_NAME="cloudflared-armv5"
BOOTSTRAP_GO_VERSION="go1.20.7"
BOOTSTRAP_GO_TARBALL="${BOOTSTRAP_GO_VERSION}.linux-amd64.tar.gz"
BOOTSTRAP_GO_URL="https://go.dev/dl/${BOOTSTRAP_GO_TARBALL}"

echo "Step 1: Download and extract Go $BOOTSTRAP_GO_VERSION bootstrap compiler"
if [ ! -d "go-bootstrap" ]; then
  curl -fsSL "$BOOTSTRAP_GO_URL" -o "$BOOTSTRAP_GO_TARBALL"
  tar -xzf "$BOOTSTRAP_GO_TARBALL"
  mv go go-bootstrap
  rm "$BOOTSTRAP_GO_TARBALL"
fi

echo "Step 2: Clone Go source"
if [ ! -d "$GO_SRC_DIR" ]; then
  git clone https://go.googlesource.com/go "$GO_SRC_DIR"
fi

cd "$GO_SRC_DIR"
git fetch --all --tags
git checkout "$GO_VERSION"

echo "Step 3: Build Go $GO_VERSION for linux/arm (ARMv5) using bootstrap compiler"
export GOROOT_BOOTSTRAP="$(pwd)/../go-bootstrap"
export PATH="$GOROOT_BOOTSTRAP/bin:$PATH"

cd src
GOOS=linux GOARCH=arm GOARM=5 ./make.bash
cd ..

echo "Step 4: Package built Go toolchain"
tar czf "../$GO_TARBALL" .

cd ..

echo "Go toolchain build complete."