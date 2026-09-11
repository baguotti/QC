#!/bin/zsh
cd "$(dirname "$0")/.."

echo "==> Building QCpie (debug)..."
swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk

if [ $? -eq 0 ]; then
    echo "==> Build succeeded. Launching QCpie..."
    if [ -d "./build/QCpie.app" ]; then
        cp ./.build/debug/QCpie ./build/QCpie.app/Contents/MacOS/QCpie
        if [ -d "/Applications/QCpie.app" ]; then
            cp ./.build/debug/QCpie /Applications/QCpie.app/Contents/MacOS/QCpie 2>/dev/null || true
        fi
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ./build/QCpie.app 2>/dev/null || true
        open ./build/QCpie.app
    else
        ./.build/debug/QCpie &
    fi
else
    echo "==> Build failed."
    read -k 1 -s -p "Press any key to close..."
fi

