#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

if [ ! -d "${DIR}/build/QCpie.app" ]; then
    echo "Building QCpie first..."
    "${DIR}/BuildApp.sh"
fi

echo "Launching QCpie..."
open "${DIR}/build/QCpie.app"
