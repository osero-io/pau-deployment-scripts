# pau-deployment-scripts

Deployment orchestration for the PAU system: a one-shot deploy
script + Makefile that stand up a shared ALMProxy, one or more PAU stacks
(AccessControls / RateLimits / Controller), and AdministeredAgents via the canonical on-chain
factories — handing sole admin to governance (PauseProxy / SubProxy). The deployer holds no role
on anything, so there is nothing to revoke.

All mutable configuration (roles, integrations, allocator grants) is left to the activation
spell, which calls the component repos' internal init libraries — `PAUInit`
(`sky-ecosystem/diamond-pau`) and `AdministeredAgentInit`
(`sky-ecosystem/pau-administered-agent`) — with the addresses this deployment exports.

## Layout

```text
.
├── script/
│   ├── DeployPAU.s.sol                  # one-shot PAU system deploy (JSON in/out)
│   ├── dependencies/
│   │   ├── PAUDeploy.sol                # deploy one PAU stack via the canonical PAUFactory
│   │   └── AdministeredAgentDeploy.sol  # deploy one AdministeredAgent via its factory
│   ├── input/
│   │   └── {chainId}/
│   │       └── deploy-pau.json          # owner, pauFactory, agentFactory, beacon, stackCount, agentCount
│   └── output/
│       └── {chainId}/
│           └── deploy-pau-latest.json   # exported addresses + deployBlock + deployer (generated)
└── test/
    ├── base-fork/                       # Base input: deploy + activation through the Osero Executor on Base
    ├── mainnet-fork/                    # deploy + init fork tests against the canonical factories
    ├── post-deploy/                     # verifies a real deployment's output JSON against mined logs
    └── utils/
        └── SpellHarness.sol             # governance-proxy stand-in that runs the init libraries
```

## Usage

```bash
cp .env.example .env    # set MAINNET_RPC_URL
forge build
forge test
```

Deploy (see the `Makefile` for the full target list):

```bash
make test-postdeploy-mainnet-simulate   # runs the script on a fork and verifies the result
make deploy-pau-mainnet-dryrun
make deploy-pau-mainnet
make test-postdeploy-mainnet            # required before the spell is written from the output JSON
```

### Post-deploy verification

`forge script` exports the addresses it *simulated*, predicted from the factories' nonces. The
factories are permissionless, so any factory call mined between simulation and broadcast shifts
the real addresses: the exported ones may then belong to contracts created by someone else, for
someone else. `test/post-deploy/` asserts, for every exported contract, that:

- the canonical factory emitted its `<Component>Deployed` event for that exact address (and, for
  Controllers, with this stack's AccessControls / ALMProxy / RateLimits as constructor arguments);
- its complete log history is the single constructor admin grant to `owner` (sender = factory)
  and nothing else — the only way to prove sole admin on the non-enumerable ALMProxy / RateLimits;
- `owner` is admin, no `CONTROLLER` / `ALLOCATOR` role is granted yet, Controller wiring and
  beacon match, and the output agrees with `script/input/{chainId}/deploy-pau.json`.

The same assertions run in two modes:

- `make test-postdeploy-mainnet-simulate` (`POSTDEPLOY_SIMULATE=true`): runs `DeployPAU.s.sol` on
  a mainnet fork inside the test and checks what it produced from the logs recorded while it ran.
  Use it before deploying to prove the script and input file work against the live factories.
  The script's output file is restored afterwards.
- `make test-postdeploy-mainnet` (`POSTDEPLOY_OUTPUT=<path>`): reconciles the exported
  `script/output/{chainId}/deploy-pau-latest.json` against the chain from mined logs
  (`eth_getLogs` on `MAINNET_RPC_URL`). Run it after the real deployment and
  before the activation spell, which legitimately adds events. Logs are scanned from the
  export's `deployBlock` (the block the script was simulated at, a lower bound on the blocks the
  deploy transactions landed in) up to the fork block, so the window is a few blocks wide and
  fits any RPC's block-range cap; `POSTDEPLOY_FROM_BLOCK` overrides it. Pin `POSTDEPLOY_BLOCK`
  to a block right after the deployment for a reproducible run. Every `Deployed` log's mined
  transaction is also fetched and asserted to have been sent by the export's `deployer` to the
  factory, so verify mode needs forge >= 1.8.

The suite is skipped when neither variable is set. Both modes fork the `POSTDEPLOY_RPC` alias
(default `mainnet`); input and output paths follow the fork's chain id.

### Base (chain 8453)

`script/input/8453/deploy-pau.json` deploys one stack and one AdministeredAgent, owned by the
Osero Executor on Base (`0x5528A5A043F74C2250c0d0983E4633F38395e19F`). That Executor only runs
spells the Osero SubProxy relays from Ethereum Mainnet, through the Osero Receiver on Base
(`0x63B4A33770F58205F3D646C5A635fF417a3819C3`). The SubProxy itself is not an account on Base, so
it must not be `owner` here. The factories and Beacon are the ones in Atlas
A.2.2.10.1.1.1.2.3.3 - Base; `sky-pau-registry` has no Base file yet.

```bash
export BASE_RPC_URL=<base rpc> ETH_FROM=<base deployer>
make test-fork-base                  # deploy + activate through the live Osero Executor on a Base fork
make test-postdeploy-base-simulate   # runs the script on a Base fork and verifies the result
make deploy-pau-base-dryrun
make deploy-pau-base                 # Ledger: DEPLOY_SIGNER="--ledger --mnemonic-derivation-paths \"<hd-path>\""
POSTDEPLOY_BLOCK=<final-deployment-block> make test-postdeploy-base
```

`test/base-fork/` pins Base block 53474900 and reads the Base input file, so changing the input
is covered by those tests.
