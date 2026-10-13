/**
 * Railway Infrastructure as Code - Ubuntu Cloud PC
 * ---------------------------------------------------------------------------
 * One `railway config apply` creates everything this project needs:
 *
 *   - the service, built from this repository's Dockerfile
 *   - a persistent volume mounted at /data (your home directory)
 *   - a public TCP proxy for port 3389, which is how RDP reaches the desktop
 *   - the /health healthcheck and an always-on restart policy
 *
 * Usage (see README.md for the full walkthrough):
 *
 *   npm install
 *   railway login
 *   railway link          # or: railway init
 *   railway config plan   # review
 *   railway config apply
 *
 * Nothing secret lives in this file. The RDP password is generated inside the
 * container at first boot and printed to the (private) deploy logs.
 *
 * Forked the repo or named the service differently? Set the environment
 * variables below before running the CLI - no edits to this file needed:
 *   CLOUD_PC_REPO=<owner>/<repo>  CLOUD_PC_SERVICE=<service name>
 *   CLOUD_PC_VOLUME_MB=<size>     CLOUD_PC_BRANCH=<branch>
 */
import { defineRailway, github, project, service, volume } from "railway/iac";

/** Only manage this project's own resources, never anything else in the environment. */
export const partial = "ubuntu-cloud-pc";

const REPO = process.env.CLOUD_PC_REPO ?? "itsrivo-dev/Rdp";
const BRANCH = process.env.CLOUD_PC_BRANCH ?? "main";
const SERVICE_NAME = process.env.CLOUD_PC_SERVICE ?? "Rdp";
const VOLUME_MB = Number(process.env.CLOUD_PC_VOLUME_MB ?? 5120);

/** Internal container ports. Keep in sync with the Dockerfile. */
const RDP_PORT = 3389;
const HTTP_PORT = 8080;

export default defineRailway(() => {
  const data = volume("cloud-pc-data", {
    sizeMB: VOLUME_MB,
  });

  const cloudPc = service(SERVICE_NAME, {
    source: github(REPO, { branch: BRANCH }),

    build: {
      builder: "DOCKERFILE",
      dockerfilePath: "Dockerfile",
    },

    // Public RDP endpoint: Railway generates <name>.proxy.rlwy.net:<port>
    // and forwards it to container port 3389.
    tcp: [RDP_PORT],

    // Readiness probe served by the container's status server.
    healthcheck: "/health",
    healthcheckTimeout: 300,

    deploy: {
      restartPolicyType: "ALWAYS",
      restartPolicyMaxRetries: 10,
      numReplicas: 1,
    },

    // Home directory + generated credentials + TLS material live here, so the
    // desktop survives restarts and redeploys.
    volumeMounts: {
      "/data": data,
    },

    env: {
      // Tells Railway which port serves HTTP (the healthcheck target) while
      // the TCP proxy handles 3389. Everything else has a built-in default.
      PORT: String(HTTP_PORT),
    },
  });

  return project(process.env.CLOUD_PC_PROJECT ?? "ubuntu-cloud-pc", {
    resources: [cloudPc, data],
  });
});
