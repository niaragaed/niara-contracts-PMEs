// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {TimelockedAccessControl} from "../governance/TimelockedAccessControl.sol";
import {IOfertaCaptacao} from "../interfaces/IOfertaCaptacao.sol";

/// @title OfertaCaptacaoFactory
/// @notice Creates one fundraising (an `OfertaCaptacao` escrow cloned via EIP-1167) per call,
/// pointing at the current `EmissaoGateway`, `RegistroInvestidorQualificado` and currency
/// (`MockBRL`). Same clone discipline as Phase 1 (`ParticipacaoTokenFactory`).
/// @dev `gateway`, `registro` and `moeda` are fixed at construction, with no timelocked setter
/// in this phase (the same decision already recorded in CLAUDE.md's "Known open items" for
/// `ParticipacaoTokenFactory.gateway`). Only `implementacao` can be swapped via timelock, and
/// the swap only affects future fundraisings; clones already created keep the logic in effect
/// when they were cloned (same behavior tested in
/// `ParticipacaoTokenFactoryTest.test_SetImplementacao_OnlyAffectsFutureOffers`).
contract OfertaCaptacaoFactory is TimelockedAccessControl, Pausable {
    /// @notice Operational role: agent/platform authorized to create fundraisings and pause the
    /// factory.
    bytes32 public constant AGENTE_ROLE = keccak256("AGENTE_ROLE");

    uint256 internal constant TAXA_BPS_MAXIMA = 100;

    /// @notice Address of the implementation (template) cloned for each new fundraising.
    address public implementacao;

    /// @notice `EmissaoGateway` set as `gateway` on every new clone.
    address public immutable gateway;

    /// @notice `RegistroInvestidorQualificado` set as `registro` on every new clone.
    address public immutable registro;

    /// @notice Currency (`MockBRL`) set as `moeda` on every new clone.
    address public immutable moeda;

    /// @notice Every fundraising (escrow) created so far, in creation order.
    address[] public captacoes;

    /// @notice `true` for every fundraising address created by this factory.
    mapping(address => bool) public isCaptacao;

    event CaptacaoCriada(
        address indexed oferta,
        address indexed token,
        uint256 metaMinima,
        uint256 metaMaxima,
        uint256 precoPorCota,
        uint256 prazo
    );
    event ImplementacaoChangeProposed(address indexed novaImplementacao, uint256 executeAfter);
    event ImplementacaoChanged(address indexed implementacaoAntiga, address indexed implementacaoNova);

    error ZeroAddress();
    error MetasInvalidas(uint256 metaMinima, uint256 metaMaxima);
    error PrecoInvalido();
    error PrazoInvalido(uint256 prazo);
    error TaxaExcedeMaximo(uint256 taxaBps, uint256 maximo);

    constructor(
        address admin_,
        address implementacao_,
        address gateway_,
        address registro_,
        address moeda_,
        uint256 timelockDelay_
    ) TimelockedAccessControl(timelockDelay_) {
        if (
            admin_ == address(0) || implementacao_ == address(0) || gateway_ == address(0) || registro_ == address(0)
                || moeda_ == address(0)
        ) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        implementacao = implementacao_;
        gateway = gateway_;
        registro = registro_;
        moeda = moeda_;
    }

    /// @notice Creates a new fundraising: clones `implementacao` and initializes it pointing at
    /// the current `gateway`, `registro` and `moeda`.
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
    ) external onlyRole(AGENTE_ROLE) whenNotPaused returns (address oferta) {
        if (token == address(0) || emissorWallet == address(0) || protocoloWallet == address(0)) revert ZeroAddress();
        if (metaMinima == 0 || metaMinima > metaMaxima) revert MetasInvalidas(metaMinima, metaMaxima);
        if (precoPorCota == 0) revert PrecoInvalido();
        if (prazo <= block.timestamp) revert PrazoInvalido(prazo);
        if (taxaBps > TAXA_BPS_MAXIMA) revert TaxaExcedeMaximo(taxaBps, TAXA_BPS_MAXIMA);

        oferta = Clones.clone(implementacao);
        IOfertaCaptacao(oferta)
            .initialize(
                IOfertaCaptacao.InitParams({
                    token: token,
                    gateway: gateway,
                    registro: registro,
                    moeda: moeda,
                    emissorWallet: emissorWallet,
                    protocoloWallet: protocoloWallet,
                    metaMinima: metaMinima,
                    metaMaxima: metaMaxima,
                    precoPorCota: precoPorCota,
                    prazo: prazo,
                    tetoPorInvestidor: tetoPorInvestidor,
                    taxaBps: taxaBps
                })
            );

        captacoes.push(oferta);
        isCaptacao[oferta] = true;

        emit CaptacaoCriada(oferta, token, metaMinima, metaMaxima, precoPorCota, prazo);
    }

    /// @notice Total number of fundraisings created so far.
    function numCaptacoes() external view returns (uint256) {
        return captacoes.length;
    }

    function pause() external onlyRole(AGENTE_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(AGENTE_ROLE) {
        _unpause();
    }

    // ── Implementation swap (subject to the timelock; only affects future fundraisings) ────

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
}
