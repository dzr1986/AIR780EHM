FROM maven:3.9-eclipse-temurin-17-alpine AS build
WORKDIR /build
COPY maven-settings.xml /root/.m2/settings.xml
COPY pom.xml .
COPY src ./src
RUN mvn -B package

FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY --from=build /build/target/video-upload.jar app.jar
RUN mkdir -p /app/incoming/dynamic /app/incoming/playback
ENV JAVA_OPTS="-Xms64m -Xmx256m" \
    VIDEO_UPLOAD_DIR=/app/incoming \
    VIDEO_UPLOAD_PORT=7003 \
    VIDEO_UPLOAD_HOST=0.0.0.0
EXPOSE 7003
VOLUME ["/app/incoming"]
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
