# =============================================================================
#  Railway infrastructure for the Ubuntu Cloud PC.
#
#  This file is evaluated by the **Railway CLI** (`railway config apply`), not
#  during a deploy. It is optional: the GitHub deployment path only needs the
#  Dockerfile in this repository (see README.md).
#
#  What it declares:
#    * one service, built from ./Dockerfile
#    * a persistent volume mounted at /data (home directory, password, session
#      key - everything that must survive a redeploy)
#    * the /health healthcheck and an always-on restart policy
#
#  Nothing secret lives here, and no credentials are required for it to work:
#  the deployment works with the defaults in the container.
#
#  Forked the repo or named the service differently? Set these before running
#  the CLI - no edits to this file needed:
#
#    CLOUD_PC_REPO=<owner>/<repo>   CLOUD_PC_BRANCH=<branch>
#    CLOUD_PC_SERVICE=<name>        CLOUD_PC_PROJECT=<project>
#    CLOUD_PC_VOLUME_MB=<size>
# =============================================================================
import { defineRailway, github, project, service, volume } from "railway/iac";

/** Only ever manage this project's own resources. */
export const partial = "ubuntu-cloud-pc";

const REPO = process.env.CLOUD_PC_REPO ?? "itsrivo-dev/Rdp";
const BRANCH = process.env.CLOUD_PC_BRANCH ?? "main";
const SERVICE_NAME = process.env.CLOUD_PC_SERVICE ?? "Rdp";
const VOLUME_MB = Number(process.env.CLOUD_PC_VOLUME_MB ?? 5120);

/** Keep in sync with the Dockerfile / entrypoint defaults. */
const HTTP_PORT = 8080;
const DATA_DIR = "/data";

export default defineRailway(() => {
  const desktopData = volume("cloudpc-data", {
    sizeMB: VOLUME_MB,
  });

  const desktop = service(SERVICE_NAME, {
    source: github(REPO, { branch: BRANCH }),

    build: {
      builder: "DOCKERFILE",
      dockerfilePath: "Dockerfile",
    },

    // The only public endpoint: the HTTPS web gateway. Railway injects PORT
    // into the container, so the gateway always listens where Railway expects.
    healthcheck: "/health",
    healthcheckTimeout: 300,

    deploy: {
      restartPolicyType: "ALWAYS",
      restartPolicyMaxRetries: 10,
      numReplicas: 1,
    },

    // Home directory, generated password and session signing key live here, so
    // the desktop and the logins survive restarts and redeploys.
    volumeMounts: {
      [DATA_DIR]: desktopData,
    },

    env: {
      PORT: String(HTTP_PORT),
      // Sensible defaults for Railway-sized containers. Override in the
      // dashboard if your plan has more memory (e.g. 1600x900).
      DESKTOP_RESOLUTION: "1280x720",
      VNC_FRAME_RATE: "30",
    },
  });

  return project(process.env.CLOUD_PC_PROJECT ?? "ubuntu-cloud-pc", {
    resources: [desktop, desktopData],
  });
});
