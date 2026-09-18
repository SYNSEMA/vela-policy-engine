# Synsema on Vela — Deliverable 1

*Horizen Acceleration Season, week 2. September 18, 2026. Repo: https://github.com/SYNSEMA/vela-policy-engine · docs: https://synsema.dev/en/0.6.x/73-vela · devnet: https://devnet.synsema.app/ · video: `[link added at submission]`*

## The problem, in the buyer's words

Nobody replaces a payment backend that already works. The person is somewhere else: reviewing the invoice, sorting out the exception when it does not match the order, approving above a threshold, catching the supplier who "changed bank account" by email. That seat is where an AI agent adds value, reading messy documents and reasoning about mismatches, and where it is dangerous, because a PDF with hidden instructions or a forged email can convince it. Synsema makes it safe to put an agent in that seat: the agent reads everything and recommends, and cannot approve more than a written policy allows. Payments within policy go out; the rest is held for a person; a change of payee details always passes through the human gate; the log shows what the agent saw and decided. Vela solves the second problem: paying on-chain publishes your business relationships, who you pay, how much and when, which is why companies do not pay salaries or suppliers in stablecoins even where it is cheaper. On Vela the policy, the ledger and the amounts per payee stay private, settlement is public, and an auditor gets a report. Keep your backend, put a reviewer you can bound in the loop, stop leaking your payments.

## What we built

Synsema is a programming language for AI agents where permissions are syntax: a program's `require` block is its manifest, and without it there is no network, no files, no signing, no secrets. For Vela we built a second way to write apps: the app is **one Synsema file with its tests**, and the WASM module is our published guest, the interpreter compiled for Vela's host ABI, with the program embedded in a 512 KB slot. No TinyGo, no Rust, no pointer ABI. The client side is Synsema too: a full protocol client and a web console per app. Four apps run end to end on the starter kit v0.2.0: private transfers with feature parity with vela-nova, a private payroll, a **payment policy engine** (this deliverable: an agent treasury) and a dark pool for block trades (a sealed-bid batch auction).

## What this gives Vela

- **Time to app.** A team without Go engineers writes a Vela app in one file, tests it locally without Docker, and deploys it from the browser in ten minutes.
- **AI coding agents as a channel.** With the Synsema skill, the docs MCP and doctested docs, Claude Code or Cursor writes and deploys a correct Vela app without reading the Go code; the protocol details we had to dig out of the Go are encoded there.
- **Legible compliance.** Today "compliance without exposure" means the hash of a binary on-chain. With Synsema, what a confidential app may do (its manifest) and the policy it applies are source text under that same `wasmSha256`, and anyone rebuilds the module from the release asset and compares. An auditor reads twenty lines, not compiled TinyGo.
- **Apps and a shared testnet, today.** Four apps as public templates and platform recipes, and a public devnet (`devnet.synsema.app`: the kit v0.2.0 behind HTTPS, an account per team, the standard `novaw` / TS / Go flow). As of September 17: 75 tokens issued, 25 apps deployed, 131 requests completed; two other cohort teams have deployed their own WASM on it.

## Architecture, hop by hop

1. **Write** `app/app.syn`: a stateless function. State comes in encrypted and goes out modified; the enclave has no clock, no randomness, no network, so `now()` and `random()` are not there to call.
2. **Build without a compiler**: `scripts/build.sh` downloads the release's guest and embeds the program in 0.16 s. The `wasmSha256` the Executor verifies covers interpreter and program; anyone can rebuild it from the asset and compare hashes.
3. **Deploy** through the standard flow: upload to the Authority Service, `submitDeployRequest` (DEPLOYER_ROLE), app id from the event. The treasury also gets a trigger contract from a factory.
4. **Requests**: the client registers a P-521 key with a subtype seed, encrypts (ECDH → HKDF → AES-256-GCM) and submits PROCESS / DEANONYMIZATION / ASSOCIATEKEY, or a facilitator pays (EIP-712 authorization + EIP-2612 permit). TRUSTPROCESS arrives from the trigger.
5. **Out**: encrypted events per user (50 HMAC-derived subtypes, unlinkable across users), public app events where the app wants them, withdrawals through the exitpoint.

The treasury is "Allow / Hold / Block, rules held in state". An invoice arrives; the agent, running outside on the Synsema platform, reviews it and turns it into a signed proposal; the enclave applies the policy (proposers, payees with caps, an automatic limit, the allowance) deterministically: within it, the trigger pays and one public event is emitted; outside it, the proposal is held with its reasons until the owner approves or rejects; the auditor gets a deanonymization report. **LLM outside, policy inside, same language on both sides.**

## What stays private, what settles on-chain, what leaks anyway

| Private (in the state, decrypted only in the enclave) | On-chain, public | Leaks anyway |
|---|---|---|
| Treasury: the policy, every proposal and its reasons, the ledger, the audit report | Deposits; payments that pass the policy, through the trigger (payee, token, amount); withdrawals | Who sent each request, when, the amount locked; the agent's address and cadence |
| Payroll: each person's payslips and balance | The employer's deposit; a public receipt per run `abi(run, count, keccak(items))`; withdrawals (address, amount) | Same |
| Auction: every bid, the ranking, the losing bids | `opened` / `cleared` events (lot, clearing price, fills); escrow; settlement | Bidder addresses and escrowed amounts |

Honest notes: the deployed WASM is loaded from the host, so the operator can read the program (we embed source), which is why every rule lives in the state and never in the module. The Manager can delay or reorder; it cannot read or forge. Reading a private balance means scanning and decrypting events (no view call); our consoles do exactly that.

## Onboarding: time to first execution, gaps, friction

- **Time to first execution**: the first Synsema app ran end to end on the local kit in one afternoon. Local run of this deliverable (September 18, Docker Desktop on a laptop, the kit's emulated TEE): the module built in 12.8 s including the download of the guest; the deploy from the console (upload, `submitDeployRequest`, the Executor's answer, two registrations) took 1 min 37 s; funding took 37 s; allowing a payee about 40 s; a hop to the enclave is 35 to 45 s here, and a payment adds the trigger cycle. On the devnet a hop to the enclave takes ~35 s (5 s polling floor plus block and result); a kit's e2e 2–3.5 min; the treasury e2e with the trigger cycle 9 min 10 s.
- **Doc gaps we filled from the Go code and the contracts**: the wire format of requests and state; the subtype seed derivation; the EIP-712 fields and the facilitator nonce; the deploy descriptor; DefaultAuthority needing `addAllowedAuthority` before any report; the event ABI a trigger reads. On fees: the fuel price is an executor variable, not on-chain and not readable; nothing says how to size `maxFeeValue`; nothing says a failed request carries no events; `ErrorCode` is renumbered in the unreleased v0.3.0. Detailed note shared; docs PR offered.
- **Friction, in order**: `AuthorityNotAllowed` with no hint; `steps()` as fuel exceeds `novaw`'s 100 wei; an event to an unregistered user drops the request (code 9); 10 app slots in the kit's ProcessorEndpoint; `novaw-linux` on a Windows bind mount; the compose needs `privileged` and `/dev/vsock` even over TCP; `forge` without DNS inside the chain container.
- **What helped**: clear Go, readable contracts, one-command compose, a TS client that shows every field.
