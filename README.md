# Cloudflared Docker Image for ARMv5 Devices (e.g., MikroTik hEX refresh) repository

## Overview

This guide outlines a robust, multi-stage Docker build process to create a Cloudflared Docker image compatible with ARMv5 architecture devices such as the MikroTik hEX refresh. The process addresses the challenges of cross-compiling Go and Cloudflared for ARMv5, ensuring the final image runs efficiently on resource-constrained hardware.

---

## Key Objectives

- **Multi-stage Docker build**: Separate build environment from runtime to minimize final image size.
- **Prebuild Go toolchain for ARMv5**: Compile Go 1.22 from source for ARMv5 using a bootstrap compiler, then package and reuse it in the build.
- **Build Cloudflared using the ARMv5 Go toolchain**: Compile Cloudflared with the custom Go toolchain targeting ARMv5.
- **Produce a minimal runtime image**: Include only necessary runtime dependencies and the Cloudflared binary.
- **Ensure compatibility with ARMv5 devices**: Specifically tested for MikroTik hEX refresh and similar hardware.

---

## Docker Hub Image:
  https://hub.docker.com/r/steerx/cloudflared-armv5

---

## Detailed Process

### 1. Prebuild Go 1.22 Toolchain for ARMv5

- **Why?**  
  Official Go binaries for ARMv5 are not readily available for the latest Go versions. Building Go 1.22 from source ensures compatibility and access to the latest language features required by Cloudflared.

- **How?**  
  - Use a bootstrap Go compiler (e.g., Go 1.20.7) on an amd64 host to build Go 1.22 for ARMv5.
  - Package the full Go distribution (including `bin/`, `src/`, and `pkg/` directories) into a tarball (`go1.22-armv5.tar.gz`).
  - Ensure the tarball structure matches Go’s expected layout for seamless integration.

- **Outcome**  
  A reusable Go 1.22 toolchain tarball tailored for ARMv5.

---

### 2. Multi-Stage Dockerfile

- **Stage 1: Builder**

  - **Base Image**: Debian stable for a consistent and minimal build environment.
  - **Setup**: Install build dependencies (`git`, `pkg-config`, `libssl-dev`, etc.).
  - **Go Toolchain**: Extract the prebuilt Go 1.22 toolchain tarball into `/usr/local/go`.
  - **Directory Structure Fix**: Move Go binaries from nested `bin/linux_arm` to `bin/` to match Go’s expected layout.
  - **Environment Variables**: Set `GOROOT`, `PATH`, `GOPATH`, `GO111MODULE`, and `GOPROXY` to ensure Go commands work correctly.
  - **Cloudflared Build**:
    - Clone the Cloudflared repository.
    - Checkout the stable `master` branch.
    - Download Go modules.
    - Build Cloudflared targeting ARMv5 (`GOOS=linux GOARCH=arm GOARM=5`).

- **Stage 2: Runtime**

  - **Base Image**: Debian stable-slim for a lightweight runtime environment.
  - **Setup**: Install only essential runtime dependencies (`ca-certificates`, `curl`).
  - **Copy Binary**: Copy the Cloudflared binary from the builder stage.
  - **Entrypoint**: Run Cloudflared with the tunnel token passed as an environment variable.

---

## Usage Instructions

---

### Deploy and Run on ARMv5 Device (e.g., MikroTik hEX refresh)

Pull the image on your device (if pushed to a registry):

```bash
docker pull steerx/cloudflared-armv5:latest
```

Run the container with your Cloudflared tunnel token:

```bash
docker run -d --restart unless-stopped \
  -e TUNNEL_TOKEN="your_actual_tunnel_token_here" \
  --name cloudflared \
  steerx/cloudflared-armv5:latest
```

---

### Deploy on MikroTik

Example command:
```bash
/container/add remote-image=steerx/cloudflared-armv5:latest interface=veth1 root-dir=disk1/images/cloudflared-armv5 envlist=TUNNEL_TOKEN name=cloudflared-armv5
```
---

### Notes on `TUNNEL_TOKEN`

- The `TUNNEL_TOKEN` environment variable is required to authenticate and configure the Cloudflared tunnel.
- Replace `"your_actual_tunnel_token_here"` with your real tunnel token obtained from your Cloudflare dashboard.
- Passing the token as an environment variable keeps your image generic and secure.
- On MikroTik it needs to be added in Envs where `TUNNEL_TOKEN` is set as `Name` and `Key` and your token as `Value`

---

## Summary

This process enables you to build and deploy a Cloudflared Docker image optimized for ARMv5 devices like the MikroTik hEX refresh. By prebuilding the Go toolchain and using a multi-stage Docker build, you ensure compatibility, efficiency, and ease of deployment.

---
