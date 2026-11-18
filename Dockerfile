# syntax=docker/dockerfile:1
FROM swift:6.4.2-noble@sha256:23d9b28ad97fb1cf1999edc3a0cb265ee915ed42299a9344e7173d5a6d2b05f4 AS build
WORKDIR /build
# Compile the dependencies (Vapor, SwiftNIO, swift-crypto…) against empty Polly targets first. This layer only
# changes with the manifests, so a layer cache (such as CI's --cache-from) skips minutes of compiling.
COPY Packages/PollyKit/Package.* Packages/PollyKit/
COPY Packages/PollyWeb/Package.* Packages/PollyWeb/
RUN for target in PollyKit/Sources/PollyKit PollyKit/Tests/PollyKitTests PollyWeb/Sources/PollyWeb \
                  PollyWeb/Sources/PollyWebServer PollyWeb/Tests/PollyWebTests; do \
      mkdir -p "Packages/$target" && touch "Packages/$target/Stub.swift"; \
    done \
    && mkdir Packages/PollyWeb/Sources/PollyWeb/Public \
    && echo 'print("stub")' > Packages/PollyWeb/Sources/PollyWebServer/main.swift \
    && rm Packages/PollyWeb/Sources/PollyWebServer/Stub.swift \
    && swift build --package-path Packages/PollyWeb -c release --product polly-web \
      --force-resolved-versions --static-swift-stdlib -j 4 \
    && rm -r Packages/PollyKit/Sources Packages/PollyKit/Tests Packages/PollyWeb/Sources Packages/PollyWeb/Tests

COPY Packages/PollyKit/Sources/ Packages/PollyKit/Sources/
COPY Packages/PollyKit/Tests/ Packages/PollyKit/Tests/
COPY Packages/PollyWeb/Sources/ Packages/PollyWeb/Sources/
COPY Packages/PollyWeb/Tests/ Packages/PollyWeb/Tests/
# Only the Polly targets compile here. The build directory is removed so it doesn't become a second cached layer.
RUN swift build --package-path Packages/PollyWeb -c release --product polly-web \
      --force-resolved-versions --static-swift-stdlib -j 4 \
    && mkdir /staging \
    && cp Packages/PollyWeb/.build/release/polly-web /staging/ \
    && cp -a Packages/PollyWeb/.build/release/PollyWeb_PollyWeb.bundle /staging/ \
    && chmod -R a-w /staging \
    && rm -r Packages/PollyWeb/.build

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
