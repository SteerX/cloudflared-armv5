#!/bin/bash
set -euo pipefail

# Usage:
#   CLOUDFLARED_VERSION=<tag_or_branch> ./build-cloudflared-armv5.sh
#   or
#   ./build-cloudflared-armv5.sh <tag_or_branch>
# If not specified, defaults to latest upstream tag

# Step 0: Set variables and get the target cloudflared version
CLOUDFLARED_REPO_URL="https://github.com/cloudflare/cloudflared.git"
CLOUDFLARED_TMP_DIR="cloudflared-upstream-tmp"

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

# Step 2: Parse go.mod for the Go version (e.g., "go 1.22" or "go 1.22.3")
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

# Step 3: Download bootstrap Go compiler (amd64)
BOOTSTRAP_GO_VERSION="go1.20.7"
BOOTSTRAP_GO_TARBALL="${BOOTSTRAP_GO_VERSION}.linux-amd64.tar.gz"
BOOTSTRAP_GO_URL="https://go.dev/dl/${BOOTSTRAP_GO_TARBALL}"

echo "Step 3: Download and extract Go $BOOTSTRAP_GO_VERSION bootstrap compiler"
rm -rf go-bootstrap
if [ ! -d "go-bootstrap" ]; then
  curl -fsSL "$BOOTSTRAP_GO_URL" -o "$BOOTSTRAP_GO_TARBALL"
  tar -xzf "$BOOTSTRAP_GO_TARBALL"
  mv go go-bootstrap
  rm "$BOOTSTRAP_GO_TARBALL"
fi

# Step 4: Clone Go source at the required version
GO_SRC_DIR="go-src"
rm -rf "$GO_SRC_DIR"
git clone https://go.googlesource.com/go "$GO_SRC_DIR"
cd "$GO_SRC_DIR"
git fetch --all --tags

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

# Step 5: Build Go toolchain for linux/arm (ARMv5) using the bootstrap compiler
echo "Step 5: Build Go $GO_VERSION for linux/arm (ARMv5) using bootstrap compiler"
export GOROOT_BOOTSTRAP="$(pwd)/../go-bootstrap"
export PATH="$GOROOT_BOOTSTRAP/bin:$PATH"
cd src
GOOS=linux GOARCH=arm GOARM=5 ./make.bash
cd ..

# Step 6: Package built Go toolchain for Docker build
cd ..
echo "Step 6: Package built Go toolchain"
rm -f "$GO_TARBALL"
tar czf "$GO_TARBALL" go-src

echo "Go toolchain build complete: $GO_TARBALL"

# Step 7: Optional - print the tarball path and next steps
echo "Toolchain tarball ready: $(realpath "$GO_TARBALL")"
echo "You can now use this tarball in your Docker build."