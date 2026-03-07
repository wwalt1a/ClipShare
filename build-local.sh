#!/bin/bash
BUILD_NUMBER=$(git rev-list --count HEAD)
echo "Building APK with build number: $BUILD_NUMBER"
C:/flutter/bin/flutter.bat build apk --build-number=$BUILD_NUMBER
echo "APK built successfully!"
ls -lh build/app/outputs/flutter-apk/app-release.apk
