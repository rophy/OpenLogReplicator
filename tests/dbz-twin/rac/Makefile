TESTS_DIR := $(abspath ../../../..)
SCRIPTS_DIR := $(TESTS_DIR)/sql/scripts
DBZ_DIR := $(TESTS_DIR)/debezium
SCENARIOS := $(filter-out %.rac.sql,$(wildcard $(TESTS_DIR)/sql/inputs/*.sql)) $(wildcard $(TESTS_DIR)/sql/inputs/*.rac.sql)
SCENARIO ?=

.PHONY: up down test-debezium setup

# One-time setup: create c##dbzuser + grants + sentinel table on RAC
setup:
	./setup.sh

# Ensure ojdbc8.jar exists (shared with tests/debezium/lib/)
$(DBZ_DIR)/lib/ojdbc8.jar:
	$(MAKE) -C $(DBZ_DIR) download-ojdbc

# Start local services (receiver + Debezium connectors)
up: $(DBZ_DIR)/lib/ojdbc8.jar
	docker compose up -d

down:
	docker compose down -v

test-debezium:
ifdef SCENARIO
	./run.sh $(SCENARIO)
else
	@for sql in $(SCENARIOS); do \
		name=$$(basename "$$sql"); \
		name=$${name%.rac.sql}; \
		name=$${name%.sql}; \
		echo ""; \
		./run.sh "$$name" || exit 1; \
	done
endif
