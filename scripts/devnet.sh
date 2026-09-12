#!/bin/sh
# A local Vela stack: Horizen's starter kit (v0.2.0) in Docker — Anvil, the contracts, the
# subgraph, the Executor (an emulated TEE), the Manager and the Authority Service. Nine containers,
# ≈ 4.3 GB of images, ≈ 400 MB of RAM idle. Then writes client/.env with the deployed addresses,
# deploys the test stablecoin (scripts/erc20: TST, 6 decimals, with permit) with forge inside the
# kit's chain image, allowlists it, and writes it as VELA_TOKEN.
#
#   sh scripts/devnet.sh          # up (idempotent)
#   sh scripts/devnet.sh down     # stop, keep the chain
#   sh scripts/devnet.sh reset    # stop and wipe volumes (same addresses come back: Anvil is deterministic)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$ROOT/.vela-devnet"
cmd="${1:-up}"

if [ ! -d "$KIT" ]; then
  git clone --depth 1 https://github.com/HorizenOfficial/vela-starterkit.git "$KIT"
fi
cd "$KIT/dockerfiles"
[ -f .env ] || cp .env.dev .env

case "$cmd" in
  down)  docker compose down; exit 0 ;;
  reset) docker compose down -v; docker compose up -d ;;
  up)    docker compose up -d ;;
  *)     echo "usage: devnet.sh [up|down|reset]"; exit 2 ;;
esac

echo "waiting for the contracts and the subgraph …"
until docker compose ps --format '{{.Name}} {{.Status}}' | grep -q 'vela-skit-authorityservice.*Up'; do sleep 5; done
# `sh -c` keeps Git Bash on Windows from rewriting the container path as a Windows one.
ADDR="$(docker exec vela-skit-manager sh -c 'cat /deploy-data/deployed_addresses.env')"
PROCESSOR="$(echo "$ADDR" | sed -n 's/^CHAIN_PROCESSOR_ADDRESS=//p')"
TEE="$(echo "$ADDR" | sed -n 's/^CHAIN_TEEAUTHENTICATOR_ADDRESS=//p')"
echo "$ADDR"

ENV="$ROOT/client/.env"
if [ ! -f "$ENV" ]; then
  sed "s#^VELA_PROCESSOR=.*#VELA_PROCESSOR=$PROCESSOR#; s#^VELA_TEE_AUTHENTICATOR=.*#VELA_TEE_AUTHENTICATOR=$TEE#" "$ROOT/client/.env.example" > "$ENV"
  echo "wrote client/.env (localhost URLs, Anvil #0 as the signing key)"
else
  echo "client/.env exists — check VELA_PROCESSOR=$PROCESSOR and VELA_TEE_AUTHENTICATOR=$TEE"
fi

if ! grep -q '^VELA_TOKEN=0x' "$ENV"; then
  echo "deploying the test token (TST, 6 decimals) and allowlisting it …"
  # forge/cast live in the kit's chain image; the default Docker network reaches Anvil through the host.
  ERC20="$ROOT/scripts/erc20"
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ERC20="$(cygpath -w "$ERC20")" ;; esac
  MSYS_NO_PATHCONV=1 docker run --rm --entrypoint sh -v "$ERC20:/erc20" -w /erc20 \
    -e RPC_URL=http://host.docker.internal:8545 horizen/cce-chain:v0.2.0 -c 'sh build.sh' | tail -1
  TOKEN="$(tr -d '\r\n' < "$ROOT/scripts/erc20/token.address")"
  sed -i.bak "s#^VELA_TOKEN=.*#VELA_TOKEN=$TOKEN#" "$ENV" && rm -f "$ENV.bak"
  echo "wrote VELA_TOKEN=$TOKEN to client/.env (the whole supply, 1 000 000 TST, belongs to Anvil #0)"
fi
echo "chain http://localhost:8545 · authority http://localhost:8081 · subgraph http://localhost:8000/subgraphs/name/hcce"
