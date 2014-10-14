DESTDIR=/

REBAR=./rebar

DEPS_PLT=$(CURDIR)/.deps_plt
APPLICATION_DEPS=erts kernel stdlib crypto public_key ssl mnesia sasl asn1 compiler syntax_tools odbc tools

DIALYZER_FLAGS=-Wrace_conditions -Werror_handling

EBIN_DIR=${DESTDIR}/usr/lib/ejabberd/ebin
INCLUDE_DIR=${DESTDIR}/usr/lib/ejabberd/include


.PHONY: compile install get-deps update-deps dialyzer clean


default: compile

compile: get-deps src/* rebar.config rebar
	$(REBAR) compile

install:
	install -d --mode 755 ${EBIN_DIR}
	install -d --mode 755 ${INCLUDE_DIR}
	install -D --mode 644  ebin/*.beam ${EBIN_DIR}
	install -D --mode 644 src/websocket_frame.hrl ${INCLUDE_DIR}

get-deps:
	mkdir -p deps
	if [ ! -d deps/ejabberd ]; then \
		git clone --branch 14.07 https://github.com/processone/ejabberd.git deps/ejabberd; \
		(cd deps/ejabberd; \
			./autogen.sh; \
			./configure --enable-mysql --enable-odbc; \
			mkdir -p deps; \
			for lib in p1_tls p1_stringprep p1_yaml p1_xml esip p1_zlib p1_pam p1_iconv; do \
			  ln -s ../../$$lib deps; \
			done); \
	fi
	$(REBAR) get-deps

update-deps:
	$(REBAR) update-deps
	$(REBAR) compile

dialyzer: $(DEPS_PLT)
	dialyzer --fullpath --plt $(DEPS_PLT) $(DIALYZER_FLAGS) -r ./ebin
	
$(DEPS_PLT): get-deps
	@echo Building local plt at $(DEPS_PLT)
	@echo
	dialyzer --output_plt $(DEPS_PLT) --apps $(APPLICATION_DEPS) --build_plt -r deps/*/ebin/


clean:
	$(REBAR) clean
