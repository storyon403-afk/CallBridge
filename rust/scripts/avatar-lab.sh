#!/bin/sh
# 本文件的目的：独立形象迁移实验入口；不重建/重启音频 App，不自动开启摄像头。
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root/avatar"
case "${1:-serve}" in
    prepare)
        npm ci --ignore-scripts --no-audit --no-fund
        node scripts/prepare.mjs
        exec node scripts/build.mjs ;;
    build) exec node scripts/build.mjs ;;
    test) npm test; exec node scripts/check-browser.mjs ;;
    serve)
        if [ ! -f ../build/avatar/index.html ]; then
            printf '%s\n' '请先执行 sh rust/scripts/avatar-lab.sh prepare 准备独立测试资源。' >&2
            exit 1
        fi
        exec node scripts/server.mjs ;;
    *) printf '%s\n' '用法：avatar-lab.sh [prepare|build|test|serve]' >&2; exit 2 ;;
esac
