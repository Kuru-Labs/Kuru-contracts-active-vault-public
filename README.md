## Kuru Active Vault

Kuru Active Vault is designed to be a vault where users can deposit liquidity which is then used for market making, thus generating a possible APY. 

### Compilation

You can compile using `forge compile`. The `via-ir` option is turned on in the foundry config. If you don't import the foundry config by default, you may need to manually turn it on. 

### How To Run Tests

The active vault interfaces with an orderbook. To get the setup up and working, you need to do the following:

1. Run a local hardhat node by running `npx hardhat node`
2. In the `kuru-contracts` repo, run the `deployStorageOrderBook` script to deploy the contracts in your local hardhat node
3. Export the following environment variables in your shell before running scripts/tests:

```bash
export RPC_URL="http://127.0.0.1:8545"

# These can be any EOA addresses you want to use
export SOURCE_OF_FUNDS="0x..."
export MINT_AND_BURN_AUTH="0x..." 
export OPERATOR="0x..."
export GAS_CRANK="0x..."

# These addresses come from the deploy script output
export MARGIN_ACCOUNT="0x..."
export ROUTER="0x..."
```

**Note**: `SOURCE_OF_FUNDS`, `MINT_AND_BURN_AUTH`, `OPERATOR`, and `GAS_CRANK` are just normal EOA addresses - you can set them to any address you prefer. Only `MARGIN_ACCOUNT` and `ROUTER` need to be copied from the deployment script output.

