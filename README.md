# LST (Liquid Staking Token)

## Overview
LST is a liquid staking solution for Berachain, allowing users to stake their BERA while maintaining liquidity through the fatBERA token.

## Installation

1. Install [Foundry](https://book.getfoundry.sh/getting-started/installation)
2. Clone this repository
3. Install dependencies:
```bash
forge install
```

## Setup

1. Copy `.env.example` to `.env`:
```bash
cp .env.example .env
```

2. Add your API keys to `.env`:
```
BERASCAN_API_KEY=your_api_key_here
```

## Dependencies

This project uses the following dependencies (automatically installed via `forge install`):
- OpenZeppelin Contracts
- OpenZeppelin Contracts Upgradeable
- OpenZeppelin Foundry Upgrades
- Forge Standard Library
- Solady

## Development

To build the project:
```bash
forge build
```

To run tests:
```bash
forge test
```

## Audits

Audit reports can be found in the [audits](./audits) directory.

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
