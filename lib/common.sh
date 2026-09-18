#!/bin/sh

_APT_UPDATED=0
INFRA_LIB_BASE_URL=${INFRA_LIB_BASE_URL:-https://raw.githubusercontent.com/madwind/infra-scripts/refs/heads/main/lib}

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "Error: root privileges are required." >&2
        return 1
    fi
}

preflight_require_root() {
    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        echo "Error: run as root or install sudo." >&2
        return 1
    fi
}

preflight_require_env() {
    missing=0

    for name in "$@"; do
        case "$name" in
            ''|*[!A-Za-z0-9_]*)
                echo "Error: invalid environment variable name: $name" >&2
                return 1
                ;;
        esac

        eval "value=\${$name-}"
        if [ -z "$value" ]; then
            echo "Error: required environment variable is not set: $name" >&2
            missing=1
        fi
    done

    [ "$missing" -eq 0 ]
}

_install_package() {
    package=$1

    if [ "$_APT_UPDATED" -eq 0 ]; then
        run_root env DEBIAN_FRONTEND=noninteractive apt-get update
        _APT_UPDATED=1
    fi

    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
}

load_infra_module() {
    module=$1

    if [ -n "${INFRA_LIB_DIR:-}" ] && [ -f "$INFRA_LIB_DIR/$module.sh" ]; then
        # shellcheck disable=SC1090
        . "$INFRA_LIB_DIR/$module.sh"
        return 0
    fi

    module_tmp=$(mktemp)
    if ! curl -fsSL "$INFRA_LIB_BASE_URL/$module.sh" -o "$module_tmp"; then
        rm -f "$module_tmp"
        echo "Error: failed to download infra module: $module" >&2
        return 1
    fi

    # shellcheck disable=SC1090
    if ! . "$module_tmp"; then
        rm -f "$module_tmp"
        echo "Error: failed to load infra module: $module" >&2
        return 1
    fi

    rm -f "$module_tmp"
}

load_infra_modules() {
    for module_name in "$@"; do
        load_infra_module "$module_name"
    done
}
