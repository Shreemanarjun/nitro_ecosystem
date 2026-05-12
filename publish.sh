#!/bin/bash

# Packages in dependency order
PACKAGES=(
    "packages/nitro_annotations"
    "packages/nitro"
    "packages/nitro_generator"
    "packages/nitrogen_cli"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

DRY_RUN=""
FORCE_FLAG=""

for arg in "$@"; do
  case $arg in
    -d|--dry-run) DRY_RUN="--dry-run" ;;
    -f|--force)   FORCE_FLAG="--force" ;;
  esac
done

ROOT_DIR=$(pwd)

# Returns 0 if <name>@<version> is already live on pub.dev, 1 otherwise.
is_published() {
    local pkg_name="$1"
    local version="$2"
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" \
        "https://pub.dev/api/packages/${pkg_name}/versions/${version}")
    [ "$status" = "200" ]
}

# Extract version field from a pubspec.yaml
pkg_version() {
    grep '^version:' "$1/pubspec.yaml" | awk '{print $2}'
}

# --- Pre-flight (dry-run only when actually publishing) ---
if [ -z "$DRY_RUN" ]; then
    echo -e "${CYAN}Checking pub.dev for already-published versions...${NC}"
    ALL_SKIP=true
    for PKG in "${PACKAGES[@]}"; do
        PKG_NAME=$(basename "$PKG")
        VERSION=$(pkg_version "$ROOT_DIR/$PKG")
        if is_published "$PKG_NAME" "$VERSION"; then
            echo -e "  ${YELLOW}⏭  $PKG_NAME $VERSION — already published, will skip${NC}"
        else
            echo -e "  ${GREEN}⬆  $PKG_NAME $VERSION — will publish${NC}"
            ALL_SKIP=false
        fi
    done
    echo

    if $ALL_SKIP; then
        echo -e "${YELLOW}All packages are already at the current version on pub.dev. Nothing to publish.${NC}"
        exit 0
    fi

    echo -e "${CYAN}Running pre-flight dry-run for packages that need publishing...${NC}"
    for PKG in "${PACKAGES[@]}"; do
        PKG_NAME=$(basename "$PKG")
        VERSION=$(pkg_version "$ROOT_DIR/$PKG")
        if is_published "$PKG_NAME" "$VERSION"; then
            continue
        fi
        echo -e "   Checking $PKG_NAME..."
        cd "$ROOT_DIR/$PKG"
        if ! flutter pub publish --dry-run >/dev/null 2>&1; then
            echo -e "${RED}❌ Pre-flight dry-run failed for $PKG_NAME $VERSION!${NC}"
            echo -e "   Run './publish.sh --dry-run' to see details."
            exit 1
        fi
    done
    echo -e "${GREEN}✅ Pre-flight checks passed!${NC}\n"

    if [ -z "$FORCE_FLAG" ]; then
        echo -e "${RED}⚠️  WARNING: You are about to publish to pub.dev!${NC}"
        read -p "Are you sure you want to continue? (Y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            echo -e "${CYAN}Publishing cancelled.${NC}"
            exit 1
        fi
    fi
    PUBLISH_CMD_FLAGS="--force"
else
    echo -e "${CYAN}--- DRY RUN MODE ---${NC}"
    PUBLISH_CMD_FLAGS="--dry-run"
fi

echo -e "${CYAN}🚀 Executing publication cycle...${NC}\n"

PUBLISHED_COUNT=0
SKIPPED_COUNT=0

for PKG in "${PACKAGES[@]}"; do
    PKG_NAME=$(basename "$PKG")
    VERSION=$(pkg_version "$ROOT_DIR/$PKG")

    echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}📦 $PKG_NAME $VERSION${NC}"

    if [ ! -d "$ROOT_DIR/$PKG" ]; then
        echo -e "${RED}❌ Directory $PKG not found!${NC}"
        exit 1
    fi

    # Skip already-published versions (only relevant during actual publish, not dry-run)
    if [ -z "$DRY_RUN" ] && is_published "$PKG_NAME" "$VERSION"; then
        echo -e "${YELLOW}⏭  Already published on pub.dev — skipping${NC}"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}\n"
        continue
    fi

    cd "$ROOT_DIR/$PKG"
    if flutter pub publish $PUBLISH_CMD_FLAGS; then
        echo -e "\n${GREEN}✅ $PKG_NAME $VERSION published${NC}"
        PUBLISHED_COUNT=$((PUBLISHED_COUNT + 1))
    else
        echo -e "\n${RED}❌ Failed for $PKG_NAME $VERSION${NC}"
        exit 1
    fi

    echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}\n"
done

echo -e "${GREEN}✨ Done — published: $PUBLISHED_COUNT, skipped (already live): $SKIPPED_COUNT${NC}"
