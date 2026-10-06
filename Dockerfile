# Build on Chainguard's Go image, run on Chainguard's static image: no shell, no package manager, non-root.
# Both bases are pinned by digest; Dependabot proposes new digests (see .github/dependabot.yml).
FROM cgr.dev/chainguard/go:latest@sha256:86536f93eb6f89f55d3b6970c5957b332c40da7496d4296ca74c9767250b9a54 AS build
ARG BUILT_BY=dev
WORKDIR /src
COPY app/ .
RUN go test ./... && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.builtBy=${BUILT_BY}" -o /out/hello .

FROM cgr.dev/chainguard/static:latest@sha256:fe55470f22d3259488d9d3739168d8f04da67755f0b69382bc26eda4a7d3d327
COPY --from=build /out/hello /hello
USER 65532
EXPOSE 8080
ENTRYPOINT ["/hello"]
