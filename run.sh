SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
if [ -f $SCRIPT_DIR/mork_ffi/target/release/libmork_ffi.so ]; then
    LD_PRELOAD=$SCRIPT_DIR/mork_ffi/target/release/libmork_ffi.so \
    swipl --stack_limit=8g -g "retractall(silent(_))" -s $SCRIPT_DIR/src/main.pl -- "$@" mork
else
    swipl --stack_limit=8g -g "retractall(silent(_))" -s $SCRIPT_DIR/src/main.pl \
        -- "$@"
fi
