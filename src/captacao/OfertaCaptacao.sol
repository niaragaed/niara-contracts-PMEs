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

/// @title OfertaCaptacao
/// @notice Escrow de uma captação primária (Resolução CVM 88): recebe aportes em `MockBRL`,
/// encerra em sucesso (`totalArrecadado >= metaMinima`, fechamento parcial permitido) ou
/// fracasso (abaixo do piso), e só então libera cotas (mint proporcional ao arrecadado) ou
/// devolve o dinheiro aportado. Nenhum token é cunhado durante a captação — o dinheiro fica
/// retido neste contrato (escrow) até o desfecho.
/// @dev PROTÓTIPO EM TESTNET, SEM AUDITORIA EXTERNA. Clonável via EIP-1167, mesma disciplina
/// da Fase 1 (`ParticipacaoToken`): estado via `initialize()`, implementação-template com
/// `_disableInitializers()`. `cancelar()` reaproveita o `AGENTE_ROLE`, já timelocked, do
/// `EmissaoGateway` apontado por `gateway` — este contrato, por ser clonado por oferta, não
/// possui `AccessControl` próprio (mesmo raciocínio de "autorização por endereço único"
/// documentado em `ParticipacaoToken`/CLAUDE.md, "Arquitetura da Fase 1").
///
/// Regra de arredondamento (simplificação deliberada desta fase, ver CLAUDE.md): todo aporte
/// deve ser múltiplo exato de `precoPorCota`, para que `cotas = aporte / precoPorCota` nunca
/// deixe poeira. Aceitar valor livre e devolver o resto fica registrado como evolução futura.
///
/// O `tetoPorInvestidor` é só o limite desta oferta específica. O teto ANUAL CRUZADO ENTRE
/// PLATAFORMAS previsto na Resolução CVM 88 é OFF-CHAIN e AUTO-DECLARATÓRIO — este contrato
/// não tem, e não pode ter, visibilidade de aportes do mesmo investidor em outras
/// plataformas, e não garante esse teto agregado.
contract OfertaCaptacao is Initializable, PausableUpgradeable, ReentrancyGuard, IOfertaCaptacao {
    using SafeERC20 for IERC20;

    /// @notice Mesmo papel operacional definido em `EmissaoGateway` — consultado via `gateway`
    /// para autorizar `cancelar()`, sem que este clone precise de `AccessControl` próprio.
    bytes32 public constant AGENTE_ROLE = keccak256("AGENTE_ROLE");

    /// @notice Teto rígido de taxa nesta fase — ver "Decisões travadas" no CLAUDE.md.
    uint256 public constant TAXA_BPS_MAXIMA = 100;
    uint256 public constant BPS_DENOMINADOR = 10_000;

    /// @notice `ParticipacaoToken` é um ERC-20 padrão de 18 casas (herdado de
    /// `ERC20Upgradeable`, sem override de `decimals()`) — "1 cota inteira" corresponde a
    /// `1 ether` (1e18) em unidade bruta do token, mesma convenção já usada na Fase 1
    /// (`gateway.emitir(token, investidor, 100 ether)` == 100 cotas). `aportado / precoPorCota`
    /// dá a CONTAGEM adimensional de cotas; multiplicar por `UNIDADE_COTA` reescala essa
    /// contagem para a unidade bruta que `mint`/`cotasAutorizadas` esperam.
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

    /// @dev Trava a implementação-template — só clones inicializados via `initialize` são
    /// utilizáveis.
    constructor() {
        _disableInitializers();
    }

    modifier onlyAgente() {
        if (!IAccessControl(gateway).hasRole(AGENTE_ROLE, msg.sender)) revert NaoAutorizado();
        _;
    }

    /// @notice Inicializa o clone (roda uma única vez, no clone). Parâmetros agrupados em
    /// struct (ver `IOfertaCaptacao.InitParams`) para evitar "stack too deep".
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

    /// @notice Aporta `valor` de `moeda` na captação (escrow). Exige múltiplo exato de
    /// `precoPorCota`, respeita a meta máxima e, para investidores não qualificados, o teto
    /// por investidor desta oferta.
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

    /// @notice Encerra a captação (permissionless): válido ao atingir o prazo ou a meta máxima
    /// antes dele. Sucesso se `totalArrecadado >= metaMinima` (fechamento parcial permitido).
    function encerrar() external {
        if (estado != Estado.Aberta) revert OfertaNaoAberta();
        if (block.timestamp < prazo && totalArrecadado != metaMaxima) revert EncerramentoPrematuro();

        estado = totalArrecadado >= metaMinima ? Estado.EncerradaSucesso : Estado.EncerradaFalha;
        emit OfertaEncerrada(estado, totalArrecadado);
    }

    /// @notice Poder protetivo do AGENTE: cancela a captação ainda aberta, movendo-a para
    /// fracasso/reembolso. Nunca retém dinheiro — apenas devolve.
    function cancelar() external onlyAgente {
        if (estado != Estado.Aberta) revert OfertaNaoAberta();
        estado = Estado.EncerradaFalha;
        emit OfertaCancelada();
    }

    /// @notice Resgata (pull, uma vez) as cotas proporcionais ao aporte do chamador, só após
    /// sucesso. O mint é feito via `gateway.emitirParaCaptacao`, que checa que este contrato é
    /// a captação autorizada daquele token.
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

    /// @notice Libera (pull, uma vez, permissionless) o arrecadado ao emissor e a taxa ao
    /// protocolo, só após sucesso.
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

    /// @notice Reembolsa (pull, uma vez) exatamente o aporte do chamador, só após fracasso.
    function reembolsar() external nonReentrant {
        if (estado != Estado.EncerradaFalha) revert OfertaNaoEncerradaComFalha();
        if (reembolsado[msg.sender]) revert JaReembolsado();
        uint256 aportado = aportadoPor[msg.sender];
        if (aportado == 0) revert NadaAReembolsar();

        reembolsado[msg.sender] = true;

        emit Reembolso(msg.sender, aportado);

        moeda.safeTransfer(msg.sender, aportado);
    }

    /// @notice Pausa novos aportes em caso de emergência. Não afeta encerramento, resgate,
    /// reembolso nem liberação — o direito de saque dos investidores nunca fica congelado.
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
