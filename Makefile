ROOT := $(CURDIR)

.PHONY: test coverage
test:
	bash scripts/test_lib_env.sh

coverage:
	rm -rf coverage
	kcov --clean --include-pattern=lib-env.sh --exclude-pattern=fake-telnet-server.py coverage bash scripts/test_lib_env.sh
	cp coverage/cobertura.xml coverage.cobertura.xml 2>/dev/null || cp coverage/*/cobertura.xml coverage.cobertura.xml 2>/dev/null || find coverage -name cobertura.xml | head -1 | xargs -I{} cp {} coverage.cobertura.xml
