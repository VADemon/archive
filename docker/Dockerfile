FROM node:10

RUN adduser --disabled-password archivist
RUN git clone https://github.com/VADemon/archive.git /archive

WORKDIR /archive/node

USER root
RUN npm install
USER archivist

WORKDIR /archive/node/worker
CMD ["node", "crawler.js"]
