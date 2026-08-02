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

/// @title LiquidacaoSecundaria
/// @notice Liquidação de cessões bilaterais de cotas já pareadas pela plataforma — NÃO é um
/// order book: não há livro de ofertas, não há matching engine, não há função de "criar ordem
/// aberta". A plataforma (AGENTE) pareia comprador e vendedor off-chain e submete a cessão já
/// casada; ambas as partes pré-aprovam as allowances necessárias antes da submissão. Esse
/// desenho materializa a intermediação exigida pela Resolução CVM 88 para o mercado secundário
/// de valores mobiliários ofertados por dispensa de registro — evitando a semântica de
/// marketplace peer-to-peer irrestrito.
/// @dev PROTÓTIPO EM TESTNET, SEM AUDITORIA EXTERNA. Padrão adaptado de `NiaraSettlement` da
/// exchange (`niara-contracts`, referência somente-leitura, ver Linhagem no CLAUDE.md):
/// liquidação atômica three-party (comprador/vendedor/protocolo) operando por `allowance` — este
/// contrato NUNCA custodia `MockBRL` nem cotas, só move o que já foi pré-aprovado, numa única
/// transação atômica.
///
/// A checagem de elegibilidade (secundário liberado, lock-up, allowlist do comprador) é feita
/// UMA VEZ pelo próprio `ParticipacaoToken` dentro de `_update`, ao consultar a
/// `RestrictedTransferPolicy` vigente — este contrato não reimplementa essa lógica. O
/// `canTransfer` chamado aqui antes da troca é só um pre-flight (`view`, sem efeito) para
/// reverter cedo com um erro claro; a garantia final, a que efetivamente bloqueia a
/// transferência de cotas caso a política negue, continua sendo o `_update` do token.
///
/// Ligar o secundário de verdade (a `RestrictedTransferPolicy` retornar `true`) depende de
/// lock-up decorrido E autorização de negócio/jurídica da plataforma — inteiramente fora deste
/// contrato (ver `RestrictedTransferPolicy`/CLAUDE.md).
///
/// Conferido item a item contra `NiaraSettlement.t.sol` da exchange (ver CLAUDE.md, "Decisões
/// travadas — Fase 4"). Reentrância pelo lado do ATIVO (a cota) não tem teste dedicado, ao
/// contrário do `NiaraSettlement` — lá o ativo é um ERC-20 arbitrário e precisa ser tratado como
/// potencialmente malicioso; aqui `token` já passou por `factory.isOferta`, ou seja, é sempre um
/// `ParticipacaoToken` clonado da implementação única desta plataforma. O caminho de
/// `transferFrom` desse token (`_update` → `ITransferPolicy.canTransfer`, uma `view` sem efeito
/// colateral, → `super._update` do ERC20 padrão da OZ) não tem nenhum hook externo com código
/// controlável por terceiro — não há superfície de reentrância para testar nesse lado sem forjar
/// um "ParticipacaoToken" artificial que nunca existiria em produção.
contract LiquidacaoSecundaria is TimelockedAccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Mesmo papel operacional das demais peças da plataforma — submeter uma cessão já
    /// casada é por-negociação, não pode esperar o timelock.
    bytes32 public constant AGENTE_ROLE = keccak256("AGENTE_ROLE");

    /// @notice Teto rígido de taxa nesta fase — mesma disciplina de `OfertaCaptacao.TAXA_BPS_MAXIMA`.
    /// A alíquota do secundário é independente da alíquota da primária (`OfertaCaptacao.taxaBps`).
    uint256 public constant TAXA_BPS_MAXIMA = 100;
    uint256 public constant BPS_DENOMINADOR = 10_000;

    /// @notice `ParticipacaoToken` é um ERC-20 padrão de 18 casas — "1 cota inteira" corresponde
    /// a `1 ether` em unidade bruta (mesma convenção das Fases 1/2). `precoPorCota` é o preço de
    /// UMA cota inteira em `MockBRL` (mesmo significado de `OfertaCaptacao.precoPorCota`);
    /// `quantidade` é a quantia de cotas movida em unidade bruta do token (a mesma escala
    /// passada a `transferFrom`, sem exigir que o chamador rescale nada à parte). `valor` reescala
    /// o produto de volta para a unidade de "cota inteira" antes de multiplicar pelo preço —
    /// omitir essa reescala multiplicaria o preço por uma fração ínfima da cota, o mesmo bug de
    /// escala já pego e corrigido em `OfertaCaptacao.resgatarCotas` na Fase 2 (ver CLAUDE.md).
    uint256 public constant UNIDADE_COTA = 1 ether;

    /// @notice Moeda de liquidação (mock de testnet, ver `MockBRL`).
    IERC20 public immutable moeda;

    /// @notice Factory usada para validar que um token é uma oferta genuína desta plataforma
    /// antes de liquidar qualquer cessão sobre ele.
    IParticipacaoTokenFactory public immutable factory;

    /// @notice Carteira do protocolo, destino da taxa do secundário. Trocável via timelock.
    address public protocoloWallet;

    /// @notice Alíquota do secundário, em bps, com teto rígido de `TAXA_BPS_MAXIMA`. Dormente
    /// (default `0`) nesta fase — ver "Regras inegociáveis" no CLAUDE.md.
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

    /// @notice Anti-evasão por fracionamento: se a taxa está ativa (`taxaSecundarioBps > 0`)
    /// mas `valor` é pequeno o bastante para a divisão inteira truncar `taxa` a zero, a
    /// liquidação reverte em vez de passar sem cobrar nada. Sem essa guarda, uma cessão grande
    /// poderia ser fatiada em muitas cessões minúsculas, cada uma com taxa arredondada a zero,
    /// fugindo da taxa inteira — mesma proteção do `NiaraSettlement`
    /// (`PaymentAmountTooSmallForFeePrecision`) da exchange. Inócua enquanto a taxa do
    /// secundário estiver dormente (`0`, ver "Regras inegociáveis" no CLAUDE.md), mas fecha a
    /// brecha antes dela ser ativada.
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

    /// @notice Liquida uma cessão bilateral já casada pela plataforma: `vendedor` cede
    /// `quantidade` de `token` a `comprador`, que paga `quantidade` cotas ao preço
    /// `precoPorCota` em `MockBRL`. Requer que `vendedor` já tenha aprovado este contrato para
    /// mover suas cotas, e que `comprador` já tenha aprovado para mover seu `MockBRL` — este
    /// contrato nunca custodia nenhum dos dois ativos, só move o que já foi pré-aprovado, numa
    /// única transação atômica (qualquer revert desfaz tudo, inclusive as pernas de `MockBRL`
    /// já executadas antes do `transferFrom` do token).
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

        // Ordem das pernas: pagamento (comprador→vendedor→protocolo) antes do ativo
        // (vendedor→comprador), na direção OPOSTA ao NiaraSettlement (ativo primeiro, depois
        // pagamento). Deliberado, não um descuido: sendo tudo atômico, a ordem não muda o
        // resultado final, mas manter o transferFrom do TOKEN por último reforça, no próprio
        // código, o que já está documentado no NatSpec do contrato — o pre-flight de
        // `canTransfer` acima é só para reverter cedo com um erro claro; a checagem que
        // efetivamente autoriza a cessão é o `_update` do token, disparado por essa última
        // chamada, então ela fica posicionada como o gate final da sequência.
        moeda.safeTransferFrom(comprador, vendedor, valorVendedor);
        if (taxa > 0) moeda.safeTransferFrom(comprador, protocoloWallet, taxa);
        IERC20(token).safeTransferFrom(vendedor, comprador, quantidade);
    }

    /// @notice Pausa `liquidarCessao` em caso de emergência — mesmo papel operacional
    /// (`AGENTE_ROLE`) usado para pausa em `ParticipacaoTokenFactory`/`OfertaCaptacaoFactory`,
    /// não um papel novo (`PAUSER_ROLE`, como na referência) — este repositório já tem um único
    /// papel operacional por contrato, e criar um segundo só para pausa fragmentaria esse
    /// padrão sem necessidade.
    function pause() external onlyRole(AGENTE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(AGENTE_ROLE) {
        _unpause();
    }

    // ── Troca de protocoloWallet (sujeita a timelock — endereço sensível) ─────────────────

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

    // ── Troca da taxa do secundário (sujeita a timelock — decisão sensível de protocolo) ──

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

    /// @dev A checagem de teto é repetida aqui, além do `propose` — inalcançável pelo fluxo
    /// normal (só existe proposta pendente para um `novaTaxa` que já passou pela checagem em
    /// `proposeSetTaxaSecundarioBps`), mas mantida como defesa em profundidade contra o
    /// parâmetro de `execute` divergir do que foi de fato proposto.
    function executeSetTaxaSecundarioBps(uint256 novaTaxa) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (novaTaxa > TAXA_BPS_MAXIMA) revert TaxaExcedeMaximo(novaTaxa, TAXA_BPS_MAXIMA);
        bytes32 actionId = keccak256(abi.encode("SET_TAXA_SECUNDARIO_BPS", novaTaxa));
        _consumeAction(actionId);
        uint256 taxaAntiga = taxaSecundarioBps;
        taxaSecundarioBps = novaTaxa;
        emit TaxaSecundarioBpsChanged(taxaAntiga, novaTaxa);
    }
}
