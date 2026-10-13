.PHONY: format
format:
	find . \( -name '*.nim' -o -name '*.nimble' \) -not -path './nimbledeps/*' -not -path './tests/nimbledeps/*' | xargs nph