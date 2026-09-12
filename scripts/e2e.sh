#!/bin/sh
# A whole sealed-bid auction against a Vela stack (the one in client/.env): the app deployed, a
# seller and two bidders registered and funded, one auction opened, two sealed bids, the close,
# each side's result, the public receipt, withdrawals claimed on-chain and the audit.
#
#   sh scripts/e2e.sh                          # sells 1000 of VELA_TOKEN for ETH, uniform price
#   BIDDER1_KEY=<hex> BIDDER2_KEY=<hex> sh scripts/e2e.sh   # other bidder keys (default: Anvil #1 and #2, funded)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_WASM="${APP_WASM:-$ROOT/build/app.wasm}"
BIDDER1_KEY="${BIDDER1_KEY:-59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
BIDDER2_KEY="${BIDDER2_KEY:-5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}"
cd "$ROOT/client"
[ -f .env ] || { echo "client/.env is missing: run scripts/devnet.sh, or `synsema run vela_client.syn -- devnet` with a copy of .env.example"; exit 2; }
[ -f "$APP_WASM" ] || { echo "$APP_WASM is missing: run scripts/build.sh (or download the CI artifact)"; exit 2; }
TOKEN="$(sed -n 's/^VELA_TOKEN=//p' .env | tr -d '\r')"
[ -n "$TOKEN" ] || { echo "VELA_TOKEN is empty in client/.env: the auction sells an allowlisted ERC-20 (scripts/devnet.sh deploys one locally; on the public devnet copy VELA_TEST_TOKEN into VELA_TOKEN)"; exit 2; }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) APP_WASM="$(cygpath -w "$APP_WASM")" ;; esac

run() { synsema run vela_client.syn -- "$@"; }
put() { sed -i.bak "s/^$1=.*/$1=$2/" .env && rm -f .env.bak; }
keyline() { echo "$1" | sed -n "s/^$2=//p"; }

if ! grep -q '^VELA_P521_KEY=.\{10,\}' .env; then
  echo "== keys: the seller's P-521 pair, written to client/.env"
  KEYS="$(run keys)"
  put VELA_P521_KEY "$(keyline "$KEYS" VELA_P521_KEY)" .env
  put VELA_P521_PUB "$(keyline "$KEYS" VELA_P521_PUB)" .env
fi
# Each bidder: its own signing key and P-521 pair (through `env`, never `VAR=x fn`: in POSIX sh an
# assignment before a function call outlives it).
K1="$(run keys)"; B1_P521="$(keyline "$K1" VELA_P521_KEY)"; B1_PUB="$(keyline "$K1" VELA_P521_PUB)"
K2="$(run keys)"; B2_P521="$(keyline "$K2" VELA_P521_KEY)"; B2_PUB="$(keyline "$K2" VELA_P521_PUB)"
bidder1() { env VELA_SECP_KEY="$BIDDER1_KEY" VELA_P521_KEY="$B1_P521" VELA_P521_PUB="$B1_PUB" VELA_USER_KEY="" synsema run vela_client.syn -- "$@"; }
bidder2() { env VELA_SECP_KEY="$BIDDER2_KEY" VELA_P521_KEY="$B2_P521" VELA_P521_PUB="$B2_PUB" VELA_USER_KEY="" synsema run vela_client.syn -- "$@"; }

SELLER="$(run address | tail -1)"
B1="$(bidder1 address | tail -1)"
B2="$(bidder2 address | tail -1)"
echo "== seller $SELLER · bidders $B1, $B2 · asset $TOKEN, payment ETH"

echo "== deploy $APP_WASM"
OUT="$(run deploy "$APP_WASM")"; echo "$OUT"
APP_ID="$(echo "$OUT" | sed -n 's/.*VELA_APP_ID=\([0-9]*\).*/\1/p')"
[ -n "$APP_ID" ] || { echo "no application id in the deploy output"; exit 1; }
put VELA_APP_ID "$APP_ID" .env

echo "== register: the seller and both bidders"; run register; bidder1 register; bidder2 register
echo "== fund: the seller deposits 1000 of the asset, each bidder 1 ETH"
run fund "$TOKEN" 1000
bidder1 fund eth 1
bidder2 fund eth 1

START1="$(run token-balance "$TOKEN" "$B1" | tail -1)"
START2="$(run token-balance "$TOKEN" "$B2" | tail -1)"
wait_delta() {  # address, start, tokens expected on top of it
  EXPECTED="$(awk -v a="$2" -v d="$3" 'BEGIN { printf "%.6f", a + d }')"
  i=0
  while [ $i -lt 30 ]; do
    B="$(run token-balance "$TOKEN" "$1" | tail -1)"
    [ "$B" = "$EXPECTED" ] && { echo "   on-chain balance of $1: $B (started at $2)"; return 0; }
    i=$((i + 1)); sleep 10
  done
  echo "   balance of $1 is $B, expected $EXPECTED"; return 1
}

echo "== 1. the seller opens: 1000 of the asset for ETH, reserve 0.5 ETH for the lot, uniform price"
run open "$TOKEN" 1000 eth 0.5 uniform
echo "== 2. sealed bids: bidder 1 wants 600 for 0.9 ETH, bidder 2 wants 600 for 0.6 ETH"
bidder1 bid 1 600 0.9
bidder2 bid 1 600 0.6
echo "== 3. the seller closes: matching inside the enclave"
run close 1
echo "== what each bidder learns (its own result, the clearing price; never the other's bid)"
bidder1 results 1
bidder2 results 1
echo "== what the chain learns"; run auctions 2
echo "== 4. settlement: the bidders withdraw the asset, the seller the proceeds, claimed on-chain"
bidder1 withdraw "$TOKEN" 600
bidder2 withdraw "$TOKEN" 400
run claim-for "$TOKEN" "$B1"
run claim-for "$TOKEN" "$B2"
wait_delta "$B1" "$START1" 600
wait_delta "$B2" "$START2" 400
run withdraw eth 1
echo "   the seller's proceeds, claimable on-chain: $(run pending eth "$SELLER" | tail -1) ETH (the wei on top are its refunded request fees)"
run claim-for eth "$SELLER"
echo "== allow-authority + audit: the whole book, for an allowed authority"
run allow-authority "$APP_ID" "$SELLER"
run audit '{"report_type":"auction","auction":"0x00000000000000000000000000000001"}' | tail -1 | cut -c1-600
echo "done: VELA_APP_ID=$APP_ID is in client/.env"
