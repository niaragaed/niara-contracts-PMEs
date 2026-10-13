// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TimelockedAccessControl} from "../governance/TimelockedAccessControl.sol";
import {ITransferPolicy} from "../interfaces/ITransferPolicy.sol";
import {IParticipacaoToken} from "../interfaces/IParticipacaoToken.sol";
import {IParticipacaoTokenFactory} from "../interfaces/IParticipacaoTokenFactory.sol";

/// @title LiquidacaoSecundaria (secondary settlement)
/// @notice Settlement of bilateral share assignments already matched by the platform. It is NOT
/// an order book: there is no book of offers, no matching engine and no "create open order"
/// function. The platform (AGENT) matches buyer and seller off-chain and submits the
/// already-matched assignment; both parties pre-approve the necessary allowances before
/// submission. This design embodies the intermediation CVM Resolution 88 requires for the
/// secondary market of securities offered under a registration exemption, avoiding the
/// semantics of an unrestricted peer-to-peer marketplace.
/// @dev TESTNET PROTOTYPE, NO EXTERNAL AUDIT. Pattern adapted from the exchange's
/// `NiaraSettlement` (`niara-contracts`, read-only reference, see Lineage in CLAUDE.md):
/// atomic three-party settlement (buyer/seller/protocol) working through `allowance`. This
/// contract NEVER holds `MockBRL` or shares; it only moves what was pre-approved, in a single
/// atomic transaction.
///
/// The eligibility check (secondary market open, lock-up, buyer allowlist) is done ONCE by
/// `ParticipacaoToken` itself inside `_update`, when it reads the current
/// `RestrictedTransferPolicy`; this contract does not reimplement that logic. The
/// `canTransfer` called here before the swap is only a pre-flight (`view`, no effect) to
/// revert early with a clear error; the final guarantee, the one that actually blocks the
/// share transfer if the policy denies it, is still the token's `_update`.
///
/// REALLY turning on the secondary market (the `RestrictedTransferPolicy` returning `true`)
/// depends on the lock-up having elapsed AND on business/legal authorization from the platform,
/// entirely outside this contract (see `RestrictedTransferPolicy`/CLAUDE.md).
///
/// Checked item by item against the exchange's `NiaraSettlement.t.sol` (see CLAUDE.md, "Locked
/// decisions — Phase 4"). Reentrancy from the ASSET side (the share) has no dedicated test,
/// unlike `NiaraSettlement`: there the asset is an arbitrary ERC-20 and must be treated as
/// potentially malicious; here `token` has already passed `factory.isOferta`, i.e. it is always a
/// `ParticipacaoToken` cloned from this platform's single implementation. That token's
/// `transferFrom` path (`_update` → `ITransferPolicy.canTransfer`, a side-effect-free `view`, →
/// OZ's standard ERC20 `super._update`) has no external hook with third-party-controllable
/// code: there is no reentrancy surface to test on that side without forging an artificial
/// "ParticipacaoToken" that would never exist in production.
contract LiquidacaoSecundaria is TimelockedAccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Same operational role as the platform's other pieces: submitting an already-matched
    /// assignment is per trade and cannot wait for the timelock.
    bytes32 public constant AGENTE_ROLE = keccak256("AGENTE_ROLE");

    /// @notice Hard fee cap in this phase, same discipline as `OfertaCaptacao.TAXA_BPS_MAXIMA`.
    /// The secondary-market rate is independent of the primary rate (`OfertaCaptacao.taxaBps`).
    uint256 public constant TAXA_BPS_MAXIMA = 100;
    uint256 public constant BPS_DENOMINADOR = 10_000;

    /// @notice `ParticipacaoToken` is a standard 18-decimal ERC-20: "1 whole share" corresponds
    /// to `1 ether` in raw units (same convention as Phases 1/2). `precoPorCota` is the price of
    /// ONE whole share in `MockBRL` (same meaning as `OfertaCaptacao.precoPorCota`); `quantidade`
    /// is the amount of shares moved, in the token's raw unit (the same scale passed to
    /// `transferFrom`, without requiring the caller to rescale anything separately). `valor`
    /// rescales the product back to the "whole share" unit before multiplying by the price;
    /// omitting that rescale would multiply the price by a tiny fraction of a share, the same
    /// scaling bug already caught and fixed in `OfertaCaptacao.resgatarCotas` in Phase 2 (see CLAUDE.md).
    uint256 public constant UNIDADE_COTA = 1 ether;

    /// @notice Settlement currency (testnet mock, see `MockBRL`).
    IERC20 public immutable moeda;

    /// @notice Factory used to validate that a token is a genuine offering of this platform
    /// before settling any assignment of it.
    IParticipacaoTokenFactory public immutable factory;

    /// @notice Protocol wallet, destination of the secondary-market fee. Changeable via timelock.
    address public protocoloWallet;

    /// @notice Secondary-market rate, in bps, with a hard cap of `TAXA_BPS_MAXIMA`. Dormant
    /// (default `0`) in this phase; see "Non-negotiable rules" in CLAUDE.md.
    uint256 public taxaSecundarioBps;

    event CessaoLiquidada(
        address indexed token,
        address indexed vendedor,
        address indexed comprador,
        uint256 quantidade,
        uint256 valor,
        uint256 taxa
    );
    event ProtocoloWalletChangeProposed(address indexed novaWallet, uint256 executeAfter);
    event ProtocoloWalletChanged(address indexed walletAntiga, address indexed walletNova);
    event TaxaSecundarioBpsChangeProposed(uint256 novaTaxa, uint256 executeAfter);
    event TaxaSecundarioBpsChanged(uint256 taxaAntiga, uint256 taxaNova);

    error ZeroAddress();
    error TokenDesconhecido(address token);
    error QuantidadeInvalida();
    error PrecoInvalido();
    error ValorInvalido();
    error VendedorIgualComprador();
    error TaxaExcedeMaximo(uint256 taxaBps, uint256 maximo);
    error CessaoNaoPermitidaPelaPolitica(address token, address vendedor, address comprador, uint256 quantidade);

    /// @notice Anti-evasion by splitting: if the fee is active (`taxaSecundarioBps > 0`) but
    /// `valor` is small enough for integer division to truncate `taxa` to zero, the settlement
    /// reverts instead of passing without charging anything. Without this guard, a large
    /// assignment could be sliced into many tiny ones, each with a fee rounded to zero, dodging
    /// the whole fee; same protection as the exchange's `NiaraSettlement`
    /// (`PaymentAmountTooSmallForFeePrecision`). Harmless while the secondary fee is dormant
    /// (`0`, see "Non-negotiable rules" in CLAUDE.md), but it closes the loophole before the fee
    /// is turned on.
    error ValorInsuficienteParaPrecisaoDaTaxa();

    constructor(address admin_, address moeda_, address factory_, address protocoloWallet_, uint256 timelockDelay_)
        TimelockedAccessControl(timelockDelay_)
    {
        if (admin_ == address(0) || moeda_ == address(0) || factory_ == address(0) || protocoloWallet_ == address(0))
        {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        moeda = IERC20(moeda_);
        factory = IParticipacaoTokenFactory(factory_);
        protocoloWallet = protocoloWallet_;
    }

    /// @notice Settles a bilateral assignment already matched by the platform: `vendedor` (seller)
    /// assigns `quantidade` of `token` to `comprador` (buyer), who pays for `quantidade` shares at
    /// `precoPorCota` in `MockBRL`. Requires `vendedor` to have already approved this contract to
    /// move their shares, and `comprador` to have approved it to move their `MockBRL`. This
    /// contract never holds either asset; it only moves what was pre-approved, in a single atomic
    /// transaction (any revert undoes everything, including the `MockBRL` legs already executed
    /// before the token's `transferFrom`).
    function liquidarCessao(address token, address vendedor, address comprador, uint256 quantidade, uint256 precoPorCota)
        external
        onlyRole(AGENTE_ROLE)
        nonReentrant
        whenNotPaused
        returns (uint256 taxa)
    {
        if (token == address(0) || vendedor == address(0) || comprador == address(0)) revert ZeroAddress();
        if (vendedor == comprador) revert VendedorIgualComprador();
        if (!factory.isOferta(token)) revert TokenDesconhecido(token);
        if (quantidade == 0) revert QuantidadeInvalida();
        if (precoPorCota == 0) revert PrecoInvalido();

        address politica = IParticipacaoToken(token).transferPolicy();
        if (!ITransferPolicy(politica).canTransfer(token, vendedor, comprador, quantidade)) {
            revert CessaoNaoPermitidaPelaPolitica(token, vendedor, comprador, quantidade);
        }

        uint256 valor = (quantidade * precoPorCota) / UNIDADE_COTA;
        if (valor == 0) revert ValorInvalido();
        taxa = (valor * taxaSecundarioBps) / BPS_DENOMINADOR;
        if (taxaSecundarioBps > 0 && taxa == 0) revert ValorInsuficienteParaPrecisaoDaTaxa();
        uint256 valorVendedor = valor - taxa;

        emit CessaoLiquidada(token, vendedor, comprador, quantidade, valor, taxa);

        // Leg order: payment (buyer→seller→protocol) before the asset (seller→buyer), the
        // OPPOSITE direction to NiaraSettlement (asset first, then payment). Deliberate, not an
        // oversight: since everything is atomic, the order does not change the final result, but
        // keeping the TOKEN's transferFrom last reinforces in the code itself what the contract
        // NatSpec already documents. The `canTransfer` pre-flight above only reverts early with a
        // clear error; the check that actually authorizes the assignment is the token's `_update`,
        // triggered by this last call, so it sits as the final gate of the sequence.
        moeda.safeTransferFrom(comprador, vendedor, valorVendedor);
        if (taxa > 0) moeda.safeTransferFrom(comprador, protocoloWallet, taxa);
        IERC20(token).safeTransferFrom(vendedor, comprador, quantidade);
    }

    /// @notice Pauses `liquidarCessao` in an emergency, with the same operational role
    /// (`AGENTE_ROLE`) used for pausing in `ParticipacaoTokenFactory`/`OfertaCaptacaoFactory`, not a
    /// new role (`PAUSER_ROLE`, as in the reference). This repository already has a single
    /// operational role per contract, and creating a second one just for pausing would fragment
    /// that pattern for no reason.
    function pause() external onlyRole(AGENTE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(AGENTE_ROLE) {
        _unpause();
    }

    // ── protocoloWallet change (subject to the timelock: a sensitive address) ─────────────

    function proposeSetProtocoloWallet(address novaWallet)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        if (novaWallet == address(0)) revert ZeroAddress();
        bytes32 actionId = keccak256(abi.encode("SET_PROTOCOLO_WALLET", novaWallet));
        executeAfter = _scheduleAction(actionId);
        emit ProtocoloWalletChangeProposed(novaWallet, executeAfter);
    }

    function executeSetProtocoloWallet(address novaWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 actionId = keccak256(abi.encode("SET_PROTOCOLO_WALLET", novaWallet));
        _consumeAction(actionId);
        address walletAntiga = protocoloWallet;
        protocoloWallet = novaWallet;
        emit ProtocoloWalletChanged(walletAntiga, novaWallet);
    }

    // ── Secondary fee change (subject to the timelock: a sensitive protocol decision) ──────

    function proposeSetTaxaSecundarioBps(uint256 novaTaxa)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        if (novaTaxa > TAXA_BPS_MAXIMA) revert TaxaExcedeMaximo(novaTaxa, TAXA_BPS_MAXIMA);
        bytes32 actionId = keccak256(abi.encode("SET_TAXA_SECUNDARIO_BPS", novaTaxa));
        executeAfter = _scheduleAction(actionId);
        emit TaxaSecundarioBpsChangeProposed(novaTaxa, executeAfter);
    }

    /// @dev The cap check is repeated here, in addition to `propose`. It is unreachable through
    /// the normal flow (a pending proposal only exists for a `novaTaxa` that already passed the
    /// check in `proposeSetTaxaSecundarioBps`), but it is kept as defense in depth against the
    /// `execute` parameter diverging from what was actually proposed.
    function executeSetTaxaSecundarioBps(uint256 novaTaxa) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (novaTaxa > TAXA_BPS_MAXIMA) revert TaxaExcedeMaximo(novaTaxa, TAXA_BPS_MAXIMA);
        bytes32 actionId = keccak256(abi.encode("SET_TAXA_SECUNDARIO_BPS", novaTaxa));
        _consumeAction(actionId);
        uint256 taxaAntiga = taxaSecundarioBps;
        taxaSecundarioBps = novaTaxa;
        emit TaxaSecundarioBpsChanged(taxaAntiga, novaTaxa);
    }
}
