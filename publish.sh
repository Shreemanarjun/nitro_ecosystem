#!/bin/bash

# Configuration: packages in the order they must be published
PACKAGES=(
    "packages/nitro_annotations"
    "packages/nitro"
    "packages/nitro_generator"
    "packages/nitrogen_cli"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Handle flags
DRY_RUN=""
FORCE_FLAG=""

for arg in "$@"; do
  case $arg in
    -d|--dry-run)
      DRY_RUN="--dry-run"
      ;;
    -f|--force)
      FORCE_FLAG="--force"
      ;;
  esac
done

if [ -z "$DRY_RUN" ]; then
    if [ -z "$FORCE_FLAG" ]; then
        echo -e "${RED}⚠️  WARNING: You are about to publish to pub.dev!${NC}"
        read -p "Are you sure you want to continue? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${CYAN}Publishing cancelled.${NC}"
            exit 1
        fi
    fi
    # Use --force for actual publication since we've confirmed here
    PUBLISH_CMD_FLAGS="--force"
else
    echo -e "${CYAN}--- DRY RUN MODE ---${NC}"
    # Dry run shouldn't use --force to get full validation reports
    PUBLISH_CMD_FLAGS="--dry-run"
fi

set -e # Exit immediately on error

ROOT_DIR=$(pwd)

echo -e "${CYAN}🚀 Starting publication process for Nitro Ecosystem...${NC}\n"

for PKG in "${PACKAGES[@]}"; do
    PKG_NAME=$(basename "$PKG")
    echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}📦 Processing $PKG_NAME...${NC}"
    
    # Check if directory exists
    if [ ! -d "$ROOT_DIR/$PKG" ]; then
        echo -e "${RED}❌ Error: Directory $PKG not found!${NC}"
        exit 1
    fi

    cd "$ROOT_DIR/$PKG"
    
    # Run publish command
    if dart pub publish $PUBLISH_CMD_FLAGS; then
        echo -e "\n${GREEN}✅ Success for $PKG_NAME${NC}"
    else
        echo -e "\n${RED}❌ Failed for $PKG_NAME${NC}"
        exit 1
    fi
    
    echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}\n"
done

echo -e "${GREEN}✨ Nitro Ecosystem publication cycle completed! ✨${NC}"
