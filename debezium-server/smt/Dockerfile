# Build stage for the SMT JAR
FROM maven:3.9-eclipse-temurin-11 AS builder

WORKDIR /build
COPY pom.xml .
COPY src ./src

# Build the JAR
RUN mvn clean package -DskipTests

# Output stage - just copy the JAR
FROM scratch AS export
COPY --from=builder /build/target/*.jar /
