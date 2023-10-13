FROM alpine:3.18

RUN apk add --update --no-cache docker bash curl jq iproute2

ADD docker.sh /usr/local/bin/

ENTRYPOINT ["docker.sh"]
