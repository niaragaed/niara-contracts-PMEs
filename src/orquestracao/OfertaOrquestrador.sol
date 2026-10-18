// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {TimelockedAccessControl} from "../governance/TimelockedAccessControl.sol";

/// @dev Minimal interfaces, LOCAL to this file, deliberately not added to
/// `src/interfaces/` nor mixed with the existing interfaces (`IEmissaoGateway`,
/// `IParticipacaoTokenFactory`, `IOfertaCaptacao`). This keeps this phase 100% additive: no
/// file outside `src/orquestracao/` is created or touched. Each one exposes only the function
/// the orchestrator actually calls, the same minimal-coupling principle already used in the
/// repository's shared interfaces, but with no `is` relationship to the concrete contract: the
/// call works by ABI selector matching (the same mechanism behind any
/// `IERC20(token).transfer(...)` called on a token that never declared `is IERC20`). Neither
/// `ParticipacaoTokenFactory`, `EmissaoGateway` nor `OfertaCaptacaoFactory` declares `is` any of
/// these; checked in the source code before writing this.
interface ITokenFactoryDoOrquestrador {
    function criarOferta(
        string memory nome,
        string memory simbolo,
        string memory empresa,
        bytes32 cnpjRef,
        string memory serie
    ) external returns (address token);
}

interface IEmissaoGatewayDoOrquestrador {
    function atestarCotas(address token, uint256 novoTeto) external;
    function registrarCaptacao(address token, address oferta) external;
}

interface ICaptacaoFactoryDoOrquestrador {
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
    ) external returns (address oferta);
}

/// @dev Mirrors `OfertaCaptacao.Estado` only through its ABI representation (enums encode as
/// `uint8`, in declaration order). It was deliberately NOT added to `IOfertaCaptacao.sol`.
/// `OfertaCaptacao is IOfertaCaptacao`: extending that interface with this enum would require
/// `OfertaCaptacao` to return EXACTLY the interface's enum type (Solidity treats enums from
/// different scopes as distinct types, even with the same members in the same order), a
/// compile error that could only be solved by editing `OfertaCaptacao.sol`, which is forbidden
/// in this phase. A fully local interface, with no `is` relationship to the concrete contract,
/// avoids the problem entirely (same reasoning as the interfaces above).
interface IOfertaCaptacaoEstadoDoOrquestrador {
    enum Estado {
        Aberta,
        EncerradaSucesso,
        EncerradaFalha
    }

    function estado() external view returns (Estado);
}

/// @title OfertaOrquestrador (offering orchestrator)
/// @notice Lets the issuing company itself (previously authorized by the platform) create its
/// fundraising offering, until now an exclusive privilege of the AGENT, in a single atomic
/// transaction, without gaining power over the platform's sensitive parameters.
/// @dev TESTNET PROTOTYPE, NO EXTERNAL AUDIT. No existing contract changes behavior: this
/// contract only chains, as any external caller could, the four calls that already existed
/// (`ParticipacaoTokenFactory.criarOferta` → `EmissaoGateway.atestarCotas` →
/// `OfertaCaptacaoFactory.criarCaptacao` → `EmissaoGateway.registrarCaptacao`), holding
/// `AGENTE_ROLE` on the three target contracts. Atomicity is not hand-written rollback logic;
/// it is native EVM semantics: if any subcall reverts, the whole transaction (including the
/// `Clones.clone` calls already executed) is undone.
///
/// Deliberate regulatory limitation, documented and not solved here (the same layer where the
/// INVESTOR's annual cap already lives; see `OfertaCaptacao`/`RegistroInvestidorQualificado`):
/// the ISSUER's AGGREGATE annual cap set by CVM Resolution 88 (fundraisings summed across ALL
/// crowdfunding platforms, not only this one) is OFF-CHAIN and SELF-DECLARED. This contract does
/// not have, and cannot have, visibility into how much a company has already raised on another
/// platform in the same period. Enforcing that cap on this single offering's `metaMaxima` would
/// be wrong by construction (an offering capped at R$ 15,000,000 that raises only
/// R$ 1,000,000 should not consume the issuer's whole aggregate window), and enforcing it on
/// `totalArrecadado` would couple this contract to each `OfertaCaptacao`'s lifecycle, which it
/// deliberately does not follow after creation (it only reads the last offering's `estado()`
/// for the "one open at a time" lock, not for financial-cap purposes). No automation should
/// describe `criarOfertaCompleta`, on its own, as sufficient to comply with that aggregate cap.
contract OfertaOrquestrador is TimelockedAccessControl, Pausable {
    /// @notice Operational role: agent/platform authorized to manage the issuer allowlist and
    /// the self-service channel's emergency pause.
    bytes32 public constant AGENTE_ROLE = keccak256("AGENTE_ROLE");

    /// @notice Fundraising cap per offering (CVM Resolution 88), in `MockBRL` units (18
    /// decimals, checked in `src/mocks/MockBRL.sol`): R$ 15,000,000.
    uint256 public constant TETO_OFERTA = 15_000_000 ether;

    /// @notice Maximum duration of a fundraising (CVM Resolution 88).
    uint256 public constant PRAZO_MAXIMO = 180 days;

    /// @notice Maximum additional lot of 25% over `metaMinima`, expressed as an integer ratio:
    /// `metaMaxima * LOTE_ADICIONAL_DENOMINADOR <= metaMinima * LOTE_ADICIONAL_NUMERADOR`.
    uint256 public constant LOTE_ADICIONAL_NUMERADOR = 125;
    uint256 public constant LOTE_ADICIONAL_DENOMINADOR = 100;

    /// @notice `ParticipacaoToken` has 18 decimals: "1 whole share" is `1 ether` in raw
    /// units (same convention as `OfertaCaptacao.UNIDADE_COTA`, see CLAUDE.md).
    uint256 public constant UNIDADE_COTA = 1 ether;

    /// @notice Same hard fee cap already used in `OfertaCaptacao`/`OfertaCaptacaoFactory`/
    /// `LiquidacaoSecundaria`, independent of all the others; see CLAUDE.md.
    uint256 internal constant TAXA_BPS_MAXIMA = 100;

    /// @notice `ParticipacaoTokenFactory` in use, fixed at construction, with no setter in this
    /// phase (the same decision already recorded for `OfertaCaptacaoFactory.gateway`/`registro`/
    /// `moeda`; see CLAUDE.md "Known open items").
    address public immutable tokenFactory;

    /// @notice `EmissaoGateway` in use, fixed at construction, with no setter in this phase.
    address public immutable emissaoGateway;

    /// @notice `OfertaCaptacaoFactory` in use, fixed at construction, with no setter in this phase.
    address public immutable captacaoFactory;

    /// @notice Protocol wallet used in every fundraising created by this orchestrator, never
    /// visible to or influenced by the issuer. Changeable via timelock.
    address public protocoloWallet;

    /// @notice Fee (bps) used in every fundraising created by this orchestrator, never visible to
    /// or influenced by the issuer. Changeable via timelock, always <= `TAXA_BPS_MAXIMA`.
    uint256 public taxaBps;

    /// @notice Per-investor cap used in every fundraising created by this orchestrator, never
    /// visible to or influenced by the issuer. Changeable via timelock.
    uint256 public tetoPorInvestidor;

    /// @notice `true` for every address the AGENT authorized to create its own offering.
    /// Immediate management, no timelock: authorizing an issuer gives no power over other
    /// people's money, only the ability to create its own offering with parameters fixed by the
    /// platform (see PLANO_OFERTA_ORQUESTRADOR.md).
    mapping(address => bool) public emissoresAutorizados;

    /// @notice Every offering (`OfertaCaptacao` address) created by each issuer, in creation
    /// order: the full history for per-issuer reconciliation.
    mapping(address => address[]) public ofertasPorEmissor;

    /// @notice The last offering created by each issuer, read to prevent a second offering while
    /// the previous one is `Aberta` (open).
    mapping(address => address) public ultimaOfertaDoEmissor;

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

    error ZeroAddress();
    error EmissorNaoAutorizado(address emissor);
    error OfertaAnteriorAindaAberta(address oferta);
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
        tokenFactory = tokenFactory_;
        emissaoGateway = emissaoGateway_;
        captacaoFactory = captacaoFactory_;
        protocoloWallet = protocoloWallet_;
        taxaBps = taxaBps_;
        tetoPorInvestidor = tetoPorInvestidor_;
    }

    // ── Issuer allowlist (AGENTE_ROLE, immediate; see the locked decision) ───────────────

    function autorizarEmissor(address emissor) external onlyRole(AGENTE_ROLE) {
        if (emissor == address(0)) revert ZeroAddress();
        emissoresAutorizados[emissor] = true;
        emit EmissorAutorizado(emissor);
    }

    function revogarEmissor(address emissor) external onlyRole(AGENTE_ROLE) {
        emissoresAutorizados[emissor] = false;
        emit EmissorRevogado(emissor);
    }

    // ── Emergency pause of the self-service channel (AGENTE_ROLE, immediate) ─────────────
    // `whenNotPaused` lives only on `criarOfertaCompleta`: the pause turns off self-service
    // creation without affecting manual creation by the platform (the factories have their own
    // independent pause) or any offering already created. Investment, closing, redemption, refund
    // and release keep working, the same principle as `OfertaCaptacao.pausar` (see CLAUDE.md).

    function pause() external onlyRole(AGENTE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(AGENTE_ROLE) {
        _unpause();
    }

    // ── Atomic creation ─────────────────────────────────────────────────────────────────────

    /// @notice Creates a complete offering (token + fundraising) for the calling issuer, with the
    /// four steps `criarOferta` → `atestarCotas` → `criarCaptacao` → `registrarCaptacao`
    /// executed atomically. `emissorWallet` is always `msg.sender` (not a parameter);
    /// `taxaBps`, `protocoloWallet` and `tetoPorInvestidor` always come from this contract's
    /// storage, never from the issuer's calldata.
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
    ) external whenNotPaused returns (address token, address oferta) {
        if (!emissoresAutorizados[msg.sender]) revert EmissorNaoAutorizado(msg.sender);

        address ofertaAnterior = ultimaOfertaDoEmissor[msg.sender];
        if (ofertaAnterior != address(0)) {
            if (
                IOfertaCaptacaoEstadoDoOrquestrador(ofertaAnterior).estado()
                    == IOfertaCaptacaoEstadoDoOrquestrador.Estado.Aberta
            ) {
                revert OfertaAnteriorAindaAberta(ofertaAnterior);
            }
        }

        // `precoPorCota == 0` must revert BEFORE the modulo below: in ^0.8, `x % 0` reverts
        // with Panic(0x12), which is opaque and cannot be translated in the frontend. The named
        // check in the downstream factories (`OfertaCaptacaoFactory.PrecoInvalido`) would never be
        // reached, because the panic fires first, so it must be checked here too.
        if (precoPorCota == 0) revert PrecoInvalido();
        if (prazo <= block.timestamp) revert PrazoInvalido(prazo);
        if (prazo - block.timestamp > PRAZO_MAXIMO) revert PrazoExcedeLimite(prazo, PRAZO_MAXIMO);
        if (metaMaxima > TETO_OFERTA) revert MetaMaximaExcedeTeto(metaMaxima, TETO_OFERTA);
        if (metaMaxima * LOTE_ADICIONAL_DENOMINADOR > metaMinima * LOTE_ADICIONAL_NUMERADOR) {
            revert LoteAdicionalExcedeLimite(metaMaxima, metaMinima);
        }
        if (metaMaxima % precoPorCota != 0) revert PrecoNaoDivideMetaMaxima(metaMaxima, precoPorCota);
        // `metaMinima == 0` / `metaMinima > metaMaxima` are deliberately NOT rechecked here:
        // `OfertaCaptacaoFactory.criarCaptacao` already reverts with `MetasInvalidas` in those cases,
        // and any revert in a subcall atomically undoes the subcalls already executed. Duplicating
        // the check would close no gap; it would only repeat logic already guaranteed downstream
        // (see CLAUDE.md, a principle already followed in the earlier phases).

        token = ITokenFactoryDoOrquestrador(tokenFactory).criarOferta(nome, simbolo, empresa, cnpjRef, serie);

        uint256 cotasAutorizadas = (metaMaxima / precoPorCota) * UNIDADE_COTA;
        IEmissaoGatewayDoOrquestrador(emissaoGateway).atestarCotas(token, cotasAutorizadas);

        oferta = ICaptacaoFactoryDoOrquestrador(captacaoFactory)
            .criarCaptacao(
                token,
                metaMinima,
                metaMaxima,
                precoPorCota,
                prazo,
                tetoPorInvestidor,
                taxaBps,
                msg.sender,
                protocoloWallet
            );

        IEmissaoGatewayDoOrquestrador(emissaoGateway).registrarCaptacao(token, oferta);

        ofertasPorEmissor[msg.sender].push(oferta);
        ultimaOfertaDoEmissor[msg.sender] = oferta;

        emit OfertaCompletaCriada(msg.sender, token, oferta, metaMinima, metaMaxima, precoPorCota, prazo);
    }

    /// @notice Total number of offerings `emissor` has created since the start.
    function numOfertasDoEmissor(address emissor) external view returns (uint256) {
        return ofertasPorEmissor[emissor].length;
    }

    // ── Platform parameters (DEFAULT_ADMIN_ROLE, timelock) ───────────────────────────────

    function proposeSetProtocoloWallet(address novo)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        if (novo == address(0)) revert ZeroAddress();
        bytes32 actionId = keccak256(abi.encode("SET_PROTOCOLO_WALLET", novo));
        executeAfter = _scheduleAction(actionId);
        emit ProtocoloWalletChangeProposed(novo, executeAfter);
    }

    function executeSetProtocoloWallet(address novo) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 actionId = keccak256(abi.encode("SET_PROTOCOLO_WALLET", novo));
        _consumeAction(actionId);
        address antigo = protocoloWallet;
        protocoloWallet = novo;
        emit ProtocoloWalletChanged(antigo, novo);
    }

    function proposeSetTaxaBps(uint256 novaTaxaBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        if (novaTaxaBps > TAXA_BPS_MAXIMA) {
            revert TaxaExcedeMaximo(novaTaxaBps, TAXA_BPS_MAXIMA);
        }
        bytes32 actionId = keccak256(abi.encode("SET_TAXA_BPS", novaTaxaBps));
        executeAfter = _scheduleAction(actionId);
        emit TaxaBpsChangeProposed(novaTaxaBps, executeAfter);
    }

    /// @dev Repeats the cap check in `execute`, not only in `propose`, the same lesson already
    /// applied in `LiquidacaoSecundaria.executeSetTaxaSecundarioBps` (see CLAUDE.md,
    /// "Cross-check against NiaraSettlement"): without it, calling `execute` directly, with no
    /// matching `propose`, would still revert in `_consumeAction` (no pending action), but as
    /// defense in depth the cap is validated in both places.
    function executeSetTaxaBps(uint256 novaTaxaBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (novaTaxaBps > TAXA_BPS_MAXIMA) revert TaxaExcedeMaximo(novaTaxaBps, TAXA_BPS_MAXIMA);
        bytes32 actionId = keccak256(abi.encode("SET_TAXA_BPS", novaTaxaBps));
        _consumeAction(actionId);
        uint256 antiga = taxaBps;
        taxaBps = novaTaxaBps;
        emit TaxaBpsChanged(antiga, novaTaxaBps);
    }

    function proposeSetTetoPorInvestidor(uint256 novoTeto)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        bytes32 actionId = keccak256(abi.encode("SET_TETO_POR_INVESTIDOR", novoTeto));
        executeAfter = _scheduleAction(actionId);
        emit TetoPorInvestidorChangeProposed(novoTeto, executeAfter);
    }

    function executeSetTetoPorInvestidor(uint256 novoTeto) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 actionId = keccak256(abi.encode("SET_TETO_POR_INVESTIDOR", novoTeto));
        _consumeAction(actionId);
        uint256 antigo = tetoPorInvestidor;
        tetoPorInvestidor = novoTeto;
        emit TetoPorInvestidorChanged(antigo, novoTeto);
    }
}
