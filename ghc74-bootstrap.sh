#!/bin/bash
# Package adaptation: STAGE is the build root, GMP_PREFIX is
# %{_libdir}/gmp612 when this hop still uses the private GMP, and
# HOST_GCC is %{_libdir}/ghc-VER/bin/host-gcc. Install is -j1.
# Build GHC 7.4.2 from its sources with the in-chain GHC 6.12.3.
# Registerised, native code generator, no GHCi, one library way.
# 7.4.2 rejects a boot compiler older than 6.12.
set -euo pipefail

ROOT=${STAGE:?}
R=$ROOT/build/ref-ghc-bootstrap
WORK=$ROOT/build/ghc74-work
TREE=$WORK/src/ghc-7.4.2
PREFIX=$WORK/ghc74-prefix
BOOT=$ROOT/build/ghc612-work/ghc612-prefix
GMP=${GMP_PREFIX:?}
SRC=$ROOT/build/sources/ghc-7.4.2-src.tar.bz2

export TMPDIR=$WORK/tmp
export LD_LIBRARY_PATH="$GMP/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
mkdir -p "$TMPDIR" "$WORK/logs" "$WORK/bin" "$WORK/shipped" "$WORK/src"

exec 9>"$WORK/bootstrap.lock"
flock -n 9 || { printf 'GHC74_FAILED: another bootstrap holds %s\n' "$WORK/bootstrap.lock"; exit 1; }

phase() { printf 'GHC74_PHASE %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail() { printf 'GHC74_FAILED: %s\n' "$*"; exit 1; }
errline() {
	grep -E 'ERR:|error:|Error:|unrecognised|not in scope|Not in scope|Failed' "$1" 2>/dev/null | tail -4 | tr '\n' ' ' | cut -c1-400
}

printf '%s\n' "$$" > "$WORK/bootstrap.pid"
ulimit -s unlimited 2>/dev/null || true
phase "start pid $$"

[ -x "$BOOT/bin/ghc" ] || fail "boot compiler missing: $BOOT/bin/ghc"
ver=$("$BOOT/bin/ghc" --numeric-version | tr -d '[:space:]')
[ "$ver" = "6.12.3" ] || fail "boot numeric-version is '$ver'"
phase "boot compiler 6.12.3"

cat > "$WORK/bin/gcc" <<EOF
#!/bin/bash
GMP="$GMP"
link=1
for a in "\$@"; do
	case "\$a" in
	-c|-E|-S|-M|-MM|-shared|--version|-dumpversion) link=0 ;;
	esac
done
args=(-I"\$GMP/include" -fno-pie "\$@")
if [ "\$link" = 1 ]; then
	args+=(-L"\$GMP/lib" -no-pie -Wl,-rpath,"\$GMP/lib")
fi
exec /usr/bin/gcc "\${args[@]}"
EOF
chmod +x "$WORK/bin/gcc"
mkdir -p "$(dirname "$HOST_GCC")"
/bin/cp -f "$WORK/bin/gcc" "$HOST_GCC"
chmod 755 "$HOST_GCC"

clean=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '\.ghcup' -e '\.cabal' -e '/ghc66-work/' -e '/ghc610-work/' -e '/ghc612-work/' -e '/ghc74-work/' | paste -sd: -)
export PATH="$BOOT/bin:$ROOT/build/happy-1.16-prefix/bin:$ROOT/build/alex-2.1.0-prefix/bin:$WORK/bin:$clean"
export CC="${HOST_GCC:?}"
export CFLAGS="-std=gnu89 -fpermissive -w"
export CPPFLAGS="-I$GMP/include"
export LDFLAGS="-L$GMP/lib -Wl,-rpath,$GMP/lib"
hash -r
command -v ghc | grep -q ghc612-prefix || fail "PATH ghc is $(command -v ghc)"
command -v happy | grep -q happy-1.16-prefix || fail "PATH happy is $(command -v happy)"
command -v alex | grep -q alex-2.1.0-prefix || fail "PATH alex is $(command -v alex)"
command -v gcc | grep -q '/ghc74-work/bin/gcc' || fail "PATH gcc is $(command -v gcc)"

if [ ! -d "$TREE/mk" ]; then
	phase "unpack"
	tar -C "$WORK/src" -xf "$SRC"
fi
[ -d "$TREE/mk" ] || fail "unpack did not produce $TREE"

cd "$TREE"
# The sdist was made from a configured tree. configure rebuilds ghc-pwd
# after deleting dist-boot; remove the shipped binary before anything runs.
if [ -e utils/ghc-pwd/dist-boot ]; then
	phase "drop shipped ghc-pwd"
	rm -rf utils/ghc-pwd/dist-boot
fi

if [ ! -f "$WORK/regen.done" ]; then
	phase "regen parsers"
	if ! SHIPPED="$WORK/shipped" sh "$R/common/regen-parsers.sh" > "$WORK/logs/regen.log" 2>&1; then
		fail "regen-parsers: $(tail -8 "$WORK/logs/regen.log" | tr '\n' ' ' | cut -c1-500)"
	fi
	touch "$WORK/regen.done"
fi

if [ ! -f mk/build.mk ]; then
	phase "build.mk"
	cat > mk/build.mk <<'EOF'
GhcUnregisterised = NO
GhcWithNativeCodeGen = YES
GhcWithInterpreter = NO
GhcWithSMP = NO
GhcLibWays = v
GhcRTSWays =
SplitObjs = NO
HADDOCK_DOCS = NO
HSCOLOUR_SRCS = NO
BUILD_DOCBOOK_HTML = NO
BUILD_DOCBOOK_PS = NO
BUILD_DOCBOOK_PDF = NO
LATEX_DOCS = NO
GhcStage1HcOpts = -O
GhcStage2HcOpts = -O -fasm
GhcLibHcOpts = -O -fasm
SRC_HC_OPTS = -H64m -O -optc-std=gnu89 -optc-fpermissive -optc-w -optc-fwrapv -optc-fno-pie -optl-no-pie
SRC_CC_OPTS += -std=gnu89 -fpermissive -w -fwrapv -fno-pie
SRC_HSC2HS_OPTS += --cflag=-std=gnu89 --cflag=-fpermissive --cflag=-w
SRC_HAPPY_OPTS = -agc --strict +RTS -K64M -H128M -RTS
SRC_ALEX_OPTS = -g +RTS -K64M -RTS
EOF
fi

phase "configure"
if [ ! -f mk/config.mk ]; then
	if ! ./configure --prefix="$PREFIX" --with-ghc="$BOOT/bin/ghc" --with-gcc="${HOST_GCC:?}" \
		CFLAGS="-std=gnu89 -fpermissive -w" > "$WORK/logs/configure.log" 2>&1
	then
		fail "configure: $(errline "$WORK/logs/configure.log") $(tail -6 "$WORK/logs/configure.log" | tr '\n' ' ' | cut -c1-400)"
	fi
fi
grep -q "with-ghc=$BOOT/bin/ghc" config.log || fail "config.log did not record the 6.12.3 boot compiler"
happy_mk=$(grep -E '^HAPPY[[:space:]]*=' mk/config.mk | head -1)
alex_mk=$(grep -E '^ALEX[[:space:]]*=' mk/config.mk | head -1)
phase "config $happy_mk"
phase "config $alex_mk"
printf '%s\n' "$happy_mk" | grep -q happy-1.16-prefix || fail "config.mk HAPPY is $happy_mk"
printf '%s\n' "$alex_mk" | grep -q alex-2.1.0-prefix || fail "config.mk ALEX is $alex_mk"

phase "make"
if ! stdbuf -oL -eL make -j1 > "$WORK/logs/make.log" 2>&1; then
	fail "make: $(tail -8 "$WORK/logs/make.log" | tr '\n' ' ' | cut -c1-500)"
fi
phase "make rc=0"

phase "install"
if ! make install > "$WORK/logs/install.log" 2>&1; then
	fail "install: $(errline "$WORK/logs/install.log")"
fi
iver=$("$PREFIX/bin/ghc" --numeric-version | tr -d '[:space:]')
[ "$iver" = "7.4.2" ] || fail "installed numeric-version '$iver'"
iver2=$("$PREFIX/bin/ghc" --numeric-version | tr -d '[:space:]')
[ "$iver2" = "7.4.2" ] || fail "second numeric-version '$iver2'"
printf '%s\n%s\n' "$iver" "$iver2" > "$WORK/logs/ghc74-version.log"
phase "installed 7.4.2"

phase "T3"
T3=$WORK/test-t3
rm -rf "$T3"
mkdir -p "$T3"
/bin/cp -f "$R/common/test/T3.hs" "$T3/T3.hs"
/bin/cp -f "$R/common/test/GmpZero.hs" "$T3/GmpZero.hs"
(
	cd "$T3"
	"$PREFIX/bin/ghc" -v0 --make T3.hs -o t3 > "$WORK/logs/t3-compile.log" 2>&1
	./t3 > "$WORK/logs/t3.out"
) || fail "T3: $(errline "$WORK/logs/t3-compile.log") $(tail -5 "$WORK/logs/t3.out" 2>/dev/null | tr '\n' ' ')"
cmp -s "$R/common/test/T3.out" "$WORK/logs/t3.out" || fail "T3 output mismatch"
phase "T3 ok"

phase "GmpZero"
(
	cd "$T3"
	"$PREFIX/bin/ghc" -v0 -O --make GmpZero.hs -o gz > "$WORK/logs/gmpzero-compile.log" 2>&1
	./gz > "$WORK/logs/gmpzero.out"
) || fail "GmpZero: $(errline "$WORK/logs/gmpzero-compile.log")"
printf '(2400000,0)\n' | cmp -s - "$WORK/logs/gmpzero.out" || fail "GmpZero output $(cat "$WORK/logs/gmpzero.out")"
phase "GmpZero ok"

phase "cmp generated"
if ! SHIPPED="$WORK/shipped" sh "$R/common/cmp-regenerated.sh" > "$WORK/logs/cmp-regenerated.log" 2>&1; then
	fail "cmp-regenerated: $(tail -12 "$WORK/logs/cmp-regenerated.log" | tr '\n' ' ' | cut -c1-500)"
fi
phase "parsers compared"

printf 'GHC74_DONE installed %s numeric-version %s\n' "$PREFIX/bin/ghc" "$iver"
