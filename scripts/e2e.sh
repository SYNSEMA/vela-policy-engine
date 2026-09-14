#!/bin/sh
# The whole treasury against a Vela stack (the one in client/.env): the trigger contract, the app,
# the owner and the agent registered, funds, the policy, then four proposals — one paid at once,
# one held and approved, one held and rejected, one dropped in inbox/ for the agent worker —
# with the on-chain balance of the payee checked after every payment.
#
#   sh scripts/e2e.sh                          # deploys build/app.wasm on VELA_TOKEN (client/.env)
#   AGENT_KEY=<hex> sh scripts/e2e.sh          # the agent's key (default: Anvil #1, which has ETH for fees)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_WASM="${APP_WASM:-$ROOT/build/app.wasm}"
AGENT_KEY="${AGENT_KEY:-59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
VENDOR="${VENDOR:-0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC}"     # Anvil #2: the allowlisted payee
STRANGER="${STRANGER:-0x90F79bf6EB2c4f870365E785982E1f101E93b906}"  # Anvil #3: not allowlisted
cd "$ROOT/client"
[ -f .env ] || { echo "client/.env is missing: run scripts/devnet.sh, or copy .env.example and point it at a hosted devnet"; exit 2; }
[ -f "$APP_WASM" ] || { echo "$APP_WASM is missing: run scripts/build.sh (or download the CI artifact)"; exit 2; }
TOKEN="$(sed -n 's/^VELA_TOKEN=//p' .env | tr -d '\r')"
[ -n "$TOKEN" ] || { echo "VELA_TOKEN is empty in client/.env: the treasury needs an allowlisted ERC-20 (scripts/devnet.sh deploys one locally; on the public devnet copy VELA_TEST_TOKEN into VELA_TOKEN, or allow-token another)"; exit 2; }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) APP_WASM="$(cygpath -w "$APP_WASM")" ;; esac

run() { synsema run vela_client.syn -- "$@"; }
put() { sed -i.bak "s/^$1=.*/$1=$2/" "$3" && rm -f "$3.bak"; }
keyline() { echo "$1" | sed -n "s/^$2=//p"; }

if ! grep -q '^VELA_P521_KEY=.\{10,\}' .env; then
  echo "== keys: the owner's P-521 pair, written to client/.env"
  KEYS="$(run keys)"
  put VELA_P521_KEY "$(keyline "$KEYS" VELA_P521_KEY)" .env
  put VELA_P521_PUB "$(keyline "$KEYS" VELA_P521_PUB)" .env
fi
if ! grep -q '^VELA_TRIGGER=0x' .env; then
  echo "== trigger: deploying TreasuryTrigger (one per treasury app)"
  sh "$ROOT/scripts/trigger/deploy.sh"
fi

# The agent's own environment: the same stack, its own keys (secp256k1 for fees, P-521 for events).
AGENT_KEYS="$(run keys)"
AGENT_P521="$(keyline "$AGENT_KEYS" VELA_P521_KEY)"; AGENT_PUB="$(keyline "$AGENT_KEYS" VELA_P521_PUB)"
# through `env`, not `VAR=x fn`: in POSIX sh an assignment before a function call outlives it
agent() { env VELA_SECP_KEY="$AGENT_KEY" VELA_P521_KEY="$AGENT_P521" VELA_P521_PUB="$AGENT_PUB" VELA_USER_KEY="" synsema run vela_client.syn -- "$@"; }

OWNER="$(run address | tail -1)"
AGENT="$(agent address | tail -1)"
echo "== owner $OWNER · agent $AGENT · payee $VENDOR · token $TOKEN"

echo "== deploy-treasury $APP_WASM (automatic limit 200 tokens per payment)"
OUT="$(run deploy-treasury "$APP_WASM" 200)"; echo "$OUT"
APP_ID="$(echo "$OUT" | sed -n 's/.*VELA_APP_ID=\([0-9]*\).*/\1/p')"
[ -n "$APP_ID" ] || { echo "no application id in the deploy output"; exit 1; }
put VELA_APP_ID "$APP_ID" .env

echo "== register (the owner)"; run register
echo "== register (the agent)"; agent register
echo "== fund 1000"; run fund 1000
echo "== policy: the agent may propose; the vendor may be paid up to 300 per payment; allowance 500"
run allow-proposer "$AGENT" "invoice agent"
run allow-payee "$VENDOR" "cloud vendor" 300
run grant 500

# The payee's on-chain balance accumulates across runs: every check is a delta over where it started.
START_BALANCE="$(run token-balance "$VENDOR" | tail -1)"
wait_balance() {  # address, tokens paid so far in this run
  EXPECTED="$(awk -v a="$START_BALANCE" -v d="$2" 'BEGIN { printf "%.6f", a + d }')"
  i=0
  while [ $i -lt 30 ]; do
    B="$(run token-balance "$1" | tail -1)"
    [ "$B" = "$EXPECTED" ] && { echo "   on-chain balance of $1: $B (started at $START_BALANCE)"; return 0; }
    i=$((i + 1)); sleep 10
  done
  echo "   balance of $1 is $B, expected $EXPECTED"; return 1
}

echo "== 1. the agent proposes 150 to the vendor: inside the policy, paid at once through the trigger"
agent propose "$VENDOR" 150 "INV-1001"
wait_balance "$VENDOR" 150
echo "== 2. the agent proposes 250: over the automatic limit, held for the owner"
agent propose "$VENDOR" 250 "INV-1002"
echo "== the owner's view"; run proposals 2
echo "== the owner approves proposal 2"; run approve 2
wait_balance "$VENDOR" 400
echo "== 3. the agent proposes 10 to an address that is not allowlisted: held"
agent propose "$STRANGER" 10 "INV-1003"
echo "== the owner rejects proposal 3"; run reject 3 "unknown vendor"
echo "== 4. an invoice dropped in inbox/, picked up by the agent worker"
cd "$ROOT"
mkdir -p inbox inbox-done inbox-review
sed "s/^VELA_SECP_KEY=.*/VELA_SECP_KEY=$AGENT_KEY/; s/^VELA_P521_KEY=.*/VELA_P521_KEY=$AGENT_P521/; s/^VELA_P521_PUB=.*/VELA_P521_PUB=$AGENT_PUB/; s/^VELA_USER_KEY=.*/VELA_USER_KEY=/" client/.env > .env
printf '{"payee": "%s", "amount": "20", "memo": "INV-1004 cloud, September"}\n' "$VENDOR" > inbox/inv-1004.json
synsema run agent.syn -- --once
cd "$ROOT/client"
wait_balance "$VENDOR" 420
echo "== the agent's outcomes"; agent outcomes 4
echo "== the owner's ledger (events)"; run proposals 6
echo "== allow-authority: the owner becomes an auditor of this app (the devnet's admin desk signs it)"; run allow-authority "$APP_ID" "$OWNER"
echo "== audit"; run audit
echo "done: VELA_APP_ID=$APP_ID is in client/.env and .env (the agent's)"
