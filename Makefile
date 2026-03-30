build:
	rebar3 compile

format:
	treefmt .

test:
	rebar3 eunit
	rebar3 ct

check:
	rebar3 dialyzer

.PHONY: build format test check
