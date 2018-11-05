#!/bin/bash -eux
# This script is intended to be ran in the docker container

if [[ $# != 2 ]]; then
  echo "Usage: $0 <revision/branch> <workdir>"
  exit 1
fi

get_abs_filename() {
  # $1 : relative filename
  echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
}

REV=$1
DEST=$(get_abs_filename $2)

mkdir -p $DEST
cd $DEST
[[ ! -d source ]] && git clone https://github.com/llvm-project/llvm-project-20170507.git source
cd source
git checkout $REV
mkdir -p ../ReleaseStage1
cd ../ReleaseStage1
cmake ../source/llvm/ \
  -DLLVM_TARGETS_TO_BUILD=Native \
  -DCMAKE_BUILD_TYPE=Release \
 '-DLLVM_ENABLE_PROJECTS=clang;lld;compiler-rt;libcxx' \
 -DCLANG_PLUGIN_SUPPORT=OFF \
 -DLLVM_ENABLE_PLUGINS=OFF \
 -DLLVM_BUILD_TOOLS=OFF \
 -DLIBCXX_CXX_ABI=libstdc++

make -j $(nproc)

mkdir -p ../ReleaseStage2
cd ../ReleaseStage2

cmake \
  ../source/llvm/ \
  -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS="clang;lld;compiler-rt;libcxx" \
  -DCLANG_PLUGIN_SUPPORT=ON \
  -DLLVM_ENABLE_PLUGINS=OFF \
  -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_ENABLE_LTO=THIN \
  -DCMAKE_C_COMPILER=`pwd`/../ReleaseStage1/bin/clang \
  -DCMAKE_CXX_COMPILER=`pwd`/../ReleaseStage1/bin/clang++ \
  -DLLVM_ENABLE_LLD=ON \
  -DLIBCXXABI_ENABLE_SHARED=ON \
  -DLIBCXX_CXX_ABI=libsupc++ \
  -DCMAKE_INSTALL_PREFIX=/usr


DESTDIR=$DEST/clang-install make -j $(nproc) install-libcxx install-lld install-compiler-rt install-clang install-clang-headers llvm-config llvm-symbolizer
cp bin/llvm-config $DEST/clang-install/usr/bin/
cp bin/llvm-symbolizer $DEST/clang-install/usr/bin/

# We have a proper cross-compiler at this point, however we need to
# Explicitely cross-compile the sanitizers runtime for ARM64 to
# be able to use ASAN/UBSAN on the device

# We need a proper GNU toolchain to cross-compile (libc, etc.)
# We assume the archive contains a single "toolchain" directory
cd $DEST
curl http://git.teslamotors.com/tarballs/firmware-os/dl-cache/aarch64-gcc-5.2.0-gnu-a6c7a34.tar.gz | tar -xz

# Build the sanitizers runtime for ARM64
mkdir -p $DEST/compiler-rt
cd $DEST/compiler-rt
cmake \
  -DLLVM_ENABLE_THREADS=OFF \
  -DCMAKE_C_COMPILER=`pwd`/../ReleaseStage2/bin/clang \
  -DCMAKE_CXX_COMPILER=`pwd`/../ReleaseStage2/bin/clang++ \
  -DLLVM_CONFIG_PATH=`pwd`/../ReleaseStage2/bin/llvm-config \
  -DCMAKE_C_FLAGS="-march=armv8-a+crc+crypto -mtune=cortex-a57 --target=aarch64-tesla-linux-gnueabi -B`pwd`/../toolchain  --sysroot=`pwd`/../toolchain/aarch64-tesla-linux-gnueabi/sysroot" \
  -DCMAKE_CXX_FLAGS="-march=armv8-a+crc+crypto -mtune=cortex-a57 --target=aarch64-tesla-linux-gnueabi -B`pwd`/../toolchain  --sysroot=`pwd`/../toolchain/aarch64-tesla-linux-gnueabi/sysroot" \
  -DCMAKE_INSTALL_PREFIX= \
  -DCMAKE_C_COMPILER_TARGET=aarch64-tesla-linux-gnueabi \
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
  ../source/compiler-rt/
# Install these in the clang resource directory to allow clang to find these.
RESOURCE_DIR=`echo "" | $DEST/clang-install/usr/bin/clang++ -x c - '-###' -E 2>&1 | tr ' ' '\n' | grep -A1 resource |tail -n1 | sed 's/"//g'`
DESTDIR=$RESOURCE_DIR make -j $(nproc) install-asan install-ubsan

echo "You can now generate a package: cd $DEST/clang-install && tar -cJf ../x86_64-clang-$REV.tar.xz ."

