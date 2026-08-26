#!/usr/bin/env bash
#
# test-servers.sh — the FTP servers the test suite runs against.
#
#   ./scripts/test-servers.sh test    run the suite against them
#   ./scripts/test-servers.sh ci      run it as the CI runner would
#   ./scripts/test-servers.sh up      start them and leave them running
#   ./scripts/test-servers.sh down    stop them
#   ./scripts/test-servers.sh logs    show what they are saying
#
# `test` runs the suite in a container on the servers' own network, and
# that is not a convenience. FTP negotiates transfers by address: a
# passive transfer has the server tell the client where to connect, and
# an active one has the server connect back to the client. A server
# behind published ports names an address the host cannot route to, so
# passive transfers time out and active ones are refused. Sharing a
# network makes the address the server names the address the client can
# reach.
#
# `up` publishes the ports anyway, so `go test` from the host works for
# everything that is not a data transfer.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose="$repo/test-servers/compose.yaml"

command -v docker >/dev/null || {
    echo "docker is not installed. It is what these servers run in —" >&2
    echo "see https://docs.docker.com/get-docker/" >&2
    exit 1
}

# The Go the tests run under.
#
# Deliberately *not* taken from go.mod. That directive is this library's
# compatibility floor — the oldest toolchain it promises to build with —
# and testing only against the floor would never exercise the toolchain
# anyone actually uses. CI runs both; this is the one a developer gets by
# default.
#
# Pinned rather than "latest", so a Go release cannot change what this
# script does without somebody editing this line.
GO_DEFAULT=1.25

go_version() {
    echo "${GO_VERSION:-$GO_DEFAULT}"
}

# The servers must run as whoever owns testroot on this machine, because
# a bind mount carries the host's ownership in. Anything else and writes
# are refused while reads succeed, which reads as a protocol fault rather
# than a permissions one.
export FTP_UID="${FTP_UID:-$(id -u)}"

case "${1:-test}" in
    up)
        GO_VERSION="$(go_version)" docker compose -f "$compose" up -d --build
        echo
        echo "Servers are up. From the host:"
        echo "  pure-ftpd            127.0.0.1:2121   (explicit TLS)"
        echo "  pure-ftpd-implicit   127.0.0.1:2122   (implicit TLS)"
        echo "  proftpd              127.0.0.1:2124"
        echo
        echo "Data transfers need the suite on the same network:"
        echo "  ./scripts/test-servers.sh test"
        ;;
    down)
        docker compose -f "$compose" --profile test down -v
        # The CI-reproduction volume is declared external, so compose
        # will not remove it and it would otherwise outlive the servers
        # that used it.
        docker volume rm -f goftp-testroot-linux >/dev/null 2>&1 || true
        ;;
    logs)
        docker compose -f "$compose" logs "${@:2}"
        ;;
    ci)
        # What CI sees, on a machine that is not CI.
        #
        # macOS remaps ownership across a bind mount, so a container can
        # write to testroot whatever uid it runs as. Linux does not, and
        # a mismatch there refuses every write while allowing every read
        # — which looks like a protocol fault rather than a permissions
        # one, and cost an afternoon once.
        #
        # So testroot goes on a Linux-native volume owned by a uid that
        # is deliberately not this machine's.
        ci_uid="${CI_UID:-1001}"
        echo "Reproducing a runner: testroot owned by uid $ci_uid"

        docker volume rm -f goftp-testroot-linux >/dev/null 2>&1 || true
        docker volume create goftp-testroot-linux >/dev/null
        docker run --rm \
            -v "$repo/testroot":/src:ro \
            -v goftp-testroot-linux:/dst \
            alpine:3 sh -c "cp -a /src/. /dst/ && chown -R $ci_uid:$ci_uid /dst"

        FTP_UID="$ci_uid" GO_VERSION="$(go_version)" docker compose \
            -f "$compose" -f "$repo/test-servers/compose.ci.yaml" up -d --build
        FTP_UID="$ci_uid" GO_VERSION="$(go_version)" docker compose \
            -f "$compose" -f "$repo/test-servers/compose.ci.yaml" --profile test \
            run --rm tests go test "${@:2}" ./...
        ;;
    test)
        GO_VERSION="$(go_version)" docker compose -f "$compose" up -d --build
        # `run` rather than `up`, so the suite's exit status is this
        # script's exit status.
        GO_VERSION="$(go_version)" docker compose -f "$compose" --profile test \
            run --rm tests go test "${@:2}" ./...
        ;;
    *)
        echo "usage: $0 [test|up|down|logs]" >&2
        exit 2
        ;;
esac
