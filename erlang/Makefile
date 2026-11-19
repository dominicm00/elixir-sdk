# Called by rebar3's compile hook and Mix's custom compiler. Requires a C
# compiler and OTP headers. Mix overrides NIF to write into its build's priv/.
ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~ts/erts-~ts/include", [code:root_dir(), erlang:system_info(version)]), halt().')
CC ?= cc
CFLAGS ?= -O2
NIF ?= priv/antithesis_nif.so

$(NIF): c_src/antithesis_nif.c
	mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=c11 -D_GNU_SOURCE -fPIC -shared -Wall -Wextra -I$(ERTS_INCLUDE_DIR) -o $@ $< -ldl -lpthread

clean:
	rm -f $(NIF)

.PHONY: clean
