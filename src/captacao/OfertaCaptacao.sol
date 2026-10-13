// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IParticipacaoToken} from "../interfaces/IParticipacaoToken.sol";
import {IEmissaoGateway} from "../interfaces/IEmissaoGateway.sol";
import {IRegistroInvestidorQualificado} from "../interfaces/IRegistroInvestidorQualificado.sol";
import {IOfertaCaptacao} from "../interfaces/IOfertaCaptacao.sol";

/// @title OfertaCaptacao (fundraising offering)
/// @notice Escrow of a primary fundraising (CVM Resolution 88): receives investments in
/// `MockBRL`, closes as a success (`totalArrecadado >= metaMinima`, partial close allowed) or a
/// failure (below the floor), and only then releases shares (minted in proportion to what was
/// raised) or returns the money invested. No token is minted during the fundraising: the money
/// stays in this contract (escrow) until the outcome.
/// @dev TESTNET PROTOTYPE, NO EXTERNAL AUDIT. Clonable via EIP-1167, same discipline as
/// Phase 1 (`ParticipacaoToken`): state via `initialize()`, template implementation with
/// `_disableInitializers()`. `cancelar()` reuses the already-timelocked `AGENTE_ROLE` of the
/// `EmissaoGateway` pointed to by `gateway`: this contract, being cloned per offering, has no
/// `AccessControl` of its own (same "authorization by a single address" reasoning documented in
/// `ParticipacaoToken`/CLAUDE.md, "Phase 1 architecture").
///
/// Rounding rule (a deliberate simplification in this phase, see CLAUDE.md): every investment
/// must be an exact multiple of `precoPorCota`, so that `shares = investment / precoPorCota`
/// never leaves dust. Accepting any amount and returning the remainder is recorded as a future
/// improvement.
///
/// `tetoPorInvestidor` is only this specific offering's limit. The ANNUAL CAP ACROSS
/// PLATFORMS set by CVM Resolution 88 is OFF-CHAIN and SELF-DECLARED: this contract does
/// not have, and cannot have, visibility into the same investor's investments on other
/// platforms, and does not guarantee that aggregate cap.
contract OfertaCaptacao is Initializable, PausableUpgradeable, ReentrancyGuard, IOfertaCaptacao {
    using SafeERC20 for IERC20;

    /// @notice Same operational role defined in `EmissaoGateway`, read via `gateway` to
    /// authorize `cancelar()` without this clone needing its own `AccessControl`.
    bytes32 public constant AGENTE_ROLE = keccak256("AGENTE_ROLE");

    /// @notice Hard fee cap in this phase; see "Locked decisions" in CLAUDE.md.
    uint256 public constant TAXA_BPS_MAXIMA = 100;
    uint256 public constant BPS_DENOMINADOR = 10_000;

    /// @notice `ParticipacaoToken` is a standard 18-decimal ERC-20 (inherited from
    /// `ERC20Upgradeable`, no `decimals()` override): "1 whole share" corresponds to
    /// `1 ether` (1e18) in the token's raw unit, the same convention already used in Phase 1
    /// (`gateway.emitir(token, investor, 100 ether)` == 100 shares). `aportado / precoPorCota`
    /// gives the dimensionless share COUNT; multiplying by `UNIDADE_COTA` rescales that count to
    /// the raw unit that `mint`/`cotasAutorizadas` expect.
    uint256 public constant UNIDADE_COTA = 1 ether;

    enum Estado {
        Aberta,
        EncerradaSucesso,
        EncerradaFalha
    }

    IParticipacaoToken public token;
    address public gateway;
    IRegistroInvestidorQualificado public registro;
    IERC20 public moeda;
    address public emissorWallet;
    address public protocoloWallet;

    uint256 public metaMinima;
    uint256 public metaMaxima;
    uint256 public precoPorCota;
    uint256 public prazo;
    uint256 public tetoPorInvestidor;
    uint256 public taxaBps;

    Estado public estado;
    uint256 public totalArrecadado;
    bool public recursosLiberados;

    mapping(address => uint256) public aportadoPor;
    mapping(address => bool) public reembolsado;
    mapping(address => bool) public cotasResgatadas;

    event Aporte(address indexed investidor, uint256 valor, uint256 totalArrecadadoAtual);
    event OfertaEncerrada(Estado resultado, uint256 totalArrecadado);
    event OfertaCancelada();
    event CotasResgatadas(address indexed investidor, uint256 cotas);
    event RecursosLiberados(
        address indexed emissorWallet, uint256 valorEmissor, address indexed protocoloWallet, uint256 taxa
    );
    event Reembolso(address indexed investidor, uint256 valor);

    error ZeroAddress();
    error NaoAutorizado();
    error MetasInvalidas(uint256 metaMinima, uint256 metaMaxima);
    error PrecoInvalido();
    error PrazoInvalido(uint256 prazo);
    error TaxaExcedeMaximo(uint256 taxaBps, uint256 maximo);
    error OfertaNaoAberta();
    error PrazoExpirado();
    error EncerramentoPrematuro();
    error AporteNaoMultiploDoPreco(uint256 valor, uint256 precoPorCota);
    error ExcedeMetaMaxima(uint256 solicitado, uint256 disponivel);
    error ExcedeTetoInvestidor(uint256 solicitado, uint256 teto);
    error OfertaNaoEncerradaComSucesso();
    error OfertaNaoEncerradaComFalha();
    error JaResgatado();
    error JaReembolsado();
    error RecursosJaLiberados();
    error NadaAResgatar();
    error NadaAReembolsar();

    /// @dev Locks the template implementation: only clones initialized via `initialize` are
    /// usable.
    constructor() {
        _disableInitializers();
    }

    modifier onlyAgente() {
        if (!IAccessControl(gateway).hasRole(AGENTE_ROLE, msg.sender)) revert NaoAutorizado();
        _;
    }

    /// @notice Initializes the clone (runs once, on the clone). Parameters grouped in a
    /// struct (see `IOfertaCaptacao.InitParams`) to avoid "stack too deep".
    function initialize(InitParams calldata params) external initializer {
        if (
            params.token == address(0) || params.gateway == address(0) || params.registro == address(0)
                || params.moeda == address(0) || params.emissorWallet == address(0)
                || params.protocoloWallet == address(0)
        ) revert ZeroAddress();
        if (params.metaMinima == 0 || params.metaMinima > params.metaMaxima) {
            revert MetasInvalidas(params.metaMinima, params.metaMaxima);
        }
        if (params.precoPorCota == 0) revert PrecoInvalido();
        if (params.prazo <= block.timestamp) revert PrazoInvalido(params.prazo);
        if (params.taxaBps > TAXA_BPS_MAXIMA) revert TaxaExcedeMaximo(params.taxaBps, TAXA_BPS_MAXIMA);

        __Pausable_init();

        token = IParticipacaoToken(params.token);
        gateway = params.gateway;
        registro = IRegistroInvestidorQualificado(params.registro);
        moeda = IERC20(params.moeda);
        emissorWallet = params.emissorWallet;
        protocoloWallet = params.protocoloWallet;
        metaMinima = params.metaMinima;
        metaMaxima = params.metaMaxima;
        precoPorCota = params.precoPorCota;
        prazo = params.prazo;
        tetoPorInvestidor = params.tetoPorInvestidor;
        taxaBps = params.taxaBps;
    }

    /// @notice Invests `valor` of `moeda` in the fundraising (escrow). Requires an exact multiple of
    /// `precoPorCota`, respects the maximum target and, for non-qualified investors, this offering's
    /// per-investor cap.
    function aportar(uint256 valor) external nonReentrant whenNotPaused {
        if (estado != Estado.Aberta) revert OfertaNaoAberta();
        if (block.timestamp >= prazo) revert PrazoExpirado();
        if (valor == 0 || valor % precoPorCota != 0) revert AporteNaoMultiploDoPreco(valor, precoPorCota);

        uint256 novoTotal = totalArrecadado + valor;
        if (novoTotal > metaMaxima) revert ExcedeMetaMaxima(novoTotal, metaMaxima);

        uint256 novoAportado = aportadoPor[msg.sender] + valor;
        if (!registro.ehQualificado(msg.sender) && novoAportado > tetoPorInvestidor) {
            revert ExcedeTetoInvestidor(novoAportado, tetoPorInvestidor);
        }

        aportadoPor[msg.sender] = novoAportado;
        totalArrecadado = novoTotal;

        emit Aporte(msg.sender, valor, novoTotal);

        moeda.safeTransferFrom(msg.sender, address(this), valor);
    }

    /// @notice Closes the fundraising (permissionless): valid once the deadline is reached, or the
    /// maximum target before it. Success if `totalArrecadado >= metaMinima` (partial close allowed).
    function encerrar() external {
        if (estado != Estado.Aberta) revert OfertaNaoAberta();
        if (block.timestamp < prazo && totalArrecadado != metaMaxima) revert EncerramentoPrematuro();

        estado = totalArrecadado >= metaMinima ? Estado.EncerradaSucesso : Estado.EncerradaFalha;
        emit OfertaEncerrada(estado, totalArrecadado);
    }

    /// @notice The AGENT's protective power: cancels a still-open fundraising, moving it to
    /// failure/refund. It never retains money; it only returns it.
    function cancelar() external onlyAgente {
        if (estado != Estado.Aberta) revert OfertaNaoAberta();
        estado = Estado.EncerradaFalha;
        emit OfertaCancelada();
    }

    /// @notice Redeems (pull, once) the shares proportional to the caller's investment, only after
    /// success. The mint goes through `gateway.emitirParaCaptacao`, which checks that this contract
    /// is the authorized fundraising for that token.
    function resgatarCotas() external nonReentrant {
        if (estado != Estado.EncerradaSucesso) revert OfertaNaoEncerradaComSucesso();
        if (cotasResgatadas[msg.sender]) revert JaResgatado();
        uint256 aportado = aportadoPor[msg.sender];
        if (aportado == 0) revert NadaAResgatar();

        cotasResgatadas[msg.sender] = true;
        uint256 cotas = (aportado / precoPorCota) * UNIDADE_COTA;

        emit CotasResgatadas(msg.sender, cotas);

        IEmissaoGateway(gateway).emitirParaCaptacao(address(token), msg.sender, cotas);
    }

    /// @notice Releases (pull, once, permissionless) the amount raised to the issuer and the fee to
    /// the protocol, only after success.
    function liberarParaEmissor() external nonReentrant {
        if (estado != Estado.EncerradaSucesso) revert OfertaNaoEncerradaComSucesso();
        if (recursosLiberados) revert RecursosJaLiberados();
        recursosLiberados = true;

        uint256 taxa = (totalArrecadado * taxaBps) / BPS_DENOMINADOR;
        uint256 valorEmissor = totalArrecadado - taxa;

        emit RecursosLiberados(emissorWallet, valorEmissor, protocoloWallet, taxa);

        if (taxa > 0) moeda.safeTransfer(protocoloWallet, taxa);
        moeda.safeTransfer(emissorWallet, valorEmissor);
    }

    /// @notice Refunds (pull, once) exactly the caller's investment, only after failure.
    function reembolsar() external nonReentrant {
        if (estado != Estado.EncerradaFalha) revert OfertaNaoEncerradaComFalha();
        if (reembolsado[msg.sender]) revert JaReembolsado();
        uint256 aportado = aportadoPor[msg.sender];
        if (aportado == 0) revert NadaAReembolsar();

        reembolsado[msg.sender] = true;

        emit Reembolso(msg.sender, aportado);

        moeda.safeTransfer(msg.sender, aportado);
    }

    /// @notice Pauses new investments in an emergency. It does not affect closing, redemption,
    /// refund or release: investors' right to withdraw is never frozen.
    function pausar() external onlyAgente {
        _pause();
    }

    function despausar() external onlyAgente {
        _unpause();
    }

    // ── Views ───────────────────────────────────────────────────────────────────────────

    function capacidadeRestante() external view returns (uint256) {
        return metaMaxima - totalArrecadado;
    }

    function cotasDe(address investidor) external view returns (uint256) {
        return (aportadoPor[investidor] / precoPorCota) * UNIDADE_COTA;
    }
}
