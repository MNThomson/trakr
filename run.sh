#!/bin/bash

# Kill any running instances of trakr
pkill -x trakr 2>/dev/null && echo "Killed existing trakr instance" || echo "No existing instance running"

# Navigate to the project directory
cd "$(dirname "$0")"

# Build the app
echo "Building trakr..."
xcodebuild -scheme trakr -configuration Debug -derivedDataPath ./build -quiet build

if [ $? -eq 0 ]; then
    echo "Build successful! Launching app..."
    open ./build/Build/Products/Debug/trakr.app
else
    echo "Build failed!"
    exit 1
fi
