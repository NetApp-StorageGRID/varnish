FROM centos
COPY varnish-6.0-plus.repo /etc/yum.repos.d/varnish-6.0-plus.repo
RUN yum -y install epel-release
RUN yum -y install varnish-plus
RUN yum -y install varnish-plus-addon-ssl
COPY default.vcl /etc/varnish/default.vcl
COPY mse.conf /var/lib/mse/mse.conf
COPY example.pem /etc/hitch/testcert.pem
CMD mkfs.mse -f -c /var/lib/mse/mse.conf && /usr/sbin/hitch --config /etc/hitch/hitch.conf && SSL_CERT_FILE=/etc/hitch/testcert.pem /usr/sbin/varnishd -F -a :80 -a :8443,PROXY -s mse,/var/lib/mse/mse.conf -p vsl_mask=+Hash -f /etc/varnish/default.vcl -p http_gzip_support=off