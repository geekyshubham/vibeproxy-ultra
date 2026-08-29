#!/bin/bash

# Local release creation script
# This builds the app and creates a distributable ZIP for manual uploads

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=${1:-"dev"}

echo -e "${BLUE}📦 Creating VibeRouter Release ${VERSION}${NC}"
echo ""

# Clean previous builds
echo -e "${BLUE}🧹 Cleaning previous builds...${NC}"
cd "$PROJECT_DIR"
# Must match APP_NAME in create-app-bundle.sh. Contains a SPACE, so keep it quoted.
APP_BUNDLE="VibeRouter.app"

rm -rf "$APP_BUNDLE"
rm -f VibeRouter.zip
rm -f VibeRouter.dmg

# Build the app
echo -e "${BLUE}🔨 Building VibeRouter...${NC}"
./create-app-bundle.sh

if [ ! -d "$APP_BUNDLE" ]; then
    echo -e "${RED}❌ Build failed - ${APP_BUNDLE} not found${NC}"
    exit 1
fi

# Create ZIP. The archive keeps a space-free name so its download URL needs no escaping.
echo -e "${BLUE}📦 Creating ZIP archive...${NC}"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "VibeRouter-${VERSION}.zip"

# Calculate checksum
echo -e "${BLUE}🔐 Calculating checksum...${NC}"
CHECKSUM=$(shasum -a 256 "VibeRouter-${VERSION}.zip" | awk '{print $1}')

# Summary
echo ""
echo -e "${GREEN}✅ Release created successfully!${NC}"
echo ""
echo -e "${BLUE}Files created:${NC}"
echo "  - ${APP_BUNDLE} (local testing)"
echo "  - VibeRouter-${VERSION}.zip (for distribution)"
echo ""
echo -e "${BLUE}SHA-256 Checksum:${NC}"
echo "  ${CHECKSUM}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Test the .app locally"
echo "  2. Create a new release on GitHub"
echo "  3. Upload VibeRouter-${VERSION}.zip"
echo "  4. Add the checksum to release notes"
echo ""
echo -e "${BLUE}GitHub Release Command:${NC}"
echo "  gh release create v${VERSION} VibeRouter-${VERSION}.zip --generate-notes"
echo ""
