require("@nomicfoundation/hardhat-toolbox"); // includes ethers, chai, mocha, coverage, etc.
require("dotenv").config();                  // loads .env file into process.env

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  // Compiler settings for all 4 LexChain contracts.
  // Optimizer is enabled with 200 runs — a balanced setting between deployment cost
  // and execution cost. Higher runs optimize for frequently-called functions.
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },

  // Network configurations.
  networks: {
    // Localhost is used for running `npx hardhat test` and local development.
    // The Hardhat Network is spun up automatically — no external node needed.
    hardhat: {
      chainId: 31337, // standard Hardhat local chain ID
    },

    // Sepolia is the Ethereum testnet we deploy to for the live demo.
    // Uses Alchemy as our free RPC node provider.
    // NEVER commit your PRIVATE_KEY or ALCHEMY_URL to GitHub.
    sepolia: {
      url: process.env.ALCHEMY_SEPOLIA_URL || "",    // Alchemy HTTPS endpoint
      accounts: process.env.PRIVATE_KEY
        ? [process.env.PRIVATE_KEY]                  // MetaMask private key from .env
        : [],
      chainId: 11155111,                              // Sepolia's official chain ID
    },
  },

  // Etherscan configuration for source code verification.
  // After deployment, run: npx hardhat verify --network sepolia <address> <args>
  // This makes the contract source code readable on etherscan.io/testnets/sepolia
  etherscan: {
    apiKey: {
      sepolia: process.env.ETHERSCAN_API_KEY || "",  // free API key from etherscan.io
    },
  },

  // Where Hardhat looks for contracts, tests, and deploy scripts.
  paths: {
    sources:   "./contracts", // our 4 Solidity files live here
    tests:     "./test",      // LexChain.test.js lives here
    cache:     "./cache",     // compiled artifact cache (auto-generated)
    artifacts: "./artifacts", // compiled ABI + bytecode (auto-generated)
  },
};
