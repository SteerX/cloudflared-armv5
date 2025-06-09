#!/bin/bash
set -euo pipefail

# Step 0: Get the required Go version from the upstream cloudflared repo
CLOUDFLARED_REPO_URL="https://github.com/cloudflare/cloudflared.git"
CLOUDFLARED_TMP_DIR="cloudflared-upstream-tmp"

if [ ! -d "$CLOUDFLARED_TMP_DIR" ]; then
  git clone --depth 1 "$CLOUDFLARED_REPO_URL" "$CLOUDFLARED_TMP_DIR"
else
  git -C "$CLOUDFLARED_TMP_DIR" fetch origin
  git -C "$CLOUDFLARED_TMP_DIR" reset --hard origin/master
fi

# Parse go.mod for the Go version (e.g., "go 1.24" or "go 1.24.2")
GO_MOD_VERSION_LINE=$(grep '^go ' "$CLOUDFLARED_TMP_DIR/go.mod" | awk '{print $2}')
# If only major.minor is specified, default patch to .0
if [[ "$GO_MOD_VERSION_LINE" =~ ^([0-9]+\.[0-9]+)$ ]]; then
  GO_MAJOR_MINOR="${BASH_REMATCH[1]}"
  GO_FULL_VERSION="${GO_MAJOR_MINOR}.0"
elif [[ "$GO_MOD_VERSION_LINE" =~ ^([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  GO_FULL_VERSION="${BASH_REMATCH[1]}"
else
  echo "Could not parse Go version from cloudflared upstream go.mod"
  exit 1
fi

GO_VERSION="go${GO_FULL_VERSION}"         # e.g., "go1.24.2"
GO_SRC_TAG="go${GO_FULL_VERSION}"         # e.g., "go1.24.2"
GO_TARBALL="go${GO_FULL_VERSION}-armv5.tar.gz"

echo "Detected required Go version: $GO_VERSION"

GO_SRC_DIR="go-src"
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

# Checkout the correct Go source version for the required Go version
if git rev-parse "$GO_SRC_TAG" >/dev/null 2>&1; then
  git checkout "$GO_SRC_TAG"
else
  # Try tag with only major.minor if full tag not found
  GO_SRC_TAG_MINOR=$(echo "$GO_FULL_VERSION" | awk -F. '{print "go"$1"."$2}')
  if git rev-parse "$GO_SRC_TAG_MINOR" >/dev/null 2>&1; then
    git checkout "$GO_SRC_TAG_MINOR"
  else
    echo "Warning: Tag $GO_SRC_TAG or $GO_SRC_TAG_MINOR not found, falling back to $GO_VERSION"
    git checkout "$GO_VERSION"
  fi
fi

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