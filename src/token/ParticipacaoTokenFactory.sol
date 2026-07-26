// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {TimelockedAccessControl} from "../governance/TimelockedAccessControl.sol";
import {IParticipacaoToken} from "../interfaces/IParticipacaoToken.sol";

/// @title ParticipacaoTokenFactory
/// @notice Cria uma oferta (um `ParticipacaoToken` clonado via EIP-1167) por chamada,
/// apontando o `EmissaoGateway` e a política de transferência padrão vigentes. Mantém o
/// registro de ofertas criadas — a linhagem probatória de cap tables desta plataforma.
/// @dev Clones EIP-1167 não executam construtor: `Clones.clone(implementacao)` seguido de
/// `initialize(...)` no clone é a sequência correta. A implementação-template deve ter
/// `_disableInitializers()` no próprio construtor (ver `ParticipacaoToken`), do contrário
/// alguém poderia inicializar o template diretamente.
contract ParticipacaoTokenFactory is TimelockedAccessControl, Pausable {
    /// @notice Papel operacional: agente/plataforma autorizado a criar ofertas e pausar a
    /// factory.
    bytes32 public constant AGENTE_ROLE = keccak256("AGENTE_ROLE");

    /// @notice Endereço da implementação (template) clonada em cada nova oferta.
    address public implementacao;

    /// @notice `EmissaoGateway` apontado como `gateway` em todo novo clone.
    address public gateway;

    /// @notice Política de transferência apontada em todo novo clone (Fase 1:
    /// `DenyAllTransferPolicy`).
    address public transferPolicyPadrao;

    /// @notice Todas as ofertas (tokens) já criadas, na ordem de criação.
    address[] public ofertas;

    /// @notice `true` para todo endereço de token criado por esta factory.
    mapping(address => bool) public isOferta;

    event OfertaCriada(address indexed token, string empresa, bytes32 indexed cnpjRef, string serie);
    event ImplementacaoChangeProposed(address indexed novaImplementacao, uint256 executeAfter);
    event ImplementacaoChanged(address indexed implementacaoAntiga, address indexed implementacaoNova);
    event TransferPolicyPadraoChangeProposed(address indexed novaPolitica, uint256 executeAfter);
    event TransferPolicyPadraoChanged(address indexed politicaAntiga, address indexed politicaNova);

    error ZeroAddress();

    constructor(
        address admin_,
        address implementacao_,
        address gateway_,
        address transferPolicyPadrao_,
        uint256 timelockDelay_
    ) TimelockedAccessControl(timelockDelay_) {
        if (
            admin_ == address(0) || implementacao_ == address(0) || gateway_ == address(0)
                || transferPolicyPadrao_ == address(0)
        ) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        implementacao = implementacao_;
        gateway = gateway_;
        transferPolicyPadrao = transferPolicyPadrao_;
    }

    /// @notice Cria uma nova oferta: clona `implementacao` e a inicializa apontando o
    /// `gateway` e a `transferPolicyPadrao` vigentes.
    function criarOferta(
        string memory nome,
        string memory simbolo,
        string memory empresa,
        bytes32 cnpjRef,
        string memory serie
    ) external onlyRole(AGENTE_ROLE) whenNotPaused returns (address token) {
        token = Clones.clone(implementacao);
        IParticipacaoToken(token).initialize(nome, simbolo, gateway, transferPolicyPadrao, empresa, cnpjRef, serie);

        ofertas.push(token);
        isOferta[token] = true;

        emit OfertaCriada(token, empresa, cnpjRef, serie);
    }

    /// @notice Número total de ofertas já criadas.
    function numOfertas() external view returns (uint256) {
        return ofertas.length;
    }

    function pause() external onlyRole(AGENTE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(AGENTE_ROLE) {
        _unpause();
    }

    // ── Troca de implementação (sujeita a timelock — afeta só ofertas futuras) ────────────

    function proposeSetImplementacao(address novaImplementacao)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        if (novaImplementacao == address(0)) revert ZeroAddress();
        bytes32 actionId = keccak256(abi.encode("SET_IMPLEMENTACAO", novaImplementacao));
        executeAfter = _scheduleAction(actionId);
        emit ImplementacaoChangeProposed(novaImplementacao, executeAfter);
    }

    function executeSetImplementacao(address novaImplementacao) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 actionId = keccak256(abi.encode("SET_IMPLEMENTACAO", novaImplementacao));
        _consumeAction(actionId);
        address implementacaoAntiga = implementacao;
        implementacao = novaImplementacao;
        emit ImplementacaoChanged(implementacaoAntiga, novaImplementacao);
    }

    // ── Troca da política de transferência padrão (sujeita a timelock — afeta só ofertas futuras) ──

    function proposeSetTransferPolicyPadrao(address novaPolitica)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 executeAfter)
    {
        if (novaPolitica == address(0)) revert ZeroAddress();
        bytes32 actionId = keccak256(abi.encode("SET_TRANSFER_POLICY_PADRAO", novaPolitica));
        executeAfter = _scheduleAction(actionId);
        emit TransferPolicyPadraoChangeProposed(novaPolitica, executeAfter);
    }

    function executeSetTransferPolicyPadrao(address novaPolitica) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 actionId = keccak256(abi.encode("SET_TRANSFER_POLICY_PADRAO", novaPolitica));
        _consumeAction(actionId);
        address politicaAntiga = transferPolicyPadrao;
        transferPolicyPadrao = novaPolitica;
        emit TransferPolicyPadraoChanged(politicaAntiga, novaPolitica);
    }
}
