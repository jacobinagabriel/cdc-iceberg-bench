.PHONY: help lint test tf-check source-counts

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-14s %s\n", $$1, $$2}'

lint: ## Ruff lint and format check
	uv run ruff check . && uv run ruff format --check .

test: ## Unit tests (the Spark ones need Java)
	uv run pytest

tf-check: ## terraform fmt and validate, without a backend
	terraform -chdir=infra fmt -check -recursive
	terraform -chdir=infra/envs/prod init -backend=false -input=false >/dev/null
	terraform -chdir=infra/envs/prod validate

source-counts: ## Row counts of the source tables, via an ECS task (needs AWS_PROFILE; the stack must be up)
	./scripts/run-ops.sh source-counts
