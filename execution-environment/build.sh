#!/usr/bin/env bash
# Build the custom EE and import it into the Colima k3s containerd so AWX can
# use it without an external registry. Run from the execution-environment/ dir.
set -euo pipefail

TAG="f5-ee:1.0"

# Requires: pip install ansible-builder ; a running docker context (Colima)
ansible-builder build --tag "$TAG" --container-runtime docker -v3

# k3s uses containerd, not docker — hand the image over directly.
docker save "$TAG" | colima ssh -- sudo k3s ctr images import -

echo
echo "Imported '$TAG' into Colima's k3s."
echo "In AWX: Administration > Execution Environments > Add"
echo "  Image:        $TAG"
echo "  Pull policy:  Never   (it's local, don't try to pull it)"
