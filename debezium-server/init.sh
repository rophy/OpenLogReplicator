#!/bin/bash
# Initialize directories with proper permissions

set -e

echo "Creating directories..."

mkdir -p oradata fra data output oracle-driver

# Oracle needs UID 54321
sudo chown 54321:54321 oradata fra

chmod 777 data output

echo "Done. Directories created:"
ls -la
