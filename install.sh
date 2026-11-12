#!/bin/sh
# Canonical public installer for Atlas AI.
# Downloads atlas-bootstrap for the host platform over HTTPS, verifies the
# pinned public SHA-256, then runs:
#   atlas-bootstrap install --version 0.6.0 [--replace]
#   "$HOME/.local/bin/atlas" upgrade
#
# Usage:
#   curl -fsSL <published-install.sh-URL> | sh
#   curl -fsSL <published-install.sh-URL> | sh -s -- --replace
#   sh install.sh
#   sh install.sh --replace
#
# This script does not modify PATH. The bootstrap binary performs the
# authenticated CLI install into ~/.local/bin. After that succeeds, the script
# unsets ATLAS_HOME and runs the absolute CLI path to set up the official Atlas
# Home runtime. Full success requires both steps. There is no sudo, no eval,
# and no URL/version override from the environment.

set -eu

# Prefer OS utilities over a hostile PATH prefix. Do not trust CDPATH or TMPDIR.
CDPATH=''
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

ATLAS_VERSION='0.6.0'
ARTIFACT_BASE='https://github.com/eshmun84/atlas-ai-releases/releases/download'

SHA256_DARWIN_AMD64='b1542c567c8fc3198128cad8fce30c86ded2ea390e97f976fa99901ff409212b'
SHA256_DARWIN_ARM64='b9f36c9b6823fc64155d4781bfb4dae8c0469a91f1021d60e37e2b16e29e277a'
SHA256_LINUX_AMD64='2dc361dec4fde9602904547efdd9e00ccc696a61ec1b93559cbdd9860935bd0e'
SHA256_LINUX_ARM64='b974f1bf4f8eb48c6a9572e889f8456818bad257af0e08be8697fa1d2cc28607'

usage() {
	printf '%s\n' "usage: sh install.sh [--replace]" >&2
	printf '%s\n' "       curl -fsSL <URL> | sh" >&2
	printf '%s\n' "       curl -fsSL <URL> | sh -s -- --replace" >&2
}

die() {
	printf 'atlas install: %s\n' "$*" >&2
	exit 1
}

reject_usage() {
	printf 'atlas install: %s\n' "$*" >&2
	usage
	exit 2
}

REPLACE=0
for arg in "$@"; do
	case "$arg" in
	--replace)
		REPLACE=1
		;;
	*)
		reject_usage "unknown argument: $arg"
		;;
	esac
done

command -v curl >/dev/null 2>&1 || die "curl is required"

detect_platform() {
	os=$(uname -s)
	arch=$(uname -m)
	case "$os" in
	Darwin) os=darwin ;;
	Linux) os=linux ;;
	*) die "unsupported operating system: $os" ;;
	esac
	case "$arch" in
	x86_64 | amd64) arch=amd64 ;;
	arm64 | aarch64) arch=arm64 ;;
	*) die "unsupported architecture: $arch" ;;
	esac
	printf '%s\n' "$os-$arch"
}

expected_sha256() {
	case "$1" in
	darwin-amd64) printf '%s\n' "$SHA256_DARWIN_AMD64" ;;
	darwin-arm64) printf '%s\n' "$SHA256_DARWIN_ARM64" ;;
	linux-amd64) printf '%s\n' "$SHA256_LINUX_AMD64" ;;
	linux-arm64) printf '%s\n' "$SHA256_LINUX_ARM64" ;;
	*) die "unsupported platform: $1" ;;
	esac
}

file_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		die "sha256sum or shasum is required"
	fi
}

tmpdir=
remove_tmpdir() {
	if [ -n "${tmpdir:-}" ] && [ -d "$tmpdir" ]; then
		rm -rf -- "$tmpdir"
		tmpdir=
	fi
}

on_exit() {
	ec=$?
	trap - EXIT INT HUP TERM
	remove_tmpdir
	exit "$ec"
}

on_signal() {
	trap - EXIT INT HUP TERM
	remove_tmpdir
	exit "$1"
}

trap on_exit EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

platform=$(detect_platform)
expected=$(expected_sha256 "$platform")
asset="atlas-bootstrap-${platform}"
url="${ARTIFACT_BASE}/v${ATLAS_VERSION}/${asset}"

case "$url" in
https://*) ;;
*) die "refusing non-HTTPS download URL" ;;
esac

tmpdir=$(mktemp -d /tmp/atlas-install.XXXXXX) || die "could not create temporary directory"
dest="${tmpdir}/${asset}"

printf '%s\n' "Downloading ${asset} for Atlas ${ATLAS_VERSION} over HTTPS."
printf '%s\n' "The first bootstrap download trusts GitHub TLS. The bootstrap then verifies the signed CLI manifest before writing ~/.local/bin/atlas."
printf '%s\n' "This script does not modify PATH. After the CLI install it runs atlas upgrade for the official Atlas Home."

curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$dest" "$url" || die "download failed"

actual=$(file_sha256 "$dest")
if [ "$actual" != "$expected" ]; then
	die "checksum mismatch for ${asset}"
fi

chmod 0755 "$dest"

set -- install --version "$ATLAS_VERSION"
if [ "$REPLACE" -eq 1 ]; then
	set -- "$@" --replace
fi

"$dest" "$@"

# Use the official Home. Do not honor a caller ATLAS_HOME override.
unset ATLAS_HOME

if [ ! -x "$HOME/.local/bin/atlas" ]; then
	die "CLI install reported success but $HOME/.local/bin/atlas is missing or not executable"
fi

printf '%s\n' "Setting up Atlas Home with atlas upgrade."
if ! "$HOME/.local/bin/atlas" upgrade; then
	printf 'atlas install: CLI installed at %s, but Atlas Home setup failed.\n' "$HOME/.local/bin/atlas" >&2
	printf 'atlas install: retry with: atlas upgrade\n' >&2
	exit 1
fi

printf '%s\n' "Atlas CLI and Atlas Home are ready."
