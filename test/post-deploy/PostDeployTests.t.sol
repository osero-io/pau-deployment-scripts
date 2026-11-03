// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { VmSafe } from "../../lib/forge-std/src/Vm.sol";

import { DeployPAUScript } from "../../script/DeployPAU.s.sol";

import {
    IAccessControlEnumerableLike,
    IAdministeredAgentFactoryEvents,
    IAdministeredAgentLike,
    IControllerLike,
    IPAUFactoryEvents,
    IPAUFactoryLike,
    PostDeployTestBase
} from "./PostDeployTestBase.t.sol";

/**
 * @notice Post-deploy verification of a `DeployPAU.s.sol` run, driven by logs.
 *
 *         `forge script` predicts the factory-created addresses from the factories' nonces during
 *         simulation and exports *those* to the output JSON. Anyone can call the permissionless
 *         factories between simulation and inclusion, so the exported addresses can end up
 *         belonging to contracts created by someone else, for someone else, possibly with
 *         governance added as a co-admin so the activation spell still passes. This suite
 *         reconciles the exported JSON against the chain and must pass before the activation
 *         spell is written from it.
 *
 *         Per exported contract it proves:
 *           - provenance: the canonical factory emitted `<Component>Deployed` for that address,
 *                         and (verify mode) the transaction behind that log was sent by the
 *                         export's `deployer` to the factory,
 *           - admin set:  its complete log history is the single constructor grant to `owner`
 *                         (sender = factory) and nothing else,
 *           - state:      `owner` is admin, no activation has happened, Controller wiring matches.
 *
 * @dev    Modes (both fork the `POSTDEPLOY_RPC` alias or URL, default `mainnet`, optionally at
 *         `POSTDEPLOY_BLOCK`, default latest; input and output paths follow the fork's chain id):
 *
 *         - `POSTDEPLOY_OUTPUT=<path>`: verify a real deployment. The path is relative to the
 *           project root (e.g. `script/output/1/deploy-pau-latest.json`); logs come from the
 *           chain via `eth_getLogs`, scanned from the export's `deployBlock` (the block the
 *           script was simulated at, a lower bound on the deploy blocks) up to the fork block, so
 *           the window is only a few blocks wide and fits any RPC's block-range cap. Override
 *           the scan start with `POSTDEPLOY_FROM_BLOCK`. Pin `POSTDEPLOY_BLOCK` to a block right
 *           after the deployment for a reproducible run. A `deployBlock` that is too high can
 *           only make the scan miss the deploy logs (a false failure), never a false pass.
 *
 *         - `POSTDEPLOY_SIMULATE=true`: run `DeployPAUScript` on the fork inside the test (from
 *           `script/input/{chainId}/deploy-pau.json`), then verify what it produced from the
 *           logs recorded while it ran. Proves the script deploys correctly against the live
 *           factories before spending gas. The script's `deploy-pau-latest.json` is restored
 *           afterwards, so a simulate run never overwrites a real export.
 *
 *         Skipped when neither is set so plain `forge test` stays green. See the Makefile
 *         `test-postdeploy-*` targets.
 */
contract PostDeployTests is PostDeployTestBase {

    string internal outputPath;
    string internal output;

    address internal owner;
    address internal pauFactory;
    address internal agentFactory;
    address internal almProxy;
    address internal beacon;

    address[] internal accessControls;
    address[] internal rateLimits;
    address[] internal controllers;
    address[] internal agents;

    function setUp() public {
        bool simulateEnv = vm.envOr("POSTDEPLOY_SIMULATE", false);

        outputPath = vm.envOr("POSTDEPLOY_OUTPUT", string(""));

        if (!simulateEnv && bytes(outputPath).length == 0) {
            vm.skip(true);
            return;
        }

        string memory rpc       = vm.envOr("POSTDEPLOY_RPC", string("mainnet"));
        uint256       forkBlock = vm.envOr("POSTDEPLOY_BLOCK", uint256(0));

        if (forkBlock == 0) vm.createSelectFork(rpc);
        else                vm.createSelectFork(rpc, forkBlock);

        if (simulateEnv) {
            outputPath = string.concat(
                "script/output/", vm.toString(block.chainid), "/deploy-pau-latest.json"
            );

            output = _runDeployScript(outputPath);
        } else {
            output = vm.readFile(string.concat(vm.projectRoot(), "/", outputPath));
        }

        deployer     = vm.parseJsonAddress(output, ".deployer");
        owner        = vm.parseJsonAddress(output, ".owner");
        pauFactory   = vm.parseJsonAddress(output, ".pauFactory");
        agentFactory = vm.parseJsonAddress(output, ".agentFactory");
        almProxy     = vm.parseJsonAddress(output, ".almProxy");
        beacon       = vm.parseJsonAddress(output, ".beacon");

        accessControls = vm.parseJsonAddressArray(output, ".accessControls");
        rateLimits     = vm.parseJsonAddressArray(output, ".rateLimits");
        controllers    = vm.parseJsonAddressArray(output, ".controllers");
        agents         = vm.parseJsonAddressArray(output, ".allocatorAgents");

        require(accessControls.length > 0,                    "PostDeployTests/no-stacks");
        require(rateLimits.length  == accessControls.length,  "PostDeployTests/rate-limits-length");
        require(controllers.length == accessControls.length,  "PostDeployTests/controllers-length");

        // Scan logs from the block the script was simulated at (a lower bound on the deploy
        // blocks) unless overridden, so the `eth_getLogs` window stays a few blocks wide. Only
        // used in verify mode; simulate mode reads the recorded logs.
        fromBlock = vm.envOr("POSTDEPLOY_FROM_BLOCK", vm.parseJsonUint(output, ".deployBlock"));

        require(fromBlock <= block.number, "PostDeployTests/from-block-after-fork-block");
    }

    /**
     * @dev Runs the deploy script on the current fork while recording logs, returns the output
     *      JSON it wrote, and puts the output file back exactly as it was before (or removes it
     *      if it did not exist).
     */
    function _runDeployScript(string memory relativePath) internal returns (string memory) {
        string memory fullPath = string.concat(vm.projectRoot(), "/", relativePath);

        bool          existed  = vm.exists(fullPath);
        string memory previous = existed ? vm.readFile(fullPath) : "";

        _startRecordingLogs();

        new DeployPAUScript().run();

        _stopRecordingLogs();

        string memory written = vm.readFile(fullPath);

        if (existed) vm.writeFile(fullPath, previous);
        else         vm.removeFile(fullPath);

        return written;
    }

    /**********************************************************************************************/
    /*** Output vs input                                                                        ***/
    /**********************************************************************************************/

    function test_output_matchesInputAndFactory() external view {
        string memory input = vm.readFile(string.concat(
            vm.projectRoot(), "/script/input/", vm.toString(block.chainid), "/deploy-pau.json"
        ));

        // 1. Check the exported fixed addresses are the ones the input asked for.
        assertEq(owner,        vm.parseJsonAddress(input, ".owner"),        "owner");
        assertEq(pauFactory,   vm.parseJsonAddress(input, ".pauFactory"),   "pauFactory");
        assertEq(agentFactory, vm.parseJsonAddress(input, ".agentFactory"), "agentFactory");
        assertEq(beacon,       vm.parseJsonAddress(input, ".beacon"),       "beacon");

        // 2. Check the export has exactly as many stacks and agents as the input asked for.
        assertEq(accessControls.length, vm.parseJsonUint(input, ".stackCount"), "stackCount");
        assertEq(agents.length,         vm.parseJsonUint(input, ".agentCount"), "agentCount");

        // 3. Check the exported beacon is what the canonical factory wires into every Controller.
        assertEq(IPAUFactoryLike(pauFactory).beacon(), beacon, "pauFactory.beacon()");
    }

    function test_output_addressesAreDistinct() external view {
        // 1. Gather every deployed address the export contains into one flat list.
        address[] memory exported = new address[](2 + 3 * accessControls.length + agents.length);

        uint256 count;

        exported[count++] = almProxy;
        exported[count++] = beacon;

        for (uint256 i = 0; i < accessControls.length; i++) {
            exported[count++] = accessControls[i];
            exported[count++] = rateLimits[i];
            exported[count++] = controllers[i];
        }

        for (uint256 i = 0; i < agents.length; i++) {
            exported[count++] = agents[i];
        }

        for (uint256 i = 0; i < exported.length; i++) {
            // 2. Check no slot was left unset (a missing JSON key parses as the zero address).
            assertNotEq(exported[i], address(0), "zero address exported");

            // 3. Check no address appears twice (a nonce-prediction slip would alias two slots).
            for (uint256 j = i + 1; j < exported.length; j++) {
                assertNotEq(exported[i], exported[j], "duplicate address exported");
            }
        }
    }

    /**********************************************************************************************/
    /*** ALMProxy (shared)                                                                      ***/
    /**********************************************************************************************/

    function test_almProxy_provenanceEventsAndState() external {
        // 1. Check the factory emitted ALMProxyDeployed for this exact address (provenance).
        _assertDeployedByFactory(
            pauFactory, IPAUFactoryEvents.ALMProxyDeployed.selector, almProxy, "almProxy"
        );

        // 2. Check the only event ever emitted is the constructor's RoleGranted(admin, owner)
        //    from the factory. ALMProxy is non-enumerable AccessControl, so the log history is
        //    the only way to prove `owner` is the *sole* admin: a front-run proxy shows a second
        //    RoleGranted here.
        _assertOnlyConstructorAdminGrant(almProxy, owner, pauFactory, "almProxy");

        // 3. Check the contract has code and `owner` holds DEFAULT_ADMIN_ROLE on-chain.
        _assertAdminState(almProxy, owner, "almProxy");

        // 4. Check no Controller holds CONTROLLER_ROLE yet (activation has not run).
        for (uint256 i = 0; i < controllers.length; i++) {
            _assertNoControllerRole(almProxy, controllers[i], _label("almProxy/controllers", i));
        }
    }

    /**********************************************************************************************/
    /*** Per-stack components                                                                   ***/
    /**********************************************************************************************/

    function test_accessControls_provenanceEventsAndState() external {
        for (uint256 i = 0; i < accessControls.length; i++) {
            string memory label = _label("accessControls", i);

            // 1. Check the factory emitted AccessControlsDeployed for this exact address
            //    (provenance).
            _assertDeployedByFactory(
                pauFactory,
                IPAUFactoryEvents.AccessControlsDeployed.selector,
                accessControls[i],
                label
            );

            // 2. Check the only event ever emitted is the constructor's RoleGranted(admin, owner)
            //    from the factory: no extra admins, no revocations.
            _assertOnlyConstructorAdminGrant(accessControls[i], owner, pauFactory, label);

            // 3. Check the contract has code and `owner` holds DEFAULT_ADMIN_ROLE on-chain.
            _assertAdminState(accessControls[i], owner, label);

            // 4. Check the sole-admin claim at the state level too: AccessControls is enumerable,
            //    so this corroborates the log-derived proof in step 2.
            IAccessControlEnumerableLike enumerableAccessControls =
                IAccessControlEnumerableLike(accessControls[i]);

            assertEq(
                enumerableAccessControls.getRoleMemberCount(DEFAULT_ADMIN_ROLE),
                1,
                string.concat(label, ": admin count")
            );

            // 5. Check no allocator has been onboarded yet (activation has not run).
            assertEq(
                enumerableAccessControls.getRoleMemberCount(ALLOCATOR_ROLE),
                0,
                string.concat(label, ": allocator count")
            );
        }
    }

    function test_rateLimits_provenanceEventsAndState() external {
        for (uint256 i = 0; i < rateLimits.length; i++) {
            string memory label = _label("rateLimits", i);

            // 1. Check the factory emitted RateLimitsDeployed for this exact address (provenance).
            _assertDeployedByFactory(
                pauFactory, IPAUFactoryEvents.RateLimitsDeployed.selector, rateLimits[i], label
            );

            // 2. Check the only event ever emitted is the constructor's RoleGranted(admin, owner)
            //    from the factory. RateLimits is non-enumerable, same reasoning as the ALMProxy.
            _assertOnlyConstructorAdminGrant(rateLimits[i], owner, pauFactory, label);

            // 3. Check the contract has code and `owner` holds DEFAULT_ADMIN_ROLE on-chain.
            _assertAdminState(rateLimits[i], owner, label);

            // 4. Check this stack's Controller does not hold CONTROLLER_ROLE yet (activation has
            //    not run).
            _assertNoControllerRole(rateLimits[i], controllers[i], label);
        }
    }

    function test_controllers_provenanceEventsAndState() external {
        for (uint256 i = 0; i < controllers.length; i++) {
            string memory label = _label("controllers", i);

            // 1. Check the factory emitted ControllerDeployed for this exact address (provenance).
            VmSafe.EthGetLogs memory controllerDeployedLog = _assertDeployedByFactory(
                pauFactory, IPAUFactoryEvents.ControllerDeployed.selector, controllers[i], label
            );

            // 2. Check the constructor args the factory used are *this* stack's exported
            //    components, not the simulation's.
            (
                address deployedAccessControls,
                address deployedProxy,
                address deployedRateLimits
            ) = abi.decode(controllerDeployedLog.data, (address, address, address));

            assertEq(
                deployedAccessControls,
                accessControls[i],
                string.concat(label, ": ControllerDeployed.accessControls")
            );
            assertEq(
                deployedProxy,
                almProxy,
                string.concat(label, ": ControllerDeployed.proxy")
            );
            assertEq(
                deployedRateLimits,
                rateLimits[i],
                string.concat(label, ": ControllerDeployed.rateLimits")
            );

            // 3. Check the only event ever emitted is the constructor's Initialized(1): nothing
            //    else has happened since (no updateIntegrations, no facet configuration).
            VmSafe.EthGetLogs[] memory logs = _getLogs(controllers[i]);

            assertEq(logs.length, 1, string.concat(label, ": log count"));
            _assertInitializedEvent(logs[0], label);

            // 4. Check the contract has code and its immutable wiring matches the export.
            IControllerLike controller = IControllerLike(controllers[i]);

            assertGt(controllers[i].code.length, 0, string.concat(label, ": no code"));

            assertEq(
                controller.accessControls(),
                accessControls[i],
                string.concat(label, ": accessControls()")
            );
            assertEq(controller.beacon(), beacon,   string.concat(label, ": beacon()"));
            assertEq(controller.proxy(),  almProxy, string.concat(label, ": proxy()"));
            assertEq(
                controller.rateLimits(),
                rateLimits[i],
                string.concat(label, ": rateLimits()")
            );

            // 5. Check no integrations have been registered yet.
            assertEq(controller.integrations().length, 0, string.concat(label, ": integrations"));
        }
    }

    /**********************************************************************************************/
    /*** AdministeredAgents                                                                     ***/
    /**********************************************************************************************/

    function test_allocatorAgents_provenanceEventsAndState() external {
        for (uint256 i = 0; i < agents.length; i++) {
            string memory label = _label("allocatorAgents", i);

            // 1. Check the agent factory emitted AdministeredAgentDeployed for this exact address
            //    (provenance).
            _assertDeployedByFactory(
                agentFactory,
                IAdministeredAgentFactoryEvents.AdministeredAgentDeployed.selector,
                agents[i],
                label
            );

            // 2. Check the only event ever emitted is the constructor's
            //    AdminAdded(owner, caller = factory): no admin changes since.
            VmSafe.EthGetLogs[] memory logs = _getLogs(agents[i]);

            assertEq(logs.length, 1, string.concat(label, ": log count"));
            _assertAdminAddedEvent(logs[0], owner, agentFactory, label);

            // 3. Check the contract has code and the owner is the sole admin.
            IAdministeredAgentLike agent = IAdministeredAgentLike(agents[i]);

            assertGt(agents[i].code.length, 0, string.concat(label, ": no code"));

            assertEq(agent.adminCount(), 1, string.concat(label, ": adminCount"));

            assertEq(agent.getAdmin(0), owner, string.concat(label, ": getAdmin(0)"));
            assertTrue(agent.getIsAdmin(owner), string.concat(label, ": owner not admin"));

            // 4. Check no actors / grantors / revokers have been added yet.
            assertEq(agent.actorCount(),   0, string.concat(label, ": actorCount"));
            assertEq(agent.grantorCount(), 0, string.concat(label, ": grantorCount"));
            assertEq(agent.revokerCount(), 0, string.concat(label, ": revokerCount"));

            // 5. Check the agent is not onboarded as ALLOCATOR on any AccessControls yet.
            for (uint256 j = 0; j < accessControls.length; j++) {
                IAccessControlEnumerableLike enumerableAccessControls =
                    IAccessControlEnumerableLike(accessControls[j]);

                assertEq(
                    enumerableAccessControls.getRoleMemberCount(ALLOCATOR_ROLE),
                    0,
                    string.concat(label, ": allocator already granted")
                );
            }
        }
    }

}
