// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {RegistroInvestidorQualificado} from "../src/registro/RegistroInvestidorQualificado.sol";

contract RegistroInvestidorQualificadoTest is Test {
    RegistroInvestidorQualificado public registro;

    address public admin = makeAddr("admin");
    address public agent = makeAddr("agente");
    address public stranger = makeAddr("estranho");
    address public investidor = makeAddr("investidor");

    uint256 public constant TIMELOCK_DELAY = 1 hours;
    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 public agentRole;

    function setUp() public {
        registro = new RegistroInvestidorQualificado(admin, TIMELOCK_DELAY);
        agentRole = registro.AGENTE_ROLE();
        _grantRole(agentRole, agent);
    }

    function _grantRole(bytes32 role, address account) internal {
        vm.prank(admin);
        registro.proposeGrantRole(role, account);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(admin);
        registro.executeGrantRole(role, account);
    }

    // ── Construtor ──────────────────────────────────────────────────────────────────────

    function test_Constructor_RevertsForZeroAdmin() public {
        vm.expectRevert(RegistroInvestidorQualificado.ZeroAddress.selector);
        new RegistroInvestidorQualificado(address(0), TIMELOCK_DELAY);
    }

    function test_Constructor_GrantsAdminRole() public view {
        assertTrue(registro.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    // ── definirQualificado ──────────────────────────────────────────────────────────────

    function test_DefinirQualificado_OnlyAgent() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, agentRole)
        );
        registro.definirQualificado(investidor, true);
    }

    function test_DefinirQualificado_SetsFlag() public {
        assertFalse(registro.ehQualificado(investidor));

        vm.prank(agent);
        registro.definirQualificado(investidor, true);

        assertTrue(registro.ehQualificado(investidor));
    }

    function test_DefinirQualificado_IsImmediateNoTimelock() public {
        // Operational action: no proposal/timelock involved, immediate effect.
        vm.prank(agent);
        registro.definirQualificado(investidor, true);
        assertTrue(registro.ehQualificado(investidor));
    }

    function test_DefinirQualificado_CanRevoke() public {
        vm.prank(agent);
        registro.definirQualificado(investidor, true);
        assertTrue(registro.ehQualificado(investidor));

        vm.prank(agent);
        registro.definirQualificado(investidor, false);
        assertFalse(registro.ehQualificado(investidor));
    }

    function test_DefinirQualificado_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(registro));
        emit RegistroInvestidorQualificado.QualificacaoAlterada(investidor, true);
        vm.prank(agent);
        registro.definirQualificado(investidor, true);
    }
}
