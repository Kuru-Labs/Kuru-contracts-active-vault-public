//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";
import {IRouter} from "../src/interfaces/IRouter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployVault is Script {
    Vault public vault;
    IRouter public router;

    function run() public {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deploy-recipes/config/inputs.json");
        string memory json = vm.readFile(path);
        string memory rpcUrl = vm.parseJsonString(json, ".rpc_url");
        vm.createSelectFork(rpcUrl);
        address vaultImpl = vm.parseJsonAddress(json, ".vault_impl");
        if (vaultImpl == address(0)) {
            vm.broadcast();
            Vault newVaultImpl = new Vault();
            vaultImpl = address(newVaultImpl);
            vm.writeJson(vm.toString(vaultImpl), path, ".vault_impl");
        }
        vm.startBroadcast();
        address vaultProxy = address(new ERC1967Proxy(vaultImpl, ""));
        vault = Vault(payable(vaultProxy));
        address vaultAdmin = vm.parseJsonAddress(json, ".vault_admin");
        address operator = vm.parseJsonAddress(json, ".operator");
        address gasCrank = vm.parseJsonAddress(json, ".gas_crank");
        address targetMarket = vm.parseJsonAddress(json, ".market");
        address marginAccount = vm.parseJsonAddress(json, ".margin_account");
        uint256 unlockInterval = vm.parseJsonUint(json, ".unlock_interval");
        uint256 gasFeeOutMax = vm.parseJsonUint(json, ".gas_fee_out_max");
        uint256 gasCrankCooldown = vm.parseJsonUint(json, ".gas_crank_cooldown");
        vault.initialize(vaultAdmin, operator, gasCrank, targetMarket, marginAccount, unlockInterval, gasFeeOutMax, gasCrankCooldown);
        vm.stopBroadcast();
        vm.writeJson(vm.toString(address(vault)), path, ".vault");
    }
}