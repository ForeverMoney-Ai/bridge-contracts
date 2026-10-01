# Scripts

Reference for what each script does and what it needs. **The runbook — first deployment, adding a
token, adding a chain, gotchas — lives in [`docs/DEPLOYMENT.md`](../../docs/DEPLOYMENT.md).**

| Script | Chain | Purpose |
|---|---|---|
| `DeployGovernance.s.sol` | any | The `ADMIN` Timelock (proposer = the Safe, self-administered). Run FIRST, once per chain |
| `DeployAlpha.s.sol` `run()` | 964 | Vault + gateway (once per chain) + the first token, pool, CCIP registration, handoff |
| `DeployAlpha.s.sol` `addToken()` | 964 | List an additional token on an existing vault |
| `DeploySpoke.s.sol` | any spoke | Token + pool + shared gateway, CCIP registration, full handoff. Infra defaults to Base, env-overridable |
| `DeploySpokeGatewayOnly.s.sol` | any spoke | A new SpokeGateway next to an existing token/pool set, pointed at a (new) 964 gateway. No pool/registry/lane changes |
| `RegisterLane.s.sol` | either | Pair a local pool with its counterpart on one remote chain. Run on **both** sides |
| `VerifyWiring.s.sol` | either | Read-back assertion of a token's full wiring. Broadcasts nothing |
| `Config.sol` | — | CCIP infra addresses, selectors, launch rate limits (not a script) |

## Environment

Common to all: `PRIVATE_KEY`, plus the relevant RPC.

**`DeployGovernance`** — `MULTISIG` (must already be deployed); optional `DELAY` (default 2 days,
matching `AlphaVault.INITIAL_ADMIN_DELAY`) and `OPEN_EXECUTOR` (default false — only the multisig
executes matured proposals). Prints the Timelock address to pass as `ADMIN` everywhere else.

**`DeployAlpha.run()`** — `ADMIN`, `OPERATOR`, `GUARDIAN`, `EMISSIONS_RECIPIENT`, `VAULT_COLDKEY`,
`NETUID`, `VALIDATOR_HOTKEY`, `TOKEN_NAME`, `TOKEN_SYMBOL`; optional `RESCUER` (defaults to `ADMIN`),
`HANDOFF`.

> `VAULT_COLDKEY` must be computed off-chain as `blake2b_256("evm:" ++ <predicted vault address>)` —
> the EVM has no blake2b. The vault is the first contract the script deploys, so predict with
> `cast compute-address`. The script asserts the prediction held, and also **derives** the coldkey
> from the predicted address and compares it, so a coldkey for the wrong address is rejected before
> anything is deployed. `GATEWAY_COLDKEY` is checked the same way.
>
> That derivation shells out to `scripts/evm-coldkey.py`, so run `DeployAlpha` and `ResumeDeploy`
> with **`--ffi`**:
>
> ```bash
> forge script script/DeployAlpha.s.sol --rpc-url subtensor --broadcast --ffi
> ```

**`DeployAlpha.addToken()`** — `VAULT`, `NETUID`, `VALIDATOR_HOTKEY`, `TOKEN_NAME`, `TOKEN_SYMBOL`,
`ADMIN`, `GUARDIAN`, `HANDOFF`.

**`DeploySpoke`** — `SUBTENSOR_GATEWAY` (the 964 `AlphaGateway`), `ADMIN`, `GUARDIAN`, `HANDOFF`;
optional `TOKEN_NAME`/`TOKEN_SYMBOL` and `ROUTER`/`RMN_PROXY`/`TOKEN_ADMIN_REGISTRY`/`REGISTRY_MODULE`
(default to the Base values in `Cfg` — override to deploy another spoke chain).

**`DeploySpokeGatewayOnly`** — `SUBTENSOR_GATEWAY`, `FEE_ADMIN`, `FEE_RECIPIENT` (both a Safe, never
the deployer); optional `ROUTER` (default Base), `EXPECT_GATEWAY` (nonce guard).

**`RegisterLane`** — `LOCAL_POOL`, `REMOTE_POOL`, `REMOTE_TOKEN`, `REMOTE_SELECTOR`; optional
`RL_CAPACITY`, `RL_RATE`.

**`VerifyWiring`** — `TOKEN`, `POOL`, `REGISTRY`, `REMOTE_SELECTOR`, `REMOTE_POOL`, `REMOTE_TOKEN`;
optional `VAULT`, `GATEWAY` (964 only), `EXPECTED_ADMIN`, `DEPLOYER`.

## Notes

- **`HANDOFF=true` is the production mode.** It makes the role addresses required rather than
  silently defaulting to the broadcasting key, and asserts afterwards that the deployer kept nothing
  — including that its temporary `OPERATOR` was revoked and `ccipAdmin` moved to the operator.
- **Naming `ADMIN` requires naming `OPERATOR`**, even without `HANDOFF`. Token custody (registry
  admin + pool ownership) follows `OPERATOR`, so a run that hands over root while letting `OPERATOR`
  default to the deployer would keep `setPool` on the broadcasting hot key — a half-handover that
  used to happen silently. Both entry points now refuse it.
- **Listing is OPERATOR-gated, not `DEFAULT_ADMIN`.** `run()` grants the deployer `OPERATOR` for the
  duration of the run and revokes it in the handoff. `addToken()` requires the broadcaster to hold
  `OPERATOR` *and* to be `vault.ccipAdmin()` — post-handoff that is the multisig, no timelock.
- **964 needs `--evm-version london`** (and `--slow`). Later EVM versions emit opcodes the chain
  rejects.
- **Every handoff is 2-step.** The scripts only *start* them; the multisig must call
  `acceptAdminRole` (registry), `acceptOwnership` (pools) and `acceptDefaultAdminTransfer` (vault).
  Re-run `VerifyWiring` with `EXPECTED_ADMIN` afterwards to prove they landed.
- **All CCIP wiring must finish before handoff**, or the multisig has to execute it through the
  timelock — see the post-handoff batch in `docs/DEPLOYMENT.md`.

## Spot checks

```bash
# pool attached for a token
cast call $REGISTRY "getPool(address)(address)" $TOKEN --rpc-url $RPC

# who actually holds CCIP registry admin (does NOT follow getCCIPAdmin after registration)
cast call $REGISTRY "getTokenConfig(address)((address,address,address))" $TOKEN --rpc-url $RPC

# per-token backing: staked alpha (RAO) vs supply, and the harvestable surplus
cast call $VAULT "stakedValueRao(address)(uint256)"      $TOKEN --rpc-url $SUBTENSOR_RPC
cast call $TOKEN "totalSupply()(uint256)"                       --rpc-url $SUBTENSOR_RPC
cast call $VAULT "harvestableAlphaRao(address)(uint256)" $TOKEN --rpc-url $SUBTENSOR_RPC

# CCIP-layer mirror: Base supply vs tokens locked in the 964 pool
cast call $BASE_TOKEN "totalSupply()(uint256)"            --rpc-url $BASE_RPC
cast call $TOKEN "balanceOf(address)(uint256)" $SUB_POOL  --rpc-url $SUBTENSOR_RPC
```

Note `1e18 token == 1e9 alpha RAO`, so compare `stakedValueRao * 1e9` against `totalSupply`.

Then do a small mainnet round-trip through the gateways before opening to users.
