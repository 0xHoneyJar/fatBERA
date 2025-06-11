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
      transport: http("http://57.129.49.205:8545/"),
    });
    const publicClient = createPublicClient({
      chain: berachain,
      transport: http("http://57.129.49.205:8545/"),
    });

    const hash = await client.writeContract({
      address: "0xcAc89B3F94eD6BAb04113884deeE2A55293c2DD7", // staked FatBERA
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