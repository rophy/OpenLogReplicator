TESTS_DIR := $(abspath ..)
SCRIPTS_DIR := $(TESTS_DIR)/sql/scripts
SCENARIOS := $(wildcard $(TESTS_DIR)/sql/inputs/*.sql)
SCENARIO ?=
OJDBC_VERSION := 21.14.0.0
OJDBC_URL := https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc8/$(OJDBC_VERSION)/ojdbc8-$(OJDBC_VERSION).jar

.PHONY: up down test-debezium download-ojdbc

download-ojdbc:
	@mkdir -p lib
	@test -f lib/ojdbc8.jar || \
		(echo "Downloading ojdbc8-$(OJDBC_VERSION).jar..." && \
		 wget -q -O lib/ojdbc8.jar $(OJDBC_URL))

up: download-ojdbc
	docker compose up -d --wait

down:
	docker compose down -v

test-debezium:
ifdef SCENARIO
	$(SCRIPTS_DIR)/run-debezium.sh $(SCENARIO)
else
	@for sql in $(SCENARIOS); do \
		name=$$(basename "$$sql" .sql); \
		echo "=== Debezium twin-test: $$name ==="; \
		$(SCRIPTS_DIR)/run-debezium.sh "$$name" || exit 1; \
	done
endif
