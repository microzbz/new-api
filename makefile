FRONTEND_DIR = ./web
BACKEND_DIR = .

.PHONY: all build-frontend start-backend upgrade-aff-commission-mysql e2e-aff-commission package-release

all: build-frontend start-backend

build-frontend:
	@echo "Building frontend..."
	@cd $(FRONTEND_DIR) && bun install && DISABLE_ESLINT_PLUGIN='true' VITE_REACT_APP_VERSION=$(cat VERSION) bun run build

start-backend:
	@echo "Starting backend dev server..."
	@cd $(BACKEND_DIR) && go run main.go &

upgrade-aff-commission-mysql:
	@./scripts/mysql_upgrade_aff_commission.sh

e2e-aff-commission:
	@./scripts/e2e_aff_commission.sh

package-release:
	@./scripts/package_release.sh
