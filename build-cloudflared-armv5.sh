#!/bin/sh

# This script sets up the environment for building the cloudflared binary

# Tolerate missing pinned_go by checking if it's set
if [ -z "$pinned_go" ]; then
    echo "Warning: pinned_go is not set; proceeding with default settings."
fi

# Set PATH correctly for the build
export PATH="/usr/local/go/bin:$PATH"

# Proceed with the build steps
# Add your build commands here

echo "Building cloudflared..."
