#!/bin/bash
set -euo pipefail

# Debug helpers: print each command and show the failing command + line on error
set -x
trap 'rc=$?; echo ">>> ERROR: command \"${BASH_COMMAND}\" failed with exit $rc at line ${LINENO}"; exit $rc' ERR

# Usage:
#   CLOUDFLARED_VERSION=<tag_or_branch> ./build-cloudflared-armv5.sh
#   or
#   ./build-cloudflared-armv5.sh <tag_or_branch>
# If not specified, defaults to latest upstream tag
# Multi-stage Go bootstrap build for ARMv5 toolchain
# 1. Uses Go 1.20.7 binary to bootstrap Go 1.22.6 (amd64)
# 2. Uses Go 1.22.6 to bootstrap the required Go version for ARMv5 (scraped from upstream cloudflared config)
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

# Robust clone that handles annotated tags and shallow environments:
# 1) shallow clone without checkout
# 2) try to fetch the specific tag (including dereferenced commit for annotated tags)
# 3) resolve tag^{commit} and checkout the commit; if that fails, try to checkout the ref directly
git clone --no-checkout --depth 1 "$CLOUDFLARED_REPO_URL" "$CLOUDFLARED_TMP_DIR"
(
  cd "$CLOUDFLARED_TMP_DIR"

  # Try to fetch the specific tag (this will create a refs/tags/<tag> and the deref refs/tags/<tag>^{})
  # If that fails (some remotes don't allow fetching single refs with depth), fall back to fetching tags
  if ! git fetch --depth 1 origin "refs/tags/$CLOUDFLARED_VERSION:refs/tags/$CLOUDFLARED_VERSION" 2>/dev/null; then
    git fetch --tags --depth 1 origin || git fetch --tags origin
  fi

  # Try to resolve the tag to a commit (handles annotated tags)
  if commit_sha=$(git rev-parse --verify --quiet "refs/tags/$CLOUDFLARED_VERSION^{commit}" 2>/dev/null); then
    git checkout "$commit_sha"
  else
    # Fallback: try to checkout branch or lightweight tag by name
    if git rev-parse --verify --quiet "$CLOUDFLARED_VERSION" >/dev/null 2>&1; then
      git checkout "$CLOUDFLARED_VERSION"
    else
      echo "Error: Could not resolve or checkout '$CLOUDFLARED_VERSION' (not found as tag, annotated-tag, or branch)"
      exit 1
    fi
  fi
)

# DIAGNOSTICS: print repo state to help CI debugging
# (kept separate so it won't interfere with normal flow unless CI fails)
echo "=== DIAGNOSTICS: upstream repo state ==="
echo "pwd: "+(pwd)"
# Show current HEAD info for the cloned repo
git -C "$CLOUDFLARED_TMP_DIR" show --no-patch --format='%H %an %ad %D' HEAD || true
# List tags available locally
git -C "$CLOUDFLARED_TMP_DIR" show-ref --tags || true
# List top-level files to ensure go.mod/cfsetup.yaml exist
ls -la "$CLOUDFLARED_TMP_DIR" || true
# Show heads of go.mod and cfsetup.yaml if present
[ -f "$CLOUDFLARED_TMP_DIR/go.mod" ] && echo "--- go.mod (head) ---" && head -n 20 "$CLOUDFLARED_TMP_DIR/go.mod" || echo "no go.mod"
[ -f "$CLOUDFLARED_TMP_DIR/cfsetup.yaml" ] && echo "--- cfsetup.yaml (head) ---" && head -n 20 "$CLOUDFLARED_TMP_DIR/cfsetup.yaml" || echo "no cfsetup.yaml"
echo "=== END DIAGNOSTICS ==="

# --- Updated version scraping logic below ---

# Try to extract the "go-boring" version from cfsetup.yaml if present, otherwise fallback to go.mod
CFSETUP_YAML="$CLOUDFLARED_TMP_DIR/cfsetup.yaml"
if [ -f "$CFSETUP_YAML" ]; then
  # Try to extract the go-boring version, fallback to normal go version if not found.
  GO_BORING_VERSION_LINE=$(grep '^pinned_go:' "$CFSETUP_YAML" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?")
  if [ -n "${GO_BORING_VERSION_LINE:-}" ]; then
    # Handle optional "-1" suffix, strip it for Go upstream
    GO_FULL_VERSION=$(echo "$GO_BORING_VERSION_LINE" | sed 's/-.*//')
    echo "Detected Go version from cfsetup.yaml: $GO_FULL_VERSION"
  else
    # Fallback: parse go.mod for the Go version (e.g., "go 1.24" or "go 1.24.2")
    GO_MOD_VERSION_LINE=$(grep '^go ' "$CLOUDFLARED_TMP_DIR/go.mod" | awk '{print $2}')
    if [[ "$GO_MOD_VERSION_LINE" =~ ^([0-9]+\.[0-9]+)$ ]]; then
      GO_FULL_VERSION="${BASH_REMATCH[1]}.0"
    elif [[ "$GO_MOD_VERSION_LINE" =~ ^([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
      GO_FULL_VERSION="${BASH_REMATCH[1]}"
    else
      echo "Could not parse Go version from cloudflared upstream go.mod"
      exit 1
    fi
    echo "Detected Go version from go.mod: $GO_FULL_VERSION"
  fi
else
  # Fallback: parse go.mod if cfsetup.yaml missing (should not happen)
  GO_MOD_VERSION_LINE=$(grep '^go ' "$CLOUDFLARED_TMP_DIR/go.mod" | awk '{print $2}')
  if [[ "$GO_MOD_VERSION_LINE" =~ ^([0-9]+\.[0-9]+)$ ]]; then
    GO_FULL_VERSION="${BASH_REMATCH[1]}.0"
  elif [[ "$GO_MOD_VERSION_LINE" =~ ^([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    GO_FULL_VERSION="${BASH_REMATCH[1]}"
  else
    echo "Could not parse Go version from cloudflared upstream go.mod"
    exit 1
  fi
  echo "Detected Go version from go.mod: $GO_FULL_VERSION"
fi

GO_VERSION="go${GO_FULL_VERSION}"
GO_SRC_TAG="go${GO_FULL_VERSION}"
GO_TARBALL="go${GO_FULL_VERSION}-armv5.tar.gz"

echo "Using required Go version: $GO_VERSION"

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
tar czf "$GO_TARBALL" -C go-src .

echo "Go toolchain build complete: $GO_TARBALL"

echo "Toolchain tarball ready: $(realpath "$GO_TARBALL")"
echo "You can now use this tarball in your Docker build."

# ---- Output Go version and tarball name for CI/CD ----
echo "GO_FULL_VERSION=$GO_FULL_VERSION" > toolchain-meta.env
echo "GO_TARBALL=$GO_TARBALL" >> toolchain-meta.env
echo "Wrote Go version and tarball name to toolchain-meta.env"