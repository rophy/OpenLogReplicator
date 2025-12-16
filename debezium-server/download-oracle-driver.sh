#!/bin/bash
# Download Oracle JDBC driver for Debezium

set -e

DRIVER_VERSION="21.11.0.0"
DRIVER_DIR="oracle-driver"

mkdir -p ${DRIVER_DIR}

echo "Downloading Oracle JDBC driver ${DRIVER_VERSION}..."

# Download from Maven Central
curl -L -o ${DRIVER_DIR}/ojdbc8.jar \
  "https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc8/${DRIVER_VERSION}/ojdbc8-${DRIVER_VERSION}.jar"

echo "Driver downloaded to ${DRIVER_DIR}/ojdbc8.jar"
ls -la ${DRIVER_DIR}/
