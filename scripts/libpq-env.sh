#!/bin/bash
# Source from build/test scripts; Homebrew's libpq is intentionally keg-only.
if command -v brew >/dev/null 2>&1; then
    makosh_libpq_prefix="$(brew --prefix libpq 2>/dev/null || true)"
    if [[ -d "$makosh_libpq_prefix/lib/pkgconfig" ]]; then
        export PKG_CONFIG_PATH="$makosh_libpq_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    fi
    makosh_openssl_prefix="$(brew --prefix openssl@3 2>/dev/null || true)"
    if [[ -d "$makosh_openssl_prefix/lib/pkgconfig" ]]; then
        export PKG_CONFIG_PATH="$makosh_openssl_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    fi
fi
if ! pkg-config --exists openssl || [[ "$(pkg-config --modversion openssl)" != 3.* ]]; then
    echo 'OpenSSL 3 is required. Install with: brew install openssl@3 pkg-config' >&2
    return 1
fi
if ! pkg-config --exists libpq; then
    echo 'libpq is required. Install with: brew install libpq pkg-config' >&2
    return 1
fi
