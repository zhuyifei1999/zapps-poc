all: absolute/exe relative/exe

.PHONY: clean
.SECONDARY:
.DELETE_ON_ERROR:

clean:
	rm -f tmp absolute relative

tmp:
	mkdir -p tmp
absolute:
	mkdir -p absolute
relative:
	mkdir -p relative

absolute/lib.so: absolute lib.c
	gcc -shared -o absolute/lib.so lib.c
absolute/exe: absolute exe.c absolute/lib.so
	gcc -fPIC -o absolute/exe -L absolute -l:lib.so -Wl,-rpath=absolute exe.c

relative/ld-linux-x86-64.so.2: relative
	cp $$(gcc --print-file-name=ld-linux-x86-64.so.2) relative/ld-linux-x86-64.so.2
relative/libc.so.6: relative
	cp $$(gcc --print-file-name=libc.so.6) relative/libc.so.6

tmp/zapps-crt0.o: tmp zapps-crt0.S
	gcc -c -o tmp/zapps-crt0.o zapps-crt0.S
tmp/strip_interp: tmp strip_interp.c
	gcc -o tmp/strip_interp strip_interp.c

relative/lib.so: relative lib.c
	gcc -shared -o relative/lib.so lib.c
relative/exe: relative exe.c tmp/strip_interp tmp/zapps-crt0.o relative/lib.so relative/ld-linux-x86-64.so.2 relative/libc.so.6
	# gcc -o relative/exe -L relative -l:lib.so -Wl,-rpath=XORIGIN -Wl,-e_zapps_start -Wl,-Ild-linux-x86-64.so.2 tmp/zapps-crt0.o exe.c
	gcc -o relative/exe -L relative -l:lib.so -Wl,-rpath=XORIGIN -Wl,-e_zapps_start tmp/zapps-crt0.o exe.c
	# gcc -o relative/exe -L relative -l:lib.so -Wl,-rpath=XORIGIN -Wl,-e_zapps_start -Wl,--no-dynamic-linker tmp/zapps-crt0.o exe.c
	# gcc -o relative/exe -L relative -l:lib.so -Wl,-rpath=XORIGIN exe.c
	sed -i '0,/XORIGIN/{s/XORIGIN/$$ORIGIN/}' relative/exe
	tmp/strip_interp relative/exe
