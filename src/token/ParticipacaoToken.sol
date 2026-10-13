// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ITransferPolicy} from "../interfaces/ITransferPolicy.sol";
import {IParticipacaoToken} from "../interfaces/IParticipacaoToken.sol";

/// @title ParticipacaoToken (participation share token)
/// @notice An offering's participation share (CVM Resolution 88), cloned via EIP-1167 from a
/// single implementation by `ParticipacaoTokenFactory`: one clone per offering. It is never
/// minted beyond the cap of shares authorized in the company's corporate acts, attested by
/// the `EmissaoGateway` (see the invariant in `mint`). Secondary market off by default via a
/// pluggable `ITransferPolicy`.
/// @dev TESTNET PROTOTYPE, NO EXTERNAL AUDIT. This on-chain record is complementary evidence:
/// it does NOT replace the corporate books required by Law 6,404/76 nor registration with a
/// notary/commercial registry. It is a security token under CVM Resolution 88, with secondary
/// transfers restricted by a pluggable policy (deny-all in this phase).
///
/// EIP-1167 clones do not run the implementation's constructor, so name/symbol and metadata
/// are set in `initialize()` (which runs on the clone), not in the constructor. The template
/// implementation calls `_disableInitializers()` in its constructor so it can never be
/// initialized directly.
contract ParticipacaoToken is Initializable, ERC20Upgradeable, PausableUpgradeable, IParticipacaoToken {
    /// @notice Cap of shares authorized in the corporate acts, attested by the `gateway`.
    /// Core invariant: `totalSupply() <= cotasAutorizadas`, always.
    uint256 public cotasAutorizadas;

    /// @notice Address authorized to attest shares and mint (the `EmissaoGateway`).
    address public gateway;

    /// @notice Policy read on every holder→holder transfer.
    address public transferPolicy;

    /// @notice Legal or trade name of the issuing company.
    string public empresa;

    /// @notice Hash/reference of the company's CNPJ: no plaintext PII on-chain.
    bytes32 public cnpjRef;

    /// @notice Identifier of the fundraising series/round (e.g. "2026-A").
    string public serie;

    event CotasAutorizadasAlteradas(uint256 tetoAntigo, uint256 tetoNovo);
    event CotasEmitidas(address indexed to, uint256 amount);
    event TransferPolicyAlterada(address indexed politicaAntiga, address indexed politicaNova);

    error ZeroAddress();
    error NaoAutorizado();
    error CotasAutorizadasNaoPodemDiminuir(uint256 atual, uint256 solicitado);
    error MintExcedeCotasAutorizadas(uint256 totalSolicitado, uint256 cotasAutorizadas);
    error TransferenciaNaoPermitida();

    /// @dev Locks the template implementation: only clones initialized via `initialize` are
    /// usable.
    constructor() {
        _disableInitializers();
    }

    modifier onlyGateway() {
        if (msg.sender != gateway) revert NaoAutorizado();
        _;
    }

    /// @notice Initializes the clone (runs once, on the clone). `cotasAutorizadas` starts at
    /// zero: the first attestation raises the cap before any mint is possible.
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

    /// @notice Raises the authorized share cap (corporate attestation). Policy in this phase:
    /// the cap can only increase; reducing authorized shares already issued would require its own
    /// corporate process (e.g. a capital reduction), outside the scope of this contract.
    function setCotasAutorizadas(uint256 novoTeto) external onlyGateway {
        if (novoTeto < cotasAutorizadas) revert CotasAutorizadasNaoPodemDiminuir(cotasAutorizadas, novoTeto);
        uint256 tetoAntigo = cotasAutorizadas;
        cotasAutorizadas = novoTeto;
        emit CotasAutorizadasAlteradas(tetoAntigo, novoTeto);
    }

    /// @notice Mints `amount` shares to `to`, as long as the resulting total supply does not
    /// exceed `cotasAutorizadas`.
    /// @dev This check is structural: it lives in this contract, not only in the caller's
    /// access control. Even if `onlyGateway` were bypassed, the lock against dilution beyond what
    /// was attested would remain.
    function mint(address to, uint256 amount) external onlyGateway {
        uint256 totalSolicitado = totalSupply() + amount;
        if (totalSolicitado > cotasAutorizadas) revert MintExcedeCotasAutorizadas(totalSolicitado, cotasAutorizadas);
        _mint(to, amount);
        emit CotasEmitidas(to, amount);
    }

    /// @notice Changes the transfer policy read on every holder→holder transfer. It did not
    /// exist until Phase 3; it was added here (instead of only in the factory, which only affects
    /// future offerings) to allow changing the policy of an already-live offering, e.g. moving
    /// from `DenyAllTransferPolicy` to `RestrictedTransferPolicy` once the fundraising has closed.
    /// Restricted to the `gateway`, which only exposes it via
    /// `EmissaoGateway.proposeSetTransferPolicy`/`executeSetTransferPolicy` (timelock: changing
    /// the policy is a sensitive decision, see CLAUDE.md).
    function setTransferPolicy(address novaPolitica) external onlyGateway {
        if (novaPolitica == address(0)) revert ZeroAddress();
        address politicaAntiga = transferPolicy;
        transferPolicy = novaPolitica;
        emit TransferPolicyAlterada(politicaAntiga, novaPolitica);
    }

    function pause() external onlyGateway {
        _pause();
    }

    function unpause() external onlyGateway {
        _unpause();
    }

    /// @dev Mint/burn (`from`/`to` == address(0)) go straight through. A holder→holder transfer
    /// reads `transferPolicy`; in this phase, `DenyAllTransferPolicy` always denies.
    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        if (from != address(0) && to != address(0)) {
            if (!ITransferPolicy(transferPolicy).canTransfer(address(this), from, to, value)) {
                revert TransferenciaNaoPermitida();
            }
        }
        super._update(from, to, value);
    }
}
