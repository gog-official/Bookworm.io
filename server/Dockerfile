FROM golang:1.27 AS build

WORKDIR /usr/src/gameserver

COPY go.mod go.sum ./
RUN go mod download && go mod verify

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -v -ldflags "-s -w" -o /gameserver/main ./cmd

FROM gcr.io/distroless/static-debian12

WORKDIR /gameserver

COPY --from=build /gameserver/main /gameserver/main

ENV PORT=10000
EXPOSE 10000

CMD ["/gameserver/main", "--config", ".env"]
