# Plan — `OfertaOrquestrador` (Phase 0: inspection + plan, no code)

Document produced without changing any `.sol` file and without committing. It checks the
locked decisions against the real source code (read in this session) and details the
contract before implementation.

**Overall verdict: none of the locked decisions is unworkable.** Every signature used by the
locked decisions matches the existing code exactly; the orchestration fits without adapting
any current contract. There are two points that are not wrong locked decisions but gaps the
locked decisions did not cover; they are flagged under "Open observations" at the end, for
your decision before implementation.

---

## 1. Requested inspection

### 1.1 Confirmed signatures (read from `src/`, not from memory)

```solidity
// src/token/ParticipacaoTokenFactory.sol
function criarOferta(
    string memory nome,
    string memory simbolo,
    string memory empresa,
    bytes32 cnpjRef,
    string memory serie
) external onlyRole(AGENTE_ROLE) whenNotPaused returns (address token);

// src/emissao/EmissaoGateway.sol
function atestarCotas(address token, uint256 novoTeto) external onlyRole(AGENTE_ROLE);
// no return value

function registrarCaptacao(address token, address oferta) external onlyRole(AGENTE_ROLE);
// no return value

// src/captacao/OfertaCaptacaoFactory.sol
function criarCaptacao(
    address token,
    uint256 metaMinima,
    uint256 metaMaxima,
    uint256 precoPorCota,
    uint256 prazo,
    uint256 tetoPorInvestidor,
    uint256 taxaBps,
    address emissorWallet,
    address protocoloWallet
) external onlyRole(AGENTE_ROLE) whenNotPaused returns (address oferta);
```

All four fit without adaptation into the sequence described in the locked decisions. This is
also confirmed against `script/DemoNiaraPMEsOnChain.s.sol` (`_createOfferingAndFundraising`),
which already runs this exact sequence today (only with the human AGENT signing, not a
contract).

The only point of attention: `criarCaptacao` takes `taxaBps` in 7th position and
`emissorWallet`/`protocoloWallet` in positions 8/9. The orchestrator must build that call with
`emissorWallet = msg.sender` (forced) and `taxaBps`/`protocoloWallet` coming from its own
storage, never from an external parameter (see §3).

### 1.2 `MockBRL`'s `decimals()`

`MockBRL` inherits OpenZeppelin's `ERC20` without overriding `decimals()` → **18 decimals**,
the same as `ParticipacaoToken`. Confirmed in `src/mocks/MockBRL.sol` (its NatSpec already
documents "18 decimals, not the usual 2 decimals of fiat BRL").

So `TETO_OFERTA` (the R$ 15,000,000 cap per offering) must be:

```solidity
uint256 public constant TETO_OFERTA = 15_000_000 ether; // 15_000_000 * 1e18
```

### 1.3 Granting `AGENTE_ROLE` to the orchestrator

`AGENTE_ROLE` has the same hash value (`keccak256("AGENTE_ROLE")`) in
`ParticipacaoTokenFactory`, `EmissaoGateway` and `OfertaCaptacaoFactory`, but they are three
**independent** `AccessControl` instances: granting it on one contract does not affect the
other two. `getRoleAdmin(AGENTE_ROLE)` is not overridden in any of the three → the admin is
always `DEFAULT_ADMIN_ROLE`, currently held by the platform admin
(`0x0D41059eBde70a46EB5207af0837921594CAFC05`, per `CLAUDE.md`).

Exact sequence (assuming the infrastructure is already deployed, as on Sepolia today):

1. Deploy `OfertaOrquestrador` → address `orchestrator`.
2. `ParticipacaoTokenFactory.proposeGrantRole(AGENTE_ROLE, orchestrator)`: admin.
3. `EmissaoGateway.proposeGrantRole(AGENTE_ROLE, orchestrator)`: admin.
4. `OfertaCaptacaoFactory.proposeGrantRole(AGENTE_ROLE, orchestrator)`: admin.
   (2–4 are independent transactions on different contracts; their order does not matter,
   and they can even go in the same block.)
5. Wait for the current `timelockDelay()` of **each** of the three contracts to elapse (1h on
   all three today, but check first: nothing prevents one of them from having had its own
   delay changed via `proposeSetTimelockDelay`/`executeSetTimelockDelay` since the original
   deploy).
6. `executeGrantRole(AGENTE_ROLE, orchestrator)` on all three contracts.
7. The orchestrator's **own** `AGENTE_ROLE` (for whoever will operate `autorizarEmissor`)
   also goes through the orchestrator's own timelock: `TimelockedAccessControl` makes no
   exception for the contract itself, so it is one more `propose` + wait + `execute`.
8. Only from this point does `autorizarEmissor(company)` work (immediate, no timelock: a
   locked decision).

**If the orchestrator is deployed before it has the roles** (or before the timelock
elapses): `criarOfertaCompleta` reverts cleanly and atomically on the first subcall
(`ParticipacaoTokenFactory.criarOferta`) with OZ's standard `AccessControl` error
(`AccessControlUnauthorizedAccount(orchestrator, AGENTE_ROLE)`), bubbled up to the caller. No
state is created and no event is emitted. The same holds if only 2 of the 3 roles have been
granted: the sequence gets as far as creating the token and attesting the cap, but reverts on
the missing third role, and the EVM **also** undoes the two earlier subcalls automatically,
because everything is inside a single external transaction. It is this native atomic undo of
the EVM, not hand-written rollback logic, that solves Obstacle 1 of the original problem.
Total fixed transactions until the first self-service offering: 1 deploy + 3 propose + 3
execute (roles on the factories/gateway) + 1 propose + 1 execute (the orchestrator's own
role) = **9**, plus one per authorized issuer.

### 1.4 `EmissaoGateway`'s `EMISSOR_ROLE`

**Recommendation: keep it exactly as it is; do not touch `EmissaoGateway.sol`.**

This is not just the safest option: it is the only one compatible with two locked decisions
at once:

- "No existing contract changes behavior" (top of the Phase 0 prompt).
- "Authorization by allowlist, **without a timelock**" for the issuer (the central point of
  the design).

Reusing `EMISSOR_ROLE` would mean granting/revoking it via
`EmissaoGateway.proposeGrantRole`/`executeGrantRole`, which **is** timelocked (inherited from
`TimelockedAccessControl`). That would contradict the decision of immediate authorization.
The new allowlist (`emissoresAutorizados` on `OfertaOrquestrador` itself) already solves
exactly the use case `EMISSOR_ROLE` had been reserved for ("future actions specific to the
issuing company"), only in a new contract, with different timelock semantics from what the
role would have if reused. `EMISSOR_ROLE` stays dead, and now there is an explicit,
documentable reason for that (timelock incompatibility), not just "it had no use yet".

Consequence for tests: none; nothing changes in `EmissaoGateway.t.sol`. Consequence for
`CLAUDE.md`: update the note in "Known open items" to record this reason, instead of the
generic "reserved, no functional use".

### 1.5 Impact on the current suite

`forge test` on the clean branch (run in this session,
`~/.foundry/bin/forge.exe test --summary`):

```
266 tests passing, 0 failing, 0 skipped
```

(Matches "Test results (Phase 4)" in `CLAUDE.md` exactly.)

**Which existing tests are likely to break once the orchestrator gets `AGENTE_ROLE`: none.**
Checked by reading `test/ParticipacaoTokenFactory.t.sol` (representative of the pattern):
each test file does `new ParticipacaoTokenFactory(...)`/`new EmissaoGateway(...)`/
`new OfertaCaptacaoFactory(...)` from scratch in its own `setUp()`, and grants `AGENTE_ROLE`
**only** to that file's local `agent` address (`makeAddr("agent")`). There is no fixture
shared between test files, and none of them will ever instantiate `OfertaOrquestrador` unless
a new test, written for it, deliberately chooses to. In other words, introducing the
orchestrator is purely additive from the suite's point of view: 266/266 keeps passing without
touching anything, and the new tests live in isolation in `test/OfertaOrquestrador.t.sol` (+
a new invariant handler), with their own local deploy of `ParticipacaoTokenFactory`/
`EmissaoGateway`/`OfertaCaptacaoFactory`. This would only stop being true if someone later
decided to share a fixture between the orchestrator and another test, which is not the case
here.

### 1.6 Gas

Estimate (no real instrumentation yet, only the known design of the 3 contracts):

| Step | Approximate cost |
|---|---|
| `Clones.clone(implementacaoToken)` + `ParticipacaoToken.initialize(...)` (7 cold SSTOREs: `gateway`, `transferPolicy`, `empresa`, `cnpjRef`, `serie`, plus the ERC20 name/symbol) | ~230k–300k gas |
| `EmissaoGateway.atestarCotas` (1 cold SSTORE + external call overhead) | ~35k–45k gas |
| `Clones.clone(implementacaoOferta)` + `OfertaCaptacao.initialize(...)` (12 `InitParams` fields, most of them cold SSTOREs) | ~300k–380k gas |
| `EmissaoGateway.registrarCaptacao` (1 SSTORE in a mapping + overhead) | ~35k–45k gas |
| `OfertaOrquestrador`'s own overhead (CVM 88 limit checks, 4 cold external `CALL`s, 1 event) | ~30k–50k gas |
| **Estimated total for `criarOfertaCompleta`** | **~650k–820k gas** |

Sepolia has the same block limit as the current mainnet (30,000,000 gas); 820k gas is ~2.7%
of a block. **There is no risk of exceeding the block limit.** The only practical risk is
wallets (MetaMask) underestimating gas when simulating a transaction with multiple internal
`CREATE`s. Recommendation for the `niara-PMEs` integration: set a generous explicit
`gasLimit` (e.g. 1.2M) on the frontend call instead of relying 100% on the wallet's automatic
estimate, so as not to risk "out of gas" from a short estimate. Confirm the real number with
`forge test --gas-report` once the contract exists; this is only a planning ceiling.

### 1.7 Risk surface: vectors the suite must cover

The orchestrator concentrates the creation path of every self-service offering; a bug in it
affects every future mint through this channel. Concrete vectors, each mapped to a test in
§5/§6:

1. **Allowlist bypass**: each of the 4 subcalls must only be reachable by an address in
   `emissoresAutorizados`. Test directly (not only the public function) that there is no
   alternative path.
2. **`emissorWallet` manipulation**: it is not a function parameter; test that the value
   stored in `OfertaCaptacao.emissorWallet()` is always `msg.sender`, never another address,
   even when the "issuer" is a contract trying to relay the call.
3. **`taxaBps`/`protocoloWallet`/`tetoPorInvestidor` manipulation**: these are not parameters
   either; test that the values stored in the resulting fundraising are always the ones in
   the orchestrator's storage **at the time of the call**, never influenced by the issuer's
   calldata (there is no possible attack surface here beyond confirming it by test, since the
   function's ABI does not even accept those values).
4. **`cotasAutorizadas` as an arithmetic consequence, not a free attestation**: test that
   `token.cotasAutorizadas()` is always exactly `(metaMaxima/precoPorCota) * 1 ether`, and
   that the orchestrator exposes no function that would let an issuer call `atestarCotas`
   with an arbitrary value.
5. **CVM 88 limits at the exact boundaries**: 180 days, R$ 15,000,000, a 25% additional lot
   (see the test cases in §5).
6. **`metaMaxima % precoPorCota != 0`**: must revert in the orchestrator, before any subcall
   (see the note on division by zero in "Open observations").
7. **Atomicity under forced failure**: no combination of partial success may persist.
   Testable by forcing a revert in the 4th subcall (e.g. an `EmissaoGateway` mock that
   reverts only on `registrarCaptacao`) and checking that neither `isOferta(token)` nor
   `isCaptacao(oferta)` ends up `true`.
8. **Roles not yet granted**: `criarOfertaCompleta` reverts cleanly (standard
   `AccessControl` error) if the orchestrator does not yet have `AGENTE_ROLE` on any of the 3
   contracts (see §1.3).
9. **Reentrancy: analyzed and ruled out, not artificially forced.** None of the 4 subcalls
   transfers value or invokes any hook on `msg.sender` (no ERC-20, no ERC-721/1155
   `onReceived`, no value `.call`); `Clones.clone` is a `CREATE` over the platform's own
   fixed implementation, not code controlled by the issuer. There is no real reentrancy
   vector in this function; document this analysis instead of forcing an artificial mock,
   following the same pattern already used in Phase 4 for "reentrancy from the asset side" in
   `LiquidacaoSecundaria` (see `CLAUDE.md`).
10. **Parity with the manual path**: an offering created by the orchestrator must behave
    identically, end to end (invest → close → redeem), to one created manually by the AGENT.
    The orchestrator only automates the same sequence and should not introduce any
    observable state difference.
11. **Front-running: analyzed and ruled out.** The clone's address (`Clones.clone`) is not
    chosen by the issuer, nor predictable in an exploitable way before the transaction is
    mined; there is no MEV-sensitive parameter (no price/slippage). It does not require a
    dedicated test, only documentation of the analysis.

---

## 2. Full contract signature

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockedAccessControl} from "../governance/TimelockedAccessControl.sol";
import {ParticipacaoTokenFactory} from "../token/ParticipacaoTokenFactory.sol";
import {EmissaoGateway} from "../emissao/EmissaoGateway.sol";
import {OfertaCaptacaoFactory} from "../captacao/OfertaCaptacaoFactory.sol";

contract OfertaOrquestrador is TimelockedAccessControl {
    // ── Operational role ───────────────────────────────────────────────────────────
    bytes32 public constant AGENTE_ROLE = keccak256("AGENTE_ROLE");

    // ── Regulatory constants (CVM Resolution 88) ──────────────────────────────────
    uint256 public constant TETO_OFERTA = 15_000_000 ether;   // fundraising cap per offering
    uint256 public constant PRAZO_MAXIMO = 180 days;          // maximum fundraising period
    uint256 public constant LOTE_ADICIONAL_NUMERADOR = 125;   // metaMaxima*100 <= metaMinima*125
    uint256 public constant LOTE_ADICIONAL_DENOMINADOR = 100; // (additional lot <= 25%)

    // ── Scale/fee constants (same discipline as the earlier phases) ───────────────
    uint256 public constant UNIDADE_COTA = 1 ether;
    uint256 internal constant TAXA_BPS_MAXIMA = 100;

    // ── Addresses fixed at construction (same pattern as OfertaCaptacaoFactory.gateway
    // /registro/moeda; no setter in this phase, see "Known open items") ─────────────
    ParticipacaoTokenFactory public immutable tokenFactory;
    EmissaoGateway public immutable emissaoGateway;
    OfertaCaptacaoFactory public immutable captacaoFactory;

    // ── Platform parameters, swappable via timelock, invisible to the issuer ──────
    address public protocoloWallet;
    uint256 public taxaBps;
    uint256 public tetoPorInvestidor;

    // ── Issuer allowlist, managed by AGENTE_ROLE, no timelock ─────────────────────
    mapping(address => bool) public emissoresAutorizados;

    // ── Events ─────────────────────────────────────────────────────────────────────
    event EmissorAutorizado(address indexed emissor);
    event EmissorRevogado(address indexed emissor);
    event OfertaCompletaCriada(
        address indexed emissor,
        address indexed token,
        address indexed oferta,
        uint256 metaMinima,
        uint256 metaMaxima,
        uint256 precoPorCota,
        uint256 prazo
    );
    event ProtocoloWalletChangeProposed(address indexed novoProtocoloWallet, uint256 executeAfter);
    event ProtocoloWalletChanged(address indexed antigo, address indexed novo);
    event TaxaBpsChangeProposed(uint256 novaTaxaBps, uint256 executeAfter);
    event TaxaBpsChanged(uint256 antiga, uint256 nova);
    event TetoPorInvestidorChangeProposed(uint256 novoTeto, uint256 executeAfter);
    event TetoPorInvestidorChanged(uint256 antigo, uint256 novo);

    // ── Errors ─────────────────────────────────────────────────────────────────────
    error ZeroAddress();
    error EmissorNaoAutorizado(address emissor);
    error PrecoInvalido();
    error PrazoInvalido(uint256 prazo);
    error PrazoExcedeLimite(uint256 prazo, uint256 limite);
    error MetaMaximaExcedeTeto(uint256 metaMaxima, uint256 teto);
    error LoteAdicionalExcedeLimite(uint256 metaMaxima, uint256 metaMinima);
    error PrecoNaoDivideMetaMaxima(uint256 metaMaxima, uint256 precoPorCota);
    error TaxaExcedeMaximo(uint256 taxaBps, uint256 maximo);

    constructor(
        address admin_,
        address tokenFactory_,
        address emissaoGateway_,
        address captacaoFactory_,
        address protocoloWallet_,
        uint256 taxaBps_,
        uint256 tetoPorInvestidor_,
        uint256 timelockDelay_
    ) TimelockedAccessControl(timelockDelay_) {
        if (
            admin_ == address(0) || tokenFactory_ == address(0) || emissaoGateway_ == address(0)
                || captacaoFactory_ == address(0) || protocoloWallet_ == address(0)
        ) revert ZeroAddress();
        if (taxaBps_ > TAXA_BPS_MAXIMA) revert TaxaExcedeMaximo(taxaBps_, TAXA_BPS_MAXIMA);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        tokenFactory = ParticipacaoTokenFactory(tokenFactory_);
        emissaoGateway = EmissaoGateway(emissaoGateway_);
        captacaoFactory = OfertaCaptacaoFactory(captacaoFactory_);
        protocoloWallet = protocoloWallet_;
        taxaBps = taxaBps_;
        tetoPorInvestidor = tetoPorInvestidor_;
    }

    // ── Allowlist (AGENTE_ROLE, immediate; see the locked decision) ────────────────
    function autorizarEmissor(address emissor) external onlyRole(AGENTE_ROLE) {
        if (emissor == address(0)) revert ZeroAddress();
        emissoresAutorizados[emissor] = true;
        emit EmissorAutorizado(emissor);
    }

    function revogarEmissor(address emissor) external onlyRole(AGENTE_ROLE) {
        emissoresAutorizados[emissor] = false;
        emit EmissorRevogado(emissor);
    }

    // ── Atomic creation ─────────────────────────────────────────────────────────────
    function criarOfertaCompleta(
        string memory nome,
        string memory simbolo,
        string memory empresa,
        bytes32 cnpjRef,
        string memory serie,
        uint256 metaMinima,
        uint256 metaMaxima,
        uint256 precoPorCota,
        uint256 prazo
    ) external returns (address token, address oferta) {
        if (!emissoresAutorizados[msg.sender]) revert EmissorNaoAutorizado(msg.sender);
        if (precoPorCota == 0) revert PrecoInvalido();
        if (prazo <= block.timestamp) revert PrazoInvalido(prazo);
        if (prazo - block.timestamp > PRAZO_MAXIMO) revert PrazoExcedeLimite(prazo, PRAZO_MAXIMO);
        if (metaMaxima > TETO_OFERTA) revert MetaMaximaExcedeTeto(metaMaxima, TETO_OFERTA);
        if (metaMaxima * LOTE_ADICIONAL_DENOMINADOR > metaMinima * LOTE_ADICIONAL_NUMERADOR) {
            revert LoteAdicionalExcedeLimite(metaMaxima, metaMinima);
        }
        if (metaMaxima % precoPorCota != 0) revert PrecoNaoDivideMetaMaxima(metaMaxima, precoPorCota);

        token = tokenFactory.criarOferta(nome, simbolo, empresa, cnpjRef, serie);

        uint256 cotasAutorizadas = (metaMaxima / precoPorCota) * UNIDADE_COTA;
        emissaoGateway.atestarCotas(token, cotasAutorizadas);

        oferta = captacaoFactory.criarCaptacao(
            token, metaMinima, metaMaxima, precoPorCota, prazo, tetoPorInvestidor, taxaBps, msg.sender, protocoloWallet
        );

        emissaoGateway.registrarCaptacao(token, oferta);

        emit OfertaCompletaCriada(msg.sender, token, oferta, metaMinima, metaMaxima, precoPorCota, prazo);
    }

    // ── Platform parameters (DEFAULT_ADMIN_ROLE, timelock) ─────────────────────────
    function proposeSetProtocoloWallet(address novo) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256);
    function executeSetProtocoloWallet(address novo) external onlyRole(DEFAULT_ADMIN_ROLE);

    function proposeSetTaxaBps(uint256 novaTaxaBps) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256);
    // validates TAXA_BPS_MAXIMA in both propose and execute (a lesson already applied in
    // LiquidacaoSecundaria.executeSetTaxaSecundarioBps, see CLAUDE.md; repeat it here)
    function executeSetTaxaBps(uint256 novaTaxaBps) external onlyRole(DEFAULT_ADMIN_ROLE);

    function proposeSetTetoPorInvestidor(uint256 novoTeto) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256);
    function executeSetTetoPorInvestidor(uint256 novoTeto) external onlyRole(DEFAULT_ADMIN_ROLE);
}
```

Each `proposeX`/`executeX` pair follows exactly the pattern already used throughout the
repository: `actionId = keccak256(abi.encode("ACTION_NAME", ...params))`, with
`_scheduleAction`/`_consumeAction` inherited from `TimelockedAccessControl`.

### 2.1 Full list of reverts

| Revert | Condition | Where |
|---|---|---|
| `ZeroAddress()` | any required constructor address is `address(0)`; `autorizarEmissor(address(0))` | constructor, `autorizarEmissor` |
| `TaxaExcedeMaximo(taxaBps_, 100)` | the initial `taxaBps` (constructor) or a proposed one (`proposeSetTaxaBps`/`executeSetTaxaBps`) exceeds 100 bps | constructor, `proposeSetTaxaBps`, `executeSetTaxaBps` |
| `EmissorNaoAutorizado(msg.sender)` | `criarOfertaCompleta` called by an address outside `emissoresAutorizados` | `criarOfertaCompleta` |
| `PrecoInvalido()` | `precoPorCota == 0` | `criarOfertaCompleta` |
| `PrazoInvalido(prazo)` | `prazo <= block.timestamp` | `criarOfertaCompleta` |
| `PrazoExcedeLimite(prazo, 180 days)` | `prazo - block.timestamp > 180 days` | `criarOfertaCompleta` |
| `MetaMaximaExcedeTeto(metaMaxima, 15_000_000 ether)` | `metaMaxima > TETO_OFERTA` | `criarOfertaCompleta` |
| `LoteAdicionalExcedeLimite(metaMaxima, metaMinima)` | `metaMaxima*100 > metaMinima*125` | `criarOfertaCompleta` |
| `PrecoNaoDivideMetaMaxima(metaMaxima, precoPorCota)` | `metaMaxima % precoPorCota != 0` | `criarOfertaCompleta` |
| *(bubbled)* `AccessControlUnauthorizedAccount` | the orchestrator does not yet have `AGENTE_ROLE` on one of the 3 target contracts | subcalls inside `criarOfertaCompleta` |
| *(bubbled)* `OfertaCaptacaoFactory`'s `MetasInvalidas`/`PrecoInvalido`/`PrazoInvalido`/`TaxaExcedeMaximo` | `metaMinima == 0`/`metaMinima > metaMaxima`: **deliberately not duplicated** in the orchestrator, already guaranteed downstream | `criarCaptacao`, called from inside `criarOfertaCompleta` |
| `ActionAlreadyPending`/`ActionNotPending`/`TimelockNotElapsed`/`InvalidTimelockDelay`/`RoleChangeRequiresTimelock` | inherited from `TimelockedAccessControl`, unchanged | any `proposeX`/`executeX`, `grantRole`/`revokeRole` |

---

## 3. Deploy sequence: summary

See the full detail in §1.3. Summary in steps:

1. Deploy `OfertaOrquestrador` (once the current infrastructure exists).
2. `propose`/wait 1h/`execute` of `AGENTE_ROLE` on `ParticipacaoTokenFactory`,
   `EmissaoGateway` and `OfertaCaptacaoFactory` (3 propose + 3 execute, independent of each
   other).
3. `propose`/wait 1h/`execute` of `AGENTE_ROLE` on the orchestrator **itself**, for the
   operator who will manage the allowlist.
4. `autorizarEmissor(company)` for each company approved off-chain: immediate.
5. The company calls `criarOfertaCompleta(...)` from its own wallet.

---

## 4. Test plan

New file: `test/OfertaOrquestrador.t.sol`. Covering, at a minimum:

**Access/allowlist**
- `criarOfertaCompleta` by an unauthorized issuer reverts with `EmissorNaoAutorizado`.
- `autorizarEmissor`/`revogarEmissor` only by `AGENTE_ROLE` (the orchestrator's); any other
  caller reverts with the standard `AccessControl` error.
- A revoked issuer can no longer create offerings after the revocation (even if it created
  one before).

**CVM Resolution 88 limits: exact boundary**
- `prazo - block.timestamp == 180 days` passes; `== 180 days + 1` reverts with
  `PrazoExcedeLimite`.
- `metaMaxima == TETO_OFERTA` passes; `== TETO_OFERTA + 1` reverts with
  `MetaMaximaExcedeTeto`.
- `metaMaxima * 100 == metaMinima * 125` (exactly a 25% additional lot) passes;
  `metaMaxima * 100 == metaMinima * 125 + 1` reverts with `LoteAdicionalExcedeLimite`.
- `prazo <= block.timestamp` reverts with `PrazoInvalido` (not with `PrazoExcedeLimite`).

**Arithmetic/derivation**
- `metaMaxima % precoPorCota != 0` reverts with `PrecoNaoDivideMetaMaxima` (including
  `precoPorCota == 0`, which must revert with `PrecoInvalido` **before** any modulo; see
  "Open observations").
- The resulting token has `cotasAutorizadas() == (metaMaxima/precoPorCota) * 1 ether`
  exactly.

**Anti-manipulation**
- `OfertaCaptacao.emissorWallet() == msg.sender`, always, even when simulating the "issuer"
  as an intermediate contract calling on its own behalf (the stored value is always whoever
  last called `criarOfertaCompleta`, never relayable).
- `OfertaCaptacao.taxaBps()`, `.protocoloWallet()`, `.tetoPorInvestidor()` match the
  orchestrator's storage **at the time of the call** exactly, including when those values
  were changed by `executeSetX` between two consecutive creations (the second offering
  reflects the new value, the first keeps the old one: the same "changes only affect the
  future" pattern already used in `ParticipacaoTokenFactory.implementacao`).

**Atomicity**
- Force a failure in the 4th subcall (`registrarCaptacao`), via a test `EmissaoGateway` that
  reverts only in that function, and confirm that neither `tokenFactory.isOferta(token)` nor
  `captacaoFactory.isCaptacao(oferta)` ends up `true`, and that no
  `OfertaCompletaCriada`/`OfertaCriada`/`CaptacaoCriada` event is emitted.
- `criarOfertaCompleta` called before the orchestrator has `AGENTE_ROLE` on all 3 contracts
  reverts cleanly (standard `AccessControl` error), with no partial state.

**Full cycle (integration)**
- An authorized issuer creates an offering → an investor invests (up to `metaMaxima`) →
  `encerrar()` → `resgatarCotas()` → the minted shares match what was invested, exactly as in
  the manual flow already tested in `OfertaCaptacao.t.sol`.

**Governance of platform parameters**
- `proposeSetTaxaBps`/`executeSetTaxaBps` only by `DEFAULT_ADMIN_ROLE`; both revert if
  `> TAXA_BPS_MAXIMA` (a test calls `executeSetTaxaBps` directly, without `propose`, with a
  value above the cap: the same lesson already recorded in `CLAUDE.md` for
  `LiquidacaoSecundaria.executeSetTaxaSecundarioBps`).
- The same coverage for `proposeSetProtocoloWallet`/`executeSetProtocoloWallet` (rejects
  `address(0)`) and `proposeSetTetoPorInvestidor`/`executeSetTetoPorInvestidor`.

---

## 5. Stateful fuzzing plan

New files: `test/invariant/HandlerOrquestrador.sol` + `test/InvariantOrquestrador.t.sol`,
with the same design as the existing handlers (`actors` = a mix of authorized and
unauthorized issuers; `agent` = the holder of `AGENTE_ROLE` on the orchestrator; `_chaos`
takes the invalid path ~1 in 5 times). Handler actions:

- `autorizarEmissor`/`revogarEmissor` (chaos: a caller without `AGENTE_ROLE`).
- `criarOfertaCompleta` with parameters `bound()`ed within the valid limits for most calls;
  on the `_chaos` path, one of the following is violated on purpose: deadline > 180 days,
  `metaMaxima` > cap, additional lot > 25%, `metaMaxima` not a multiple of `precoPorCota`, or
  an unauthorized caller.
- `proposeSetTaxaBps`/`executeSetTaxaBps`, `proposeSetProtocoloWallet`/
  `executeSetProtocoloWallet`, `proposeSetTetoPorInvestidor`/`executeSetTetoPorInvestidor`
  (chaos: a caller without `DEFAULT_ADMIN_ROLE`; `taxaBps` above the cap).

There is no handler action for "try to influence `taxaBps`/`protocoloWallet`/`emissorWallet`
via `criarOfertaCompleta`": the function's ABI does not even accept those parameters, so this
invariant holds by construction, not by dynamic testing. It is mentioned explicitly in the
coverage report instead of forcing an artificial handler action.

**Invariants (text)**:

1. For every offering created via the orchestrator:
   `token.totalSupply() <= token.cotasAutorizadas()` (Phase 1's general invariant, checked
   specifically on the new path).
2. For every offering created via the orchestrator: `metaMaxima <= TETO_OFERTA`,
   `prazo - <creation timestamp, in the handler's mirror> <= 180 days`, and
   `metaMaxima*100 <= metaMinima*125`: no live offering violates the CVM 88 limits encoded
   in the orchestrator.
3. For every offering created via the orchestrator: `oferta.emissorWallet()` is always the
   address that called `criarOfertaCompleta` for that specific offering (mirrored by the
   handler).
4. For every offering created via the orchestrator: `oferta.taxaBps()`,
   `.protocoloWallet()` and `.tetoPorInvestidor()` match the value in the orchestrator's
   storage at the exact moment of creation (a `ghost_*` mirror updated on each successful
   `executeSetX`); they never diverge.
5. No call to `criarOfertaCompleta` by an address outside `emissoresAutorizados` (at the time
   of the call) ever succeeded.
6. No call without `AGENTE_ROLE` (on the orchestrator) to `autorizarEmissor`/
   `revogarEmissor`, nor without `DEFAULT_ADMIN_ROLE` to `proposeSetTaxaBps`/
   `proposeSetProtocoloWallet`/`proposeSetTetoPorInvestidor`, ever succeeded.
7. The orchestrator's `taxaBps` never exceeded `TAXA_BPS_MAXIMA` (100) at any point in the
   sequence (same pattern as Phase 4's invariant 6, applied here to a second contract with
   an independent fee cap).

Scale: the same `foundry.toml` configuration already in use (`runs=256 * depth=100` = 25,600
calls per run), with no need to change the global profile.

---

## 6. Coverage

Target: **100% line/statement/branch/function** on `OfertaOrquestrador.sol`, the same bar as
Phases 1–4. No new branch should fall into the same "known instrumenter limitation" category
documented for `DenyAllTransferPolicy`: all branches here are normal conditionals
(`if`/`revert`), not `pure` functions returning a literal.

---

## 7. Required `CLAUDE.md` updates (once implementation is approved)

- A new section "Phase N architecture — `OfertaOrquestrador`" (numbering to be decided: today
  Phase 5 is "additional categories" and Phase 6 is in progress; this work will probably
  become a Phase 7, but that is only labeling, not a technical decision).
- A new entry in "Locked decisions" recording: allowlist without a timelock (with the
  rationale already given in the prompt), derived `cotasAutorizadas`, and the decision
  **not** to touch `EMISSOR_ROLE` (with the timelock-incompatibility reason, see §1.4).
- A new row in the "Timelock × operational split" table: `criarOfertaCompleta` and
  `autorizarEmissor`/`revogarEmissor` → operational/immediate; `setTaxaBps`/
  `setProtocoloWallet`/`setTetoPorInvestidor` → timelock.
- An explicit, honest note in the contract's NatSpec and in `CLAUDE.md`: CVM Resolution 88's
  annual cap across platforms (R$ 20,000 per retail investor) remains **entirely off-chain
  and self-declared**; `OfertaOrquestrador` adds no new guarantee about it, it only automates
  the creation of the offering itself.
- Update "Known open items": `OfertaOrquestrador.tokenFactory`/`emissaoGateway`/
  `captacaoFactory` are `immutable`, with no setter in this phase (the same pattern already
  recorded for `OfertaCaptacaoFactory.gateway`/`registro`/`moeda`).

---

## 8. Open observations (not broken locked decisions; gaps to fill)

1. **`precoPorCota == 0` before the modulo.** The locked decisions describe
   `metaMaxima % precoPorCota != 0` as a revert, but do not mention the `precoPorCota == 0`
   case explicitly. In plain Solidity that would be `Panic(0x12)` (division/modulo by zero)
   instead of a custom error, which breaks this repository's convention of never letting a
   "raw" revert happen. The plan above already includes
   `if (precoPorCota == 0) revert PrecoInvalido();` before the modulo, reusing the same error
   name already used in `OfertaCaptacaoFactory`. Confirm you agree with this addition before
   implementation.
2. **Emergency pause for the orchestrator.** Unlike `ParticipacaoTokenFactory`/
   `OfertaCaptacaoFactory` (both `Pausable`, `AGENTE_ROLE`), the locked design does not
   mention a `pause()` on `OfertaOrquestrador`. Note that a **transitive** pause already
   exists: if `ParticipacaoTokenFactory.pause()` or `OfertaCaptacaoFactory.pause()` is
   triggered (already `AGENTE_ROLE` and immediate today), `criarOfertaCompleta` automatically
   reverts on the corresponding subcall. So an emergency already has a button, only one
   "borrowed" from contracts that also affect the AGENT's manual path. Ask whether that is
   enough or whether you want a dedicated `pause()` just for the self-service channel (not
   included in the design above, so as not to expand scope silently).
3. **An issuer can create multiple offerings.** `emissoresAutorizados` is a boolean
   permission, not a counter or a "one offering at a time" limit: an authorized company can
   call `criarOfertaCompleta` as many times as it wants while it is on the allowlist. The
   locked decisions impose no restriction here; flagged only to confirm it is intended
   behavior (it seems reasonable, since a company can legitimately have more than one
   series/round, but I am recording the assumption).

None of these three observations contradicts a locked decision; they are points the problem
statement simply did not specify. I recommend deciding all three before I write any `.sol`.
