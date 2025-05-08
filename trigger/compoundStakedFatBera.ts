import { logger, schedules, wait } from "@trigger.dev/sdk/v3";
import { createPublicClient, createWalletClient, http, getAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { berachain } from "viem/chains";

export const compoundStakedFatBera = schedules.task({
  id: "compound-staked-fat-bera",
  // Set an optional maxDuration to prevent tasks from running indefinitely
  maxDuration: 300, // Stop executing after 300 secs (5 mins) of compute
  run: async (payload, { ctx }) => {

    const privateKey = process.env[`PRIVATE_KEY_OPERATOR`];
    if (!privateKey) {
      throw new Error("Private key is required");
    }

    const account = privateKeyToAccount(privateKey as `0x${string}`);
    const client = createWalletClient({
      account,
      chain: berachain,
      transport: http(),
    });
    const publicClient = createPublicClient({
      chain: berachain,
      transport: http(),
    });

    const hash = await client.writeContract({
      address: "0xe4F5E6586CD6bff230948bD1e3973C5105ad92fC", // staked FatBERA
      abi: [
        {
          inputs: [],
          name: "compound",
          outputs: [],
          stateMutability: "nonpayable",
          type: "function",
        },
      ] as const,
      functionName: "compound",
      args: [],
    });

    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    logger.log("Compound staked fat bera", { receipt });
  },
});