TEST = docker compose -f compose.yml -f compose.test.yml

.PHONY: up test down logs

up:
	$(TEST) up -d --build --wait

test:
	$(TEST) exec -T gateway openresty -e stderr -p /tmp -c /tests/unit.conf
	./test/test.sh

down:
	$(TEST) down -v

logs:
	$(TEST) logs -f
