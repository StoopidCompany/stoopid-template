.DEFAULT_GOAL := help
.SHELLFLAGS := -eu -o pipefail -c
SHELL := bash

# =============================================================================
# Language detection
# =============================================================================
# Each variable is non-empty if that language is present in the repo.

HAS_PYTHON := $(shell test -f pyproject.toml && echo 1)
HAS_PNPM   := $(shell test -f pnpm-lock.yaml && echo 1)
HAS_NPM    := $(shell test -f package-lock.json && echo 1)
HAS_NODE   := $(shell test -f package.json && echo 1)
HAS_RUST   := $(shell test -f Cargo.toml && echo 1)
HAS_TF     := $(shell find . -maxdepth 3 -name '*.tf' -not -path './.terraform/*' -print -quit 2>/dev/null)
HAS_DOCKER := $(shell test -f Dockerfile -o -f docker-compose.yml -o -f compose.yml && echo 1)
HAS_TILT   := $(shell test -f Tiltfile && echo 1)

# Pick the JS package manager: pnpm preferred, fall back to npm
ifdef HAS_PNPM
JS_PM := pnpm
else ifdef HAS_NPM
JS_PM := npm
endif

# =============================================================================
# Help
# =============================================================================

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "; printf "\nUsage: make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2} /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)}' $(MAKEFILE_LIST)
	@echo ""
	@echo "Detected:"
	@$(if $(HAS_PYTHON),echo "  - Python (uv)",)
	@$(if $(JS_PM),echo "  - JavaScript/TypeScript ($(JS_PM))",)
	@$(if $(HAS_RUST),echo "  - Rust (cargo)",)
	@$(if $(HAS_TF),echo "  - Terraform",)
	@$(if $(HAS_DOCKER),echo "  - Docker",)
	@$(if $(HAS_TILT),echo "  - Tilt",)
	@echo ""

# =============================================================================
##@ Setup
# =============================================================================

.PHONY: bootstrap
bootstrap: ## Install dependencies and set up pre-commit hooks
	@echo "==> Bootstrapping project..."
	@test -f .env || (test -f .env.example && cp .env.example .env && echo "Created .env from .env.example")
ifdef HAS_PYTHON
	@echo "==> Installing Python dependencies (uv)..."
	@uv sync
endif
ifdef JS_PM
	@echo "==> Installing JS dependencies ($(JS_PM))..."
	@$(JS_PM) install
endif
ifdef HAS_RUST
	@echo "==> Fetching Rust dependencies..."
	@cargo fetch
endif
	@echo "==> Installing pre-commit hooks..."
	@command -v pre-commit >/dev/null 2>&1 && pre-commit install || echo "pre-commit not installed; skipping"
	@echo "==> Bootstrap complete."

.PHONY: install
install: bootstrap ## Alias for bootstrap

# =============================================================================
##@ Development
# =============================================================================

.PHONY: dev
dev: ## Start project for local development
ifdef HAS_TILT
	@tilt up
else ifdef HAS_DOCKER
	@docker compose up
else
	@echo "No dev orchestrator detected (no Tiltfile or compose.yml)."
	@echo "Override 'dev' in a project-specific Makefile or define one."
	@exit 1
endif

.PHONY: dev-down
dev-down: ## Stop local development environment
ifdef HAS_TILT
	@tilt down
else ifdef HAS_DOCKER
	@docker compose down
endif

# =============================================================================
##@ Quality
# =============================================================================

.PHONY: format
format: ## Apply formatters across all detected languages
ifdef HAS_PYTHON
	@echo "==> Formatting Python..."
	@uv run ruff format .
	@uv run ruff check --fix .
endif
ifdef JS_PM
	@echo "==> Formatting JS/TS..."
	@$(JS_PM) run format || $(JS_PM) exec prettier --write .
endif
ifdef HAS_RUST
	@echo "==> Formatting Rust..."
	@cargo fmt --all
endif
ifdef HAS_TF
	@echo "==> Formatting Terraform..."
	@terraform fmt -recursive
endif

.PHONY: lint
lint: ## Run linters across all detected languages
ifdef HAS_PYTHON
	@echo "==> Linting Python..."
	@uv run ruff check .
	@uv run ruff format --check .
endif
ifdef JS_PM
	@echo "==> Linting JS/TS..."
	@$(JS_PM) run lint
endif
ifdef HAS_RUST
	@echo "==> Linting Rust..."
	@cargo clippy --all-targets --all-features -- -D warnings
	@cargo fmt --all -- --check
endif
ifdef HAS_TF
	@echo "==> Checking Terraform formatting..."
	@terraform fmt -check -recursive
endif

.PHONY: typecheck
typecheck: ## Run type checkers
ifdef HAS_PYTHON
	@echo "==> Type-checking Python..."
	@uv run pyright || uv run mypy .
endif
ifdef JS_PM
	@echo "==> Type-checking TypeScript..."
	@$(JS_PM) exec tsc --noEmit
endif

.PHONY: test
test: ## Run all tests
ifdef HAS_PYTHON
	@echo "==> Testing Python..."
	@uv run pytest
endif
ifdef JS_PM
	@echo "==> Testing JS/TS..."
	@$(JS_PM) test
endif
ifdef HAS_RUST
	@echo "==> Testing Rust..."
	@cargo test --all-features
endif

.PHONY: test-coverage
test-coverage: ## Run tests with coverage reporting
ifdef HAS_PYTHON
	@uv run pytest --cov --cov-report=term-missing --cov-report=xml
endif
ifdef JS_PM
	@$(JS_PM) test -- --coverage
endif
ifdef HAS_RUST
	@cargo tarpaulin --out Xml || echo "cargo-tarpaulin not installed; skipping Rust coverage"
endif

.PHONY: check
check: lint typecheck test ## Run full CI-equivalent checks locally
	@echo "==> All checks passed."

# =============================================================================
##@ Build
# =============================================================================

.PHONY: build
build: ## Build all detected languages
ifdef HAS_PYTHON
	@echo "==> Building Python..."
	@uv build
endif
ifdef JS_PM
	@echo "==> Building JS/TS..."
	@$(JS_PM) run build
endif
ifdef HAS_RUST
	@echo "==> Building Rust (release)..."
	@cargo build --release
endif

# =============================================================================
##@ Docker
# =============================================================================

# Override IMAGE and TAG as needed:
#   make docker-build IMAGE=ghcr.io/org/myproject TAG=v1.2.3
IMAGE ?= $(notdir $(CURDIR))
TAG   ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "latest")

.PHONY: docker-build
docker-build: ## Build Docker image (override IMAGE and TAG vars)
	@docker build -t $(IMAGE):$(TAG) -t $(IMAGE):latest .

.PHONY: docker-run
docker-run: ## Run Docker image locally with .env
	@docker run --rm -it --env-file .env $(IMAGE):$(TAG)

.PHONY: docker-push
docker-push: ## Push Docker image
	@docker push $(IMAGE):$(TAG)
	@docker push $(IMAGE):latest

# =============================================================================
##@ Cleanup
# =============================================================================

.PHONY: clean
clean: ## Remove build artifacts (preserves dependencies)
	@echo "==> Cleaning build artifacts..."
	@rm -rf dist/ build/ out/ coverage/ .coverage htmlcov/ coverage.xml
	@rm -rf .pytest_cache/ .ruff_cache/ .mypy_cache/ .pyright/
	@rm -rf .turbo/ .next/ .nuxt/ .svelte-kit/ .vite/ .parcel-cache/ .tsbuildinfo
	@find . -type d -name __pycache__ -not -path './.git/*' -exec rm -rf {} + 2>/dev/null || true
	@find . -type f -name '*.pyc' -not -path './.git/*' -delete 2>/dev/null || true
ifdef HAS_RUST
	@cargo clean
endif
	@echo "==> Clean complete."

.PHONY: distclean
distclean: clean ## Remove everything (deps, venvs, lockfile caches)
	@echo "==> Removing dependencies and virtual environments..."
	@rm -rf node_modules/ .venv/ venv/ .yarn/ .pnpm-store/
	@rm -rf .terraform/ .terragrunt-cache/
	@rm -rf .tiltbuild/ tilt_modules/
	@echo "==> Distclean complete. Run 'make bootstrap' to rebuild."

# =============================================================================
##@ Info
# =============================================================================

.PHONY: detect
detect: ## Show what languages and tools are detected
	@echo "Python (pyproject.toml):     $(if $(HAS_PYTHON),yes,no)"
	@echo "JS package manager:          $(if $(JS_PM),$(JS_PM),none)"
	@echo "Rust (Cargo.toml):           $(if $(HAS_RUST),yes,no)"
	@echo "Terraform (*.tf):            $(if $(HAS_TF),yes,no)"
	@echo "Docker (Dockerfile/compose): $(if $(HAS_DOCKER),yes,no)"
	@echo "Tilt (Tiltfile):             $(if $(HAS_TILT),yes,no)"
