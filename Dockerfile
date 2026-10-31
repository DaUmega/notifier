# notify image: builds the stdlib-only notify.go and runs it alone.
# No shell, no package manager, no other tools in the final image.
# No CA certs: the app makes no outbound requests.
FROM golang:1.23 AS build
WORKDIR /src
COPY notify.go .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /notify notify.go

FROM scratch
COPY --from=build /notify /notify
WORKDIR /data
USER 10001:10001
# The app listens on :47124 by default. That must stay: Docker's
# port publishing forwards to the container's own interface, and
# localhost-only is enforced by manage.sh at publish time.
EXPOSE 47124
ENTRYPOINT ["/notify"]
