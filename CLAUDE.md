# CLAUDE.md — niara-contracts-PMEs

Standing instructions for Claude Code in this repository. Read them before writing any
code.

This repository is **separate** from:
- `niara-contracts`: the exchange (secondary market), a read-only reference (see the
  "Lineage" section). Never edit or copy files from there.
- `niara-PMEs`: the Niara SMEs web app. Do not look for or reference files from that
  project here.

---

## Language

**English is the default for everything in this repository**: comments, NatSpec, docs,
test names, script output, local variables/helpers in tests and scripts, and commit
messages.

**Exception: the deployed on-chain interface.** Contract, function, event, error,
struct, parameter and state-variable names in `src/` are in Portuguese because they are
the ABI of contracts already live on Sepolia (`OfertaCaptacao`, `aportar`,
`CotasResgatadas`, `PrazoExpirado`, `metaMinima`, ...). Renaming them would require
redeploying everything and would break the link to the existing on-chain history. Tests
and scripts keep those names wherever they call the API, and local variables that
mirror on-chain entities (`oferta`, `emissor`, `investidor`, `vendedor`, `comprador`)
may keep the same vocabulary. Also kept as is: script file/contract names (the
`broadcast/` receipts and the DEMO_*.md records refer to them), offering/company display
data (`"Padaria Silva Ltda"`), `cnpj-*` labels (hashed into `cnpjRef`) and `makeAddr`
labels (they derive deterministic addresses). New contracts should use English names
from the start. The README has a short glossary.

## No AI attribution (hard rule)

Nothing in this repository credits an AI tool, anywhere:

- no `Co-Authored-By: Claude` or `Claude-Session:` trailers, and no "Generated with Claude Code"
  line, in commit messages;
- no AI tool as a commit author or committer: commits use the project identity
  (`git config user.name`/`user.email` = `Niara <niaragaed@gmail.com>`, set in every clone and
  environment before the first commit — some environments default to `Claude <noreply@anthropic.com>`);
- no "Generated with/by Claude Code" footer in pull request descriptions, comments, issues or files.

It's enforced in two layers: the versioned `.claude/settings.json` turns Claude Code's commit
and PR attribution off (`"attribution": {"commit": "", "pr": ""}`), and the `No AI attribution`
GitHub Actions check (`.github/workflows/no-ai-attribution.yml`) fails on any commit or pull
request description that carries it. Some hosted environments append a footer to PR
descriptions by themselves; if the check flags one, delete that line in the GitHub UI. The rule
applies to every Niara repository, including new ones: copy both files when creating a repo.

---

## Product vision

A platform for tokenizing participation shares of Brazilian small and medium-sized
enterprises (SMEs), under **CVM Resolution 88** (securities offerings under a
registration exemption). A company creates an offering; investors invest and receive
tokens representing the issued shares.

**Everything here is a testnet (Sepolia) prototype, a demo, with no published external
audit.** Honest wording to always use: *"full test coverage + fuzzing invariants, WITHOUT
an external audit"*. Never describe any contract in this repository as "secure" or
"audited". Never deploy to mainnet in this phase.

Key difference from the exchange (`niara-contracts`): there it is a secondary market (P2P
trading of an asset that already exists, backed by a custody attestation). Here it is the
**primary market / fundraising**: the company issues shares and the investor invests.
That is why this repository has things the exchange did not: a factory with clones (one
token per offering) and a pluggable transfer policy (secondary market off by default).

From Phase 4 on this repository also has a secondary market, but it is **not** a P2P
order book like the exchange's: it is a bilateral assignment matched by the platform (see
`LiquidacaoSecundaria`/"Phase 4 architecture"), always behind the Phase 3 transfer
restriction. It is still not the exchange's design.

## Regulatory: the limits of what this code is

- **An on-chain cap table is a complementary evidentiary record. It does NOT replace the
  corporate books of Law 6,404/76 nor registration with a notary/commercial registry.**
  This is also in `ParticipacaoToken`'s NatSpec. No automation in this repository should
  suggest otherwise.
- `MockBRL` is a test mock: unbacked, valueless, labeled as such in NatSpec.
- No fee numbers in this phase: the SME revenue model is **still to be defined**. There
  is no `CashbackDistributor` in this repo (unlike the exchange).

---

## Locked decisions

- **Token architecture**: factory-per-offering, ERC-20 clonable via EIP-1167
  (OpenZeppelin's `Clones`). One clone per offering, a single auditable implementation.
- **Attested = shares authorized** in the company's corporate acts. Core invariant, valid
  for every token: `totalSupply() <= cotasAutorizadas`.
- **Initial category**: participation (shares) only. Debt/receivables are for a future
  phase; the base (`ITransferPolicy`, gateway, factory) is designed to extend to other
  categories without rewriting what exists.
- **Pluggable transfer policy** via `ITransferPolicy`. Phase 1 ships
  `DenyAllTransferPolicy` (secondary market fully off). The sophisticated policy (lock-up
  + allowlist + release flag) is Phase 3's `RestrictedTransferPolicy`, swappable by
  governance (see "Locked decisions — Phase 3" on the governed setter this required adding
  to the token).
- **Timelocked governance from day one** (minimum delay 1h, propose→execute pattern,
  ported from `niara-contracts`). The roles `AGENTE_ROLE` (agent/platform, attester/
  authorized issuer) and `EMISSOR_ROLE` (reserved for future actions specific to the
  issuing company) are declared in `EmissaoGateway` and `ParticipacaoTokenFactory`;
  `TimelockedAccessControl` itself is agnostic to concrete roles (it only knows
  `DEFAULT_ADMIN_ROLE`, inherited from OZ's `AccessControl`).
- **No `CashbackDistributor`.** The fee stays dormant/absent in this phase: do not add any
  fee bps number until explicitly instructed.
- **On-chain unit for investments**: `MockBRL` (mock, 18 decimals) on testnet. It was not
  load-bearing in Phases 0/1; it becomes load-bearing in the Phase 2 escrow
  (`OfertaCaptacao`).

### Locked decisions — Phase 2 (fundraising with escrow)

- **Partial close.** The offering has `metaMinima` (floor) and `metaMaxima` (cap). At
  closing (`OfertaCaptacao.encerrar`): `totalArrecadado >= metaMinima` ⇒ success (even
  below the maximum); below the floor ⇒ failure ⇒ refund. Closing is permissionless,
  valid once the deadline is reached OR the maximum target before it (a fully subscribed
  offering closes early).
- **Mint only on success.** No share is minted during the fundraising: the money stays in
  the escrow (`OfertaCaptacao`). Shares are only minted when success is settled
  (`resgatarCotas`), proportionally to what each investor contributed, via individual pull
  (never a loop over all investors, which would be a gas/DoS risk).
- **Per-investor cap on-chain, per offering**, with a qualified/uncapped flag attested by
  the AGENT in `RegistroInvestidorQualificado`. **The ANNUAL CAP ACROSS PLATFORMS set by
  CVM Resolution 88 is OFF-CHAIN and SELF-DECLARED**: no contract in this repository has,
  or can have, visibility into the same investor's investments on other platforms, and no
  automation should promise otherwise. The qualification flag is only the on-chain form of
  a suitability check the platform is already required to do off-chain.
- **Investment unit**: `MockBRL` (18 decimals), no FX conversion: "R$ 20k" is face value
  in `MockBRL`. USDT/WBTC as investment currency are out of this phase (they would require
  an FX oracle; under legal review).
- **Dormant fee with a hard cap**: `taxaBps` per fundraising, validated `<= 100` (1%) in
  `OfertaCaptacao.initialize` and in `OfertaCaptacaoFactory.criarCaptacao`, with no final
  value defined: whoever creates the fundraising chooses (including `0`, in which case the
  issuer receives 100% of what was raised). Do not hardcode a final number until
  explicitly instructed.
- **Rounding rule**: `aportar` requires the amount to be an exact multiple of
  `precoPorCota`, so that `shares = investment / precoPorCota` is always exact (no dust).
  A deliberate simplification in this phase; accepting any amount and returning the
  remainder is recorded as a possible future improvement.
- **Scale of minted shares**: `ParticipacaoToken` is a standard 18-decimal ERC-20 (no
  `decimals()` override), so "1 whole share" corresponds to `1 ether` in the token's raw
  unit, the same convention already used in Phase 1
  (`gateway.emitir(token, investidor, 100 ether)` == 100 shares). `OfertaCaptacao`
  computes the share COUNT as `aportado / precoPorCota` and then rescales by
  `UNIDADE_COTA` (`1 ether`) before minting; dividing without rescaling back would mint a
  tiny fraction of a share (a bug already caught and fixed while developing this phase).
  Any cap attestation (`atestarCotas`) for a token used in a fundraising must also be on
  the same scale: `(metaMaxima / precoPorCota) * 1 ether`.
- **`OfertaCaptacao` has no `AccessControl` of its own** (same reasoning as
  `ParticipacaoToken` in Phase 1: it is a lightweight clone replicated per offering). The
  escrow's only restricted action (`cancelar`) reuses the already-timelocked `AGENTE_ROLE`
  of the `EmissaoGateway` pointed to by `gateway`, read via `IAccessControl.hasRole`; it
  does not duplicate role management per clone.

### Locked decisions — Phase 3 (restricted transfer policy)

- **Deviation from the original plan: `ParticipacaoToken` gained a governed policy
  setter.** The Phase 1 plan assumed policy changes would only live in the factory's
  `transferPolicyPadrao`, but that change only affects **future** offerings (clones
  already created freeze the policy in effect when they were cloned, see "Phase 1
  architecture"). Migrating an already-live offering from `DenyAllTransferPolicy` to
  `RestrictedTransferPolicy`, the very point of Phase 3, requires touching the existing
  clone. That is why `ParticipacaoToken.setTransferPolicy(address)` was added, following
  the same single-authorization pattern (`onlyGateway`) as the token's other restricted
  functions (`mint`, `setCotasAutorizadas`, `pause`/`unpause`), not a new `AccessControl`
  in the clone. The decision of *when* to switch is sensitive (same category as swapping
  the factory's implementation), so it sits behind a timelock in
  `EmissaoGateway.proposeSetTransferPolicy`/`executeSetTransferPolicy`
  (`DEFAULT_ADMIN_ROLE`, same pattern as `SET_IMPLEMENTACAO`/`SET_TRANSFER_POLICY_PADRAO`),
  not `AGENTE_ROLE`; the token only exposes the raw setter to the `gateway`.
- **`RestrictedTransferPolicy` is shared, not cloned**: the
  `ITransferPolicy.canTransfer(token, from, to, amount)` signature already receives the
  token address, so a single instance serves any number of offerings, with all state
  (lock-up, allowlist, master flag) keyed by `token`. Fewer contracts to deploy/verify
  than a clone per offering.
- **`canTransfer` truth table**, in this order, all required: (1)
  `secundarioLiberado[token]` (master flag, default `false`); (2)
  `block.timestamp >= lockupAte[token]` (lock-up); (3) `elegivel[token][to]` (recipient
  allowlist). `from` is not part of the check: whoever already holds the token is a holder
  by construction (it only got there via mint), so CVM 88's requirement that "the buyer is
  an active investor" falls only on `to`.
- **Timelock × operational split identical to the earlier phases' pattern**:
  `definirElegivel`/`definirLockup` are operational (`AGENTE_ROLE`, immediate, for agile
  onboarding); `setSecundarioLiberado` is the only lever behind a timelock in this policy,
  because it is the decision that actually opens secondary trading. Full table in "Phase 3
  architecture".
- **`definirLockup` is set-once via a dedicated flag (`lockupDefinido[token]`), not a
  sentinel `lockupAte == 0`.** A lock-up of `0` seconds ("no lock-up") is a legitimate
  configuration; if "already set" were inferred from the value being non-zero, setting a
  `0` lock-up would leave the field permanently resettable, breaking the guarantee of a
  "deadline written into the offering, for real". The separate flag avoids that ambiguity.
- **Regulatory honesty**: `setSecundarioLiberado(token, true)` is the on-chain lever, but
  really turning it on depends on two conditions the contract does not and cannot check
  in full: the lock-up having elapsed (that one IS checked on-chain, in `canTransfer`)
  **and** the platform's business/legal authorization to open that secondary market
  (entirely external to the code, a governance decision that precedes the call). No
  automation should describe `setSecundarioLiberado` as, on its own, a regulatory
  approval.

### Locked decisions — Phase 4 (secondary settlement)

- **A matched bilateral assignment, not an order book.** `LiquidacaoSecundaria.liquidarCessao`
  receives an already-matched assignment (`token`, `vendedor`, `comprador`, `quantidade`,
  `precoPorCota`): there is no book of offers, no matching engine and no "create open
  order" function. The platform (AGENT) matches the parties off-chain; both pre-approve
  the necessary allowances before submission. This design embodies the intermediation
  CVM Resolution 88 requires for the secondary market of securities offered under a
  registration exemption, and avoids the unrestricted P2P marketplace semantics the
  exchange (`niara-contracts`) has.
- **It holds nothing: it works through `allowance`, adapted from the exchange's
  `NiaraSettlement`.** `LiquidacaoSecundaria` never keeps a balance of `MockBRL` or of
  shares; every assignment moves funds directly between `vendedor`/`comprador`/
  `protocoloWallet` via `transferFrom`, atomically. Same three-party (buyer/seller/protocol)
  pattern as `NiaraSettlement`. **Checked against the `NiaraSettlement.sol` source** in two
  rounds: first against the properties extracted from `NiaraSettlement.t.sol` (tests),
  then against an excerpt of `settle` itself (the fee anti-evasion guard, see below). See
  "Cross-check against `NiaraSettlement`" right below for the full result, including the
  confirmation of `SafeERC20` on every leg and of the transfer order. `niara-contracts` as
  a full repository (local clone, checkout) remained out of reach in this environment, but
  the relevant `NiaraSettlement` code was checked excerpt by excerpt over this phase's
  sessions; there is no open "unread file" item left.
- **The token remains the single source of truth for eligibility.** When
  `liquidarCessao` calls `IERC20(token).transferFrom(vendedor, comprador, quantidade)`,
  `ParticipacaoToken`'s `_update` already reads the current `RestrictedTransferPolicy` with
  `from=vendedor, to=comprador`: the same secondary-open/lock-up/allowlist check as Phase
  3, with no duplicated logic. `LiquidacaoSecundaria` only does a **pre-flight**
  (`ITransferPolicy.canTransfer`, `view`, no effect) before moving any funds, just to revert
  early with a clear error (`CessaoNaoPermitidaPelaPolitica`) instead of letting the revert
  happen mid-swap. If the pre-flight and `_update` ever diverged (they should not; it is the
  same view call), the guarantee that counts is always the token's.
- **Scale of `quantidade`/`precoPorCota`, same `UNIDADE_COTA` discipline as Phase 2.**
  `quantidade` is the amount of shares in the token's raw unit (18 decimals, the same
  passed straight to `transferFrom`, without requiring the caller to rescale anything);
  `precoPorCota` is the price of ONE whole share in `MockBRL` (same meaning as
  `OfertaCaptacao.precoPorCota`). `valor = (quantidade * precoPorCota) / UNIDADE_COTA`
  rescales back before multiplying by the price; omitting that rescale would inflate the
  amount by `1e18`, the same scaling bug already caught and fixed in
  `OfertaCaptacao.resgatarCotas` in Phase 2. Deliberate decision: the original task text
  for this phase described `valor = quantidade * precoPorCota` with no visible rescale;
  following it literally would have reintroduced exactly that scaling bug. The rescale was
  added on purpose and locked by a test
  (`test_LiquidarCessao_MovesSharesAndCurrency_NoFee`, which checks the exact amount).
- **The secondary fee is independent of the primary fee.** `taxaSecundarioBps` (Phase 4)
  and `OfertaCaptacao.taxaBps` (Phase 2) are separate parameters, each with its own hard
  cap of 100 bps and default `0`; nothing prevents different rates between primary and
  secondary. Do not hardcode either until explicitly instructed.
- **`LiquidacaoSecundaria` reuses `AGENTE_ROLE`/`TimelockedAccessControl`; it does not
  reinvent governance.** It is a single contract (not cloned, like
  `RestrictedTransferPolicy`, unlike `OfertaCaptacao`), so it declares its own
  `AGENTE_ROLE` and inherits `TimelockedAccessControl` directly, in the same pattern as
  `EmissaoGateway`/`RegistroInvestidorQualificado`/`RestrictedTransferPolicy`.
  `AGENTE_ROLE` must be granted on it separately; see "Phase 4 architecture" for the
  updated count of contracts that require the role.
- **Known-token validation via `IParticipacaoTokenFactory.isOferta`.** `liquidarCessao`
  reverts early (`TokenDesconhecido`) if `token` was not created by the
  `ParticipacaoTokenFactory` set at construction; this avoids settling assignments over an
  arbitrary address that is not even a `ParticipacaoToken` of this platform.

### Cross-check against `NiaraSettlement`

In two rounds, `NiaraSettlement`'s behavior was checked item by item against
`LiquidacaoSecundaria`: first against the properties extracted from
`NiaraSettlement.t.sol` (tests), then against an excerpt of the source of `settle` itself
(the fee anti-evasion guard). Result:

| Property | Status before | What changed |
|---|---|---|
| Atomic swap via `allowance`, no custody | Already compliant (since the initial implementation) | — |
| `SafeERC20.safeTransferFrom` on all three legs (payment to seller, fee to protocol, share to buyer) | Already compliant (`using SafeERC20 for IERC20` covers `moeda` and `token`) | Confirmed, no change needed |
| Fee with a hard cap via timelock | Already compliant (`TAXA_BPS_MAXIMA = 100`, `propose`/`execute`) | — |
| Reentrancy blocked (payment side) | Already compliant (`nonReentrant`, tested with `ReentrantMockBRL`) | — |
| `BuyerEqualsSeller` | Missing | Added: `VendedorIgualComprador()`, checked before any other validation |
| `ZeroAmount` (quantity) | Already compliant (`QuantidadeInvalida`) | — |
| `ZeroAmount` (payment amount) | Missing (a real gap: `quantidade`/`precoPorCota` != 0 did not prevent the derived `valor` from rounding to `0` by integer division) | Added: `ValorInvalido()`, checked after computing `valor` |
| **Anti-evasion by splitting** (`PaymentAmountTooSmallForFeePrecision` in the reference) | Missing (a real gap: with the fee active, a small enough `valor` made `taxa` truncate to `0` by integer division; splitting a large assignment into many tiny ones would dodge the fee) | Added: `ValorInsuficienteParaPrecisaoDaTaxa()`, `if (taxaSecundarioBps > 0 && taxa == 0) revert ...`, right after computing `taxa`. Harmless with the fee dormant (`0`), but it closes the loophole before the fee is turned on |
| `ZeroAddress` (token/buyer/seller) | Missing in `liquidarCessao` (it only existed in the constructor/setters) | Added: reuses the existing `ZeroAddress()`, checked first in the function |
| `Pausable` with a pause role | Missing | Added: `pause()`/`unpause()`. **Deliberate decision**: it reuses `AGENTE_ROLE` (the same single operational role used for pausing in `ParticipacaoTokenFactory`/`OfertaCaptacaoFactory`), not a new `PAUSER_ROLE` as in the reference; this repository never split pausing into a separate role, and creating one now just for this contract would break that consistency for no reason |
| Reentrancy from the ASSET side | Not applicable; see the justification below | Documented instead of forcing an artificial test |
| `settle` returns the fee charged | Missing (`liquidarCessao` returned nothing) | Added: `returns (uint256 taxa)` |
| Cap guard repeated in `execute` | Missing (`executeSetTaxaSecundarioBps` only relied on the `propose` validation) | Added: the same `TAXA_BPS_MAXIMA` check repeated in `execute`, covered by a test that calls `execute` directly without `propose` |
| Transfer order (asset → payment → fee in the reference) | `LiquidacaoSecundaria` does payment → fee → asset, the reverse order | **Deliberate divergence, documented instead of changed**; see below |

**Transfer order: why the divergence was kept**: in `NiaraSettlement` the order is asset
first, payment after. In `LiquidacaoSecundaria` it is the reverse: the two `MockBRL` legs
first, the token's `transferFrom` last. Since everything is atomic (`nonReentrant`, a
single `liquidarCessao`), the order does not change the final result on success or revert,
but keeping the TOKEN's `transferFrom` as the last call reinforces, in the code itself, the
theme already documented in the contract NatSpec: the `canTransfer` pre-flight only serves
to revert early with a clear error; the check that actually authorizes the assignment is
the token's `_update`, triggered by this last call, so it sits as the final gate of the
sequence rather than some leg in the middle. Commented inline in the code
(`liquidarCessao`).

**Reentrancy from the asset side: why it does not apply here**: in `NiaraSettlement` the
traded asset is an arbitrary ERC-20 (any pair can be listed on the exchange), so it must be
treated as potentially malicious, hence the re-entry test from the asset side too. In
`LiquidacaoSecundaria`, `token` has already passed the `factory.isOferta(token)` pre-flight:
it is always a `ParticipacaoToken` cloned from this platform's single implementation, never
an arbitrary ERC-20. That token's `transferFrom` path (`_update` →
`ITransferPolicy.canTransfer`, a side-effect-free `view`, → OZ's standard `super._update`)
has no external hook with third-party-controllable code. Forcing a re-entry test on that
side would require forging a malicious "ParticipacaoToken" that would never exist in
production (the implementation is fixed and auditable, cloned via EIP-1167); the test
would be artificial, not proof of anything that could really happen. Recorded as a
justification, not as a gap.

**Intentional divergence: fee destination**: `NiaraSettlement` sends the fee to a
`CashbackDistributor`. `LiquidacaoSecundaria` sends it straight to `protocoloWallet`. This
is deliberate, not an omission: this repository never had a `CashbackDistributor` (see
"Product vision" and "Locked decisions" at the top of this file). Cashback on trading
volume is an exchange mechanism that does not apply to the SMEs' restricted
primary/secondary model, where the intermediation is already the platform, not an open
market to be incentivized with cashback. Do not reintroduce `CashbackDistributor` in this
or future phases without an explicit instruction.

---

## Lineage (what came from `niara-contracts`)

`niara-contracts` (the exchange) is a **read-only** reference: never edited or copied
verbatim, but the following patterns were studied and adapted:

- **Structural invariant style**: the exchange's `AssetToken.mint` locks
  `totalSupply() + amount <= totalAttested`, checked inside the token contract itself (not
  only through the caller's access control). `ParticipacaoToken.mint` follows the same
  principle: `totalSupply() + amount <= cotasAutorizadas`, checked in the token,
  regardless of who holds the role authorized to call it.
- **Attest → mint pattern**: the exchange's `BackingGateway` records a request, a custodian
  role attests, and only then allows minting. `EmissaoGateway` replicates the pattern:
  `atestarCotas` (raises the cap) before `emitir` (mints), both restricted to
  `AGENTE_ROLE`.
- **`governance/TimelockedAccessControl.sol`**: ported almost verbatim: minimum delay of
  1h, standard `grantRole`/`revokeRole` disabled in favor of `proposeX`/`executeX`,
  `renounceRole` free. Adapted only in the concrete roles (`AGENTE_ROLE`/`EMISSOR_ROLE`
  instead of `MINTER_ROLE`/`CUSTODIAN_ROLE`/etc.).
- **`test/` structure and fuzzing harness**: `test/invariant/Handler.sol` +
  `test/Invariant.t.sol` follow the same design: a `Handler` (a single actor, one public
  function per protocol action) that Foundry's invariant engine explores with
  `targetContract`/`targetSelector`, with a fraction of the calls deliberately taking the
  invalid path (`_chaos`, ~1 in 5) to exercise the `revert`s. Fuzzing scale
  (`runs=256 * depth=100` = 25,600 calls per invariant run) chosen to deliberately mirror
  the exchange's.
- **`MockUSDT.sol`** → direct model for `src/mocks/MockBRL.sol` (simple ERC-20, public
  unrestricted `mint`, labeled as a mock in NatSpec).
- **`NiaraSettlement.sol`** → pattern adapted for `src/secundario/LiquidacaoSecundaria.sol`
  (Phase 4): atomic three-party settlement (buyer/seller/protocol) working through
  `allowance`, without holding funds, `SafeERC20` on all three legs, a hard fee cap of
  100 bps and the same anti-evasion-by-splitting guard
  (`PaymentAmountTooSmallForFeePrecision` in the reference,
  `ValorInsuficienteParaPrecisaoDaTaxa` here). The full `niara-contracts` repository was
  never accessible in the sessions where Phase 4 was implemented and checked (not on disk,
  not public on GitHub, no `gh` CLI/credentials in the environment); the implementation
  started from the functional description of the pattern and the two-round check of the
  properties of `NiaraSettlement.t.sol` and then of an excerpt of `settle`'s source code
  provided in the instruction. See "Cross-check against `NiaraSettlement`" (inside
  "Locked decisions — Phase 4") for the item-by-item result.

What did **not** come from the exchange (specific to this repository): the factory with
EIP-1167 clones, the pluggable `ITransferPolicy`, and the "authorized shares" model instead
of "custodied backing". The exchange never needed cloning because each `AssetToken` was
deployed once per asset.

---

## Phase plan

- **Phase 0** (done): foundation: Foundry project, conventions, `MockBRL`, `CLAUDE.md`.
- **Phase 1** (done): clonable `ParticipacaoToken` + `ITransferPolicy`/
  `DenyAllTransferPolicy` + `EmissaoGateway` + `ParticipacaoTokenFactory` +
  `TimelockedAccessControl` + unit and invariant tests. See "Phase 1 architecture" and
  "Test results (Phase 1)" below.
- **Phase 2** (done): CVM 88 primary fundraising with escrow: clonable `OfertaCaptacao` +
  `OfertaCaptacaoFactory` + `RegistroInvestidorQualificado` + an `EmissaoGateway`
  extension (fundraising-scoped mint) + unit, money-invariant and reentrancy tests. See
  "Phase 2 architecture" and "Test results (Phase 2)" below.
- **Phase 3** (done): sophisticated transfer policy: `RestrictedTransferPolicy` (lock-up +
  allowlist + secondary-market release flag) + a governed policy setter on
  `ParticipacaoToken` (a deviation from the original plan, see "Locked decisions — Phase
  3") + an `EmissaoGateway` extension (policy change via timelock) + unit and truth-table
  invariant tests. See "Phase 3 architecture" and "Test results (Phase 3)" below.
- **Phase 4** (done): secondary settlement: `LiquidacaoSecundaria` (a bilateral assignment
  matched by the platform, gated by Phase 3's `RestrictedTransferPolicy`, a pattern adapted
  from the exchange's `NiaraSettlement`) + unit, reentrancy and conservation/atomicity
  invariant tests. See "Phase 4 architecture" and "Test results (Phase 4)" below.
- **Phase 5** (future): additional categories (debt/receivables).
- **Phase 6** (in progress): integration with the site (`niara-PMEs`): the frontend now
  really reads/writes against the infrastructure already deployed on Sepolia (Phase 4),
  via `script/DemoNiaraPMEsOnChain.s.sol` (see below) + `src/lib/web3/` in that repository.
  No new contract was deployed for this; it is only a new write call
  (`criarOferta`/`atestarCotas`/`criarCaptacao`/`registrarCaptacao`) using the factories
  already verified and the `AGENTE_ROLE` already granted to the deployer.
- **`OfertaOrquestrador`** (done: implementation and real deploy on Sepolia): an additive
  self-service channel: the issuing company itself, previously authorized, creates its
  offering (token + fundraising) in a single atomic transaction, without gaining power over
  platform parameters. It does not replace or change any earlier phase; it is a second path
  to the same result (manual creation by the AGENT keeps working unchanged). See
  `PLANO_OFERTA_ORQUESTRADOR.md` (design) and "`OfertaOrquestrador`: self-service
  channel" below (real deploy and results).

### 🔴 Phase 4 deployer key lost: infrastructure redeployed on 2026-08-15

The original Phase 4 deployer's key (`0x101e8ad58F2D2A923553FeFE558a7bEf5566871E`,
documented in `DEMO_SECUNDARIO_SEPOLIA.md`) was lost (not found in any MetaMask wallet).
Since that deployer's `admin_` was the only address to receive `DEFAULT_ADMIN_ROLE` on all
6 contracts that require it (checked in `_deployInfra(admin, protocoloWallet)`,
`script/DemoSecundarioSetup.s.sol:74-95`: the same `admin` is passed to every constructor)
and the standard `grantRole`/`revokeRole` are disabled
(`TimelockedAccessControl.sol:102-110`), there was no on-chain path to recover access: the
10 original Phase 4 contracts (see the table in `DEMO_SECUNDARIO_SEPOLIA.md`) were
permanently orphaned. `DEMO_SECUNDARIO_SEPOLIA.md` **was not deleted** (it still documents
that historical deploy), but its addresses are no longer operable; always use the new
addresses below.

`script/DemoSecundarioSetup.s.sol` was run again, with a new burner wallet
(`0x0D41059eBde70a46EB5207af0837921594CAFC05`), confirming the 10 deploys + the 6
`AGENTE_ROLE` proposals on-chain (nonce 0→16, balance debited; verified via `cast`, not
only through the script log). After waiting the real 1h timelock, `AGENTE_ROLE` was
executed and the demo offering created (see the next section); everything was read back
from the chain via `cast call` before being considered confirmed.

| Contract | New address (2026-08-15) |
|---|---|
| MockBRL | `0xb99dda4e4d89f40324A7831970b8f37dBc35668F` |
| DenyAllTransferPolicy | `0x28020B9370E140b5a542443a767F2f016b9a461A` |
| RestrictedTransferPolicy | `0x0Ea184A5A02f2104D250ff7fA2F97d26FcceFb42` |
| ParticipacaoToken (implementation) | `0xf603fc5dEb042053567ebEB0cEc1CCe646B63346` |
| EmissaoGateway | `0x3082981ceE0068c0B9d6144edB1B0CEE14931a6E` |
| ParticipacaoTokenFactory | `0xD12808283E953E975f46799B1Eac0ad88BfbA697` |
| RegistroInvestidorQualificado | `0xd5608D6FAAAC715eE9edeB2c47fe1f2De86F64F5` |
| OfertaCaptacao (implementation) | `0x53a7C7F8a5E88DD9db8Ee8109f44aA7BCB08552B` |
| OfertaCaptacaoFactory | `0x28BE1a83189CA6Bc8A163dC7bf659FAF09621dA7` |
| LiquidacaoSecundaria | `0x156aa697739eCa43ED0916D58C4913b4863629ac` |

New deployer/admin/agent: `0x0D41059eBde70a46EB5207af0837921594CAFC05`; its private key
lives only in the local `.env` (gitignored), never printed in a log/console/chat.

### `script/DemoNiaraPMEsOnChain.s.sol` (Phase 6: offering for the real frontend)

Creates ONE new fundraising offering per run, fully reusing the infra above (no new
contract), designed to be consumed by the real `/investir/onchain` flow of `niara-PMEs`. It
also executes (not just proposes) the pending `AGENTE_ROLE` on the 3 contracts it uses,
**idempotently** (`_executeAgent` checks `hasRole` before calling `executeGrantRole` and
skips if already granted, instead of reverting with `ActionNotPending`); for this case only,
it replaces the original `DemoSecundarioPreparar.s.sol` (which also prepares the secondary
market's seller/buyer/lock-up, out of scope here). That idempotence is what allows
**running the script several times in a row to create several offerings**, not just one;
see "10 reserve offerings" below. Small parameters on purpose (`metaMinima=100 mBRL`,
`metaMaxima=200 mBRL`, `precoPorCota=10 mBRL`, `tetoPorInvestidor=200 mBRL`, equal to the
maximum target so a single wallet can close the offering alone); see the script's own
NatSpec for the full reasoning, including why `encerrar()` can close before the 180-day
deadline (by reaching `metaMaxima` exactly).

**First offering, run on 2026-08-15** (`--broadcast`, confirmed via `cast call` against
the real state, not only the script log), tested end to end through the real UI the same
day (mint → invest 2x → close → redeem), **already closed**:

| | Address |
|---|---|
| Token (the offering's ParticipacaoToken) | `0xAD141F009160789A50C93f116a41635a31EbEE3A` |
| Offering (OfertaCaptacao escrow) | `0x8390a7dCD1a379B99b67E3876c1bf200A27C57c6` |

### 10 reserve offerings for the Startup Summit (2026-08-15)

Created by running the script 10x in a row, all confirmed `estado=Aberta` via `cast call`
before being considered ready. Designed for an in-person demo (the presenter guides one
visitor at a time and switches offerings between demos through the UI selector; see
`niara-PMEs/CLAUDE.md`, "One or several offerings"). None of them had been touched by the
UI yet, all with `totalArrecadado=0`. Already loaded into `NEXT_PUBLIC_OFERTAS_ONCHAIN` in
`niara-PMEs`' `.env.local`/deployment.

| # | Token (ParticipacaoToken) | Offering (OfertaCaptacao) |
|---|---|---|
| 1 | `0x4DDDD5DeF833f9Ad3F6f714661a55fDC0D71d18D` | `0xd4AC69a4c7Bfdc5E85c0e0da76ce12a1552b2704` |
| 2 | `0x42B054aA3A6b4Eb4fDEd2E81E145C4C30268494b` | `0xcB5B8D945996114F781DD729F229638192d18258` |
| 3 | `0xdb7c0A4059384b6Dd36354b6897419d968B739be` | `0xDd9a14c221C6d9E2Cf33c56d8A4bF7C8BDfAF938` |
| 4 | `0x4f92299B02A677b4b9888da16096763c2D60f1d8` | `0x29f10569644871BcD57e442E8802434D963688d9` |
| 5 | `0xA1a2C9F3877ddAE6eC5dcedE9Cf00c3e4cD1A1F6` | `0xfAa7946221F4a1D66c1B172bed79cF37ca003261` |
| 6 | `0x2fA50be34DF5C123B4f12B1f12A79C3bc12F4B9D` | `0xa60119428905fDf66BF967DE90A2F892985d99b2` |
| 7 | `0x076f06668F04cF5Bf7fB33a2aAaFe58e72881DD9` | `0xE4E7c347823f648aBba73B31855E2Fc1D7fE2fb1` |
| 8 | `0x757534f9A0bfEF76C1f8532a3561670F481dcCc5` | `0x4378E93588603385B1A51b74c06c0a9FCfc66A16` |
| 9 | `0x944ad3048F9940F53eA68d6546FB7029afe70601` | `0xd720e3E0f53B7BA278A2beE99Da7F0Edd1F14B9c` |
| 10 | `0x466e066d155724b62e75De340ceF7097D3996176` | `0xaef8C045cAaBe0F283bD92893031F4f2644d534F` |

🔴 Each one uses part of the deployer's Sepolia ETH balance
(`0x0D41059eBde70a46EB5207af0837921594CAFC05`, ~0.0025 ETH per offering). If the event
requires more than 10 full demos, run the script again (idempotent, no timelock,
`AGENTE_ROLE` already active) and check the balance first via `cast balance`.

On-chain state checked: `estado=0` (Aberta), `metaMinima=100 ether`, `metaMaxima=200 ether`,
`precoPorCota=10 ether`, `tetoPorInvestidor=200 ether`, `token.cotasAutorizadas=20 ether` (20
shares, correctly rescaled). These 3 addresses (token + offering + the fixed `MockBRL` from
the table above) are already in `niara-PMEs/.env.local`
(`NEXT_PUBLIC_MOCKBRL_ADDRESS`/`NEXT_PUBLIC_PARTICIPACAO_TOKEN_ADDRESS`/
`NEXT_PUBLIC_OFERTA_CAPTACAO_ADDRESS`); `/investir/onchain` already reads the real offering.

### `OfertaOrquestrador`: self-service channel (implementation + real Sepolia deploy)

An additive contract (`src/orquestracao/OfertaOrquestrador.sol`, commit `0216eb0`) that lets
the issuing company itself, previously authorized, create its offering (token +
fundraising) in a single atomic transaction (`criarOfertaCompleta`), without gaining power
over `cotasAutorizadas`, `taxaBps`, `protocoloWallet` or `tetoPorInvestidor`. See
`PLANO_OFERTA_ORQUESTRADOR.md` for the full design and `test/OfertaOrquestrador.t.sol` +
`test/InvariantOrquestrador.t.sol` for the suite (43 unit tests + 6 stateful fuzzing
invariants, 100% line/statement/branch/function coverage on the new contract). No existing
contract changed behavior.

Real deploy on Sepolia (`script/DeployFase2Sepolia.s.sol` +
`script/DeployFase2SepoliaExecute.s.sol`, 2026-09-24) and the first real self-service
offering ("Padaria Silva", R$ 600,000 raised, a 1% fee split on-chain between protocol and
issuer): full transaction timeline, demo script and limitations in `DEMO_SEPOLIA.md`,
section "Results: first real self-service offering".

🔴 **The `TIMELOCK_DELAY = 1 hour` used in this deploy is a prototype value, not a
production one.** `TimelockedAccessControl.MIN_TIMELOCK_DELAY` (1h) is the **minimum** the
contract allows (`MAX_TIMELOCK_DELAY` is 30 days); the real deploy used exactly that
minimum, chosen so the demo would not be held up for days, not because 1h is an adequate
governance delay. A production deploy should use a much longer delay (recommended order of
magnitude: ~48h) to give someone real time to react to an incorrect or malicious
role/parameter change proposal before it can be executed. Nothing in the code prevents a
longer delay; it is a parameter choice at deploy time (`timelockDelay_` in the
constructor), not a contract limitation.

🔴 **Gas on Sepolia varied sharply within the SAME deploy/demo session**, from ~1 gwei to
tens of gwei, with a single `aportar` call costing ~0.018 ETH in one of those peak windows.
Any live demo on Sepolia needs (a) a balance margin well above the cost estimated from a
previously observed low gas price, and (b) to be prepared **days in advance**, not in the
same session it will be presented in: faucet Sepolia ETH is limited, and an unexpected gas
spike can burn balance faster than planned in the middle of a demo.

Addresses of the infrastructure deployed for this channel (a new reference infra; it
**does not replace** the Phase 4/Phase 6 address table above, which serves the frontend's
`/investir/onchain` flow via the manual AGENT; this one serves the issuer's self-service
channel):

| Contract | Address |
|---|---|
| MockBRL | `0xEC377e00e022675B67Da6ab1966Bc0764bF792A4` |
| DenyAllTransferPolicy | `0xC763cd522B8D4632ccd1adE698BAD09Be22f6a69` |
| ParticipacaoToken (implementation) | `0x367D71E1A578a1Ac061991aCa8f302f9119dB603` |
| EmissaoGateway | `0xeaedcAea403F793AFf6c345a5321c05eE55Cb1FE` |
| ParticipacaoTokenFactory | `0xA116Aeb034633ef58AF68A387778C59f99FE9539` |
| RegistroInvestidorQualificado | `0x5BE2cF3f1aeA02987Bea87a635FC9ba7BdF04732` |
| OfertaCaptacao (implementation) | `0x46c6690Db2Ad39AF5Fa29581Ed01172a65949656` |
| OfertaCaptacaoFactory | `0x5E248656516140360ADEFB66c1095ef0951e45cB` |
| OfertaOrquestrador | `0xde9cC84d1300b57F640f2d1862900393b82796e5` |

---

## Phase 1 architecture

```
ParticipacaoTokenFactory (TimelockedAccessControl, Pausable)
  ├─ implementacao (ParticipacaoToken template, swappable via timelock)
  ├─ gateway (EmissaoGateway, fixed at construction)
  ├─ transferPolicyPadrao (swappable via timelock)
  └─ criarOferta(...) [AGENTE_ROLE] → Clones.clone(implementacao) → initialize(...)

EmissaoGateway (TimelockedAccessControl)
  ├─ AGENTE_ROLE — atestarCotas / emitir / pausarToken / despausarToken
  └─ EMISSOR_ROLE — reserved, no functional use in this phase

ParticipacaoToken (Initializable, ERC20Upgradeable, PausableUpgradeable)
  ├─ gateway — the only address authorized to call setCotasAutorizadas/mint/pause/unpause
  ├─ cotasAutorizadas — the cap, only goes up (setCotasAutorizadas reverts if novoTeto < current)
  ├─ transferPolicy (ITransferPolicy) — read on every holder→holder transfer
  └─ invariant: totalSupply() <= cotasAutorizadas, always

DenyAllTransferPolicy (ITransferPolicy) — canTransfer always false (Phase 1)
```

Authorization in the token is by a single address (`gateway`), not by `AccessControl`,
because the token is a lightweight clone replicated per offering; role-based governance is
concentrated in `EmissaoGateway`/`ParticipacaoTokenFactory`, which are not cloned.

Swapping `implementacao`/`transferPolicyPadrao` in the factory (via timelock) only affects
**future** offerings: clones already created keep the logic/policy in effect when they
were cloned (tested in `test_SetImplementacao_OnlyAffectsFutureOffers`).

---

## Phase 2 architecture

```
RegistroInvestidorQualificado (TimelockedAccessControl)
  └─ AGENTE_ROLE — definirQualificado(investidor, bool) [immediate, no timelock on the action]

OfertaCaptacaoFactory (TimelockedAccessControl, Pausable)
  ├─ implementacao (OfertaCaptacao template, swappable via timelock)
  ├─ gateway, registro, moeda (fixed at construction, no setter in this phase)
  └─ criarCaptacao(...) [AGENTE_ROLE] → Clones.clone(implementacao) → initialize(...)

EmissaoGateway (TimelockedAccessControl) — EXTENDED in Phase 2
  ├─ AGENTE_ROLE — atestarCotas / emitir / pausarToken / despausarToken (Phase 1)
  ├─ registrarCaptacao(token, oferta) [AGENTE_ROLE] — sets the authorized escrow
  └─ emitirParaCaptacao(token, to, cotas) — only the `oferta` registered for that token;
     calls token.mint(to, cotas); the same Phase 1 invariant still holds

OfertaCaptacao (Initializable, PausableUpgradeable, ReentrancyGuard)
  ├─ token, gateway, registro, moeda, emissorWallet, protocoloWallet (via initialize)
  ├─ metaMinima, metaMaxima, precoPorCota, prazo, tetoPorInvestidor, taxaBps (<= 100)
  ├─ estado: Aberta → EncerradaSucesso | EncerradaFalha (never goes back)
  ├─ aportar (nonReentrant, whenNotPaused) — escrow, CEI, multiple of precoPorCota
  ├─ encerrar (permissionless) — deadline OR metaMaxima reached
  ├─ cancelar — AGENT only (via gateway.hasRole), a protective power (Aberta → Falha)
  ├─ resgatarCotas / reembolsar / liberarParaEmissor — pull, nonReentrant, once
  └─ pausar/despausar — only blocks `aportar`; withdrawals are never frozen
```

The `ReentrancyGuard` used is the **non-upgradeable** one from
`@openzeppelin/contracts/utils/ReentrancyGuard.sol`: in this OZ version (`v5.6.1`) it is
already stateless/namespaced (a fixed slot via `keccak256`, marked `@custom:stateless` in
the OZ contract itself), so it works correctly in an EIP-1167 clone without needing an
"Upgradeable" variant (which no longer exists in the package, replaced by this design).
There is no `ReentrancyGuardUpgradeable.sol` in `lib/openzeppelin-contracts-upgradeable`;
do not look for it.

### Mint authorization chain (the AGENT's operational sequence)

To put a fundraising offering live, in this order:

1. `ParticipacaoTokenFactory.criarOferta(...)` → `token`.
2. `EmissaoGateway.atestarCotas(token, N)`: `N >= metaMaxima / precoPorCota`, **on the
   scale of `1 ether` per share** (see "Locked decisions — Phase 2").
3. `OfertaCaptacaoFactory.criarCaptacao(token, ...)` → `oferta`.
4. `EmissaoGateway.registrarCaptacao(token, oferta)`: only after this can the `oferta`
   mint via `emitirParaCaptacao` on success.

### Timelock × operational split (Phase 2)

The timelock (1h) cannot be required on every action of a live fundraising: an investor
will not wait 1h to invest. Classification:

| Action | Category |
|---|---|
| `criarOferta`, `atestarCotas`, `criarCaptacao`, `registrarCaptacao`, `definirQualificado`, `cancelar` | Operational (AGENT, immediate) |
| `aportar`, `encerrar`, `reembolsar`, `resgatarCotas`, `liberarParaEmissor` | Investor/permissionless, immediate |
| Granting/revoking `AGENTE_ROLE` (on any of the 4 contracts that require it), swapping `implementacao`/default `taxaBps`/sensitive protocol parameters | Timelock (1h, propose→execute) |

`AGENTE_ROLE` must be granted **on 4 independent contracts** for full operation:
`EmissaoGateway`, `ParticipacaoTokenFactory`, `RegistroInvestidorQualificado` and
`OfertaCaptacaoFactory`, each with its own `TimelockedAccessControl` (same pattern as
Phase 1, extended). `OfertaCaptacao` (a clone) has no role of its own: its `cancelar`
reuses the `EmissaoGateway`'s `AGENTE_ROLE` via `hasRole`.

---

## Phase 3 architecture

```
RestrictedTransferPolicy (TimelockedAccessControl, ITransferPolicy)
  ├─ AGENTE_ROLE — definirElegivel(token, investidor, bool) [immediate]
  │              — definirLockup(token, lockupAte) [immediate, set-once per token]
  ├─ DEFAULT_ADMIN_ROLE (timelock) — proposeSetSecundarioLiberado/executeSetSecundarioLiberado
  └─ canTransfer(token, from, to, amount):
       secundarioLiberado[token] && block.timestamp >= lockupAte[token] && elegivel[token][to]

ParticipacaoToken — EXTENDED in Phase 3
  └─ setTransferPolicy(novaPolitica) [onlyGateway] — swaps the transferPolicy of an already-live clone

EmissaoGateway (TimelockedAccessControl) — EXTENDED in Phase 3
  └─ proposeSetTransferPolicy/executeSetTransferPolicy(token, novaPolitica)
     [DEFAULT_ADMIN_ROLE, timelock] → calls token.setTransferPolicy(novaPolitica)
```

A single `RestrictedTransferPolicy` serves any number of offerings: all state (lock-up,
allowlist, master flag) is keyed by `token`, taking advantage of
`ITransferPolicy.canTransfer` already receiving the token address in its signature (see
"Locked decisions — Phase 3"). `from` is never checked: whoever holds the token is a holder
by construction (only mint grants a balance), so CVM 88's "the buyer is an active
investor" requirement falls only on `to`.

### Timelock × operational split (Phase 3)

| Action | Category |
|---|---|
| `definirElegivel`, `definirLockup` | Operational (AGENT, immediate, for agile onboarding) |
| `setSecundarioLiberado` (the lever that actually opens trading) | Timelock (1h, propose→execute, `DEFAULT_ADMIN_ROLE`) |
| The token's `setTransferPolicy` (switching an already-live offering's policy) | Timelock (1h, propose→execute, via `EmissaoGateway`, `DEFAULT_ADMIN_ROLE`) |

Pointing a token at the `RestrictedTransferPolicy` before configuring lock-up/allowlist is
safe: while `secundarioLiberado[token] == false` (the default), `canTransfer` keeps denying
everything, the same "locked initial state" guarantee `DenyAllTransferPolicy` gave, only now
reversible by governance instead of fixed.

---

## Phase 4 architecture

```
LiquidacaoSecundaria (TimelockedAccessControl, ReentrancyGuard, Pausable)
  ├─ moeda, factory (immutable, fixed at construction; the same decision already recorded
  │  for OfertaCaptacaoFactory.gateway/registro/moeda in "Known open items")
  ├─ protocoloWallet, taxaSecundarioBps (<= 100, default 0) — swappable via timelock
  ├─ pause()/unpause() [AGENTE_ROLE] — emergency, same pause pattern as the factories
  └─ liquidarCessao(token, vendedor, comprador, quantidade, precoPorCota)
       [AGENTE_ROLE, whenNotPaused] returns (uint256 taxa)
       0. defensive guards: token/vendedor/comprador != address(0);
          vendedor != comprador                              — checked against NiaraSettlement
       1. factory.isOferta(token)                          — known token
       2. policy.canTransfer(token, vendedor, comprador, quantidade)  — pre-flight (view)
       3. valor = (quantidade * precoPorCota) / UNIDADE_COTA; reverts if valor == 0
          taxa = valor * bps / 10_000
       4. moeda.transferFrom(comprador, vendedor, valor - taxa)
       5. if taxa > 0: moeda.transferFrom(comprador, protocoloWallet, taxa)
       6. token.transferFrom(vendedor, comprador, quantidade)  — triggers the token's
          _update, which reads the RestrictedTransferPolicy again; this call, not the
          step 2 pre-flight, is the one that actually counts
```

Allowance requirements (the platform never holds anything; see "Locked decisions — Phase
4"): the **seller** approves `LiquidacaoSecundaria` to move their shares
(`ParticipacaoToken.approve`); the **buyer** approves it to move their `MockBRL`
(`MockBRL.approve`). Without both pre-existing approvals, `liquidarCessao` reverts cleanly
(OZ's standard ERC-20 insufficient-allowance error), with no partial state: any leg that
fails undoes the legs already executed before it in the same transaction.

### Timelock × operational split (Phase 4)

| Action | Category |
|---|---|
| `liquidarCessao` | Operational (AGENT, immediate: it is per trade and cannot wait 1h) |
| `pause`/`unpause` | Operational (AGENT, immediate: an emergency cannot wait 1h; same pattern as `ParticipacaoTokenFactory`/`OfertaCaptacaoFactory`) |
| `setTaxaSecundarioBps`, `setProtocoloWallet` | Timelock (1h, propose→execute, `DEFAULT_ADMIN_ROLE`) |

With Phase 4, `AGENTE_ROLE` must be granted **on 6 independent contracts** for full platform
operation (primary + secondary): `EmissaoGateway`, `ParticipacaoTokenFactory`,
`RegistroInvestidorQualificado`, `OfertaCaptacaoFactory` (Phases 1/2),
`RestrictedTransferPolicy` (Phase 3) and `LiquidacaoSecundaria` (Phase 4), each with its own
`TimelockedAccessControl`.

---

## Test results (Phase 1)

- `forge build`: no errors.
- `forge test`: 76/76 passing (unit + 6 invariants).
- `forge coverage` on the main contracts (`src/`, excluding the deploy script):
  `EmissaoGateway`, `TimelockedAccessControl`, `ParticipacaoToken`,
  `ParticipacaoTokenFactory` and `MockBRL`: **100% line/statement/branch/function**.
  `DenyAllTransferPolicy` shows 50%/0% on its single line (`return false`) because of a
  known limitation of Foundry's coverage instrumenter with `pure` functions returning a
  literal; the function's own hit count (2336, via fuzz test + handler) confirms it is
  exercised extensively, so it is not a real test gap. `script/DeployFase1.s.sol` stays at
  0% on purpose: deploy scripts are not covered by the test suite, only validated by
  manual runs (see below).
- Invariants (`forge test --match-contract InvariantTest`) run at the configured scale,
  `runs=256 * depth=100` = 25,600 calls per invariant, with no violation, and ~35-40% of
  calls reverting on purpose ("chaotic" paths exercising the `revert`s). The 6 invariants
  checked:
  1. `totalSupply() <= cotasAutorizadas`, for every token created.
  2. `sum(balances) == totalSupply()`, for every token created.
  3. No unauthorized call to the token's `mint`/`setCotasAutorizadas`/`pause`/`unpause`
     (outside the `gateway`) ever succeeded.
  4. No call without `AGENTE_ROLE` to `atestarCotas`/`emitir`/`pausarToken`/
     `despausarToken`/`criarOferta` ever succeeded.
  5. No holder→holder transfer (`transfer`/`transferFrom`) ever succeeded (deny-all
     policy).
  6. No already-initialized clone could be reinitialized.
- `script/DeployFase1.s.sol` was validated in two ways:
  - **Dry run** (`forge script script/DeployFase1.s.sol`, no `--rpc-url` or
    `--broadcast`): the full flow (deploy → grant `AGENTE_ROLE` via
    propose/`vm.warp`/execute → create offering → attest → issue) runs successfully,
    because `vm.warp` is honored in local simulation.
  - **Broadcast against a local `anvil`** (never Sepolia): it fails, on purpose, at
    `executeGrantRole` with `TimelockNotElapsed`, because when really broadcasting the
    timelock time must pass on the chain's real clock, and `vm.warp` does not affect a
    running node receiving real transactions. Correct, expected behavior, documented in
    the script's NatSpec; not a bug. For a real demo against a live `anvil`, you would
    need either to really wait `TIMELOCK_DELAY` seconds between two broadcasts, or to
    advance `anvil`'s clock via `evm_increaseTime`/`evm_mine` (not implemented in this
    phase).

---

## Test results (Phase 2)

- `forge build`: no errors (same Phase 1 + Phase 2 suite).
- `forge test`: **183/183 passing**: 165 unit + 18 invariants (6 from Phase 1 + 12 new
  from Phase 2), with no regression in the Phase 1 suite after extending `EmissaoGateway`.
- `forge coverage` on Phase 2's main contracts (`OfertaCaptacao`, `OfertaCaptacaoFactory`,
  `RegistroInvestidorQualificado`, and the `EmissaoGateway` extension): **100%
  line/statement/branch/function**, the same bar as Phase 1. `DenyAllTransferPolicy` keeps
  the same known instrumenter limitation from Phase 1 (not a real gap).
  `script/DeployFase1.s.sol` and `script/DeployFase2.s.sol` stay at 0% on purpose (deploy
  scripts are not covered by the suite, only validated by manual runs).
- Dedicated reentrancy test (`test/OfertaCaptacaoReentrancy.t.sol`): a malicious currency
  (`ReentrantMockBRL`) tries to re-enter `aportar`/`reembolsar`/`liberarParaEmissor` from
  its own `transfer`/`transferFrom`; all 3 attempts are blocked by `nonReentrant`, and each
  external function completes successfully exactly once (no double payment/double
  investment).
- Money invariants (`forge test --match-contract InvariantCaptacaoTest`), at the same
  configured scale (`runs=256 * depth=100` = 25,600 calls per invariant), **zero
  violations**, ~10% of calls reverting on purpose (`tentar*`). The 12 invariants checked:
  1. `moeda.balanceOf(oferta) == totalArrecadado - sumReembolsado` (or `0` if
     `recursosLiberados`), for every fundraising: the escrow's core accounting.
  2. `sum(refunds) <= totalArrecadado`, for every fundraising.
  3. No double refund ever succeeded.
  4. `sum(shares minted via redemption) <= totalArrecadado / precoPorCota`, for every
     fundraising.
  5. No double share redemption ever succeeded.
  6. `totalArrecadado <= metaMaxima`, always, for every fundraising.
  7. No non-qualified investor managed, in a single `aportar` call, to exceed
     `tetoPorInvestidor` (checked at call time, not as a retroactive snapshot, since
     qualification is a mutable flag: an investor can legitimately be above the current
     cap if they were qualified at the time of investing and disqualified later; that is
     not a bug, it is the absence of retroactive confiscation).
  8. There was never both a refund AND a mint/release for the same fundraising
     (success/failure exclusion).
  9. No call without `AGENTE_ROLE` to `cancelar`/`definirQualificado`/`criarCaptacao` ever
     succeeded.
  10. No double release to the issuer (`liberarParaEmissor`) ever succeeded.
  11. No `aportar` outside the `Aberta` state or after the deadline ever succeeded.
  12. No premature `encerrar` (before the deadline and before the maximum target) ever
      succeeded.
- During development, the invariant run caught a genuine scaling bug: `resgatarCotas`
  minted `aportado / precoPorCota` (a dimensionless count, e.g. `60`) directly, without
  rescaling to `ParticipacaoToken`'s raw 18-decimal unit (it should have been `60 ether`);
  fixed with the `UNIDADE_COTA` constant (see "Locked decisions — Phase 2"). It is a good
  example of the value of stateful fuzzing in this phase: the isolated unit test did not
  catch it because it compared against the same (unscaled) calculation used in the test
  itself; only the `DeployFase2` dry run (showing "60" instead of "60000000000000000000"
  shares) made the problem obvious.
- `script/DeployFase2.s.sol` was validated in two ways, same pattern as
  `DeployFase1.s.sol`:
  - **Dry run**: both scenarios run successfully: (A) partial success: two investors
    invest a total between the minimum and maximum targets, closing as a success, one
    investor redeems shares (receives `60 ether` = 60 shares), release to the issuer (net
    of the fee) and to the protocol (the fee); (B) failure: investment stays below the
    minimum target, closing as a failure, both investors get refunds and recover exactly
    the amount invested.
  - **Broadcast against a local `anvil`**: it fails, on purpose, at the same point as
    `DeployFase1`: `executeGrantRole` with `TimelockNotElapsed`, for the same reason (real
    time has not passed on the node). Expected behavior, not a bug.

---

## Test results (Phase 3)

- `forge build`: no errors (same Phase 1 + Phase 2 + Phase 3 suite).
- `forge test`: **220/220 passing**: 196 unit + 24 invariants (6 from Phase 1 + 12 from
  Phase 2 + 6 new from Phase 3), with no regression in the Phase 1/2 suites after extending
  `ParticipacaoToken`/`EmissaoGateway`. Phase 3's contribution: 19 tests in
  `test/RestrictedTransferPolicy.t.sol` (truth table, access, set-once, per-token isolation)
  + 3 in `test/RestrictedTransferPolicyIntegration.t.sol` (mint/redemption keep working
  with the Restricted policy attached + the full opening cycle) + 4 new in
  `test/ParticipacaoToken.t.sol` (`setTransferPolicy`) + 6 new in
  `test/EmissaoGateway.t.sol` (`proposeSetTransferPolicy`/`executeSetTransferPolicy`) + 6
  new invariants in `test/InvariantPolitica.t.sol`.
- `forge coverage` on Phase 3's main contracts (`RestrictedTransferPolicy`, and the
  `ParticipacaoToken`/`EmissaoGateway` extensions): **100% line/statement/branch/function**,
  the same bar as Phases 1/2. `DenyAllTransferPolicy` keeps the same known instrumenter
  limitation (not a real gap, see "Test results (Phase 1)"). Deploy/demo scripts stay at
  0% on purpose.
- Restricted-policy invariants (`forge test --match-contract InvariantPoliticaTest`), same
  configured scale (`runs=256 * depth=100` = 25,600 calls per invariant), **zero
  violations**, ~5.5% of calls reverting on purpose (`tryDuplicateLockup`, the only
  "chaotic" action in this suite, since most other actions have no natural invalid path to
  explore beyond what `NoUnauthorizedOperationalCallEverSucceeded`/
  `NoUnauthorizedSecundarioToggleEverSucceeded` already cover). The 6 invariants checked:
  1. No holder→holder transfer had a result (success/revert) different from what the truth
     table predicts (`secundarioLiberado && !lockup && elegivel[to]`): Phase 3's core
     proof.
  2. `gateway.emitir` (mint, within the attested cap) never failed because of the attached
     `RestrictedTransferPolicy`'s state: mint never reads the policy (see
     `ParticipacaoToken._update`, `from == address(0)`).
  3. No call without `AGENTE_ROLE` to `definirElegivel`/`definirLockup` ever succeeded.
  4. No call without `DEFAULT_ADMIN_ROLE` to `proposeSetSecundarioLiberado` ever succeeded.
  5. No second `definirLockup` on the same token ever succeeded ("set-once").
  6. No state leak between tokens: the mirror kept by the handler (`ghost_*Esperado`,
     updated on every successful write) matches the policy's real getters for every token
     and every tracked investor, on every call in the sequence: proof of per-token
     isolation "for free", since a write leaking from `tokenA` into `tokenB` would make
     `tokenB`'s mirror diverge.
- `script/DemoFase3.s.sol` was validated in two ways, same pattern as the earlier scripts:
  - **Dry run**: shows the 4 steps in sequence: (1) secondary market off
    (`DenyAllTransferPolicy`): the transfer reverts; (2) the token already points at the
    `RestrictedTransferPolicy` but is still locked (`secundarioLiberado == false`, within
    the lock-up): the transfer keeps reverting, proving that "pointing early is safe"; (3)
    secondary market open and after the lock-up, but the recipient is outside the
    allowlist: it reverts; (4) secondary market open, after the lock-up, eligible
    recipient: it passes. The final log shows balances and the full policy state.
  - **Broadcast against a local `anvil`**: it fails, on purpose, at the same point as
    `DeployFase1`/`DeployFase2`: `executeGrantRole` with `TimelockNotElapsed`. Expected
    behavior, not a bug.

---

## Test results (Phase 4)

- `forge build`: no errors (same Phase 1 + Phase 2 + Phase 3 + Phase 4 suite).
- `forge test`: **266/266 passing**: 236 unit + 30 invariants (6 from Phase 1 + 12 from
  Phase 2 + 6 from Phase 3 + 6 from Phase 4), with no regression in the earlier suites.
  The original Phase 4 contribution: 24 tests in `test/LiquidacaoSecundaria.t.sol` + 1 in
  `test/LiquidacaoSecundariaReentrancy.t.sol` + 6 invariants in
  `test/InvariantSecundario.t.sol`. Then two rounds of cross-checking against
  `NiaraSettlement` (see "Locked decisions — Phase 4"): **+12 tests** against the
  properties of `NiaraSettlement.t.sol` (one revert per new guard: `VendedorIgualComprador`,
  `ValorInvalido`, `ZeroAddress` on `token`/`vendedor`/`comprador`; two for the `taxa`
  return value; four for `pause`/`unpause`; one for the defensive cap guard in `execute`
  called without `propose`) and **+3 tests** against the `settle` source excerpt (the
  anti-evasion guard: reverts when the fee truncates to zero, passes when the amount is
  sufficient, and confirms the guard does not fire with the fee dormant). The current total,
  including the `OfertaOrquestrador` suites, is **315/315** test functions. Since forge
  1.8, each invariant suite runs all its `invariant_*` functions in one shared campaign and is
  reported as a single result, so `forge test` prints **284 passed** for the same 315 functions
  (checked: breaking any one invariant still fails its suite).
- `forge coverage` on Phase 4's main contracts (`LiquidacaoSecundaria`, and the small
  extensions of `IParticipacaoToken`/the new `IParticipacaoTokenFactory`): **100%
  line/statement/branch/function**, the same bar as the earlier phases. The guards added in
  the two cross-check rounds took `LiquidacaoSecundaria` from 44/44 to 53/53 lines and from
  8/8 to 13/13 branches, all covered. `DenyAllTransferPolicy` keeps the same known
  instrumenter limitation (not a real gap, see "Test results (Phase 1)"). Deploy/demo
  scripts stay at 0% on purpose.
- Dedicated reentrancy test (`test/LiquidacaoSecundariaReentrancy.t.sol`), same pattern as
  `OfertaCaptacaoReentrancy.t.sol` (Phase 2): `ReentrantMockBRL` tries to re-enter
  `liquidarCessao` from its own `transferFrom`; it is blocked by `nonReentrant`, and the
  original assignment completes successfully exactly once (no double movement of shares or
  currency).
- Conservation/atomicity invariants (`forge test --match-contract
  InvariantSecundarioTest`), same configured scale (`runs=256 * depth=100` = 25,600 calls
  per invariant), **zero violations**. All handler actions use `try/catch` (the same
  practice as `HandlerCaptacao`), so the per-selector revert table is zero by design; what
  matters is the absence of violations in the 6 invariants below, not the raw revert rate:
  1. `moeda.balanceOf(actor_) == ghost_expectedCurrency(actor_)`, for every tracked actor
     and the `protocoloWallet`: `MockBRL` conservation, proven by a mirror updated with the
     SAME arithmetic `liquidarCessao` should apply on every balance inflow (mint) and every
     successful assignment.
  2. `token.balanceOf(actor_) == ghost_expectedShares(token, actor_)`, for every tracked
     token and actor: share conservation, same mirror mechanism. Since there are only two
     mirrored balance routes (mint via gateway, successful assignment), any conservation
     bug (losing dust, duplicating a leg, applying the wrong fee) or any blocked assignment
     that moved funds anyway would show up as a divergence, proving conservation AND
     atomicity in the same check.
  3. No successful `liquidarCessao` happened with
     `policy.canTransfer(token, vendedor, comprador, quantidade) == false` at call time:
     the Phase 3 ↔ Phase 4 gate is never bypassed.
  4. No call without `AGENTE_ROLE` to `liquidarCessao` ever succeeded.
  5. No call without `DEFAULT_ADMIN_ROLE` to `proposeSetTaxaSecundarioBps`/
     `proposeSetProtocoloWallet` (nor to `RestrictedTransferPolicy.
     proposeSetSecundarioLiberado`, checked here as defense in depth) ever succeeded.
  6. `taxaSecundarioBps` never exceeded `TAXA_BPS_MAXIMA` (100) at any point in the
     sequence.
- A scaling decision made while developing this phase (not a bug caught AFTERWARDS; this
  time caught BEFORE writing the code, by recognizing the pattern of the bug already
  documented in Phase 2): the task text described `valor = quantidade * precoPorCota` with
  no visible rescale; following it literally would have multiplied the amount by `1e18`,
  given the same raw-unit convention for `quantidade`. `LiquidacaoSecundaria` rescales by
  `UNIDADE_COTA` on purpose (see "Locked decisions — Phase 4"), locked by a test with exact
  values.
- `script/DemoFase4.s.sol` was validated in two ways, same pattern as the earlier scripts:
  - **Dry run**: issuance mini-cycle (the seller receives 1,000 shares) → migration from
    `DenyAllTransferPolicy` to `RestrictedTransferPolicy` (timelock) → counterexample 1 (an
    assignment before the lock-up, with the secondary market already open, reverts) → time
    advance → counterexample 2 (an assignment to a buyer outside the allowlist reverts) →
    a valid assignment of 50 shares at 100 `MockBRL` each: seller `950 ether` shares left,
    buyer `50 ether` shares received, seller `5,000 ether` `MockBRL` received (fee `0`),
    buyer `995,000 ether` `MockBRL` left, protocol `0` (fee dormant); values checked exactly
    in the log.
  - **Broadcast against a local `anvil`**: it fails, on purpose, at the same point as the
    earlier scripts: `executeGrantRole` with `TimelockNotElapsed`. Expected behavior, not a
    bug.

---

## Non-negotiable rules

### Honesty / regulatory
- Testnet prototype, no mainnet, no published audit. Honest wording: "full coverage +
  fuzzing invariants, WITHOUT an external audit".
- `MockBRL` is a test mock, always labeled as such.
- An on-chain cap table does not replace Law 6,404 or a notary: always in the token's
  NatSpec.
- No **final** fee number defined: `taxaBps` (Phase 2) has a hard cap of 100 bps and a
  default of `0`, but the value actually used per fundraising is up to whoever creates it;
  do not present any bps as "the platform fee" until explicitly instructed.
- `OfertaCaptacao`'s per-investor cap is only that offering's limit; CVM Resolution 88's
  ANNUAL CAP ACROSS PLATFORMS is OFF-CHAIN/SELF-DECLARED. Never describe the on-chain cap as
  meeting that aggregate requirement on its own.
- `RestrictedTransferPolicy.setSecundarioLiberado` turns on the flag that opens secondary
  trading, but really turning it on depends on the lock-up having elapsed (checked
  on-chain) **and** on business/legal authorization from the platform (entirely outside the
  code). Never describe that call, on its own, as a regulatory approval.
- `LiquidacaoSecundaria` **is not an order book**: do not describe it as a marketplace, an
  exchange or "free trading between investors". It is a bilateral assignment matched by the
  platform; CVM 88's intermediation is precisely the platform submitting the
  already-matched assignment, not investors trading directly with each other on-chain.
- No **final** fee number for the secondary market: `taxaSecundarioBps` (Phase 4) has a hard
  cap of 100 bps and a default of `0`, independent of `OfertaCaptacao.taxaBps` (primary);
  do not present any bps as "the secondary fee" until explicitly instructed.

### Git / GitHub
- Commit messages in English, with a `feat:`/`fix:`/`refactor:`/`chore:`/`docs:`/`test:`
  prefix.
- No `git push` without an explicit instruction. No `--force`. No rewriting already
  published history.
- Repo identity: `niara <niaragaed@gmail.com>` (configured locally via
  `git config user.name`/`user.email`, without `--global`). It sets each commit's
  author/committer.
- 🔴 No AI attribution in commits, PRs or files: see "No AI attribution (hard rule)" at
  the top of this file.
- Public repository: no versioned secrets. `.gitignore` covers `out/`, `cache/`,
  `broadcast/` (except dry-run/local), `.env`.
- No Sepolia deploy (`--broadcast`) without an explicit instruction. Deploy scripts may be
  written and run only locally (`anvil`/dry run) at this stage.

### Test bar
- Foundry: unit tests + stateful fuzzing invariants (handlers).
- Target full coverage (line/branch/function) on the main contracts; a genuinely
  unreachable branch must be documented honestly, never inflate the number.
- Fuzzing configured for ~25,600+ calls per invariant run (`runs=256 * depth=100`),
  mirroring the exchange's scale.

---

## Stack

- Solidity `0.8.24` (compatible with OpenZeppelin v5).
- `lib/openzeppelin-contracts` and `lib/openzeppelin-contracts-upgradeable`, installed via
  `forge install` (git submodules), both at tag `v5.6.1`.
- Remappings and fuzz/invariant profiles in `foundry.toml`.
- **Foundry pinned to `v1.8.5`** in CI (`.github/workflows/test.yml`). `forge fmt --check`
  is part of CI and its rules change between releases, so an unpinned toolchain can turn CI red
  without any code change (CI was red from 2026-10-02 until the `forge fmt` pass with v1.8.5).
  Format with the same version locally, and bump the pin together with a `forge fmt` pass.

## How to run

```bash
forge build
forge test -vv
forge coverage
forge test --match-contract Invariant -vv   # runs InvariantTest (Phase 1), InvariantCaptacaoTest (Phase 2), InvariantPoliticaTest (Phase 3) and InvariantSecundarioTest (Phase 4)
```

## Conventions

- Comments and NatSpec in English (see "Language" at the top).
- Custom errors (`error X()` + `revert X()`), not `require(cond, "string")`, except where
  already used by external libraries (OpenZeppelin).
- Timelock pattern identical to the exchange's: `proposeX(...)` schedules
  (`_scheduleAction`), `executeX(...)` consumes (`_consumeAction`) and applies. The
  `actionId` is `keccak256(abi.encode("ACTION_NAME", ...params))`.
- EIP-1167 clones do not run a constructor: `ParticipacaoToken` inherits from
  `ERC20Upgradeable`/`Initializable`, sets name/symbol/metadata inside `initialize()`, and
  the template implementation calls `_disableInitializers()` in its constructor so it cannot
  be initialized directly.

## Workflow

1. Before coding, read the files involved; do not assume.
2. `forge build` and `forge test -vv` at the end of each change; fix whatever shows up.
3. Local commit at the end of each block of work, message in English.
4. Never `--force`, never rewrite history, never push unless asked.
5. If something breaks or becomes ambiguous: stop and explain, do not improvise.

---

## Known open items

- 🔴 Updated note in this revision: self-service offering creation by the issuing company
  itself, the use case `EMISSOR_ROLE` had been reserved for ("proposing its own offering"),
  already exists and is live on Sepolia, but **not** via `EMISSOR_ROLE`.
  `OfertaOrquestrador.emissoresAutorizados` (the orchestrator's own allowlist, managed by
  `autorizarEmissor`/`revogarEmissor`) solves it; see "`OfertaOrquestrador`: self-service
  channel" above. `EMISSOR_ROLE` is still defined in `EmissaoGateway`, a dead constant with
  no functional use in any phase. Not reusing it was deliberate, not an oversight:
  `EMISSOR_ROLE` is granted/revoked via `EmissaoGateway.proposeGrantRole`/
  `executeGrantRole`, inherited from `TimelockedAccessControl`, so it goes through the
  contract's 1h timelock. Authorizing an issuer to create its own offering needed to be
  **immediate** (it is only the ability to create its own offering with parameters fixed by
  the platform, never power over other people's funds), which is incompatible with the
  delay of a reused `EMISSOR_ROLE`. The new allowlist, in a new contract, solves the same
  use case without that incompatibility (see `PLANO_OFERTA_ORQUESTRADOR.md`, §1.4,
  "`EMISSOR_ROLE` of `EmissaoGateway`").
- `ParticipacaoTokenFactory.gateway` is fixed at construction: there is no timelocked
  setter to change it in this phase (only `implementacao` and `transferPolicyPadrao` are
  swappable). If a future phase needs to replace the `EmissaoGateway`, that setter will
  have to be added then.
- 🔴 Outdated note corrected in this revision: Sepolia has already received several real
  deploys (see `DEMO_SEPOLIA.md`, `DEMO_SECUNDARIO_SEPOLIA.md` and the "Phase 6"/
  "`OfertaOrquestrador`" sections above). `script/DeployFase1.s.sol`,
  `script/DemoFase3.s.sol` and `script/DemoFase4.s.sol` still run only locally (`anvil`) or
  as a dry run; `script/DeployFase2.s.sol` was removed, replaced by
  `script/DeployFase2Sepolia.s.sol` + `script/DeployFase2SepoliaExecute.s.sol` (which have
  already run for real on Sepolia).
- No external audit has been done. Do not describe this code as audited in any future
  documentation.
- `OfertaCaptacaoFactory.gateway`/`registro`/`moeda` are fixed at construction
  (`immutable`): no setter, timelocked or not, in this phase. Only `implementacao` is
  swappable. Same decision already recorded above for `ParticipacaoTokenFactory.gateway`.
- `aportar`'s rounding rule (exact multiple of `precoPorCota`) means an investor cannot
  invest an "uneven" amount; a real UX would need to compute/suggest the nearest multiple
  in the frontend; not implemented in this phase.
- `OfertaCaptacao.pausar()` only blocks `aportar`: there is no emergency "pause
  everything" that also locks `resgatarCotas`/`reembolsar`/`liberarParaEmissor` (a
  deliberate decision: withdrawals must never be freezable by the platform).
- `LiquidacaoSecundaria.moeda`/`factory` are fixed at construction (`immutable`): no
  setter, timelocked or not, in this phase. Only `protocoloWallet` and `taxaSecundarioBps`
  are swappable. Same decision already recorded for `OfertaCaptacaoFactory.gateway`/
  `ParticipacaoTokenFactory.gateway`.
- `niara-contracts` (the exchange) as a full repository (local clone, checkout) was never
  accessible in this line of sessions (not on disk, not public on GitHub, no `gh`
  CLI/credentials in the environment), but that did not remain an open item:
  `LiquidacaoSecundaria` was checked item by item against `NiaraSettlement`, first via the
  properties of `NiaraSettlement.t.sol`, then via an excerpt of `settle` itself (the fee
  anti-evasion guard), both provided in the instruction; see "Cross-check against
  `NiaraSettlement`" in "Locked decisions — Phase 4".
