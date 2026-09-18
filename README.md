## Quick Start

Discovery-OVA is designed to be installed using the bootstrap script in this repository.

The bootstrap script downloads the current `discovery-ova-install.sh` from the `main` branch, displays its SHA-256 hash, and then launches the installer.

Download the bootstrap script:

```bash
curl -fL \
  https://raw.githubusercontent.com/mgw24/discovery-ova/refs/heads/main/discovery-ova-bootstrap.sh \
  -o discovery-ova-bootstrap.sh
