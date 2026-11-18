SWIFT = swift build --disable-sandbox
.PHONY: build app install login unlogin checks snapshots clean

build:
	$(SWIFT)

app:
	./scripts/build-app.sh

install: app
	./scripts/install.sh

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
