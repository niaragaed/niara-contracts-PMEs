# niara-contracts-PMEs

Solidity contracts for the tokenized fundraising of Brazilian small and medium-sized
enterprises (SMEs, "PMEs" in Portuguese), under **CVM Resolution 88**: a company creates
an offering, investors invest and receive tokens representing the issued shares. Sister
repository of `niara-PMEs` (the Niara SMEs web app, which really reads from and writes to
this infrastructure at `/investir/onchain`) and separate from the `niara-contracts`
exchange (the group's secondary market, used here only as a read-only reference).

**Testnet prototype (Sepolia), with no published external audit.**
Honest wording: full test coverage + fuzzing invariants, **without** an external
audit. No contract in this repository should be described as "secure" or "audited", and
there is no mainnet deployment in this phase. `MockBRL`, the currency used for
investments, is an unbacked test mock.

## Current stage

Four contract phases completed, **315/315 tests passing** (unit + stateful fuzzing
invariants), with 100% line/branch/function coverage on the main contracts:

- **Phase 1**: clonable participation token (`ParticipacaoToken`, via EIP-1167) with a
  pluggable transfer policy, secondary market off by default.
- **Phase 2**: primary fundraising with escrow (`OfertaCaptacao`): minimum/maximum
  target, per-investor cap, shares only minted when the fundraising succeeds.
- **Phase 3**: restricted transfer policy (`RestrictedTransferPolicy`): lock-up +
  allowlist + a flag that opens the secondary market.
- **Phase 4**: secondary settlement (`LiquidacaoSecundaria`): a bilateral assignment
  matched by the platform, not an open order book.

The infrastructure is deployed on Sepolia and really connected to the `niara-PMEs`
frontend (`/investir/onchain`), including a set of demo offerings ready for live pitches.

See [`CLAUDE.md`](./CLAUDE.md) for the full history of decisions, each phase's
architecture, deployed addresses and known open items. It is this repository's source
of truth.

## Naming

Contract, function, event, error and parameter names are in Portuguese because they are
the ABI of contracts already deployed on Sepolia. Everything else (comments, NatSpec,
tests, scripts and docs) is in English. Quick glossary: *oferta* = offering,
*captação* = fundraising, *cota* = share, *aporte/aportar* = investment/invest,
*emissor* = issuer, *investidor* = investor, *encerrar* = close, *resgatar* = redeem,
*reembolsar* = refund, *liberar* = release, *taxa* = fee, *teto* = cap, *prazo* =
deadline, *meta mínima/máxima* = minimum/maximum target, *cessão* = assignment,
*vendedor/comprador* = seller/buyer, *liquidação* = settlement.

## How to run

```bash
forge build
forge test -vv
forge coverage
```

## Foundry

Ethereum toolkit used in this project: Forge for build/tests, Cast to interact with
contracts and the chain, Anvil for a local node. Docs: https://book.getfoundry.sh/

```bash
forge fmt         # formats the code
forge snapshot    # gas snapshots
anvil             # local node
cast <subcommand> # interacts with contracts/chain
```
