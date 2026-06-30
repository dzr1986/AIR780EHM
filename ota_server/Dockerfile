FROM eclipse-temurin:17-jre-alpine

WORKDIR /app

COPY target/ota-server-*.jar app.jar
COPY firmware ./firmware

ENV JAVA_OPTS="-Xms64m -Xmx256m"
EXPOSE 8080

VOLUME ["/app/firmware", "/app/logs"]

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
