// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {TimelockedAccessControl} from "../governance/TimelockedAccessControl.sol";

/// @dev Interfaces mínimas, LOCAIS a este arquivo — deliberadamente não adicionadas a
/// `src/interfaces/` nem misturadas às interfaces já existentes (`IEmissaoGateway`,
/// `IParticipacaoTokenFactory`, `IOfertaCaptacao`). Mantém esta fase 100% aditiva: nenhum
/// arquivo fora de `src/orquestracao/` é criado ou tocado. Cada uma expõe só a função que o
/// orquestrador realmente chama — mesmo princípio de acoplamento mínimo já usado nas
/// interfaces compartilhadas do restante do repositório, só que sem relação `is` com o
/// contrato concreto: a chamada funciona por casamento de seletor ABI (o mesmo mecanismo por
/// trás de qualquer `IERC20(token).transfer(...)` chamado num token que nunca declarou
/// `is IERC20`). Nem `ParticipacaoTokenFactory`, nem `EmissaoGateway`, nem `OfertaCaptacaoFactory`
/// declaram `is` de nenhuma dessas — conferido no código-fonte antes de escrever isto.
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

/// @dev Espelha `OfertaCaptacao.Estado` só pela representação ABI (enums codificam como
/// `uint8`, na ordem de declaração) — NÃO foi adicionada a `IOfertaCaptacao.sol` de propósito.
/// `OfertaCaptacao is IOfertaCaptacao`: estender aquela interface com este enum exigiria que
/// `OfertaCaptacao` retornasse EXATAMENTE o tipo do enum da interface — Solidity trata enums
/// de escopos diferentes como tipos distintos, mesmo com os mesmos membros na mesma ordem —
/// um erro de compilação que só se resolveria editando `OfertaCaptacao.sol`, proibido nesta
/// fase. Uma interface totalmente local, sem relação `is` com o contrato concreto, evita o
/// problema por completo (mesmo raciocínio das interfaces acima).
interface IOfertaCaptacaoEstadoDoOrquestrador {
    enum Estado {
        Aberta,
        EncerradaSucesso,
        EncerradaFalha
    }

    function estado() external view returns (Estado);
}

/// @title OfertaOrquestrador
/// @notice Permite que a própria empresa emissora (autorizada previamente pela plataforma)
/// crie sua oferta de captação — hoje um privilégio exclusivo do AGENTE — numa única
/// transação atômica, sem ganhar poder sobre parâmetros sensíveis da plataforma.
/// @dev PROTÓTIPO EM TESTNET, SEM AUDITORIA EXTERNA. Nenhum contrato existente muda de
/// comportamento: este contrato apenas encadeia, como qualquer chamador externo poderia,
/// as quatro chamadas que já existiam (`ParticipacaoTokenFactory.criarOferta` →
/// `EmissaoGateway.atestarCotas` → `OfertaCaptacaoFactory.criarCaptacao` →
/// `EmissaoGateway.registrarCaptacao`), detendo `AGENTE_ROLE` nos três contratos-alvo. A
/// atomicidade não é uma lógica de rollback escrita à mão — é a semântica nativa da EVM: se
/// qualquer subchamada reverter, a transação inteira (incluindo os `Clones.clone` já
/// executados) é desfeita.
///
/// Limitação regulatória deliberada, documentada e não resolvida aqui — mesma camada onde já
/// vive o teto anual do INVESTIDOR (ver `OfertaCaptacao`/`RegistroInvestidorQualificado`): o
/// teto anual AGREGADO DO EMISSOR previsto na Resolução CVM 88 (captações somadas em TODAS as
/// plataformas de crowdfunding, não só nesta) é OFF-CHAIN e AUTO-DECLARATÓRIO. Este contrato
/// não tem, e não pode ter, visibilidade de quanto uma empresa já captou em outra plataforma
/// no mesmo período — impor esse teto sobre `metaMaxima` desta oferta isolada estaria errado
/// por construção (uma oferta com teto de R$ 15.000.000 que capta apenas R$ 1.000.000 não
/// deveria consumir a janela agregada inteira do emissor), e impor sobre `totalArrecadado`
/// acoplaria este contrato ao ciclo de vida de cada `OfertaCaptacao`, que ele deliberadamente
/// não acompanha após a criação (só lê `estado()` da última oferta para a trava de "uma aberta
/// por vez", não para fins de teto financeiro). Nenhuma automação deve descrever
/// `criarOfertaCompleta`, sozinho, como suficiente para cumprir esse teto agregado.
contract OfertaOrquestrador is TimelockedAccessControl, Pausable {
    /// @notice Papel operacional: agente/plataforma autorizado a gerir a allowlist de
    /// emissores e a pausa de emergência do canal self-service.
    bytes32 public constant AGENTE_ROLE = keccak256("AGENTE_ROLE");

    /// @notice Teto de captação por oferta (Resolução CVM 88), na unidade do `MockBRL` (18
    /// casas, conferido em `src/mocks/MockBRL.sol`) — R$ 15.000.000.
    uint256 public constant TETO_OFERTA = 15_000_000 ether;

    /// @notice Prazo máximo de uma captação (Resolução CVM 88).
    uint256 public constant PRAZO_MAXIMO = 180 days;

    /// @notice Lote adicional máximo de 25% sobre `metaMinima`, expresso como razão inteira:
    /// `metaMaxima * LOTE_ADICIONAL_DENOMINADOR <= metaMinima * LOTE_ADICIONAL_NUMERADOR`.
    uint256 public constant LOTE_ADICIONAL_NUMERADOR = 125;
    uint256 public constant LOTE_ADICIONAL_DENOMINADOR = 100;

    /// @notice `ParticipacaoToken` tem 18 casas — "1 cota inteira" é `1 ether` em unidade
    /// bruta (mesma convenção de `OfertaCaptacao.UNIDADE_COTA`, ver CLAUDE.md).
    uint256 public constant UNIDADE_COTA = 1 ether;

    /// @notice Mesmo teto rígido de taxa já usado em `OfertaCaptacao`/`OfertaCaptacaoFactory`/
    /// `LiquidacaoSecundaria` — independente de todos os outros, ver CLAUDE.md.
    uint256 internal constant TAXA_BPS_MAXIMA = 100;

    /// @notice `ParticipacaoTokenFactory` apontado — fixado na construção, sem setter nesta
    /// fase (mesma decisão já registrada para `OfertaCaptacaoFactory.gateway`/`registro`/
    /// `moeda`, ver CLAUDE.md "Pendências conhecidas").
    address public immutable tokenFactory;

    /// @notice `EmissaoGateway` apontado — fixado na construção, sem setter nesta fase.
    address public immutable emissaoGateway;

    /// @notice `OfertaCaptacaoFactory` apontado — fixado na construção, sem setter nesta fase.
    address public immutable captacaoFactory;

    /// @notice Carteira do protocolo usada em toda captação criada por este orquestrador —
    /// nunca visível nem influenciável pelo emissor. Trocável via timelock.
    address public protocoloWallet;

    /// @notice Taxa (bps) usada em toda captação criada por este orquestrador — nunca visível
    /// nem influenciável pelo emissor. Trocável via timelock, sempre <= `TAXA_BPS_MAXIMA`.
    uint256 public taxaBps;

    /// @notice Teto por investidor usado em toda captação criada por este orquestrador — nunca
    /// visível nem influenciável pelo emissor. Trocável via timelock.
    uint256 public tetoPorInvestidor;

    /// @notice `true` para todo endereço autorizado, pelo AGENTE, a criar sua própria oferta.
    /// Gestão imediata, sem timelock — autorizar um emissor não dá poder sobre dinheiro de
    /// terceiros, só a capacidade de criar a própria oferta com parâmetros fixados pela
    /// plataforma (ver PLANO_OFERTA_ORQUESTRADOR.md).
    mapping(address => bool) public emissoresAutorizados;

    /// @notice Todas as ofertas (endereços de `OfertaCaptacao`) já criadas por cada emissor,
    /// na ordem de criação — histórico completo para reconciliação por emissor.
    mapping(address => address[]) public ofertasPorEmissor;

    /// @notice Última oferta criada por cada emissor — consultada para impedir uma segunda
    /// oferta enquanto a anterior estiver `Aberta`.
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

    // ── Allowlist de emissores (AGENTE_ROLE, imediato — ver decisão travada) ──────────────

    function autorizarEmissor(address emissor) external onlyRole(AGENTE_ROLE) {
        if (emissor == address(0)) revert ZeroAddress();
        emissoresAutorizados[emissor] = true;
        emit EmissorAutorizado(emissor);
    }

    function revogarEmissor(address emissor) external onlyRole(AGENTE_ROLE) {
        emissoresAutorizados[emissor] = false;
        emit EmissorRevogado(emissor);
    }

    // ── Pausa de emergência do canal self-service (AGENTE_ROLE, imediata) ─────────────────
    // `whenNotPaused` vive só em `criarOfertaCompleta`: a pausa desliga a criação self-service
    // sem afetar a criação manual pela plataforma (as factories têm sua própria pausa
    // independente) nem qualquer oferta já criada — aporte, encerramento, resgate, reembolso e
    // liberação seguem funcionando, mesmo princípio de `OfertaCaptacao.pausar` (ver CLAUDE.md).

    function pause() external onlyRole(AGENTE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(AGENTE_ROLE) {
        _unpause();
    }

    // ── Criação atômica ─────────────────────────────────────────────────────────────────────

    /// @notice Cria uma oferta completa (token + captação) para o emissor que chama, com os
    /// quatro passos de `criarOferta` → `atestarCotas` → `criarCaptacao` → `registrarCaptacao`
    /// executados atomicamente. `emissorWallet` é sempre `msg.sender` (não é parâmetro);
    /// `taxaBps`, `protocoloWallet` e `tetoPorInvestidor` vêm sempre do storage deste
    /// contrato, nunca de calldata do emissor.
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

        // `precoPorCota == 0` precisa reverter ANTES do módulo abaixo — em ^0.8, `x % 0`
        // reverte com Panic(0x12), opaco e intraduzível no frontend. O check nomeado das
        // factories a jusante (`OfertaCaptacaoFactory.PrecoInvalido`) nunca seria alcançado,
        // porque o pânico dispara primeiro, então precisa ser checado aqui também.
        if (precoPorCota == 0) revert PrecoInvalido();
        if (prazo <= block.timestamp) revert PrazoInvalido(prazo);
        if (prazo - block.timestamp > PRAZO_MAXIMO) revert PrazoExcedeLimite(prazo, PRAZO_MAXIMO);
        if (metaMaxima > TETO_OFERTA) revert MetaMaximaExcedeTeto(metaMaxima, TETO_OFERTA);
        if (metaMaxima * LOTE_ADICIONAL_DENOMINADOR > metaMinima * LOTE_ADICIONAL_NUMERADOR) {
            revert LoteAdicionalExcedeLimite(metaMaxima, metaMinima);
        }
        if (metaMaxima % precoPorCota != 0) revert PrecoNaoDivideMetaMaxima(metaMaxima, precoPorCota);
        // `metaMinima == 0` / `metaMinima > metaMaxima` NÃO são reverificados aqui de propósito:
        // `OfertaCaptacaoFactory.criarCaptacao` já reverte com `MetasInvalidas` nesses casos, e
        // qualquer revert numa subchamada desfaz atomicamente as subchamadas já executadas —
        // duplicar a checagem não fecharia lacuna nenhuma, só repetiria lógica já garantida a
        // jusante (ver CLAUDE.md, princípio já seguido nas fases anteriores).

        token = ITokenFactoryDoOrquestrador(tokenFactory).criarOferta(nome, simbolo, empresa, cnpjRef, serie);

        uint256 cotasAutorizadas = (metaMaxima / precoPorCota) * UNIDADE_COTA;
        IEmissaoGatewayDoOrquestrador(emissaoGateway).atestarCotas(token, cotasAutorizadas);

        oferta = ICaptacaoFactoryDoOrquestrador(captacaoFactory).criarCaptacao(
            token, metaMinima, metaMaxima, precoPorCota, prazo, tetoPorInvestidor, taxaBps, msg.sender, protocoloWallet
        );

        IEmissaoGatewayDoOrquestrador(emissaoGateway).registrarCaptacao(token, oferta);

        ofertasPorEmissor[msg.sender].push(oferta);
        ultimaOfertaDoEmissor[msg.sender] = oferta;

        emit OfertaCompletaCriada(msg.sender, token, oferta, metaMinima, metaMaxima, precoPorCota, prazo);
    }

    /// @notice Número total de ofertas já criadas por `emissor`, desde o início.
    function numOfertasDoEmissor(address emissor) external view returns (uint256) {
        return ofertasPorEmissor[emissor].length;
    }

    // ── Parâmetros de plataforma (DEFAULT_ADMIN_ROLE, timelock) ───────────────────────────

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

    function proposeSetTaxaBps(uint256 novaTaxaBps) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 executeAfter) {
        if (novaTaxaBps > TAXA_BPS_MAXIMA) revert TaxaExcedeMaximo(novaTaxaBps, TAXA_BPS_MAXIMA);
        bytes32 actionId = keccak256(abi.encode("SET_TAXA_BPS", novaTaxaBps));
        executeAfter = _scheduleAction(actionId);
        emit TaxaBpsChangeProposed(novaTaxaBps, executeAfter);
    }

    /// @dev Repete a checagem do teto no `execute`, não só no `propose` — mesma lição já
    /// aplicada em `LiquidacaoSecundaria.executeSetTaxaSecundarioBps` (ver CLAUDE.md,
    /// "Conferência contra NiaraSettlement"): sem isso, chamar `execute` diretamente, sem um
    /// `propose` correspondente, ainda reverteria em `_consumeAction` (nenhuma ação pendente)
    /// — mas por segurança em profundidade, o teto é validado nos dois lugares.
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
