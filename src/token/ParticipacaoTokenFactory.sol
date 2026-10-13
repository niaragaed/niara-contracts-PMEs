// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {TimelockedAccessControl} from "../governance/TimelockedAccessControl.sol";
import {IParticipacaoToken} from "../interfaces/IParticipacaoToken.sol";

/// @title ParticipacaoTokenFactory
/// @notice Creates one offering (a `ParticipacaoToken` cloned via EIP-1167) per call, pointing at
/// the current `EmissaoGateway` and default transfer policy. Keeps the record of created
/// offerings: the evidentiary lineage of this platform's cap tables.
/// @dev EIP-1167 clones do not run a constructor: `Clones.clone(implementacao)` followed by
/// `initialize(...)` on the clone is the correct sequence. The template implementation must
/// have `_disableInitializers()` in its own constructor (see `ParticipacaoToken`); otherwise
/// someone could initialize the template directly.
contract ParticipacaoTokenFactory is TimelockedAccessControl, Pausable {
    /// @notice Operational role: agent/platform authorized to create offerings and pause the
    /// factory.
    bytes32 public constant AGENTE_ROLE = keccak256("AGENTE_ROLE");

    /// @notice Address of the implementation (template) cloned for each new offering.
    address public implementacao;

    /// @notice `EmissaoGateway` set as `gateway` on every new clone.
    address public gateway;

    /// @notice Transfer policy set on every new clone (Phase 1:
    /// `DenyAllTransferPolicy`).
    address public transferPolicyPadrao;

    /// @notice Every offering (token) created so far, in creation order.
    address[] public ofertas;

    /// @notice `true` for every token address created by this factory.
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

    /// @notice Creates a new offering: clones `implementacao` and initializes it pointing at the
    /// current `gateway` and `transferPolicyPadrao`.
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

    /// @notice Total number of offerings created so far.
    function numOfertas() external view returns (uint256) {
        return ofertas.length;
    }

    function pause() external onlyRole(AGENTE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(AGENTE_ROLE) {
        _unpause();
    }

    // ── Implementation swap (subject to the timelock; only affects future offerings) ───────

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

    // ── Default transfer policy change (subject to the timelock; only affects future offerings) ──

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
