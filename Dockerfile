# syntax=docker/dockerfile:1
FROM swift:6.4.2-noble@sha256:23d9b28ad97fb1cf1999edc3a0cb265ee915ed42299a9344e7173d5a6d2b05f4 AS build
WORKDIR /build
COPY Packages/PollyKit/Package.* Packages/PollyKit/
COPY Packages/PollyKit/Sources/ Packages/PollyKit/Sources/
COPY Packages/PollyKit/Tests/ Packages/PollyKit/Tests/
COPY Packages/PollyWeb/Package.* Packages/PollyWeb/
COPY Packages/PollyWeb/Sources/ Packages/PollyWeb/Sources/
COPY Packages/PollyWeb/Tests/ Packages/PollyWeb/Tests/
ARG TARGETARCH
RUN --mount=type=cache,id=polly-swift-6.4.2-${TARGETARCH},target=/build/Packages/PollyWeb/.build \
    swift build --package-path Packages/PollyWeb -c release --product polly-web \
      --force-resolved-versions --static-swift-stdlib -j 4 \
    && mkdir /staging \
    && cp Packages/PollyWeb/.build/release/polly-web /staging/ \
    && cp -a Packages/PollyWeb/.build/release/PollyWeb_PollyWeb.bundle /staging/ \
    && chmod -R a-w /staging

FROM ubuntu:24.04@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8 AS runtime
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends ca-certificates libcurl4t64 libxml2 tzdata \
    && apt-get clean \
    && useradd --uid 10001 --user-group --no-create-home --home-dir /app polly
WORKDIR /app
COPY --from=build /staging/ /app/
ARG REVISION=unknown
LABEL org.opencontainers.image.title="Polly web" \
      org.opencontainers.image.source="https://github.com/unilynx/maggie" \
      org.opencontainers.image.revision=$REVISION
USER 10001:10001
EXPOSE 8088
ENTRYPOINT ["/app/polly-web"]
CMD ["serve", "--hostname", "0.0.0.0", "--port", "8088"]
