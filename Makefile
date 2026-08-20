build:
	rebar3 compile

format:
	treefmt .

test:
	rebar3 eunit
	rebar3 ct

check:
	rebar3 as examples dialyzer

examples:
	rebar3 as examples escriptize
	_build/examples/bin/generate_examples

.PHONY: build format test check examples
