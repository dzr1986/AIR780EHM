FROM maven:3.9-eclipse-temurin-17-alpine AS build
WORKDIR /build
COPY deploy/maven-settings.xml /root/.m2/settings.xml
COPY pom.xml .
COPY src ./src
RUN mvn -B -DskipTests package

FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY --from=build /build/target/ota-server-*.jar app.jar
COPY firmware ./firmware

ENV JAVA_OPTS="-Xms64m -Xmx256m"
EXPOSE 8080

VOLUME ["/app/firmware", "/app/logs"]

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
