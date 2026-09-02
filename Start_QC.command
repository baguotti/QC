#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

if [ ! -d "${DIR}/build/VideoQC.app" ]; then
    echo "Building VideoQC.app first..."
    "${DIR}/BuildApp.sh"
fi

echo "Launching Video QC..."
open "${DIR}/build/VideoQC.app"
