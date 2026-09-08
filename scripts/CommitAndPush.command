#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=========================================="
echo " 🚀 QCpie - Git Commit & Push"
echo "=========================================="
echo ""

if [ -z "$(git status --porcelain)" ]; then
    echo "ℹ️  Working tree clean. No uncommitted changes."
    read -p "Push current commits to origin? (y/n): " PUSH_CHOICE
    if [[ "$PUSH_CHOICE" =~ ^[Yy]$ ]]; then
        BRANCH=$(git rev-parse --abbrev-ref HEAD)
        git push origin "$BRANCH"
        echo "✅ Pushed to origin/$BRANCH"
    fi
    echo ""
    read -p "Press [Enter] to exit..."
    exit 0
fi

echo "📋 Modified / Untracked files:"
git status -s
echo ""

read -p "Enter commit message: " COMMIT_MSG

if [ -z "$COMMIT_MSG" ]; then
    COMMIT_MSG="Update QCpie ($(date +'%Y-%m-%d %H:%M'))"
    echo "Using default message: '${COMMIT_MSG}'"
fi

echo ""
echo "📦 Staging changes..."
git add -A

echo "💾 Committing..."
git commit -m "$COMMIT_MSG"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "🚀 Pushing to origin/${BRANCH}..."
git push origin "$BRANCH"

echo ""
echo "=========================================="
echo " ✅ Successfully committed and pushed!"
echo "=========================================="
read -p "Press [Enter] to exit..."
