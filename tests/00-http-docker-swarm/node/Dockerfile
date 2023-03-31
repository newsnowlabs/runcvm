FROM alpine

RUN apk add --update docker bash curl

ADD docker.sh /usr/local/bin/

ENTRYPOINT ["docker.sh"]
