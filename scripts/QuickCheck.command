#!/bin/zsh
cd "$(dirname "$0")/.."

echo "==> Building QCpie (debug)..."
swift build --sdk "$(xcrun --show-sdk-path)"

if [ $? -eq 0 ]; then
    echo "==> Build succeeded. Launching QCpie..."
    if [ -d "./build/QCpie.app" ]; then
        # Re-sign each bundle after swapping its binary: the debug binary's own ad-hoc signature names it by a hash, so
        # macOS wouldn't see it as com.studio.qcpie (notifications, for one, never register).
        cp ./.build/debug/QCpie ./build/QCpie.app/Contents/MacOS/QCpie
        codesign --force --deep --sign - ./build/QCpie.app 2>/dev/null || true
        if [ -d "/Applications/QCpie.app" ]; then
            cp ./.build/debug/QCpie /Applications/QCpie.app/Contents/MacOS/QCpie 2>/dev/null \
                && codesign --force --deep --sign - /Applications/QCpie.app 2>/dev/null || true
        fi
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ./build/QCpie.app 2>/dev/null || true
        open ./build/QCpie.app
    else
        ./.build/debug/QCpie &
    fi
else
    echo "==> Build failed."
    read -k 1 -s "?Press any key to close..."
fi

