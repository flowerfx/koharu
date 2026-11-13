#!/bin/sh
# Builds the stable-diffusion-native Android runtime with Vulkan into
# Vendor/sd-android-vulkan-v0.3.0-3 (git-ignored); app/build.gradle.kts uses it
# instead of the CPU-only release runtime when it exists.
#
# Same sources as the published v0.3.0-3 release plus an android-arm64-vulkan
# target. Shaders must be compiled with the LunarG Vulkan SDK glslc
# (shaderc 2023.8, as upstream's Linux/Windows Vulkan builds): the NDK's older
# glslc emits a tri_f16 module that upstream's NaN guard rejects. The build
# fails if that guard fails; never relax it.
#
# Needs: Android NDK r28 (ANDROID_NDK_HOME), Vulkan SDK 1.4.313.1 in
# ~/VulkanSDK/1.4.313.1, cmake, ninja, git, python3.
set -eu
TAG=v0.3.0-3
NDK=${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/28.0.12674087}
GLSLC=${GLSLC:-$HOME/VulkanSDK/1.4.313.1/macOS/bin/glslc}
HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$HERE/.sd-vulkan-build}
OUT=$HERE/Vendor/sd-android-vulkan-$TAG
mkdir -p "$WORK" && cd "$WORK"
[ -d src ] || git clone -q --depth 1 --branch "$TAG" --recurse-submodules --shallow-submodules https://github.com/leehack/stable-diffusion-native.git src
[ -d vkh ] || git clone -q --depth 1 https://github.com/KhronosGroup/Vulkan-Headers.git vkh
if [ ! -d spirv-prefix ]; then
  git clone -q --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv
  cmake -S spirv -B spirv/build -G Ninja -DCMAKE_INSTALL_PREFIX="$WORK/spirv-prefix" -DSPIRV_HEADERS_ENABLE_TESTS=OFF >/dev/null
  cmake --install spirv/build >/dev/null
fi
python3 - "$WORK" "$NDK" "$GLSLC" <<'PY'
import sys
work, ndk, glslc = sys.argv[1:]
path = f"{work}/src/tools/build.py"
source = open(path).read()
if "android-arm64-vulkan" not in source:
    anchor = '        *_desktop("linux-x64", "linux", "libstable-diffusion.so", "x86_64"),'
    target = f'''        Target(
            "android-arm64-vulkan", "android", "libstable-diffusion.so", ("vulkan", "cpu"),
            (
                "-DANDROID_ABI=arm64-v8a",
                f"-DANDROID_PLATFORM={{ANDROID_PLATFORM}}",
                "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON",
                f"-DGGML_CPU_ARM_ARCH={{ANDROID_ARM64_CPU_ARCH}}",
                "-DSD_VULKAN=ON",
                "-DVulkan_INCLUDE_DIR={work}/vkh/include",
                "-DSPIRV-Headers_DIR={work}/spirv-prefix/share/cmake/SPIRV-Headers",
                "-DCMAKE_CXX_FLAGS=-I{work}/spirv-prefix/include",
                "-DVulkan_LIBRARY={ndk}/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/aarch64-linux-android/28/libvulkan.so",
                "-DVulkan_GLSLC_EXECUTABLE={glslc}",
            ),
        ),
'''
    assert source.count(anchor) == 1
    open(path, "w").write(source.replace(anchor, target + anchor))
PY
cd src
ANDROID_NDK_HOME=$NDK python3 tools/build.py build --target android-arm64-vulkan
rm -rf "$OUT" && mkdir -p "$OUT"
cp -R bin/android-arm64-vulkan/. "$OUT/"
echo "Vulkan runtime: $OUT"
