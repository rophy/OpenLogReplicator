ORACLE_TARGET := free-23
TESTS_DIR := $(abspath ../..)
SCRIPTS_DIR := $(TESTS_DIR)/scripts
SCENARIOS := $(wildcard $(TESTS_DIR)/0-inputs/*.sql)
SCENARIO ?=

.PHONY: up down test-sql

up:
	docker compose up -d --wait

down:
	docker compose down

test-sql:
ifdef SCENARIO
	ORACLE_TARGET=$(ORACLE_TARGET) $(SCRIPTS_DIR)/generate.sh $(SCENARIO)
else
	@for sql in $(SCENARIOS); do \
		name=$$(basename "$$sql" .sql); \
		echo "=== Generating: $$name ==="; \
		ORACLE_TARGET=$(ORACLE_TARGET) $(SCRIPTS_DIR)/generate.sh "$$name" || exit 1; \
	done
endif
