// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ITransferPolicy} from "../interfaces/ITransferPolicy.sol";
import {IParticipacaoToken} from "../interfaces/IParticipacaoToken.sol";

/// @title ParticipacaoToken
/// @notice Cota de participação de uma oferta (Resolução CVM 88), clonada via EIP-1167 a
/// partir de uma implementação única por `ParticipacaoTokenFactory` — um clone por oferta.
/// Nunca é cunhada além do teto de cotas autorizadas nos atos societários da empresa,
/// atestado pelo `EmissaoGateway` (ver invariante em `mint`). Secundário desligado por padrão
/// via `ITransferPolicy` plugável.
/// @dev PROTÓTIPO EM TESTNET, SEM AUDITORIA EXTERNA. Este registro on-chain é prova
/// complementar — NÃO substitui os livros societários exigidos pela Lei 6.404/76 nem o
/// registro em cartório/junta comercial. É um token de valor mobiliário sob a Resolução CVM
/// 88, com transferência secundária restrita por política plugável (nega-tudo nesta fase).
///
/// Clones EIP-1167 não executam o construtor da implementação — por isso nome/símbolo e
/// metadados são definidos em `initialize()` (que roda no clone), não no construtor. A
/// implementação-template chama `_disableInitializers()` no construtor para nunca poder ser
/// inicializada diretamente.
contract ParticipacaoToken is Initializable, ERC20Upgradeable, PausableUpgradeable, IParticipacaoToken {
    /// @notice Teto de cotas autorizadas nos atos societários — atestado pelo `gateway`.
    /// Invariante central: `totalSupply() <= cotasAutorizadas`, sempre.
    uint256 public cotasAutorizadas;

    /// @notice Endereço autorizado a atestar cotas e cunhar (o `EmissaoGateway`).
    address public gateway;

    /// @notice Política consultada em toda transferência titular→titular.
    address public transferPolicy;

    /// @notice Razão social ou nome fantasia da empresa emissora.
    string public empresa;

    /// @notice Hash/referência do CNPJ da empresa — sem PII em claro on-chain.
    bytes32 public cnpjRef;

    /// @notice Identificador da série/rodada de captação (ex.: "2026-A").
    string public serie;

    event CotasAutorizadasAlteradas(uint256 tetoAntigo, uint256 tetoNovo);
    event CotasEmitidas(address indexed to, uint256 amount);

    error ZeroAddress();
    error NaoAutorizado();
    error CotasAutorizadasNaoPodemDiminuir(uint256 atual, uint256 solicitado);
    error MintExcedeCotasAutorizadas(uint256 totalSolicitado, uint256 cotasAutorizadas);
    error TransferenciaNaoPermitida();

    /// @dev Trava a implementação-template — só clones inicializados via `initialize` são
    /// utilizáveis.
    constructor() {
        _disableInitializers();
    }

    modifier onlyGateway() {
        if (msg.sender != gateway) revert NaoAutorizado();
        _;
    }

    /// @notice Inicializa o clone (roda uma única vez, no clone). `cotasAutorizadas` começa
    /// em zero — a primeira atestação eleva o teto antes de qualquer mint ser possível.
    function initialize(
        string memory nome_,
        string memory simbolo_,
        address gateway_,
        address transferPolicy_,
        string memory empresa_,
        bytes32 cnpjRef_,
        string memory serie_
    ) external initializer {
        if (gateway_ == address(0) || transferPolicy_ == address(0)) revert ZeroAddress();

        __ERC20_init(nome_, simbolo_);
        __Pausable_init();

        gateway = gateway_;
        transferPolicy = transferPolicy_;
        empresa = empresa_;
        cnpjRef = cnpjRef_;
        serie = serie_;
    }

    /// @notice Eleva o teto de cotas autorizadas (atestação societária). Política desta fase:
    /// o teto só pode aumentar — reduzir cotas autorizadas já emitidas exigiria um processo
    /// societário próprio (ex.: redução de capital), fora do escopo deste contrato.
    function setCotasAutorizadas(uint256 novoTeto) external onlyGateway {
        if (novoTeto < cotasAutorizadas) revert CotasAutorizadasNaoPodemDiminuir(cotasAutorizadas, novoTeto);
        uint256 tetoAntigo = cotasAutorizadas;
        cotasAutorizadas = novoTeto;
        emit CotasAutorizadasAlteradas(tetoAntigo, novoTeto);
    }

    /// @notice Cunha `amount` de cotas para `to`, desde que o total emitido resultante não
    /// exceda `cotasAutorizadas`.
    /// @dev Esta checagem é estrutural: vive neste contrato, não apenas no controle de acesso
    /// de quem chama — mesmo que `onlyGateway` fosse contornado, a trava contra diluição além
    /// do atestado permaneceria.
    function mint(address to, uint256 amount) external onlyGateway {
        uint256 totalSolicitado = totalSupply() + amount;
        if (totalSolicitado > cotasAutorizadas) revert MintExcedeCotasAutorizadas(totalSolicitado, cotasAutorizadas);
        _mint(to, amount);
        emit CotasEmitidas(to, amount);
    }

    function pause() external onlyGateway {
        _pause();
    }

    function unpause() external onlyGateway {
        _unpause();
    }

    /// @dev Mint/burn (`from`/`to` == address(0)) passam direto. Transferência titular→titular
    /// consulta `transferPolicy` — nesta fase, `DenyAllTransferPolicy` sempre nega.
    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        if (from != address(0) && to != address(0)) {
            if (!ITransferPolicy(transferPolicy).canTransfer(address(this), from, to, value)) {
                revert TransferenciaNaoPermitida();
            }
        }
        super._update(from, to, value);
    }
}
