FROM alpine:3.20

ARG SUPERCRONIC_VERSION=v0.2.44
ARG SUPERCRONIC_SHA=6eb0a8e1e6673675dc67668c1a9b6409f79c37bc
ARG SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64

RUN apk add --no-cache openssh-client curl \
 && curl -fsSL -o /usr/local/bin/supercronic "${SUPERCRONIC_URL}" \
 && echo "${SUPERCRONIC_SHA}  /usr/local/bin/supercronic" | sha1sum -c - \
 && chmod +x /usr/local/bin/supercronic \
 && apk del curl

ENTRYPOINT ["/usr/local/bin/supercronic", "-passthrough-logs"]
CMD ["/etc/crontab"]
