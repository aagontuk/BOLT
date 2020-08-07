#!/bin/bash

# Script for collecting profiles

SCRIPTDIR=$(pwd)
PROFDIR="${HOME}/universe/programming/repos/profiles"

cd ${PROFDIR}

# Download llvm-project if no exist
if [ ! -d llvm-project ]; then
    git clone https://github.com/llvm/llvm-project.git
fi

CLANG_SRC_DIR=${PROFDIR}/llvm-project
cd $CLANG_SRC_DIR

# Build all the versions specified
clang_versions=$(git tag -l | grep 10)
clang_versions_count=$(echo $clang_versions | wc -w)
echo "clang version specified: $clang_versions_count"

CLANG_BUILD_DIR=${PROFDIR}/clang_builds
if [ ! -d $CLANG_BUILD_DIR ]; then
    echo "Creating CLANG_BUILD_DIR"
    mkdir -v $CLANG_BUILD_DIR
fi

BUILD_FLAGS="-DLLVM_ENABLE_PROJECTS="clang;lld""
BUILD_FLAGS="${BUILD_FLAGS} -DLLVM_TARGETS_TO_BUILD=X86 -DCMAKE_BUILD_TYPE=Release"
BUILD_FLAGS="${BUILD_FLAGS} -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_ASM_COMPILER=lld"

# Flag needed for llvm-bolt to work
export LDFLAGS="-Wl,-q"

for ver in $clang_versions; do
    VERSION_BUILD_DIR="${CLANG_BUILD_DIR}/${ver}"
    if [ -d $VERSION_BUILD_DIR ]; then
        continue
    fi
    
    echo "Creating VERSION_BUILD_DIR"
    mkdir -v $VERSION_BUILD_DIR
    cd $CLANG_SRC_DIR
    git checkout $ver
    cd $VERSION_BUILD_DIR
    cmake -G Ninja ${CLANG_SRC_DIR}/llvm ${BUILD_FLAGS} -DCMAKE_INSTALL_PREFIX="${VERSION_BUILD_DIR}/install"
    ninja -j4 install
    break
done

# Collect profiles
sample_periods=(320000 10000 20000 30000 40000 50000)

# Save all profiles in this directory
CLANG_PROFILE_DIR=${PROFDIR}/clang_profiles
if [ ! -d $CLANG_PROFILE_DIR ]; then
    mkdir -v $CLANG_PROFILE_DIR
fi

for sp in ${sample_periods[@]}; do
    
    for ver in $clang_versions; do
        # collect profile for clang input
        VERSION_BIN_DIR=${CLANG_BUILD_DIR}/${ver}/install/bin
        PROFILE_BUILD_DIR=${CLANG_BUILD_DIR}/prof_build
        PROFILE_NAME=${CLANG_PROFILE_DIR}/${ver}_clang_${sp}
        
        BUILD_FLAGS="-DLLVM_TARGETS_TO_BUILD=X86 -DCMAKE_BUILD_TYPE=Release"
        BUILD_FLAGS="${BUILD_FLAGS} -DCMAKE_C_COMPILER=${VERSION_BIN_DIR}/clang"
        BUILD_FLAGS="${BUILD_FLAGS} -DCMAKE_CXX_COMPILER=${VERSION_BIN_DIR}/clang++"
        BUILD_FLAGS="${BUILD_FLAGS} -DCMAKE_ASM_COMPILER=${VERSION_BIN_DIR}/lld"

        if [ -d $PROFILE_BUILD_DIR ]; then
            rmdir $PROFILE_BUILD_DIR
        fi

        echo "Creating PROFILE_BUILD_DIR"
        mkdir -v $PROFILE_BUILD_DIR

        # build
        echo "Collecting profile for ${ver} with ${sp} sampling period"
        cd $CLANG_SRC_DIR
        git checkout llvmorg-7.0.0
        cd $PROFILE_BUILD_DIR
        cmake -G Ninja ${CLANG_SRC_DIR}/llvm ${BUILD_FLAGS} -DCMAKE_INSTALL_PREFIX="${PROFILE_BUILD_DIR}/install"
        perf record -e cycles:u -j any,u -o ${PROFILE_NAME}.data -- ninja clang
        perf2bolt ${VERSION_BIN_DIR}/clang-10 -p ${PROFILE_NAME}.data -o ${PROFILE_NAME}.fdata -w ${PROFILE_NAME}.yaml
        break
    done

    break
done
