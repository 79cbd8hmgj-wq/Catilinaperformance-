#!/bin/sh
# Run the CatalinaPerformance local GUI without changing system settings.

set -u

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd -P) || exit 1
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P) || exit 1
PACKAGE_DIR="$REPO_ROOT/app/CatalinaPerformance"

if [ ! -d "$PACKAGE_DIR" ]; then
    printf 'Error: Swift package directory was not found: %s\n' "$PACKAGE_DIR" >&2
    exit 1
fi

export CATALINA_PERFORMANCE_SCRIPTS_DIR="$SCRIPT_DIR"

printf 'Running command:\n'
printf '  cd %s && CATALINA_PERFORMANCE_SCRIPTS_DIR=%s swift run CatalinaPerformance\n' "$PACKAGE_DIR" "$CATALINA_PERFORMANCE_SCRIPTS_DIR"

cd "$PACKAGE_DIR" || exit 1
swift run CatalinaPerformance
