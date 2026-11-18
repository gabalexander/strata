SWIFT = swift build --disable-sandbox
.PHONY: build app install release login unlogin checks snapshots clean

build:
	$(SWIFT)

app:
	./scripts/build-app.sh

install: app
	./install.sh --app "$(CURDIR)/build/Strata.app"

# Zips build/Strata.app for a GitHub release (the installer downloads Strata-macos-arm64.zip).
release: app
	ditto -c -k --keepParent build/Strata.app build/Strata-macos-arm64.zip
	@echo build/Strata-macos-arm64.zip

login:
	./scripts/shell-login.sh enable

unlogin:
	./scripts/shell-login.sh disable

checks:
	$(SWIFT) --product StrataChecks
	.build/debug/StrataChecks

snapshots:
	$(SWIFT) --product StrataSnapshot
	.build/debug/StrataSnapshot build/snapshots

clean:
	rm -rf build .build
