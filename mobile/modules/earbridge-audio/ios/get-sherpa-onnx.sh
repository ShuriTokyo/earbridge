#!/bin/bash
# Gets sherpa-onnx's iOS framework (the C API, with ONNX Runtime linked in) into Frameworks/,
# checked by its SHA-256. The podspec runs this when the framework is missing. Keep the
# version the same as Android's (android/build.gradle): voice prints are only alike when
# made the same way.
set -euo pipefail

VERSION=1.13.8
SHA256=e259a7d3b38ad7dec49bb078252a30bb42ede8355e2bb130cf8c1c78ed131f75
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v${VERSION}-ios-shared-onnxruntime-static.xcframework.zip"

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 3 -o "$work/sherpa.zip" "$URL"
actual="$(shasum -a 256 "$work/sherpa.zip" | cut -d' ' -f1)"
if [ "$actual" != "$SHA256" ]; then
  echo "sherpa-onnx download damaged: SHA-256 $actual, expected $SHA256" >&2
  exit 1
fi
unzip -q "$work/sherpa.zip" -d "$work/unzipped"
mkdir -p "$here/Frameworks"
rm -rf "$here/Frameworks/SherpaOnnxC.xcframework"
mv "$work/unzipped/SherpaOnnxC.xcframework" "$here/Frameworks/"
