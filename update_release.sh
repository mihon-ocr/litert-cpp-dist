#!/bin/bash

REPO_OWNER="mihon-ocr"
REPO_NAME="litert-cpp-dist"
TAG="v2.1.0rc1"
FILE_NAME="litert_android.zip"

# Check if the file exists locally
if [ ! -f "$FILE_NAME" ]; then
    echo "Error: File '$FILE_NAME' not found in current directory."
    exit 1
fi

# Check if GitHub CLI is installed
if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) is not installed."
    echo "Please install it: https://cli.github.com/"
    exit 1
fi

echo "Uploading $FILE_NAME to $REPO_OWNER/$REPO_NAME @ $TAG..."

# Upload and overwrite the package
# --clobber ensures the old file is replaced
gh release upload "$TAG" "$FILE_NAME" \
  --repo "$REPO_OWNER/$REPO_NAME" \
  --clobber

if [ $? -eq 0 ]; then
    echo "Success! File updated."
    echo "Download link: https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$TAG/$FILE_NAME"
else
    echo "Upload failed."
    exit 1
fi
