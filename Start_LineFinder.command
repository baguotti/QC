#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

if [ ! -d "${DIR}/build/THE LINEFINDER 5000.app" ]; then
    echo "Building THE LINEFINDER 5000 first..."
    "${DIR}/BuildApp.sh"
fi

echo "Launching THE LINEFINDER 5000..."
open "${DIR}/build/THE LINEFINDER 5000.app"
