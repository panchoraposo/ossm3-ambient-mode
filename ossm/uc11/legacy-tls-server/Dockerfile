FROM registry.access.redhat.com/ubi7/ubi:7.9

RUN yum -y install openssl \
  && yum clean all \
  && rm -rf /var/cache/yum

COPY run.sh /usr/local/bin/run-legacy-tls.sh
RUN chmod 0755 /usr/local/bin/run-legacy-tls.sh

ENTRYPOINT ["/usr/local/bin/run-legacy-tls.sh"]

