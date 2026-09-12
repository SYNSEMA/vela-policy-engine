# vela-treasury — an agent treasury on Vela (Horizen), in Synsema

An agent proposes payments. The enclave applies the owner's policy — who may propose, who may be
paid and up to how much, the automatic limit per payment, the allowance the owner granted — and
either pays at once through a trigger contract or holds the proposal for the owner. Every decision
is deterministic, every proposal lands in an audit report, and the agent never holds a key that
can move the funds. **LLM outside, policy inside**, in the same language on both sides.

```
invoices (JSON, or free text through an LLM)
   │  agent.syn — outside: turns them into proposals, signed with the AGENT's key
   ▼
enclave (app/app.syn) — the policy: proposers, payees + caps, automatic limit, allowance
   │ inside the policy → withdrawal to the trigger + one public event (id, payee, token, amount)
   │ outside it → held; the OWNER approves or rejects (client/vela_client.syn)
   ▼
TreasuryTrigger.sol — transfers the token to the payee, reports back (settled / failed → refund)
owner — funds, grants, allowlists, approves, withdraws, audits
```

Built on [Vela](https://docs.horizen.io/vela/introduction/), whose Executor runs the app inside a
TEE and settles every result on-chain, and on the [vela-app](https://github.com/SYNSEMA/vela-app)
starter kit. Verified end to end against Horizen's starter kit v0.2.0 (the real Executor, the real
contracts) on the public devnet, trigger cycle included.

## What you get

```
app/app.syn                  the policy, inside the enclave: deploy · deposit · propose · approve · reject · policy · withdraw · trusted · deanonymize, with tests
agent.syn                    the agent worker, outside: inbox/ → proposals; the recipe's entry on the Synsema platform
client/vela_lib.syn          Vela's client protocol as a module (keys, cipher, submit, events, facilitator, reports, token amounts)
client/vela_client.syn       the owner's and the proposers' commands, on top of the module
scripts/trigger/             TreasuryTrigger.sol, built against Vela's contracts and deployed by scripts/trigger/deploy.sh
scripts/erc20/               the test stablecoin (TST, 6 decimals, permit) scripts/devnet.sh deploys and allowlists locally
scripts/build.sh             app/app.syn → build/app.wasm (the release's guest module with your program in its slot) + sha256
scripts/embed.syn            puts a .syn into the app slot of a guest module — what build.sh runs; no compiler
scripts/smoke.mjs            probe of the module under Node's WASI, the way the Executor drives it
scripts/devnet.sh            Horizen's starter kit in Docker + the test token + the trigger; client/.env written
scripts/e2e.sh               the whole treasury: trigger → app → policy → paid · held+approved · held+rejected · from inbox/
examples/                    an invoice as JSON and as free text
.github/workflows/build.yml  CI: tests, build, Node 24 + wasmtime-go probes, build/app.wasm as an artifact
syn.toml                     the recipe descriptor for the Synsema platform (kind = worker, entry = agent.syn)
```

## The policy

Set at deploy and changed by the owner at any time (`grant`, `set-max`, `allow-payee`, …):

| rule | what it does |
|---|---|
| **proposers** | addresses that may propose (the agent's; a person's). Anyone else gets an error, nothing is recorded |
| **payees** with an optional **cap** | who may be paid, and at most how much per payment |
| **automatic limit** (`max_auto`) | at or below it a proposal is paid at once; above it, the owner decides |
| **allowance** | the budget automatic payments draw from; the owner grants it (a "daily limit" is a grant a day — the enclave has no clock, so the period is whoever grants) |
| **balance** | what the treasury holds; a proposal it cannot cover waits for funds and the owner |

A proposal inside every rule is paid at once. Outside any of them it is **held** with every reason
(`over the automatic limit 200`, `payee not allowlisted`, …); the owner's `approve` pays it without
touching the allowance, `reject` closes it. The trigger's answer settles it or, if the transfer
reverted, refunds the treasury (and the allowance when the payment was automatic).

## Ten minutes

You need the [`synsema` binary](https://synsema.org) (`npm i -g synsema`, or the install script). That is
all: the module is the release's guest with your program in its slot — no compiler, a few seconds.
For the stack you need Docker, or a token of your own on the public devnet (`synsema run vela_client.syn -- devnet`);
the trigger contract compiles with `forge` — foundry if you have it, the kit's Docker image otherwise.

```sh
synsema test app/app.syn                 # 1. the policy, natively — the same code runs in the enclave
sh scripts/build.sh                      # 2. build/app.wasm: the release's guest + your program (the guest downloads once)
node scripts/smoke.mjs build/app.wasm    #    Node 20 or 24+ (not 22)
sh scripts/devnet.sh                     # 3. Vela in Docker + the test token + the trigger; writes client/.env
sh scripts/e2e.sh                        # 4. the whole treasury, four proposals, balances checked on-chain
```

`scripts/e2e.sh` deploys the trigger if `client/.env` has none and the app for the signing address
(the owner) with an automatic limit of 200 tokens; registers the owner and the agent (Anvil #1 by
default; `AGENT_KEY=<hex>` for another); funds 1000; allows the agent as proposer and Anvil #2 as
payee with a cap of 300; grants 500. Then: a proposal of 150 paid at once (balance checked on-chain),
250 held and approved, 10 to a stranger held and rejected, and an invoice dropped in `inbox/` that
the worker proposes. About ten minutes on the public devnet.

## The owner

`client/vela_client.syn`, run from `client/` with the owner's keys in `client/.env`:

| `synsema run vela_client.syn -- …` | does |
|---|---|
| `deploy-treasury <wasm> <max-auto> [allowance]` | deploys the app for you, `VELA_TOKEN` and `VELA_TRIGGER`; prints the app id |
| `fund <tokens>` | approves and deposits the token |
| `grant <tokens>` · `set-max <tokens>` · `set-allowance <tokens>` | the budget and the automatic limit |
| `allow-payee <address> [label] [cap]` · `deny-payee <address>` | who may be paid |
| `allow-proposer <address> [label]` · `deny-proposer <address>` | who may propose |
| `proposals [n]` | the owner's decrypted events: `approval_needed`, `payment`, `settled`, `failed`, `rejected`, `policy` |
| `approve <n\|id>` · `reject <n\|id> [reason]` | what the policy held (n = the proposal's number) |
| `withdraw <tokens> [to]` | takes funds out as a pull-payment (`claim-for`) |
| `audit ['<json>']` | the whole picture from the enclave (balance, policy, every proposal), for an allowed authority; `{"report_type":"ledger","status":"pending"}` filters |
| `pending <address>` · `claim-for <address>` · `token-balance <address>` · `units` · `tokens` | claims, balances, conversions |

Plus the starter kit's generic commands (`keys`, `register`, `deploy`, `send`, `events`, the
facilitator flow). Amounts are in tokens (`150.50`), converted by text with the token's `decimals()`.

## The agent

`agent.syn`, run from the repository root with the agent's own keys in `.env` (copy `.env.example`):
a secp256k1 key with a little ETH for fees — never the owner's — and a P-521 pair for its events.
The owner allowlists its address with `allow-proposer`.

```sh
synsema run agent.syn              # watches inbox/, proposes what lands there
synsema run agent.syn -- --once    # one pass, then exits
```

An invoice is a file in `inbox/`. `*.json` (`{"payee": "0x…", "amount": "150.00", "memo": "INV-1001"}`)
is proposed as is, no model involved. Anything else — an email, a PDF's text — is read by the LLM
when a provider is configured (`SYNSEMA_LLM_PROVIDER` and its key in `.env`); it extracts three
fields and nothing more, and without a provider the file goes to `inbox-review/` for a person.
Handled files move to `inbox-done/` or `inbox-review/`; the log says what happened, and the
enclave's answers to the agent's proposals (`pending` with reasons, `executing`, `settled`, …) are
printed as they arrive. A proposer can also propose by hand: `vela_client.syn -- propose <payee> <tokens> [memo]`
and `outcomes` with the agent's keys.

The worst a bug or a prompt injection in the agent can do is a proposal the policy stops: it holds
no funds, and the enclave does not take orders from it beyond `propose`.

On the Synsema platform this file is the recipe's entry (`syn.toml`: kind `worker`); `inbox/`,
`inbox-done/` and `inbox-review/` are its volumes.

## What the chain sees

Each payment that is executed: one public app event with `(id, payee, token, amount)` — the trigger
needs it to pay, and an on-chain transfer is public anyway — the token transfer itself, deposits,
withdrawals, request fees. What stays inside: the policy, the budget, who proposed, memos, what was
held, approved or rejected, and the reasons.

## Keys, roles, the trigger

- The **owner** deploys, funds, sets the policy, approves, withdraws, audits. Its key is `VELA_SECP_KEY`
  in `client/.env` (Anvil #0 on the kit: it also has `DEPLOYER_ROLE`).
- A **proposer** only proposes. The agent's key is `VELA_SECP_KEY` in the root `.env`.
- The **trigger** is one contract per treasury app (the endpoint binds them at deploy). It holds
  nothing between payments and has no owner; `scripts/trigger/deploy.sh` compiles it against Vela's
  contracts (cloned at build time, BSL-licensed, not vendored) and writes `VELA_TRIGGER`.
- Everyone who receives events — the owner, every proposer — registers first (`register`); an event
  for an unregistered address fails the request.

## Gotchas

- The app is deployed for one owner, one token, one trigger; redeploying creates a new application
  id, a new ledger, and needs a new trigger.
- Deploying needs `DEPLOYER_ROLE`; the token needs `TokenAllowlist.addAllowedToken`; the auditor
  needs `DefaultAuthority.addAllowedAuthority(appId, address)` from the admin, per application
  (`vela_client.syn -- allow-authority <appId> <address>`; on a devnet the admin key is Anvil #0).
- Amounts are the token's smallest unit as text inside the enclave; the client converts.
- Node 22 crashes intermittently inside V8 running this module; use Node 20 or 24+.
- On Windows, run the scripts from Git Bash.

The full reference is the docs page [Vela (Horizen)](https://synsema.dev/en/0.6.x/73-vela); the
adapter lives in [kitecosmic/synsema — packages/guests/vela](https://github.com/kitecosmic/synsema/tree/main/packages/guests/vela).

## Guía rápida (español)

Tesorería con política para agentes: un agente propone pagos, el enclave aplica la política del
dueño (quién propone, a quién se paga y hasta cuánto, el límite automático por pago, la
asignación otorgada) y paga al instante por el contrato trigger o retiene la propuesta para que el
dueño la apruebe o rechace. 1. `synsema test app/app.syn`. 2. `sh scripts/build.sh`. 3. `sh scripts/devnet.sh`.
4. `sh scripts/e2e.sh`: trigger, app, política, cuatro propuestas (pagada, retenida y aprobada,
retenida y rechazada, tomada de `inbox/` por el worker) con los saldos verificados en cadena.
El agente (`agent.syn`, desde la raíz, con sus propias claves en `.env`) lee `inbox/`: JSON directo,
texto libre con un LLM configurado. Referencia completa en [synsema.dev/es/0.6.x/73-vela](https://synsema.dev/es/0.6.x/73-vela).

## License

Apache-2.0.
