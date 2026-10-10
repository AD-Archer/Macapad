# Macapad tasks. `just` lists them. The real work lives in scripts/, so CI can call those directly.

default:
	@just --list

# Run from source (fallback menu bar icon). Other port: just dev 7399
dev port="7317":
	MACAPAD_PORT={{port}} swift run

# Build build/Macapad.app. Set VERSION=1.2.3 to stamp a version
build:
	./scripts/build-app.sh

# Build, copy to ~/Applications and launch
install:
	./scripts/build-app.sh --install

# One-time: self-signed "Macapad Dev" identity, so Accessibility survives rebuilds
cert:
	./scripts/make-signing-cert.sh

# Regenerate Resources/ icons from assets/ (needs Pillow)
icons:
	python3 scripts/make-icons.py

# Serve the docs page with Bonjour + Tailscale discovery on :7318
tester:
	cd tester && pnpm install && pnpm start
