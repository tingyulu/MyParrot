#!/bin/bash
# 產出 Frameworks/whisper.xcframework(whisper.cpp 推理引擎,macOS 單平台切片)。
# 二進位 ~35MB 不進 git;clone 本 repo 後先跑這支再 build。
# 需求:Xcode(xcodebuild)+ cmake(brew install cmake)。全程 ~5-10 分鐘。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/whisper-build.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

WHISPER_REF="${WHISPER_REF:-master}"   # 可釘版本:WHISPER_REF=v1.8.0 bash scripts/fetch-whisper.sh

echo "▶ cloning whisper.cpp (${WHISPER_REF})..."
git clone --depth 1 --branch "$WHISPER_REF" https://github.com/ggml-org/whisper.cpp.git "$WORK/whisper.cpp" 2>/dev/null \
  || git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git "$WORK/whisper.cpp"
cd "$WORK/whisper.cpp"

echo "▶ deriving macOS-only build script..."
python3 - <<'PY'
lines = open('build-xcframework.sh').read().splitlines(keepends=True)
cut = next(i for i, l in enumerate(lines) if 'Building for iOS sim' in l)
head = ''.join(lines[:cut])
tail = '''echo "Building for macOS..."
cmake -B build-macos -G Xcode \\
    "${COMMON_CMAKE_ARGS[@]}" \\
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_MIN_OS_VERSION} \\
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \\
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \\
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \\
    -DWHISPER_COREML="ON" \\
    -DWHISPER_COREML_ALLOW_FALLBACK="ON" \\
    -S .
cmake --build build-macos --config Release -- -quiet

setup_framework_structure "build-macos" ${MACOS_MIN_OS_VERSION} "macos"
combine_static_libraries "build-macos" "Release" "macos" "false"

xcodebuild -create-xcframework \\
    -framework $(pwd)/build-macos/framework/whisper.framework \\
    -debug-symbols $(pwd)/build-macos/dSYMs/whisper.dSYM \\
    -output $(pwd)/build-apple/whisper.xcframework
'''
open('build-xcframework-macos.sh', 'w').write(head + tail)
PY
bash -n build-xcframework-macos.sh

echo "▶ building (this takes a few minutes)..."
bash build-xcframework-macos.sh > build.log 2>&1 || { tail -20 build.log; exit 1; }

mkdir -p "$REPO_ROOT/Frameworks"
rm -rf "$REPO_ROOT/Frameworks/whisper.xcframework"
cp -R build-apple/whisper.xcframework "$REPO_ROOT/Frameworks/"
echo "✅ Frameworks/whisper.xcframework ready"
