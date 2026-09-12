#!/bin/sh
# Deploys the TreasuryTrigger on the stack named by client/.env and writes VELA_TRIGGER there.
# Every treasury app needs its own trigger (the ProcessorEndpoint binds one trigger to one app).
# Uses `forge` from the PATH when you have foundry; otherwise the starter kit's chain image
# (horizen/cce-chain) through Docker, which the kit already pulled.
#
#   sh scripts/trigger/deploy.sh            # deploys and writes VELA_TRIGGER=0x… to client/.env
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV="$ROOT/client/.env"
[ -f "$ENV" ] || { echo "client/.env is missing: run scripts/devnet.sh, or copy .env.example and point it at a hosted devnet"; exit 2; }
RPC="$(sed -n 's/^VELA_RPC_URL=//p' "$ENV" | tr -d '\r')"
PROCESSOR="$(sed -n 's/^VELA_PROCESSOR=//p' "$ENV" | tr -d '\r')"
KEY="$(sed -n 's/^VELA_SECP_KEY=//p' "$ENV" | tr -d '\r')"
case "$KEY" in 0x*) ;; *) KEY="0x$KEY" ;; esac

if command -v forge >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  RPC_URL="$RPC" PRIVATE_KEY="$KEY" PROCESSOR="$PROCESSOR" sh "$ROOT/scripts/trigger/build.sh" | tail -1
else
  # Inside the container, localhost is the container: the host's Anvil is host.docker.internal.
  CRPC="$(echo "$RPC" | sed 's#://localhost#://host.docker.internal#; s#://127\.0\.0\.1#://host.docker.internal#')"
  DIR="$ROOT/scripts/trigger"
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) DIR="$(cygpath -w "$DIR")" ;; esac
  MSYS_NO_PATHCONV=1 docker run --rm --entrypoint sh -v "$DIR:/trigger" -w /trigger \
    -e RPC_URL="$CRPC" -e PRIVATE_KEY="$KEY" -e PROCESSOR="$PROCESSOR" horizen/cce-chain:v0.2.0 -c 'sh build.sh' | tail -1
fi
TRIGGER="$(tr -d '\r\n' < "$ROOT/scripts/trigger/trigger.address")"
if grep -q '^VELA_TRIGGER=' "$ENV"; then
  sed -i.bak "s#^VELA_TRIGGER=.*#VELA_TRIGGER=$TRIGGER#" "$ENV" && rm -f "$ENV.bak"
else
  printf '\n# The trigger contract that pays (scripts/trigger/deploy.sh; one per treasury app).\nVELA_TRIGGER=%s\n' "$TRIGGER" >> "$ENV"
fi
echo "wrote VELA_TRIGGER=$TRIGGER to client/.env"
