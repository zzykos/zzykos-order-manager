# syntax=docker/dockerfile:1

FROM maven:3.9-eclipse-temurin-26 AS build
WORKDIR /workspace

COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -q dependency:go-offline

COPY src ./src
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -q package -DskipTests -Djacoco.skip=true \
 && cp target/order-manager-*.jar app.jar

FROM eclipse-temurin:17-jre-alpine AS extract
WORKDIR /extract
COPY --from=build /workspace/app.jar app.jar
RUN java -Djarmode=layertools -jar app.jar extract

FROM eclipse-temurin:17-jre-alpine AS runtime

ARG VERSION=dev
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
LABEL org.opencontainers.image.title="order-manager" \
      org.opencontainers.image.description="Order Manager API - E-commerce (DOY0101)" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}"

RUN apk upgrade --no-cache \
 && addgroup -S -g 10001 appgroup \
 && adduser -S -u 10001 -G appgroup -h /app -s /sbin/nologin appuser

WORKDIR /app

COPY --from=extract --chown=appuser:appgroup /extract/dependencies/ ./
COPY --from=extract --chown=appuser:appgroup /extract/spring-boot-loader/ ./
COPY --from=extract --chown=appuser:appgroup /extract/snapshot-dependencies/ ./
COPY --from=extract --chown=appuser:appgroup /extract/application/ ./

USER appuser

ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError -Djava.security.egd=file:/dev/./urandom" \
    SERVER_PORT=8098

EXPOSE 8098

HEALTHCHECK --interval=15s --timeout=3s --start-period=40s --retries=3 \
  CMD wget -qO- http://127.0.0.1:${SERVER_PORT}/actuator/health/liveness | grep -q '"UP"' || exit 1

ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
