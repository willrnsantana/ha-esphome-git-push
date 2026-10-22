ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache git openssh-client gnupg inotify-tools curl jq

COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
