import { createPublicClient, http, keccak256, toHex, parseAbiItem, Address, Log } from 'viem';
import { berachain } from 'viem/chains';

// Contract addresses from deployments.txt (newest versions only)
// Note: xfatBERA proxy is the fatBERA proxy address, implementation is 0x33227085B31dE446ed2364B429aae7dc6d6Ee5de
const CONTRACTS: Record<string, { address: Address; name: string; startBlock: bigint }> = {
  fatBERA: {
    address: '0xBAE11292A3E693aF73651BDa350D752AE4A391D4',
    name: 'fatBERA Proxy',
    startBlock: 1007438n, // Approximate deployment block
  },
  xfatBERA: {
    address: '0xcAc89B3F94eD6BAb04113884deeE2A55293c2DD7',
    name: 'xfatBERAV3 Proxy',
    startBlock: 4789690n, // Query from same time as fatBERA since proxy was deployed early
  },
  automatedStake: {
    address: '0x8ba92925c156ea522Cd80b4633bd0a9824c3bcdf',
    name: 'AutomatedStake Proxy',
    startBlock: 1830707n,
  },
  validatorWithdrawalModule: {
    address: '0x56c70E5eFbA5f18B04d17bBC580b6d37B3AFE5Ed',
    name: 'ValidatorWithdrawalModuleV3 (Proxy)',
    startBlock: 8178291n, // Approximate deployment block
  },
};

// Known role hashes from the contracts
const ROLE_HASHES: Record<string, string> = {
  [keccak256(toHex('REWARD_NOTIFIER_ROLE'))]: 'REWARD_NOTIFIER_ROLE',
  [keccak256(toHex('PAUSER_ROLE'))]: 'PAUSER_ROLE',
  [keccak256(toHex('OPERATOR_ROLE'))]: 'OPERATOR_ROLE',
  [keccak256(toHex('STAKER_ROLE'))]: 'STAKER_ROLE',
  [keccak256(toHex('TRIGGER_ROLE'))]: 'TRIGGER_ROLE',
  [keccak256(toHex('ADMIN_ROLE'))]: 'ADMIN_ROLE',
  ['0x0000000000000000000000000000000000000000000000000000000000000000']: 'DEFAULT_ADMIN_ROLE',
};

// ABI for AccessControl events
const ROLE_GRANTED_EVENT = parseAbiItem(
  'event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)'
);
const ROLE_REVOKED_EVENT = parseAbiItem(
  'event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender)'
);

interface RoleInfo {
  address: string;
  roles: Set<string>;
  grantedBy: Map<string, string>;
  grantedAt: Map<string, bigint>;
}

interface ContractRoles {
  contractName: string;
  contractAddress: string;
  roleHolders: Map<string, RoleInfo>;
}

const BLOCK_RANGE = 2000000n; // Alchemy supports much larger ranges

async function getLogsInBatches(
  client: ReturnType<typeof createPublicClient>,
  params: {
    address: Address;
    event: ReturnType<typeof parseAbiItem>;
    fromBlock: bigint;
    toBlock: bigint;
  }
): Promise<Log[]> {
  const allLogs: Log[] = [];
  let currentFrom = params.fromBlock;
  let currentRange = BLOCK_RANGE;

  while (currentFrom <= params.toBlock) {
    const currentTo =
      currentFrom + currentRange > params.toBlock ? params.toBlock : currentFrom + currentRange;

    try {
      const logs = await client.getLogs({
        address: params.address,
        event: params.event as any,
        fromBlock: currentFrom,
        toBlock: currentTo,
      });
      allLogs.push(...(logs as unknown as Log[]));
      currentFrom = currentTo + 1n;
      currentRange = BLOCK_RANGE; // Reset range on success
    } catch (error: any) {
      // If range too large, halve it and retry
      if (error?.details?.includes('limited') || error?.details?.includes('range') || error?.status === 413) {
        currentRange = currentRange / 2n;
        if (currentRange < 1000n) currentRange = 1000n;
        continue;
      }
      // Rate limited - wait and retry
      if (error?.status === 429) {
        await new Promise((r) => setTimeout(r, 1000));
        continue;
      }
      throw error;
    }
  }

  return allLogs;
}

async function queryRolesForContract(
  client: ReturnType<typeof createPublicClient>,
  contractKey: string,
  contractInfo: { address: Address; name: string; startBlock: bigint }
): Promise<ContractRoles> {
  const result: ContractRoles = {
    contractName: contractInfo.name,
    contractAddress: contractInfo.address,
    roleHolders: new Map(),
  };

  console.log(`\n📋 Querying ${contractInfo.name} (${contractInfo.address})...`);

  try {
    const latestBlock = await client.getBlockNumber();

    // Query RoleGranted events in batches
    console.log(`  Fetching RoleGranted events from block ${contractInfo.startBlock} to ${latestBlock}...`);
    const grantedLogs = await getLogsInBatches(client, {
      address: contractInfo.address,
      event: ROLE_GRANTED_EVENT,
      fromBlock: contractInfo.startBlock,
      toBlock: latestBlock,
    });

    // Query RoleRevoked events in batches
    console.log(`  Fetching RoleRevoked events...`);
    const revokedLogs = await getLogsInBatches(client, {
      address: contractInfo.address,
      event: ROLE_REVOKED_EVENT,
      fromBlock: contractInfo.startBlock,
      toBlock: latestBlock,
    });

    console.log(`  Found ${grantedLogs.length} RoleGranted events`);
    console.log(`  Found ${revokedLogs.length} RoleRevoked events`);

    // Process granted events
    for (const log of grantedLogs) {
      const args = (log as any).args;
      const role = args.role as string;
      const account = args.account as string;
      const sender = args.sender as string;
      const roleName = ROLE_HASHES[role] || role;

      if (!result.roleHolders.has(account)) {
        result.roleHolders.set(account, {
          address: account,
          roles: new Set(),
          grantedBy: new Map(),
          grantedAt: new Map(),
        });
      }

      const holder = result.roleHolders.get(account)!;
      holder.roles.add(roleName);
      holder.grantedBy.set(roleName, sender);
      holder.grantedAt.set(roleName, log.blockNumber!);
    }

    // Process revoked events (remove roles)
    for (const log of revokedLogs) {
      const args = (log as any).args;
      const role = args.role as string;
      const account = args.account as string;
      const roleName = ROLE_HASHES[role] || role;

      const holder = result.roleHolders.get(account);
      if (holder) {
        holder.roles.delete(roleName);
        holder.grantedBy.delete(roleName);
        holder.grantedAt.delete(roleName);
      }
    }

    // Clean up holders with no remaining roles
    for (const [address, holder] of result.roleHolders) {
      if (holder.roles.size === 0) {
        result.roleHolders.delete(address);
      }
    }
  } catch (error) {
    console.error(`  Error querying ${contractInfo.name}:`, error);
  }

  return result;
}

function printResults(allResults: ContractRoles[]) {
  console.log('\n');
  console.log('═'.repeat(80));
  console.log('                         ROLE ASSIGNMENT REPORT');
  console.log('═'.repeat(80));

  for (const contractRoles of allResults) {
    console.log('\n');
    console.log('─'.repeat(80));
    console.log(`📄 ${contractRoles.contractName}`);
    console.log(`   Address: ${contractRoles.contractAddress}`);
    console.log('─'.repeat(80));

    if (contractRoles.roleHolders.size === 0) {
      console.log('   No role holders found (or contract does not use AccessControl)');
      continue;
    }

    // Group by role
    const roleToHolders = new Map<string, string[]>();
    for (const [address, holder] of contractRoles.roleHolders) {
      for (const role of holder.roles) {
        if (!roleToHolders.has(role)) {
          roleToHolders.set(role, []);
        }
        roleToHolders.get(role)!.push(address);
      }
    }

    // Print roles and their holders
    for (const [role, holders] of roleToHolders) {
      console.log(`\n   🔑 ${role}:`);
      for (const holder of holders) {
        const info = contractRoles.roleHolders.get(holder)!;
        const grantedBy = info.grantedBy.get(role);
        const grantedAt = info.grantedAt.get(role);
        console.log(`      • ${holder}`);
        if (grantedBy) {
          console.log(`        └─ Granted by: ${grantedBy} (block ${grantedAt})`);
        }
      }
    }
  }

  // Summary by address
  console.log('\n');
  console.log('═'.repeat(80));
  console.log('                        SUMMARY BY ADDRESS');
  console.log('═'.repeat(80));

  const addressSummary = new Map<string, Map<string, Set<string>>>();

  for (const contractRoles of allResults) {
    for (const [address, holder] of contractRoles.roleHolders) {
      if (!addressSummary.has(address)) {
        addressSummary.set(address, new Map());
      }
      const contracts = addressSummary.get(address)!;
      if (!contracts.has(contractRoles.contractName)) {
        contracts.set(contractRoles.contractName, new Set());
      }
      for (const role of holder.roles) {
        contracts.get(contractRoles.contractName)!.add(role);
      }
    }
  }

  for (const [address, contracts] of addressSummary) {
    console.log(`\n👤 ${address}`);
    for (const [contractName, roles] of contracts) {
      console.log(`   📄 ${contractName}:`);
      for (const role of roles) {
        console.log(`      • ${role}`);
      }
    }
  }

  // JSON output for programmatic use
  console.log('\n');
  console.log('═'.repeat(80));
  console.log('                           JSON OUTPUT');
  console.log('═'.repeat(80));

  const jsonOutput: Record<string, Record<string, string[]>> = {};
  for (const contractRoles of allResults) {
    const contractData: Record<string, string[]> = {};
    for (const [address, holder] of contractRoles.roleHolders) {
      contractData[address] = Array.from(holder.roles);
    }
    jsonOutput[contractRoles.contractName] = contractData;
  }
  console.log(JSON.stringify(jsonOutput, null, 2));
}

async function main() {
  console.log('🔍 Querying role data from deployed contracts on Berachain...\n');

  const client = createPublicClient({
    chain: berachain,
    transport: http('https://berachain-mainnet.g.alchemy.com/v2/HwxvELpRuVjvuxUZaVAk0G4NmdZiOJAi'),
  });

  const results: ContractRoles[] = [];

  for (const [key, contractInfo] of Object.entries(CONTRACTS)) {
    const contractRoles = await queryRolesForContract(client, key, contractInfo);
    results.push(contractRoles);
  }

  printResults(results);
}

main().catch(console.error);
