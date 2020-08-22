#!/bin/bash

# Script for collecting profiles

SCRIPTDIR=$(pwd)

if [ -z "$1" ]; then
    PROFDIR=$HOME/profquality
    echo "Using default directory: ${PROFDIR}"
else
    PROFDIR=$1
fi

if [ ! -d $PROFDIR ]; then
    echo "Directory ${PROFDIR} doesn't exists!"
    mkdir -pv ${PROFDIR}
fi

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
echo "Number of clang-10 versions: $clang_versions_count"
echo "Installing:"
echo $clang_versions

CLANG_BUILD_DIR=${PROFDIR}/clang_builds
if [ ! -d $CLANG_BUILD_DIR ]; then
    echo "Creating CLANG_BUILD_DIR"
    mkdir -v $CLANG_BUILD_DIR
fi

BUILD_FLAGS="-DLLVM_ENABLE_PROJECTS='clang;lld'"

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
    echo "Building ${ver}"
    cmake -G Ninja ${CLANG_SRC_DIR}/llvm ${BUILD_FLAGS}
    ninja
done

# Collect profiles
sample_periods=(320000 160000 80000 40000 20000)

# Save all profiles in this directory
CLANG_PROFILE_DIR=${PROFDIR}/clang_profiles
if [ ! -d $CLANG_PROFILE_DIR ]; then
    mkdir -v $CLANG_PROFILE_DIR
fi

# Change temporary files dierectory for perf2bolt
export TMPDIR=$PROFDIR

for sp in ${sample_periods[@]}; do
    
    for ver in $clang_versions; do
        # collect profile for clang input
        VERSION_BIN_DIR=${CLANG_BUILD_DIR}/${ver}/bin
        PROFILE_BUILD_DIR=${CLANG_BUILD_DIR}/prof_build
        PROFILE_NAME=${CLANG_PROFILE_DIR}/${ver}_clang_${sp}

        # Don't bother if .fdata already exists
        if [ -e "${PROFILE_NAME}.fdata" ]; then
            echo "${PROFILE_NAME}.fdata already exists"
            continue
        fi
        
        # Check if sufficient space is available
        # Go ahead if and only if enough space available
        # else wait for perf2bolt processes to finish and make some room
        SPACE_CURRENT=$(df $PROFDIR | grep / | awk '{print $4}') 
        SPACE_LIMIT=2147483648

        while [ $SPACE_CURRENT -lt $SPACE_LIMIT ]; do
            echo "Not enough space. Waiting for pef2bolt to finish. Sleeping..."
            sleep 60
            SPACE_CURRENT=$(df $PROFDIR | grep / | awk '{print $4}') 
        done

        # Collect profile if it doesn't exist
        if [ ! -e "${PROFILE_NAME}.data" ]; then
            BUILD_FLAGS="-DLLVM_ENABLE_PROJECTS=clang"
            BUILD_FLAGS="${BUILD_FLAGS} -DLLVM_TARGETS_TO_BUILD=X86 -DCMAKE_BUILD_TYPE=Release"
            BUILD_FLAGS="${BUILD_FLAGS} -DCMAKE_C_COMPILER=${VERSION_BIN_DIR}/clang"
            BUILD_FLAGS="${BUILD_FLAGS} -DCMAKE_CXX_COMPILER=${VERSION_BIN_DIR}/clang++"
            BUILD_FLAGS="${BUILD_FLAGS} -DCMAKE_ASM_COMPILER=${VERSION_BIN_DIR}/lld"

            if [ -d $PROFILE_BUILD_DIR ]; then
                rm -r $PROFILE_BUILD_DIR
            fi

            echo "Creating PROFILE_BUILD_DIR"
            mkdir -v $PROFILE_BUILD_DIR

            # collect profile
            echo "Collecting profile for ${ver} with ${sp} sampling period"
            cd $CLANG_SRC_DIR
            git checkout llvmorg-7.0.0
            cd $PROFILE_BUILD_DIR
            cmake -G Ninja ${CLANG_SRC_DIR}/llvm ${BUILD_FLAGS}
            perf record -e cycles:u -j any,u -o ${PROFILE_NAME}.data -- ninja clang
        fi

        # convert .data to .fdata and rmove .data
        perf2bolt ${VERSION_BIN_DIR}/clang-10 -p ${PROFILE_NAME}.data -o ${PROFILE_NAME}.fdata && rm ${PROFILE_NAME}.data &
    done

done

# Wait for all the perf2bolt processes to finish
wait

# BOLTify all the clang versions with the collected profiles
for prof in $CLANG_PROFILE_DIR/*.fdata; do
    PROF_NAME=$(basename $prof)
    PROF_NAME=${PROF_NAME%.*}
    for ver in $clang_versions; do
        VERSION_BIN_DIR=${CLANG_BUILD_DIR}/${ver}/bin
        
        echo "BOLTing ${ver} usign ${prof}"
        llvm-bolt ${VERSION_BIN_DIR}/clang-10 -o ${VERSION_BIN_DIR}/clang-10.${PROF_NAME} \
            -data=${prof} -reorder-blocks=cache+ -reorder-functions=hfsort+ -split-functions=3 \
            -split-all-cold -dyno-stats -icf=1 -use-gnu-stack \
            -cg-profile-file=${CLANG_PROFILE_DIR}/${PROF_NAME}.cgprofile \
            -bb-profile-file=${CLANG_PROFILE_DIR}/${PROF_NAME}.bbprofile 
    done
done
