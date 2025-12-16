#!/bin/bash
# Build the Big5 Decoder SMT JAR

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building Big5 Decoder SMT..."

# Option 1: Use Docker to build (no local Maven required)
if command -v docker &> /dev/null; then
    echo "Using Docker to build..."

    # Build using multi-stage Dockerfile
    docker build --target builder -t big5-smt-builder .

    # Extract JAR from builder
    mkdir -p target
    docker run --rm big5-smt-builder cat /build/target/big5-decoder-smt-1.0.0.jar > target/big5-decoder-smt-1.0.0.jar

    echo "JAR built: target/big5-decoder-smt-1.0.0.jar"

# Option 2: Use local Maven
elif command -v mvn &> /dev/null; then
    echo "Using local Maven to build..."
    mvn clean package -DskipTests
    echo "JAR built: target/big5-decoder-smt-1.0.0.jar"

else
    echo "ERROR: Neither Docker nor Maven found. Please install one of them."
    exit 1
fi

echo "Done!"
ls -la target/*.jar
