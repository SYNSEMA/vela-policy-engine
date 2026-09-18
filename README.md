# vela-policy-engine — a payment policy engine on Vela (Horizen), in Synsema

An AI agent reviews invoices and proposes payments. The enclave enforces the owner's spending
policy — who may propose, who may be paid and up to how much, the automatic limit per payment, the
allowance the owner granted — and either pays at once through a trigger contract or holds the
proposal for the owner. Every decision is deterministic, every proposal lands in an audit report,
and the agent never holds a key that can move the funds. **LLM outside, policy inside**, in the
same language on both sides. The funds the policy governs are called the treasury below.

```
the agent — outside: turns an invoice into a proposal, signed with the AGENT's key
   ▼
enclave (app/app.syn) — the policy: proposers, payees + caps, automatic limit, allowance
   │ inside the policy → withdrawal to the trigger + one public event (id, payee, token, amount)
   │ outside it → held; the OWNER approves or rejects
   ▼
TreasuryTrigger.sol — transfers the token to the payee, reports back (settled / failed → refund)
owner — funds, grants, allowlists, approves, withdraws, audits
```

Built on [Vela](https://docs.horizen.io/vela/introduction/), whose Executor runs the app inside a
TEE and settles every result on-chain. The app is **one `.syn` file** with its tests; the module is
the release's guest with that program in its slot (no compiler); and the side outside the enclave is
Synsema too: a **web console** (the recipe's entry), a standalone agent worker, and a command-line
client on the same library. Verified end to end against Horizen's starter kit v0.2.0 (the real
Executor, the real contracts) on the public devnet, trigger cycle included.

## The console

Deploy the recipe on [synsema.com](https://synsema.com) — the project's environment is provisioned
from the public devnet at creation (a token of your own, the addresses, the keys, the trigger
factory) — or run it locally: `synsema serve web.syn` from this folder, with `.env` copied from
`.env.example` and filled by `cd client && synsema run vela_client.syn -- devnet`. Then, in the browser:

1. **Deploy the treasury.** The console makes a trigger contract for it through the factory on the
   stack, embeds `app/app.syn` into the release's guest module, deploys it to Vela for this owner,
   token and trigger with the automatic limit and the allowance you set, and registers the owner
   and a demo agent (a key of its own) with the enclave.
2. **Fund, set the policy, allow payees.** Deposits, grants, the automatic limit, who may be paid
   and with what cap per payment.
3. **The agent proposes.** A payee, an amount, a memo — signed with the agent's key, submitted by
   the owner's facilitator. Inside the policy it is paid at once through the trigger; outside it,
   the proposal waits at the top of the page with every reason.
4. **Approve or reject** what was held. An approval pays without touching the allowance.
5. **Watch it settle.** The enclave's answers to the owner (payment, settled, failed, approval
   needed, policy), what the chain sees (one receipt per executed payment) and the payees' wallets.

Every action is one request to the enclave: 30 to 60 seconds on a devnet; a payment also runs
the trigger cycle before it shows as settled. The console's state (app id, trigger, keys, the
agent's key, payees) lives in `data/treasury.json`, a volume on the platform.

## What you get

```
web.syn                      the console: deploy · fund · policy · payees · propose · approve / reject · events · receipts (the recipe's entry, kind = web)
pages/home.html              its page
app/app.syn                  the policy, inside the enclave: deploy · deposit · propose · approve · reject · policy · withdraw · trusted · deanonymize, with tests
agent.syn                    the standalone agent worker: inbox/ → proposals (JSON as is; free text through an LLM)
client/vela_lib.syn          Vela's client protocol as a module (keys, cipher, submit, events, facilitator, reports, token amounts)
client/vela_client.syn       the owner's and the proposers' commands, on top of the module
scripts/trigger/             TreasuryTrigger.sol and its factory, built against Vela's contracts (deploy.sh, build.sh WHAT=factory)
scripts/erc20/               the test stablecoin (TST, 6 decimals, permit) scripts/devnet.sh deploys and allowlists locally
scripts/embed_lib.syn        the app slot of a guest module (what build.sh and the console use to embed the program)
scripts/build.sh             app/app.syn → build/app.wasm with the release's guest, for the CLI's deploy
scripts/smoke.mjs            probe of the module under Node's WASI, the way the Executor drives it
scripts/devnet.sh            Horizen's starter kit in Docker + the test token + the trigger; client/.env written
scripts/e2e.sh               the CLI's whole treasury: trigger → app → policy → paid · held+approved · held+rejected · from inbox/
examples/                    an invoice as JSON and as free text
.github/workflows/build.yml  CI: tests, build, Node 24 + wasmtime-go probes, build/app.wasm as an artifact
syn.toml                     the recipe descriptor: the console as entry, the public devnet as default, [provision] for the token
```

## The policy

Set at deploy and changed by the owner at any time:

| rule | what it does |
|---|---|
| **proposers** | addresses that may propose (the agent's; a person's). Anyone else gets an error, nothing is recorded |
| **payees** with an optional **cap** | who may be paid, and at most how much per payment |
| **automatic limit** (`max_auto`) | at or below it a proposal is paid at once; above it, the owner decides |
| **allowance** | the budget automatic payments draw from; the owner grants it (a "daily limit" is a grant a day — the enclave has no clock, so the period is whoever grants) |
| **balance** | what the treasury holds; a proposal it cannot cover waits for funds and the owner |

A proposal inside every rule is paid at once. Outside any of them it is **held** with every reason
(`over the automatic limit 200`, `payee not allowlisted`, …); the owner's approval pays it without
touching the allowance, a rejection closes it. The trigger's answer settles it or, if the transfer
reverted, refunds the treasury (and the allowance when the payment was automatic).

## The trigger and its factory

The trigger is one contract per treasury (the endpoint binds them at deploy). It holds nothing
between payments and has no owner. A Synsema program cannot send a contract-creation transaction,
so the console makes triggers through `TreasuryTriggerFactory`, deployed once per stack
(`WHAT=factory sh scripts/trigger/build.sh`; the public devnet hands its address out as
`VELA_TRIGGER_FACTORY`). The CLI's `deploy-treasury` uses a trigger deployed directly by
`scripts/trigger/deploy.sh`. Both compile against Vela's contracts, cloned at build time
(BSL-licensed, not vendored).

## The command line

`client/vela_client.syn`, run from `client/` with the owner's keys in `client/.env`:

| `synsema run vela_client.syn -- …` | does |
|---|---|
| `devnet [host]` | a token of your own on the public devnet, written to `.env` |
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
`scripts/e2e.sh` runs the whole cycle from the CLI: about ten minutes on the public devnet.

## The standalone agent

`agent.syn`, run from the repository root with the agent's own keys in `.env`: a secp256k1 key
with a little ETH for fees — never the owner's — and a P-521 pair for its events. The owner
allowlists its address with `allow-proposer` (the console's demo agent is allowed at deploy).

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
printed as they arrive.

The worst a bug or a prompt injection in the agent can do is a proposal the policy stops: it holds
no funds, and the enclave does not take orders from it beyond `propose`.

## What the chain sees

Each payment that is executed: one public app event with `(id, payee, token, amount)` — the trigger
needs it to pay, and an on-chain transfer is public anyway — the token transfer itself, deposits,
withdrawals, request fees. What stays inside: the policy, the budget, who proposed, memos, what was
held, approved or rejected, and the reasons.

## Keys and roles

- The **owner** deploys, funds, sets the policy, approves, withdraws, audits. Its key is
  `VELA_SECP_KEY` (on the devnet, the account that comes with your token: it has `DEPLOYER_ROLE`).
- A **proposer** only proposes. The console's demo agent has a key of its own, kept on the
  volume; the standalone agent's is `VELA_SECP_KEY` in its `.env`.
- Everyone who receives events — the owner, every proposer — registers first; an event for an
  unregistered address fails the request. The console registers through the facilitator: a
  proposer needs no ETH.

## Gotchas

- The app is deployed for one owner, one token, one trigger; redeploying creates a new application
  id, a new ledger, and needs a new trigger (the console makes one).
- Deploying needs `DEPLOYER_ROLE`; the token needs `TokenAllowlist.addAllowedToken`; the auditor
  needs `DefaultAuthority.addAllowedAuthority(appId, address)` from the admin, per application
  (`vela_client.syn -- allow-authority <appId> <address>`; on the devnet `VELA_ADMIN_URL` signs it for you).
- Amounts are the token's smallest unit as text inside the enclave; the console and the client convert.
- Node 22 crashes intermittently inside V8 running this module; use Node 20 or 24+.
- On Windows, run the scripts from Git Bash.

The full reference is the docs page [Vela (Horizen)](https://synsema.dev/en/0.6.x/73-vela); the
adapter lives in [kitecosmic/synsema — packages/guests/vela](https://github.com/kitecosmic/synsema/tree/main/packages/guests/vela).

## Guía rápida (español)

Tesorería con política para agentes: un agente propone pagos, el enclave aplica la política del
dueño (quién propone, a quién se paga y hasta cuánto, el límite automático por pago, la
asignación otorgada) y paga al instante por el contrato trigger o retiene la propuesta para que el
dueño la apruebe o rechace. La consola web (`synsema serve web.syn`, o la receta en synsema.com con
el entorno aprovisionado desde el devnet público) hace todo desde el navegador: desplegar la
tesorería con su trigger, fondear, política, beneficiarios, las propuestas del agente, aprobar o
rechazar, y ver cada pago liquidarse en cadena. Desde la terminal: `synsema test app/app.syn`,
`sh scripts/build.sh`, `sh scripts/devnet.sh`, `sh scripts/e2e.sh`. El agente autónomo (`agent.syn`,
con sus propias claves en `.env`) lee `inbox/`: JSON directo, texto libre con un LLM configurado.
Referencia completa en [synsema.dev/es/0.6.x/73-vela](https://synsema.dev/es/0.6.x/73-vela).

## License

Apache-2.0.
