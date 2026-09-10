FROM getwud/wud
USER root
# nsenter is required so the command trigger can run host `sb install`
# (the WUD image is Alpine / musl; the host binary will not run here).
RUN apk add --no-cache util-linux
