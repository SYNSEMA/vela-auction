# vela-auction — a sealed-bid auction on Vela (Horizen), in Synsema

A seller offers a block of one token for another: an OTC block, a token sale, a bill. Bidders
deposit the payment token and send their bids **encrypted to the enclave**. Nobody — not the other
bidders, not the seller — sees a bid before the close. The matching runs inside, deterministically;
winners and losers are settled from their escrow; the losing bids are never revealed to anyone.
The chain sees that an auction opened and what it cleared at, never who bid what.

```
seller ───open (asset, quantity, payment, reserve, kind)──▶ ┌────────── enclave ──────────┐──▶ chain: opened(id, asset, quantity, payment, kind)
bidder ───bid (quantity, total), sealed────────────────────▶ │ escrow · the book · ranking   │
seller ───close───────────────────────────────────────────▶ │ matching · settlement        │──▶ chain: cleared(id, sold, proceeds, kind)
                                                             └──────────────────────────────┘──▶ each bidder: its own result (fill, price paid)
anyone ───withdraw (a pull-payment) · claim-for on-chain                                       ──▶ the seller: the fills
auditor ──audit ──▶ the whole book
```

Built on [Vela](https://docs.horizen.io/vela/introduction/), whose Executor runs the app inside a
TEE and settles every result on-chain. The app is **one `.syn` file** with its tests; the module is
the release's guest with that program in its slot (no compiler); and the side outside the enclave is
Synsema too: a **web console** (the recipe's entry) and a command-line client on the same library.
Verified end to end against Horizen's starter kit v0.2.0 (the real Executor, the real contracts) on
the public devnet.

## The console

Deploy the recipe on [synsema.com](https://synsema.com) — the project's environment is provisioned
from the public devnet at creation (a token of your own, the addresses, the keys) — or run it
locally: `synsema serve web.syn` from this folder, with `.env` copied from `.env.example` and filled
by `cd client && synsema run vela_client.syn -- devnet`. Then, in the browser:

1. **Deploy the auction house.** The console embeds `app/app.syn` into the release's guest module,
   deploys it to Vela and registers the seller's key with the enclave.
2. **Deposit the asset** the seller will sell: the stack's token (`VELA_TOKEN`).
3. **Set up bidders' desks.** On a devnet the console plays every side: a bidder is a wallet it
   custodies, given some ETH from the seller's wallet; it registers and deposits by itself, and its
   bids are signed with its own key. The enclave treats it exactly as a bidder with a wallet of
   their own, who uses the command-line client and never sees this page.
4. **Open an auction**: a quantity of the token for ETH, a reserve for the whole lot, uniform price
   or pay-as-bid.
5. **Bid from each desk.** A quantity and a total; the desk shows the price it means and sends the
   bid encrypted. Nobody — not the seller, not the other desks — sees it before the close.
6. **Close.** The matching runs inside. Each desk learns its own result (fill, price paid, refund,
   the clearing price); the seller learns the fills; the chain learns what cleared.
7. **Withdraw and claim**: what was won, what came back, the proceeds — pull-payments claimed on-chain
   from the same button.

Every action is one request to the enclave: 30 to 60 seconds on a devnet. The console's state
(app id, keys, desks, auctions) lives in `data/auction.json`, a volume on the platform.

## What you get

```
web.syn                      the console: deploy · deposit · desks · open · bid · close · results · withdrawals (the recipe's entry, kind = web)
pages/                       its two pages: the seller's desk, a bidder's desk
app/app.syn                  the book, inside the enclave: deploy · deposit · open · bid · cancel_bid · close · cancel · withdraw · deanonymize, with tests
client/vela_lib.syn          Vela's client protocol as a module (keys, cipher, submit, events, facilitator, reports, token amounts)
client/vela_client.syn       the seller's, the bidders' and the auditor's commands, on top of the module
scripts/embed_lib.syn        the app slot of a guest module (what build.sh and the console use to embed the program)
scripts/erc20/               the test token (TST, 6 decimals, permit) scripts/devnet.sh deploys and allowlists locally
scripts/build.sh             app/app.syn → build/app.wasm (the release's guest module with your program in its slot) + sha256
scripts/embed.syn            puts a .syn into the app slot of a guest module — what build.sh runs; no compiler
scripts/smoke.mjs            probe of the module under Node's WASI, the way the Executor drives it
scripts/devnet.sh            Horizen's starter kit in Docker + the test token; client/.env written
scripts/e2e.sh               a whole auction: deploy → three parties → open → two sealed bids → close → results → claims → audit
.github/workflows/build.yml  CI: tests, build, Node 24 + wasmtime-go probes, build/app.wasm as an artifact
syn.toml                     the recipe descriptor: the console as entry, the public devnet as default, [provision] for the token
```

## How the matching works

- A bid is a pair: `quantity` of the asset for `total` of the payment token. The price is the
  ratio, and bids are ranked by cross-multiplication — exact integers, never a float. Ties go to
  the earlier bid.
- `reserve` is the least total the seller accepts for the whole quantity, a price floor; bids
  below it are never filled.
- **Uniform price** (default): the best bids win until the quantity runs out; every winner pays the
  price of the lowest accepted bid (the clearing price); the last winner may be partly filled and
  pays `floor(filled × total ÷ quantity)` at that price. **Pay-as-bid**: each winner pays its own.
- The rest of every bidder's escrow comes back to its balance; the unsold remainder goes back to
  the seller; the proceeds land in the seller's balance. Everyone withdraws as a pull-payment,
  claimed on-chain by anyone (`claim-for`).
- One live bid per bidder per auction; a new one replaces the old; `cancel-bid` before the close.
  The seller can `cancel` an open auction: every bid is refunded.

## Ten minutes, from the terminal

You need the [`synsema` binary](https://synsema.org) (`npm i -g synsema`, or the install script). That is
all: the module is the release's guest with your program in its slot — no compiler, a few seconds.
For the stack you need Docker, or a token of your own on the public devnet (`synsema run vela_client.syn -- devnet`).

```sh
synsema test app/app.syn                 # 1. the book, natively — the same code runs in the enclave
sh scripts/build.sh                      # 2. build/app.wasm: the release's guest + your program (the guest downloads once)
node scripts/smoke.mjs build/app.wasm    #    Node 20 or 24+ (not 22)
sh scripts/devnet.sh                     # 3. Vela in Docker + the test token; writes client/.env
sh scripts/e2e.sh                        # 4. a whole auction with three parties, claims checked on-chain
```

`scripts/e2e.sh` deploys the app, registers the seller (the signing key, Anvil #0 on the kit) and two
bidders (Anvil #1 and #2 by default), funds them, opens an auction of 1000 of `VELA_TOKEN` for ETH
with a 0.5 ETH reserve, places two sealed bids (600 for 0.9 ETH and 600 for 0.6 ETH), closes it —
the first bidder gets 600, the second 400, both at the clearing price of 0.001 ETH per unit — and
claims the withdrawals on-chain, checking the balances. About twelve minutes on the public devnet.

## The commands

`client/vela_client.syn`, run from `client/`; whoever holds `VELA_SECP_KEY` in `.env` is the caller.
Amounts are in tokens; `eth` names the native token.

| `synsema run vela_client.syn -- …` | who | does |
|---|---|---|
| `fund <eth\|token> <tokens>` | anyone | deposits into your balance in the app (approves first for an ERC-20) |
| `open <asset> <quantity> <payment> [reserve] [uniform\|pay_as_bid]` | the seller | locks the asset, opens the book; the chain learns the offer, not the seller |
| `bid <n> <quantity> <total>` | a bidder | a sealed bid; the client shows the price it means and sends it encrypted |
| `cancel-bid <n>` | a bidder | before the close; the escrow comes back |
| `close <n>` · `cancel <n>` | the seller | the matching, or a refund of every bid |
| `results [n]` | anyone | your decrypted events: your bids, your result (fill, price paid, refund, the clearing), the seller's fills |
| `auctions [n]` | anyone | the public events decoded: `opened`, `cleared` |
| `withdraw <eth\|token> <tokens> [to]` · `pending` · `claim-for` · `token-balance` | anyone | balances out as pull-payments, claims, on-chain balances |
| `audit ['<json>']` | an allowed authority | the whole book; `{"report_type":"auction","auction":"0x…01"}` for one |
| `devnet` · `allow-token` · `allow-authority` | anyone | a token of your own on the public devnet; allowlists with the admin key |

Plus the starter kit's generic commands (`keys`, `register`, `deploy`, `send`, `events`, the
facilitator flow). An auction is named by its number (`1`) or its id (`0x…01`).

## What stays private, what the chain sees

Private: every bid (quantity, total, who), the ranking, who lost, what the winners paid
individually, the balances. Each bidder learns only its own result and the clearing price; the
seller learns the fills; an allowed authority can read the whole book. Public: that an auction
opened (asset, quantity, payment token, kind), that it cleared (quantity sold, proceeds, kind),
deposits and withdrawals as token movements, request fees.

## Gotchas

- Every party that receives events — the seller, every bidder — registers first (`register`); an
  event for an unregistered address fails the request.
- Both tokens must be on Vela's allowlist (`allow-token` with the admin key on a devnet); ETH always is.
- Deploying needs `DEPLOYER_ROLE`; the auditor needs `DefaultAuthority.addAllowedAuthority(appId, address)`
  (`vela_client.syn -- allow-authority <appId> <address>`; on a devnet the admin key is Anvil #0).
- Amounts are the token's smallest unit as text inside the enclave; the client converts. Integers
  in Synsema multiply and compare exactly at any size, but `/` goes through a float: the app and
  the client divide with their own long division.
- Node 22 crashes intermittently inside V8 running this module; use Node 20 or 24+.
- On Windows, run the scripts from Git Bash.

The full reference is the docs page [Vela (Horizen)](https://synsema.dev/en/0.6.x/73-vela); the
adapter lives in [kitecosmic/synsema — packages/guests/vela](https://github.com/kitecosmic/synsema/tree/main/packages/guests/vela).

## Guía rápida (español)

Subasta de sobre cerrado: la parte vendedora ofrece un bloque de un token a cambio de otro; las
pujas van cifradas al enclave y nadie las ve antes del cierre; el matching corre adentro (precio
uniforme o pay-as-bid, ranking exacto por multiplicación cruzada); la liquidación sale del escrow y
las pujas perdedoras no se revelan nunca. La consola web (`synsema serve web.syn`, o la receta en
synsema.com con el entorno aprovisionado desde el devnet público) hace todo desde el navegador: la
mesa del vendedor y una mesa por postor; desplegar, depositar, abrir, pujar en sobre cerrado, cerrar,
resultados y retiros reclamados en cadena. Desde la terminal: 1. `synsema test app/app.syn`.
2. `sh scripts/build.sh`. 3. `sh scripts/devnet.sh` (o `synsema run vela_client.syn -- devnet`).
4. `sh scripts/e2e.sh`: tres partes, una subasta, dos pujas, cierre, resultados, retiros verificados en
cadena y auditoría. Referencia completa en [synsema.dev/es/0.6.x/73-vela](https://synsema.dev/es/0.6.x/73-vela).

## License

Apache-2.0.
