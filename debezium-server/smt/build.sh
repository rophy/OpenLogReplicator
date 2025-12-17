#!/bin/bash
# Build the Legacy Charset SMT JAR

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building Legacy Charset SMT..."

# Option 1: Use Docker to build (no local Maven required)
if command -v docker &> /dev/null; then
    echo "Using Docker to build..."

    # Build using multi-stage Dockerfile
    docker build --target builder -t legacy-charset-smt-builder .

    # Extract JAR from builder
    mkdir -p target
    docker run --rm legacy-charset-smt-builder cat /build/target/legacy-charset-smt-1.0.0.jar > target/legacy-charset-smt-1.0.0.jar

    echo "JAR built: target/legacy-charset-smt-1.0.0.jar"

# Option 2: Use local Maven
elif command -v mvn &> /dev/null; then
    echo "Using local Maven to build..."
    mvn clean package -DskipTests
    echo "JAR built: target/legacy-charset-smt-1.0.0.jar"

else
    echo "ERROR: Neither Docker nor Maven found. Please install one of them."
    exit 1
fi

echo "Done!"
ls -la target/*.jar
