// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../lib/forge-std/src/Test.sol";

import {
    AdministeredAgentDeploy,
    AdministeredAgentDeployParams
} from "../../script/dependencies/AdministeredAgentDeploy.sol";

import { PAUDeploy, PAUDeployParams } from "../../script/dependencies/PAUDeploy.sol";

import {
    AdministeredAgentInit,
    AdministeredAgentInitParams
} from "../../lib/pau-administered-agent/deploy/AdministeredAgentInit.sol";

import { PAUInit, PAUInstance } from "../../lib/diamond-pau/deploy/PAUInit.sol";

interface IAccessControlLike {

    function hasRole(bytes32 role, address account) external view returns (bool);

}

interface IAccessControlEnumerableLike {

    function getRoleMemberCount(bytes32 role) external view returns (uint256);

}

interface IAdministeredAgentLike {

    function adminCount() external view returns (uint256);

    function getIsActor(address account) external view returns (bool);

    function getIsAdmin(address account) external view returns (bool);

    function getIsGrantor(address account) external view returns (bool);

    function getIsRevoker(address account) external view returns (bool);

}

interface IControllerLike {

    // Mirrors diamond-pau's IEnumerableIntegrations records (layout must match for ABI decoding).
    struct Wire {
        bytes4 callSelector;
        bytes4 delegateSelector;
    }

    struct Config {
        address facet;
        Wire[]  wires;
    }

    struct Integration {
        bytes32 id;
        Config  config;
    }

    function accessControls() external view returns (address);

    function beacon() external view returns (address);

    function integrations() external view returns (Integration[] memory);

    function proxy() external view returns (address);

    function rateLimits() external view returns (address);

}

interface IExecutorLike {

    function SUBMISSION_ROLE() external view returns (bytes32);

    function actionsSetCount() external view returns (uint256);

    function delay() external view returns (uint256);

    function execute(uint256 actionsSetId) external payable;

    function queue(
        address[] memory targets,
        uint256[] memory values,
        string[]  memory signatures,
        bytes[]   memory calldatas,
        bool[]    memory withDelegatecalls
    ) external;

}

interface IOptimismReceiverLike {

    function l1Authority() external view returns (address);

    function target() external view returns (address);

}

interface IPAUFactoryLike {

    function beacon() external view returns (address);

}

/**
 * @notice Stand-in for the Osero Base activation payload. The Osero Executor on Base runs it by
 *         delegatecall, so the inlined init libraries execute with the Executor as
 *         `address(this)` / `msg.sender`, exactly as the real spell will. Addresses are
 *         immutables (code, not storage), so they survive the delegatecall.
 */
contract BaseActivationPayloadMock {

    bytes32 internal constant CCTP_INTEGRATION_ID = "CCTP_FACET";

    address internal immutable accessControls;
    address internal immutable almProxy;
    address internal immutable beacon;
    address internal immutable controller;
    address internal immutable rateLimits;
    address internal immutable agent;
    address internal immutable actor;
    address internal immutable grantor;
    address internal immutable revoker;

    constructor(PAUInstance memory inst, address agent_, address[3] memory roles) {
        accessControls = inst.accessControls;
        almProxy       = inst.almProxy;
        beacon         = inst.beacon;
        controller     = inst.controller;
        rateLimits     = inst.rateLimits;
        agent          = agent_;
        actor          = roles[0];
        grantor        = roles[1];
        revoker        = roles[2];
    }

    function execute() external {
        PAUInstance memory inst = PAUInstance({
            accessControls : accessControls,
            almProxy       : almProxy,
            beacon         : beacon,
            controller     : controller,
            rateLimits     : rateLimits
        });

        bytes32[] memory integrationIds = new bytes32[](1);
        integrationIds[0] = CCTP_INTEGRATION_ID;

        PAUInit.init(inst, integrationIds);
        PAUInit.addAllocator(inst, agent);

        address[] memory actors = new address[](1);
        actors[0] = actor;

        address[] memory grantors = new address[](1);
        grantors[0] = grantor;

        address[] memory revokers = new address[](1);
        revokers[0] = revoker;

        AdministeredAgentInit.init(agent, AdministeredAgentInitParams({
            admins   : new address[](0),
            actors   : actors,
            grantors : grantors,
            revokers : revokers
        }));
    }

}

/**
 * @notice Base fork test for the Base deployment configuration
 *         (`script/input/8453/deploy-pau.json`). Deploys with that input through {PAUDeploy} /
 *         {AdministeredAgentDeploy} against the canonical Base factories, then activates through
 *         the live Osero governance relay on Base (Receiver -> Executor.queue -> execute ->
 *         delegatecall payload). This proves the configured `owner` can run the activation
 *         spell; the mainnet suite's SpellHarness cannot, since `owner` on Base is a fixed,
 *         already-deployed Executor.
 */
contract PAUDeployAndActivate_Base_Fork_Tests is Test {

    uint256 internal constant BASE_CHAIN_ID   = 8453;
    uint256 internal constant BASE_FORK_BLOCK = 53474900;

    // Osero governance relay on Base (osero-io/diamond-pau-deployment, `gov-relay/`).
    address internal constant OSERO_EXECUTOR = 0x5528A5A043F74C2250c0d0983E4633F38395e19F;
    address internal constant OSERO_RECEIVER = 0x63B4A33770F58205F3D646C5A635fF417a3819C3;

    // Osero SubProxy on Ethereum Mainnet: the Receiver's L1 authority. Not an account on Base.
    address internal constant OSERO_SUBPROXY = 0x24fdcd3bFA5C2553e05B2f9AD0365EBC296278D3;

    // Shared PAU contracts on Base: Atlas A.2.2.10.1.1.1.2.3.3 - Base.
    address internal constant ADMINISTERED_AGENT_FACTORY = 0xD711DbfD937a45e2C89CA0D4781cfa5BAb32e752;
    address internal constant BEACON                     = 0x7ac96180C4d6b2A328D3a19ac059D0E7Fc3C6d41;
    address internal constant CCTP_FACET                 = 0xb22d50c393c6E1D13E3e05B172448dD8BF8DdC32;
    address internal constant PAU_FACTORY                = 0x011A115b5498B85b3d12245A3a7296F77325B5C3;

    bytes32 internal constant ALLOCATOR_ROLE      = keccak256("ALLOCATOR_ROLE");
    bytes32 internal constant CCTP_INTEGRATION_ID = "CCTP_FACET";
    bytes32 internal constant CONTROLLER_ROLE     = keccak256("CONTROLLER");
    bytes32 internal constant DEFAULT_ADMIN_ROLE  = 0x00;

    address internal actor    = makeAddr("actor");
    address internal deployer = makeAddr("deployer");
    address internal grantor  = makeAddr("grantor");
    address internal revoker  = makeAddr("revoker");

    address internal owner;
    address internal pauFactory;
    address internal agentFactory;
    address internal beacon;
    uint256 internal stackCount;
    uint256 internal agentCount;

    function setUp() external {
        vm.createSelectFork("base", BASE_FORK_BLOCK);

        string memory input = vm.readFile(
            string.concat(vm.projectRoot(), "/script/input/8453/deploy-pau.json")
        );

        owner        = vm.parseJsonAddress(input, ".owner");
        pauFactory   = vm.parseJsonAddress(input, ".pauFactory");
        agentFactory = vm.parseJsonAddress(input, ".agentFactory");
        beacon       = vm.parseJsonAddress(input, ".beacon");
        stackCount   = vm.parseJsonUint(input,    ".stackCount");
        agentCount   = vm.parseJsonUint(input,    ".agentCount");
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _deployPAU(address owner_) internal returns (PAUInstance memory inst) {
        vm.prank(deployer);
        inst = this.deployPAUExternal(PAUDeployParams({ pauFactory: pauFactory, owner: owner_ }));
    }

    function _deployAgent(address owner_) internal returns (address agent) {
        vm.prank(deployer);
        agent = this.deployAgentExternal(
            AdministeredAgentDeployParams({ agentFactory: agentFactory, owner: owner_ })
        );
    }

    // External wrappers so the deploy libraries execute in a frame whose msg.sender can be
    // pranked to `deployer`.
    function deployPAUExternal(PAUDeployParams memory p)
        external
        returns (PAUInstance memory inst)
    {
        (inst.accessControls, inst.almProxy, inst.rateLimits, inst.controller) =
            PAUDeploy.deploy(p);

        inst.beacon = IPAUFactoryLike(p.pauFactory).beacon();
    }

    function deployAgentExternal(AdministeredAgentDeployParams memory p)
        external
        returns (address agent)
    {
        agent = AdministeredAgentDeploy.deploy(p);
    }

    /// @dev Queues `payload.execute()` on the Osero Executor exactly as a relayed spell message
    ///      from the Osero SubProxy would (the Receiver is the only submitter). With `delay == 0`
    ///      anyone can then `execute` the returned id in the same block.
    function _queueOnOseroExecutor(address payload) internal returns (uint256 actionsSetId) {
        address[] memory targets = new address[](1);
        targets[0] = payload;

        uint256[] memory values = new uint256[](1);

        string[] memory signatures = new string[](1);
        signatures[0] = "execute()";

        bytes[] memory calldatas = new bytes[](1);

        bool[] memory withDelegatecalls = new bool[](1);
        withDelegatecalls[0] = true;

        actionsSetId = IExecutorLike(OSERO_EXECUTOR).actionsSetCount();

        vm.prank(OSERO_RECEIVER);
        IExecutorLike(OSERO_EXECUTOR).queue(
            targets, values, signatures, calldatas, withDelegatecalls
        );

        assertEq(IExecutorLike(OSERO_EXECUTOR).delay(), 0, "executor delay");
    }

    /**********************************************************************************************/
    /*** Input Tests                                                                            ***/
    /**********************************************************************************************/

    function test_input_isBaseConfiguration() external view {
        assertEq(block.chainid, BASE_CHAIN_ID, "not a Base fork");

        // 1. Check the input points at the canonical Base PAU contracts.
        assertEq(pauFactory,   PAU_FACTORY,                "pauFactory");
        assertEq(agentFactory, ADMINISTERED_AGENT_FACTORY, "agentFactory");
        assertEq(beacon,       BEACON,                     "beacon");

        assertEq(IPAUFactoryLike(pauFactory).beacon(), beacon, "pauFactory.beacon()");
        assertGt(agentFactory.code.length, 0, "agentFactory has no code");

        // 2. Check `owner` is the Osero Executor on Base, not the (L1-only) Osero SubProxy.
        assertEq(owner, OSERO_EXECUTOR, "owner");
        assertNotEq(owner, OSERO_SUBPROXY, "owner is the L1 SubProxy");

        // 3. Check `owner` only acts on spells from the Osero SubProxy: the Receiver is its
        //    submitter and forwards only messages whose L1 sender is the SubProxy.
        assertTrue(
            IAccessControlLike(OSERO_EXECUTOR).hasRole(
                IExecutorLike(OSERO_EXECUTOR).SUBMISSION_ROLE(),
                OSERO_RECEIVER
            ),
            "receiver is not the executor's submitter"
        );
        assertEq(IOptimismReceiverLike(OSERO_RECEIVER).target(),      OSERO_EXECUTOR, "receiver.target()");
        assertEq(IOptimismReceiverLike(OSERO_RECEIVER).l1Authority(), OSERO_SUBPROXY, "receiver.l1Authority()");

        // 4. Check the counts match the planned topology: one stack, one AdministeredAgent.
        assertEq(stackCount, 1, "stackCount");
        assertEq(agentCount, 1, "agentCount");
    }

    /**********************************************************************************************/
    /*** Deploy Tests                                                                           ***/
    /**********************************************************************************************/

    function test_deploy_ownerIsSoleAdmin_deployerHasNothing() external {
        PAUInstance memory inst = _deployPAU(owner);
        address agent           = _deployAgent(owner);

        address[3] memory components = [inst.accessControls, inst.almProxy, inst.rateLimits];

        for (uint256 i = 0; i < components.length; i++) {
            assertTrue(
                IAccessControlLike(components[i]).hasRole(DEFAULT_ADMIN_ROLE, owner),
                "owner not admin"
            );
            assertFalse(
                IAccessControlLike(components[i]).hasRole(DEFAULT_ADMIN_ROLE, deployer),
                "deployer has admin"
            );
        }

        assertEq(
            IAccessControlEnumerableLike(inst.accessControls).getRoleMemberCount(DEFAULT_ADMIN_ROLE),
            1,
            "owner not sole admin"
        );

        assertEq(IControllerLike(inst.controller).accessControls(), inst.accessControls);
        assertEq(IControllerLike(inst.controller).proxy(),          inst.almProxy);
        assertEq(IControllerLike(inst.controller).beacon(),         BEACON);
        assertEq(IControllerLike(inst.controller).rateLimits(),     inst.rateLimits);

        assertEq(IAdministeredAgentLike(agent).adminCount(), 1);
        assertTrue(IAdministeredAgentLike(agent).getIsAdmin(owner));
        assertFalse(IAdministeredAgentLike(agent).getIsAdmin(deployer));
    }

    /**********************************************************************************************/
    /*** Activation Tests                                                                       ***/
    /**********************************************************************************************/

    function test_activate_throughOseroExecutor() external {
        PAUInstance memory inst = _deployPAU(owner);
        address agent           = _deployAgent(owner);

        address payload = address(
            new BaseActivationPayloadMock(inst, agent, [actor, grantor, revoker])
        );

        IExecutorLike(OSERO_EXECUTOR).execute(_queueOnOseroExecutor(payload));

        // 1. Check the Controller holds CONTROLLER on the ALMProxy and on its RateLimits.
        assertTrue(IAccessControlLike(inst.almProxy).hasRole(CONTROLLER_ROLE,   inst.controller));
        assertTrue(IAccessControlLike(inst.rateLimits).hasRole(CONTROLLER_ROLE, inst.controller));

        // 2. Check CCTP_FACET was imported from the Base Beacon.
        IControllerLike.Integration[] memory integrations =
            IControllerLike(inst.controller).integrations();

        assertEq(integrations.length,          1);
        assertEq(integrations[0].id,           CCTP_INTEGRATION_ID);
        assertEq(integrations[0].config.facet, CCTP_FACET);

        // 3. Check the agent is the stack's allocator and its roles are configured.
        assertTrue(IAccessControlLike(inst.accessControls).hasRole(ALLOCATOR_ROLE, agent));

        assertTrue(IAdministeredAgentLike(agent).getIsActor(actor));
        assertTrue(IAdministeredAgentLike(agent).getIsGrantor(grantor));
        assertTrue(IAdministeredAgentLike(agent).getIsRevoker(revoker));

        // 4. Check the Executor is still the sole admin and the deployer still holds nothing.
        assertEq(
            IAccessControlEnumerableLike(inst.accessControls).getRoleMemberCount(DEFAULT_ADMIN_ROLE),
            1
        );
        assertTrue(IAccessControlLike(inst.accessControls).hasRole(DEFAULT_ADMIN_ROLE, owner));
        assertFalse(IAccessControlLike(inst.accessControls).hasRole(DEFAULT_ADMIN_ROLE, deployer));

        assertEq(IAdministeredAgentLike(agent).adminCount(), 1);
        assertTrue(IAdministeredAgentLike(agent).getIsAdmin(owner));
    }

    /// @dev The failure mode the process doc warns about: on Base the Osero SubProxy is only an
    ///      L1 address. A stack owned by it can never be initialized by the Osero Executor.
    function test_activate_subProxyAsOwner_reverts() external {
        PAUInstance memory inst = _deployPAU(OSERO_SUBPROXY);
        address agent           = _deployAgent(OSERO_SUBPROXY);

        address payload = address(
            new BaseActivationPayloadMock(inst, agent, [actor, grantor, revoker])
        );

        uint256 actionsSetId = _queueOnOseroExecutor(payload);

        vm.expectRevert(bytes("PAUInit/not-access-controls-admin"));
        IExecutorLike(OSERO_EXECUTOR).execute(actionsSetId);
    }

}
