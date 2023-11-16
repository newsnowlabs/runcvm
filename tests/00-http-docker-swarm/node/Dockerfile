FROM alpine:3.18

RUN apk add --update --no-cache docker bash curl jq iproute2

ADD docker.sh https://raw.githubusercontent.com/newsnowlabs/docker-ingress-routing-daemon/main/docker-ingress-routing-daemon /usr/local/bin/

RUN chmod 755 /usr/local/bin/docker-ingress-routing-daemon

ENTRYPOINT ["docker.sh"]
