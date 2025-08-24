#!/bin/bash

# Release script for ccstreamer
# Usage: ./scripts/release.sh [major|minor|patch]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if we're in the right directory
if [ ! -f "build.zig" ]; then
    echo -e "${RED}Error: build.zig not found. Please run this script from the project root.${NC}"
    exit 1
fi

# Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
    echo -e "${YELLOW}Warning: You have uncommitted changes.${NC}"
    read -p "Do you want to continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Get current version from last tag
CURRENT_VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
CURRENT_VERSION=${CURRENT_VERSION#v}  # Remove 'v' prefix

# Parse version components
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

# Determine version bump type
BUMP_TYPE=${1:-patch}

case $BUMP_TYPE in
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    patch)
        PATCH=$((PATCH + 1))
        ;;
    *)
        echo -e "${RED}Error: Invalid version bump type. Use major, minor, or patch.${NC}"
        exit 1
        ;;
esac

NEW_VERSION="v${MAJOR}.${MINOR}.${PATCH}"

echo -e "${GREEN}Bumping version from v${CURRENT_VERSION} to ${NEW_VERSION}${NC}"

# Update version in build.zig if it exists there
if grep -q "version.*=.*\"" build.zig; then
    sed -i.bak "s/version.*=.*\".*\"/version = \"${MAJOR}.${MINOR}.${PATCH}\"/" build.zig
    rm build.zig.bak
    git add build.zig
    echo "Updated version in build.zig"
fi

# Create or update CHANGELOG entry
if [ ! -f "CHANGELOG.md" ]; then
    cat > CHANGELOG.md << EOF
# Changelog

All notable changes to ccstreamer will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [${NEW_VERSION}] - $(date +%Y-%m-%d)

### Added
- Initial release of ccstreamer
- JSON formatting for Claude Code output
- Tool use and tool result formatting
- Color support with ANSI escape sequences
- Cross-platform support (Linux, macOS, Windows)

EOF
else
    # Add new version section at the top of changelog
    TEMP_FILE=$(mktemp)
    cat > "$TEMP_FILE" << EOF
# Changelog

All notable changes to ccstreamer will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [${NEW_VERSION}] - $(date +%Y-%m-%d)

### Added
- 

### Changed
- 

### Fixed
- 

EOF
    tail -n +7 CHANGELOG.md >> "$TEMP_FILE"
    mv "$TEMP_FILE" CHANGELOG.md
fi

echo -e "${YELLOW}Please update CHANGELOG.md with the actual changes for this release.${NC}"
echo "Opening CHANGELOG.md in your editor..."

# Try to open in default editor
if [ -n "$EDITOR" ]; then
    $EDITOR CHANGELOG.md
elif command -v nano &> /dev/null; then
    nano CHANGELOG.md
elif command -v vim &> /dev/null; then
    vim CHANGELOG.md
else
    echo "Please manually edit CHANGELOG.md"
fi

# Commit changes
read -p "Commit changes and create tag ${NEW_VERSION}? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    git add CHANGELOG.md
    git commit -m "Release ${NEW_VERSION}"
    git tag -a "${NEW_VERSION}" -m "Release ${NEW_VERSION}"
    
    echo -e "${GREEN}✓ Version ${NEW_VERSION} tagged successfully!${NC}"
    echo ""
    echo "To push the release:"
    echo "  git push origin master"
    echo "  git push origin ${NEW_VERSION}"
    echo ""
    echo "GitHub Actions will automatically build and create the release."
else
    echo -e "${YELLOW}Release cancelled. Changes were not committed.${NC}"
fi