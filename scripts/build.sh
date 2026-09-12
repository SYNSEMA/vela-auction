#!/bin/sh
# Builds app/app.syn into a Vela guest module: build/app.wasm (+ .sha256). No compiler involved.
#
# The module is Synsema's interpreter plus your program. Every Synsema release publishes the
# interpreter as a Vela guest (`synsema-vela-guest.wasm`, an asset of the release) with an app slot
# inside; scripts/embed.syn puts your program into that slot. The SHA-256 Vela verifies on-chain
# covers interpreter and program together. Needs the `synsema` binary and curl.
#
#   sh scripts/build.sh                          # app/app.syn with the guest of SYNSEMA_TAG (downloaded once into .synsema/)
#   APP=path/to/other.syn sh scripts/build.sh
#   SYNSEMA_TAG=v0.6.23 sh scripts/build.sh      # pin the guest's release (default below)
#   GUEST_WASM=/path/to/synsema-vela-guest.wasm sh scripts/build.sh   # a guest you built or downloaded yourself
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYNSEMA_TAG="${SYNSEMA_TAG:-v0.6.23}"
APP="${APP:-$ROOT/app/app.syn}"
GUEST_WASM="${GUEST_WASM:-$ROOT/.synsema/synsema-vela-guest-$SYNSEMA_TAG.wasm}"

if [ ! -f "$GUEST_WASM" ]; then
  BASE="https://github.com/kitecosmic/synsema/releases/download/$SYNSEMA_TAG"
  echo "downloading the Vela guest of Synsema $SYNSEMA_TAG …"
  mkdir -p "$(dirname "$GUEST_WASM")"
  curl -fsSL -o "$GUEST_WASM.part" "$BASE/synsema-vela-guest.wasm"
  curl -fsSL -o "$GUEST_WASM.sha256" "$BASE/synsema-vela-guest.wasm.sha256"
  WANT="$(cut -d' ' -f1 "$GUEST_WASM.sha256")"
  GOT="$(sha256sum "$GUEST_WASM.part" | cut -d' ' -f1)"
  [ "$WANT" = "$GOT" ] || { echo "sha256 mismatch for the guest: wanted $WANT, got $GOT"; rm -f "$GUEST_WASM.part"; exit 1; }
  mv "$GUEST_WASM.part" "$GUEST_WASM"
fi

mkdir -p "$ROOT/build"
cd "$ROOT"
synsema run scripts/embed.syn -- "$GUEST_WASM" "$APP" build/app.wasm
( cd build && sha256sum app.wasm > app.wasm.sha256 )
echo "next: node scripts/smoke.mjs build/app.wasm   (optional; Node 20 or 24+, not 22)"
