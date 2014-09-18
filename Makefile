DESTDIR=/usr

EBIN_DIR=${DESTDIR}/lib/ejabberd/ebin
INCLUDE_DIR=${DESTDIR}/lib/ejabberd/include

.PHONY: compile
compile: src/*.erl src/*.hrl Emakefile
	mkdir -p ebin
	erl -pa ${DISTDIR}/lib/ejabberd/ebin -make

.PHONY: install
install:
	install -d --mode 755 ${EBIN_DIR}
	install -d --mode 755 ${INCLUDE_DIR}
	install -D --mode 644  ebin/*.beam ${EBIN_DIR}
	install -D --mode 644 src/websocket_frame.hrl ${INCLUDE_DIR}
