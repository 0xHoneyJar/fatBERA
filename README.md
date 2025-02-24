# fatBERA

## Overview
fatBERA is a liquid staking token (LST) designed for users looking to stake their BERA with THJ validators on Berachain. By staking BERA through fatBERA, users receive:

- Immediate liquidity through the fatBERA token
- Staking rewards in WBERA that are instantly claimable
- Future rewards in additional ERC20 tokens (e.g., Honey)
- Simplified staking experience with THJ validators

## Features

- **Liquid Staking**: Stake BERA while maintaining liquidity through fatBERA tokens
- **Instant Rewards**: Earn WBERA rewards that are immediately claimable
- **Multiple Reward Types**: Support for multiple reward tokens (WBERA, and soon other ERC20s)
- **Secure Architecture**: Fully audited, upgradeable smart contracts
- **Transparent Operation**: Open source code and public audit reports

## Technical Details

fatBERA is implemented as an ERC4626-compliant vault with the following key characteristics:
- Upgradeable smart contracts using OpenZeppelin's UUPS pattern
- Multi-token reward distribution system
- Native BERA deposit support
- Comprehensive security features and access controls

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
PRIVATE_KEY=YourPrivateKey
```

## Development

To build the project:
```bash
forge build
```

To run tests:
```bash
forge test
```

## Security

### Audits
Audit reports can be found in the [audits](./audits) directory.

### Dependencies
This project uses the following audited dependencies:
- OpenZeppelin Contracts
- OpenZeppelin Contracts Upgradeable
- OpenZeppelin Foundry Upgrades
- Forge Standard Library
- Solady

## Documentation

For Foundry documentation, visit: https://book.getfoundry.sh/

## License
A THJ product 